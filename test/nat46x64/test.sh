#!/usr/bin/env bash

PS4='+[\t] '
set -eux

IMG_OWNER=${1:-cilium}
IMG_TAG=${2:-latest}
CILIUM_EXEC="docker exec -t lb-node docker exec -t cilium-lb"

CFG_COMMON=("--enable-ipv4=true" "--enable-ipv6=true" "--devices=eth0" \
            "--datapath-mode=lb-only" "--bpf-lb-dsr-dispatch=ipip" \
            "--bpf-lb-mode=snat" "--enable-nat46x64-gateway=true")

TXT_XDP_MAGLEV="Mode:XDP\tAlgorithm:Maglev\tRecorder:Disabled"
CFG_XDP_MAGLEV=("--bpf-lb-acceleration=native" "--bpf-lb-algorithm=maglev")

TXT_TC__MAGLEV="Mode:TC \tAlgorithm:Maglev\tRecorder:Disabled"
CFG_TC__MAGLEV=("--bpf-lb-acceleration=disabled" "--bpf-lb-algorithm=maglev")

TXT_TC__RANDOM="Mode:TC \tAlgorithm:Random\tRecorder:Disabled"
CFG_TC__RANDOM=("--bpf-lb-acceleration=disabled" "--bpf-lb-algorithm=random")

TXT_XDP_MAGLEV_RECORDER="Mode:XDP\tAlgorithm:Maglev\tRecorder:Enabled"

CMD="$0"

function trace_offset {
    local line_no=$1
    shift
    >&2 echo -e "\e[92m[${CMD}:${line_no}]\t$*\e[0m"
}

# $1 - Text to represent the install, used for logging
# $2+ - configuration options to pass to Cilium on startup
function cilium_install {
    local cfg_text=$1
    shift

    trace_offset "${BASH_LINENO[*]}" "Installing Cilium with $cfg_text"
    docker exec -t lb-node docker rm -f cilium-lb || true
    docker exec -t lb-node \
        docker run --name cilium-lb -td \
            -v /sys/fs/bpf:/sys/fs/bpf \
            -v /lib/modules:/lib/modules \
            --privileged=true \
            --network=host \
            "quay.io/${IMG_OWNER}/cilium-ci:${IMG_TAG}" \
            cilium-agent "${CFG_COMMON[@]}" "$@"
    while ! ${CILIUM_EXEC} cilium-dbg status; do sleep 3; done
    sleep 1
}

function assert_maglev_maps_sane {
    MAG_V4=$(${CILIUM_EXEC} cilium-dbg bpf lb maglev list -o=jsonpath='{.\[1\]/v4}' | tr -d '\r')
    MAG_V6=$(${CILIUM_EXEC} cilium-dbg bpf lb maglev list -o=jsonpath='{.\[1\]/v6}' | tr -d '\r')
    if [ -n "$MAG_V4" ] || [ -z "$MAG_V6" ]; then
        echo "Invalid content of Maglev table!"
        ${CILIUM_EXEC} cilium-dbg bpf lb maglev list
        exit 1
    fi
}

function initialize_docker_env {
    # With Docker-in-Docker we create two nodes:
    #
    # * "lb-node" runs cilium in the LB-only mode.
    # * "nginx" runs the nginx server.

    trace_offset "${BASH_LINENO[*]}" "Initializing docker environment..."

    docker network create --subnet="172.12.42.0/24,2001:db8:1::/64" --ipv6 cilium-l4lb
    docker run --privileged --name lb-node -d \
        --network cilium-l4lb -v /lib/modules:/lib/modules \
        docker:dind
    docker exec -t lb-node mount bpffs /sys/fs/bpf -t bpf
    docker run --name nginx -d --network cilium-l4lb nginx

    # Wait until Docker is ready in the lb-node node
    while ! docker exec -t lb-node docker ps >/dev/null; do sleep 1; done

    # Disable TX and RX csum offloading, as veth does not support it. Otherwise,
    # the forwarded packets by the LB to the worker node will have invalid csums.
    IFIDX=$(docker exec -i lb-node \
        /bin/sh -c 'echo $(( $(ip -o l show eth0 | awk "{print $1}" | cut -d: -f1) ))')
    LB_VETH_HOST=$(ip -o l | grep "if$IFIDX" | awk '{print $2}' | cut -d@ -f1)
    ethtool -K "$LB_VETH_HOST" rx off tx off
}

