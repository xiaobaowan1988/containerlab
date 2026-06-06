#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "=== Tearing down K8s BGP Lab ==="
containerlab destroy --topo topology.yaml --cleanup
echo "Done."
