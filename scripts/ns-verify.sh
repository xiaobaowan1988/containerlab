#!/bin/bash
# Verify BGP sessions, route propagation, and dataplane reachability
set -euo pipefail

LAB_DIR="/tmp/ns-bgp-lab"
NODES="spine1 tor1 tor2 worker1 worker2"
PASS=0; FAIL=0

vtysh_node() {
    local node=$1; shift
    ip netns exec "$node" /usr/bin/vtysh \
        --vty_socket "$LAB_DIR/$node" \
        -c "$@" 2>/dev/null
}

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        printf "  [PASS] %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$desc"
        FAIL=$((FAIL + 1))
    fi
}

# check_fail: passes when the command FAILS (expected-unreachable tests)
check_fail() {
    local desc="$1"; shift
    if ! "$@" &>/dev/null; then
        printf "  [PASS] %s\n" "$desc"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$desc (expected unreachable, but succeeded)"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== BGP Session Status ==="
for node in $NODES; do
    echo ""
    echo "--- $node ---"
    vtysh_node "$node" "show bgp summary" \
        | grep -E "^Neighbor|^[a-z].*\(|Total number|router identifier" \
        || echo "  (not ready)"
done

echo ""
echo "=== Route Propagation ==="
check "worker1 pod CIDR (10.244.1.0/24) visible at spine1" \
    vtysh_node spine1 "show ip route 10.244.1.0/24"

check "worker2 pod CIDR (10.244.2.0/24) visible at spine1" \
    vtysh_node spine1 "show ip route 10.244.2.0/24"

check "worker1 pod CIDR visible at worker2 (full BGP path, 4 AS hops)" \
    vtysh_node worker2 "show ip route 10.244.1.0/24"

check "worker2 pod CIDR visible at worker1 (full BGP path, 4 AS hops)" \
    vtysh_node worker1 "show ip route 10.244.2.0/24"

echo ""
echo "=== Dataplane: pod → pod (TTL should be 61, 4 hops) ==="
check "worker2 pod 10.244.2.1 → worker1 pod 10.244.1.1" \
    ip netns exec worker2 ping -c 2 -W 2 -I 10.244.2.1 10.244.1.1

check "worker1 pod 10.244.1.1 → worker2 pod 10.244.2.1" \
    ip netns exec worker1 ping -c 2 -W 2 -I 10.244.1.1 10.244.2.1

echo ""
echo "=== Dataplane: pod → node (BGP-advertised loopbacks) ==="
# Loopbacks are advertised in BGP — full fabric routing applies
check "worker2 pod → worker1 loopback (10.255.0.4)" \
    ip netns exec worker2 ping -c 2 -W 2 -I 10.244.2.1 10.255.0.4

check "worker1 pod → spine1 loopback (10.255.0.1)" \
    ip netns exec worker1 ping -c 2 -W 2 -I 10.244.1.1 10.255.0.1

echo ""
echo "=== Dataplane: pod → p-t-p link IPs (NOT in BGP) ==="
# /31 link subnet on the same segment is reachable (direct ARP), cross-segment is not
check "worker1 pod → tor1 eth2 10.0.1.0  [direct /31, TTL=64]" \
    ip netns exec worker1 ping -c 2 -W 2 -I 10.244.1.1 10.0.1.0

check_fail "worker1 pod → tor1 eth1 10.0.0.1  [correctly unreachable — not in BGP]" \
    ip netns exec worker1 ping -c 2 -W 2 -I 10.244.1.1 10.0.0.1

echo ""
echo "=== Dataplane: external (192.168.100.2) → pod ==="
# Return path needs 192.168.100.0/24 on every hop; deploy script installs static routes.
check "external → worker1 pod 10.244.1.1  [3 hops: external→spine→tor→worker, TTL=62]" \
    ip netns exec external ping -c 2 -W 2 10.244.1.1

check "external → worker2 pod 10.244.2.1" \
    ip netns exec external ping -c 2 -W 2 10.244.2.1

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
