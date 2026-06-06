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

echo "=== Namespace BGP Lab (spine / ToR / worker) ==="

# ── 1. Directories ────────────────────────────────────────────────────────────
mkdir -p "$LAB_DIR"
for node in $NODES; do install -d -o frr -g frr "$LAB_DIR/$node"; done

# ── 2. Namespaces ─────────────────────────────────────────────────────────────
echo "[1/4] Creating network namespaces..."
for ns in $NODES; do
    ip netns add "$ns" 2>/dev/null || true
    ip netns exec "$ns" ip link set lo up
done

# ── 3. Veth wiring ────────────────────────────────────────────────────────────
echo "[2/4] Wiring veth pairs..."
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
wire spine1 eth1  tor1    eth1   # vlsp1tr1a/b
wire spine1 eth2  tor2    eth1   # vlsp1tr2a/b
wire tor1   eth2  worker1 eth1   # vltr1wk1a/b
wire tor2   eth2  worker2 eth1   # vltr2wk2a/b

# ── 4. FRR daemons ───────────────────────────────────────────────────────────
echo "[3/4] Starting FRR daemons..."
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

echo "[4/4] Setting up external test node..."
ip netns add external 2>/dev/null || true
ip netns exec external ip link set lo up
ip link add vlsp1exta type veth peer name vlsp1extb
ip link set vlsp1exta netns spine1
ip link set vlsp1extb netns external
ip netns exec spine1   ip link set vlsp1exta name eth3
ip netns exec external ip link set vlsp1extb name eth0
ip netns exec spine1   ip addr add 192.168.100.1/24 dev eth3
ip netns exec external ip addr add 192.168.100.2/24 dev eth0
ip netns exec spine1   ip link set eth3 up
ip netns exec external ip link set eth0 up
# Return routes: external's /24 must be known by all nodes on the return path
ip netns exec external ip route add 10.244.0.0/16   via 192.168.100.1
ip netns exec worker1  ip route add 192.168.100.0/24 via 10.0.1.0
ip netns exec worker2  ip route add 192.168.100.0/24 via 10.0.1.2
ip netns exec tor1     ip route add 192.168.100.0/24 via 10.0.0.0
ip netns exec tor2     ip route add 192.168.100.0/24 via 10.0.0.2

echo "[5/5] Waiting for BGP sessions to establish (20s)..."
sleep 20

echo ""
echo "Lab is up. Run:  make ns-verify"
echo "Inspect a node:  bash scripts/ns-vtysh.sh spine1"
