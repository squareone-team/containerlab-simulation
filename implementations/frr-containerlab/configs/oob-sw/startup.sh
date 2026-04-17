#!/bin/sh
set -eu

# Build a pure L2 bridge interconnecting all OOB ports.
ip link add br-oob type bridge 2>/dev/null || true
ip link set br-oob up

for path in /sys/class/net/eth*; do
  iface="${path##*/}"
  [ "${iface}" = "eth0" ] && continue
  ip link set "${iface}" up || true
  ip link set "${iface}" master br-oob || true
done
