#!/bin/bash
echo "=== Tearing down namespace BGP lab ==="
for node in spine1 tor1 tor2 worker1 worker2 external; do
    pkill -f "bgpd.*ns-bgp-lab/$node"  2>/dev/null || true
    pkill -f "zebra.*ns-bgp-lab/$node" 2>/dev/null || true
    ip netns del "$node" 2>/dev/null || true
done
# Remove any leftover host-side veth pairs (deleting one end removes both)
for link in vlsp1tr1 vlsp1tr2 vltr1wk1 vltr2wk2 vlsp1ext; do
    ip link delete "${link}a" 2>/dev/null || true
done
rm -rf /tmp/ns-bgp-lab
echo "Done."
