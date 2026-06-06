#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

LAB="k8s-bgp-lab"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=== BGP Session Status ==="
for node in spine1 tor1 tor2 worker1 worker2; do
    echo ""
    echo "--- ${node} ---"
    docker exec "${LAB}-${node}" vtysh -c "show bgp summary" 2>/dev/null \
        | grep -E "^Neighbor|^[0-9]|Total" \
        || echo "  (FRR not ready)"
done

echo ""
echo "=== Route Propagation Checks ==="
check "worker1 pod CIDR (10.244.1.0/24) reaches spine1" \
    docker exec "${LAB}-spine1" vtysh -c "show ip route 10.244.1.0/24"

check "worker2 pod CIDR (10.244.2.0/24) reaches spine1" \
    docker exec "${LAB}-spine1" vtysh -c "show ip route 10.244.2.0/24"

check "worker1 pod CIDR visible from worker2 (cross-worker)" \
    docker exec "${LAB}-worker2" vtysh -c "show ip route 10.244.1.0/24"

check "worker2 pod CIDR visible from worker1 (cross-worker)" \
    docker exec "${LAB}-worker1" vtysh -c "show ip route 10.244.2.0/24"

echo ""
echo "=== Dataplane Reachability ==="
check "worker1 (10.244.1.1) pingable from worker2" \
    docker exec "${LAB}-worker2" ping -c 2 -W 2 10.244.1.1

check "worker2 (10.244.2.1) pingable from worker1" \
    docker exec "${LAB}-worker1" ping -c 2 -W 2 10.244.2.1

echo ""
echo "=== Result: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