function force_cleanup {
    ${CILIUM_EXEC} cilium-dbg service delete 1 || true
    ${CILIUM_EXEC} cilium-dbg service delete 2 || true
    ip -4 r d "10.0.0.4/32" || true
    ip -6 r d "fd00:cafe::1" || true
    docker rm -f lb-node || true
    docker rm -f nginx || true
    docker network rm cilium-l4lb || true
}

function cleanup {
    if tty -s; then
        read -p "Hold the environment for debugging? [y/n]" -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    force_cleanup
}

# $1 - target service, for example "[fd00:dead:beef:15:bad::1]:80"
function wait_service_ready {
    # Try and sleep until the LB2 comes up, seems to be no other way to detect when the service is ready.
    set +e
    for i in $(seq 1 10); do
        curl -s -o /dev/null "${1}" && break
        sleep 1
    done
    set -e
}

force_cleanup 2>&1 >/dev/null
initialize_docker_env
trap cleanup EXIT

cilium_install "$TXT_TC__MAGLEV" ${CFG_TC__MAGLEV[@]}

NGINX_PID=$(docker inspect nginx -f '{{ .State.Pid }}')
WORKER_IP4=$(nsenter -t "$NGINX_PID" -n ip -o -4 a s eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
WORKER_IP6=$(nsenter -t "$NGINX_PID" -n ip -o -6 a s eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1)

# NAT 4->6 test suite (services)
################################

LB_VIP="10.0.0.4"

${CILIUM_EXEC} \
    cilium-dbg service update --id 1 --frontend "${LB_VIP}:80" --backends "[${WORKER_IP6}]:80" --k8s-load-balancer

SVC_BEFORE=$(${CILIUM_EXEC} cilium-dbg service list)

${CILIUM_EXEC} cilium-dbg bpf lb list

assert_maglev_maps_sane

LB_NODE_IP=$(docker exec -t lb-node ip -o -4 a s eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
ip r a "${LB_VIP}/32" via "$LB_NODE_IP"

# Issue 10 requests to LB
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_VIP}:80" || (echo "Failed $i"; exit 1)
done

cilium_install "$TXT_XDP_MAGLEV" ${CFG_XDP_MAGLEV[@]}

# Check that restoration went fine. Note that we currently cannot do runtime test
# as veth + XDP is broken when switching protocols. Needs something bare metal.
SVC_AFTER=$(${CILIUM_EXEC} cilium-dbg service list)

${CILIUM_EXEC} cilium-dbg bpf lb list

[ "$SVC_BEFORE" != "$SVC_AFTER" ] && exit 1

cilium_install "$TXT_TC__MAGLEV" ${CFG_TC__MAGLEV[@]}

# Check that curl still works after restore
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_VIP}:80" || (echo "Failed $i"; exit 1)
done

cilium_install "$TXT_TC__RANDOM" ${CFG_TC__RANDOM[@]}

# Check that curl also works for random selection
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_VIP}:80" || (echo "Failed $i"; exit 1)
done

# Add another IPv6->IPv6 service and reuse backend

LB_ALT="fd00:dead:beef:15:bad::1"

${CILIUM_EXEC} \
    cilium-dbg service update --id 2 --frontend "[${LB_ALT}]:80" --backends "[${WORKER_IP6}]:80" --k8s-load-balancer

${CILIUM_EXEC} cilium-dbg service list
${CILIUM_EXEC} cilium-dbg bpf lb list

LB_NODE_IP=$(docker exec lb-node ip -o -6 a s eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
ip -6 r a "${LB_ALT}/128" via "$LB_NODE_IP"

# Issue 10 requests to LB1
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_VIP}:80" || (echo "Failed $i"; exit 1)
done

wait_service_ready "[${LB_ALT}]:80"

# Issue 10 requests to LB2
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_ALT}]:80" || (echo "Failed $i"; exit 1)
done

# Check if restore for both is proper and that this also works
# under nat46x64-gateway enabled.

cilium_install "$TXT_TC__MAGLEV" ${CFG_TC__MAGLEV[@]}

# Issue 10 requests to LB1
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_VIP}:80" || (echo "Failed $i"; exit 1)
done

# Issue 10 requests to LB2
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_ALT}]:80" || (echo "Failed $i"; exit 1)
done

${CILIUM_EXEC} cilium-dbg service delete 1
${CILIUM_EXEC} cilium-dbg service delete 2

# NAT 6->4 test suite (services)
################################

LB_VIP="fd00:cafe::1"

${CILIUM_EXEC} \
    cilium-dbg service update --id 1 --frontend "[${LB_VIP}]:80" --backends "${WORKER_IP4}:80" --k8s-load-balancer

SVC_BEFORE=$(${CILIUM_EXEC} cilium-dbg service list)

