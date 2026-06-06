#!/bin/bash
# Verify BGP sessions and route propagation in the namespace lab
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

check "worker1 pod CIDR visible at worker2 (full BGP path)" \
    vtysh_node worker2 "show ip route 10.244.1.0/24"

check "worker2 pod CIDR visible at worker1 (full BGP path)" \
    vtysh_node worker1 "show ip route 10.244.2.0/24"

echo ""
echo "=== Dataplane Ping (pod CIDR → pod CIDR, 4 hops) ==="
# Source must be a BGP-advertised pod IP so the return path exists.
# TTL=61 means: worker→tor→spine→tor→worker (4 decrements from 64)
check "worker2 pod 10.244.2.1 -> worker1 pod 10.244.1.1" \
    ip netns exec worker2 ping -c 2 -W 2 -I 10.244.2.1 10.244.1.1

check "worker1 pod 10.244.1.1 -> worker2 pod 10.244.2.1" \
    ip netns exec worker1 ping -c 2 -W 2 -I 10.244.1.1 10.244.2.1

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
