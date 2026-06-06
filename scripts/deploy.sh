#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== Deploying K8s BGP Lab ==="

if ! command -v containerlab &>/dev/null; then
    echo "ERROR: containerlab not found."
    echo "Install: bash -c \"\$(curl -sL https://get.containerlab.dev)\""
    exit 1
fi

echo "[1/3] Starting topology..."
containerlab deploy --topo topology.yaml --reconfigure

echo "[2/3] Waiting for BGP sessions to establish (20s)..."
sleep 20

echo "[3/3] Running verification..."
bash scripts/verify.sh