${CILIUM_EXEC} cilium-dbg bpf lb list

assert_maglev_maps_sane

LB_NODE_IP=$(docker exec -t lb-node ip -o -6 a s eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
ip -6 r a "${LB_VIP}/128" via "$LB_NODE_IP"

# Issue 10 requests to LB
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_VIP}]:80" || (echo "Failed $i"; exit 1)
done

cilium_install "$TXT_XDP_MAGLEV" ${CFG_XDP_MAGLEV[@]}

# Check that restoration went fine. Note that we currently cannot do runtime test
# as veth + XDP is broken when switching protocols. Needs something bare metal.
SVC_AFTER=$(${CILIUM_EXEC} cilium-dbg service list)

${CILIUM_EXEC} cilium-dbg bpf lb list

[ "$SVC_BEFORE" != "$SVC_AFTER" ] && exit 1

cilium_install "$TXT_TC__MAGLEV" ${CFG_TC__MAGLEV[@]}

# Check that curl still works after restore
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_VIP}]:80" || (echo "Failed $i"; exit 1)
done

cilium_install "$TXT_TC__RANDOM" ${CFG_TC__RANDOM[@]}

# Check that curl also works for random selection
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_VIP}]:80" || (echo "Failed $i"; exit 1)
done

# Add another IPv4->IPv4 service and reuse backend

LB_ALT="10.0.0.8"

${CILIUM_EXEC} \
    cilium-dbg service update --id 2 --frontend "${LB_ALT}:80" --backends "${WORKER_IP4}:80" --k8s-load-balancer

${CILIUM_EXEC} cilium-dbg service list
${CILIUM_EXEC} cilium-dbg bpf lb list

LB_NODE_IP=$(docker exec -t lb-node ip -o -4 a s eth0 | awk '{print $4}' | cut -d/ -f1 | head -n1)
ip r a "${LB_ALT}/32" via "$LB_NODE_IP"

# Issue 10 requests to LB1
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_VIP}]:80" || (echo "Failed $i"; exit 1)
done

wait_service_ready "${LB_ALT}:80"

# Issue 10 requests to LB2
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_ALT}:80" || (echo "Failed $i"; exit 1)
done

# Check if restore for both is proper and that this also works
# under nat46x64-gateway enabled.

cilium_install "$TXT_TC__MAGLEV" ${CFG_TC__MAGLEV[@]}

# Issue 10 requests to LB1
for i in $(seq 1 10); do
    curl -s -o /dev/null "[${LB_VIP}]:80" || (echo "Failed $i"; exit 1)
done

# Issue 10 requests to LB2
for i in $(seq 1 10); do
    curl -s -o /dev/null "${LB_ALT}:80" || (echo "Failed $i"; exit 1)
done

${CILIUM_EXEC} cilium-dbg service delete 1
${CILIUM_EXEC} cilium-dbg service delete 2

# Misc compilation tests
########################

# Install Cilium as standalone L4LB & NAT46/64 GW: tc
cilium_install \
    --bpf-lb-algorithm=maglev \
    --bpf-lb-acceleration=disabled

# Install Cilium as standalone L4LB & NAT46/64 GW: XDP
cilium_install \
    --bpf-lb-algorithm=maglev \
    --bpf-lb-acceleration=native

# Install Cilium as standalone L4LB & NAT46/64 GW: restore
cilium_install \
    --bpf-lb-algorithm=maglev \
    --bpf-lb-acceleration=disabled

# NAT test suite & PCAP recorder
################################

# Install Cilium as standalone L4LB: XDP/Maglev/SNAT/Recorder
cilium_install "$TXT_XDP_MAGLEV_RECORDER" \
    --bpf-lb-algorithm=maglev \
    --bpf-lb-acceleration=native \
    --enable-recorder=true

