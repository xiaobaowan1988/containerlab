#!/bin/bash
# Namespace-based BGP lab — equivalent to Containerlab but needs only FRR + iproute2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="$SCRIPT_DIR/../configs"
LAB_DIR="/tmp/ns-bgp-lab"
FRRD="/usr/lib/frr"
NODES="spine1 tor1 tor2 worker1 worker2"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root (sudo $0)"
command -v ip &>/dev/null || die "iproute2 not found (apt install iproute2)"
[[ -x "$FRRD/zebra" ]] || die "FRR not found (apt install frr)"

echo "=== Namespace BGP Lab (spine / ToR / worker / external) ==="

# ── 1. Directories ────────────────────────────────────────────────────────────
mkdir -p "$LAB_DIR"
for node in $NODES external; do install -d -o frr -g frr "$LAB_DIR/$node"; done

# ── 2. Namespaces ─────────────────────────────────────────────────────────────
echo "[1/5] Creating network namespaces..."
for ns in $NODES external; do
    ip netns add "$ns" 2>/dev/null || true
    ip netns exec "$ns" ip link set lo up
done

# ── 3. Veth wiring ────────────────────────────────────────────────────────────
echo "[2/5] Wiring veth pairs..."
# Short unique IDs so link names don't collide (Linux iface names max 15 chars)
node_id() { case "$1" in spine1) echo sp1;; tor1) echo tr1;; tor2) echo tr2;; worker1) echo wk1;; worker2) echo wk2;; esac; }
wire() {
    local nsA=$1 ifA=$2 nsB=$3 ifB=$4
    local tmp="vl$(node_id "$nsA")$(node_id "$nsB")"  # e.g. vlsp1tr1
    ip link add "${tmp}a" type veth peer name "${tmp}b"
    ip link set "${tmp}a" netns "$nsA"
    ip link set "${tmp}b" netns "$nsB"
    ip netns exec "$nsA" ip link set "${tmp}a" name "$ifA"
    ip netns exec "$nsB" ip link set "${tmp}b" name "$ifB"
    ip netns exec "$nsA" ip link set "$ifA" up
    ip netns exec "$nsB" ip link set "$ifB" up
}
# topology: spine1 – tor1 – worker1
#                  – tor2 – worker2
#                  – external (AS65200, BGP peer)
wire spine1 eth1  tor1    eth1   # vlsp1tr1a/b
wire spine1 eth2  tor2    eth1   # vlsp1tr2a/b
wire tor1   eth2  worker1 eth1   # vltr1wk1a/b
wire tor2   eth2  worker2 eth1   # vltr2wk2a/b

# external connects to spine1 on eth3 (manual link — no node_id helper)
ip link add vlsp1exta type veth peer name vlsp1extb
ip link set vlsp1exta netns spine1
ip link set vlsp1extb netns external
ip netns exec spine1   ip link set vlsp1exta name eth3
ip netns exec external ip link set vlsp1extb name eth0
ip netns exec spine1   ip addr add 192.168.100.1/24 dev eth3
ip netns exec external ip addr add 192.168.100.2/24 dev eth0
ip netns exec spine1   ip link set eth3 up
ip netns exec external ip link set eth0 up

# ── 4. FRR daemons ───────────────────────────────────────────────────────────
echo "[3/5] Starting FRR daemons (fabric nodes)..."
start_node() {
    local node=$1
    local rd="$LAB_DIR/$node"
    local cfg="$CFG_DIR/$node/frr.conf"

    # --vty_socket takes a *directory*; daemon creates <dir>/daemonname.vty inside it
    ip netns exec "$node" "$FRRD/zebra" \
        --daemon \
        --config_file "$cfg" \
        --pid_file    "$rd/zebra.pid" \
        --socket      "$rd/zserv.api" \
        --vty_socket  "$rd" \
        --log stdout 2>>"$rd/zebra.log" || true

    sleep 0.5

    ip netns exec "$node" "$FRRD/bgpd" \
        --daemon \
        --config_file "$cfg" \
        --pid_file    "$rd/bgpd.pid" \
        --socket      "$rd/zserv.api" \
        --vty_socket  "$rd" \
        --log stdout 2>>"$rd/bgpd.log" || true

    echo "  ✓ $node"
}
for node in $NODES; do start_node "$node"; done

echo "[4/5] Starting FRR on external (AS 65200)..."
start_node external
# external advertises 192.168.100.0/24 into the fabric via BGP —
# no static routes needed anywhere; every node learns it dynamically.

echo "[5/6] Creating pod namespaces (Calico-style /32 + veth + proxy-neigh)..."
# Each pod is a separate network namespace connected to its worker via veth.
# The pod routes its default via 169.254.1.1 (link-scope, no subnet).
# The host-side veth holds 169.254.1.1/32 and a /32 host route → pod.
# This mirrors how Calico BGP actually wires pods to the fabric.

setup_pod() {
    local pod_ns=$1 worker_ns=$2 pod_ip=$3
    local hlink="veth${pod_ns}h" plink="veth${pod_ns}p"

    ip netns add "$pod_ns" 2>/dev/null || true
    ip link add "$hlink" type veth peer name "$plink"
    ip link set "$plink" netns "$pod_ns"
    ip link set "$hlink" netns "$worker_ns"

    # pod side: /32 address, default via 169.254.1.1
    ip netns exec "$pod_ns" ip link set lo up
    ip netns exec "$pod_ns" ip link set "$plink" name eth0
    ip netns exec "$pod_ns" ip addr add "${pod_ip}/32" dev eth0
    ip netns exec "$pod_ns" ip link set eth0 up
    ip netns exec "$pod_ns" ip route add 169.254.1.1/32 dev eth0 scope link
    ip netns exec "$pod_ns" ip route add default via 169.254.1.1

    # host side: 169.254.1.1/32 as gateway + /32 host route to pod
    ip netns exec "$worker_ns" ip link set "$hlink" up
    ip netns exec "$worker_ns" ip addr add 169.254.1.1/32 dev "$hlink"
    ip netns exec "$worker_ns" ip neighbor add proxy 169.254.1.1 dev "$hlink"
    ip netns exec "$worker_ns" ip route add "${pod_ip}/32" dev "$hlink"

    echo "  ✓ $pod_ns ($pod_ip) on $worker_ns"
}
setup_pod w1pod1 worker1 10.244.1.2
setup_pod w2pod1 worker2 10.244.2.2

echo "[6/6] Waiting for all BGP sessions to establish (25s)..."
sleep 25

echo ""
echo "Lab is up. Run:  make ns-verify"
echo "Inspect a node:  bash scripts/ns-vtysh.sh spine1"
echo "Inspect external: bash scripts/ns-vtysh.sh external"
