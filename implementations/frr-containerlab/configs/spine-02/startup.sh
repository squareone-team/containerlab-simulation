#!/bin/bash
set -e
for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

# === NTP CLIENT ===
apk add --no-cache chrony
cat > /etc/chrony.conf << 'EOF'
server 192.168.50.20 iburst prefer
local stratum 10
EOF
chronyd -f /etc/chrony.conf