#!/bin/bash
# Open an interactive vtysh session for a namespace node
# Usage: ns-vtysh.sh <node>  e.g.  ns-vtysh.sh spine1
NODE="${1:?Usage: $0 <node>}"
LAB_DIR="/tmp/ns-bgp-lab"
exec ip netns exec "$NODE" /usr/bin/vtysh --vty_socket "$LAB_DIR/$NODE"