# Trigger recompilation with 32 IPv4 filter masks
${CILIUM_EXEC} \
    cilium-dbg recorder update --id 1 --caplen 100 \
        --filters="2.2.2.2/0 0 1.1.1.1/32 80 TCP,\
2.2.2.2/1 0 1.1.1.1/32 80 TCP,\
2.2.2.2/2 0 1.1.1.1/31 80 TCP,\
2.2.2.2/3 0 1.1.1.1/30 80 TCP,\
2.2.2.2/4 0 1.1.1.1/29 80 TCP,\
2.2.2.2/5 0 1.1.1.1/28 80 TCP,\
2.2.2.2/6 0 1.1.1.1/27 80 TCP,\
2.2.2.2/7 0 1.1.1.1/26 80 TCP,\
2.2.2.2/8 0 1.1.1.1/25 80 TCP,\
2.2.2.2/9 0 1.1.1.1/24 80 TCP,\
2.2.2.2/10 0 1.1.1.1/23 80 TCP,\
2.2.2.2/11 0 1.1.1.1/22 80 TCP,\
2.2.2.2/12 0 1.1.1.1/21 80 TCP,\
2.2.2.2/13 0 1.1.1.1/20 80 TCP,\
2.2.2.2/14 0 1.1.1.1/19 80 TCP,\
2.2.2.2/15 0 1.1.1.1/18 80 TCP,\
2.2.2.2/16 0 1.1.1.1/17 80 TCP,\
2.2.2.2/17 0 1.1.1.1/16 80 TCP,\
2.2.2.2/18 0 1.1.1.1/15 80 TCP,\
2.2.2.2/19 0 1.1.1.1/14 80 TCP,\
2.2.2.2/20 0 1.1.1.1/13 80 TCP,\
2.2.2.2/21 0 1.1.1.1/12 80 TCP,\
2.2.2.2/22 0 1.1.1.1/11 80 TCP,\
2.2.2.2/23 0 1.1.1.1/10 80 TCP,\
2.2.2.2/24 0 1.1.1.1/9 80 TCP,\
2.2.2.2/25 0 1.1.1.1/8 80 TCP,\
2.2.2.2/26 0 1.1.1.1/7 80 TCP,\
2.2.2.2/27 0 1.1.1.1/6 80 TCP,\
2.2.2.2/28 0 1.1.1.1/5 80 TCP,\
2.2.2.2/29 0 1.1.1.1/4 80 TCP,\
2.2.2.2/30 0 1.1.1.1/3 80 TCP,\
2.2.2.2/31 0 1.1.1.1/2 80 TCP,\
2.2.2.2/32 0 1.1.1.1/1 80 TCP,\
2.2.2.2/32 0 1.1.1.1/0 80 TCP"

# Trigger recompilation with 32 IPv6 filter masks
${CILIUM_EXEC} \
    cilium-dbg recorder update --id 2 --caplen 100 \
        --filters="f00d::1/0 80 cafe::/128 0 UDP,\
f00d::1/1 80 cafe::/127 0 UDP,\
f00d::1/2 80 cafe::/126 0 UDP,\
f00d::1/3 80 cafe::/125 0 UDP,\
f00d::1/4 80 cafe::/124 0 UDP,\
f00d::1/5 80 cafe::/123 0 UDP,\
f00d::1/6 80 cafe::/122 0 UDP,\
f00d::1/7 80 cafe::/121 0 UDP,\
f00d::1/8 80 cafe::/120 0 UDP,\
f00d::1/9 80 cafe::/119 0 UDP,\
f00d::1/10 80 cafe::/118 0 UDP,\
f00d::1/11 80 cafe::/117 0 UDP,\
f00d::1/12 80 cafe::/116 0 UDP,\
f00d::1/13 80 cafe::/115 0 UDP,\
f00d::1/14 80 cafe::/114 0 UDP,\
f00d::1/15 80 cafe::/113 0 UDP,\
f00d::1/16 80 cafe::/112 0 UDP,\
f00d::1/17 80 cafe::/111 0 UDP,\
f00d::1/18 80 cafe::/110 0 UDP,\
f00d::1/19 80 cafe::/109 0 UDP,\
f00d::1/20 80 cafe::/108 0 UDP,\
f00d::1/21 80 cafe::/107 0 UDP,\
f00d::1/22 80 cafe::/106 0 UDP,\
f00d::1/23 80 cafe::/105 0 UDP,\
f00d::1/24 80 cafe::/104 0 UDP,\
f00d::1/25 80 cafe::/103 0 UDP,\
f00d::1/26 80 cafe::/102 0 UDP,\
f00d::1/27 80 cafe::/101 0 UDP,\
f00d::1/28 80 cafe::/100 0 UDP,\
f00d::1/29 80 cafe::/99 0 UDP,\
f00d::1/30 80 cafe::/98 0 UDP,\
f00d::1/31 80 cafe::/97 0 UDP,\
f00d::1/32 80 cafe::/96 0 UDP,\
f00d::1/32 80 cafe::/0 0 UDP"

${CILIUM_EXEC} cilium-dbg recorder list
${CILIUM_EXEC} cilium-dbg bpf recorder list
${CILIUM_EXEC} cilium-dbg recorder delete 1
${CILIUM_EXEC} cilium-dbg recorder delete 2
${CILIUM_EXEC} cilium-dbg recorder list

echo "YAY!"
