#!/bin/bash
set -euo pipefail

LAB="esi-datacenter"
C="docker exec clab-${LAB}"

activate() {
  # Add a VRF-local default only during BAC activation.
  # In this lab, this acts as the orientation route switch without touching
  # other themes' ownership.
  $C-leaf-01 vtysh \
    -c "configure terminal" \
    -c "ip route 0.0.0.0/0 Null0 vrf VRF-ORIENTATION" \
    -c "end"
  echo "[INFO] VRF-ORIENTATION activation complete"
}

deactivate() {
  $C-leaf-01 vtysh \
    -c "configure terminal" \
    -c "no ip route 0.0.0.0/0 Null0 vrf VRF-ORIENTATION" \
    -c "end"
  echo "[INFO] VRF-ORIENTATION deactivation complete"
}

status() {
  $C-leaf-01 ip route show vrf VRF-ORIENTATION || true
}

case "${1:-status}" in
  --activate) activate ;;
  --deactivate) deactivate ;;
  --status|status) status ;;
  *)
    echo "Usage: $0 [--activate|--deactivate|--status]"
    exit 2
    ;;
esac
