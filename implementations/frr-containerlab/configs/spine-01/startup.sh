#!/bin/bash
set -e
for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

# === NTP CLIENT ===
# Install chrony
apk add --no-cache chrony

# Write client config
cat > /etc/chrony.conf << 'EOF'
# Sync from lab NTP server (stratum 2)
server 192.168.50.20 iburst prefer


# Fallback: if NTP server unreachable, use local clock at high stratum
local stratum 10

# Accept clock step on first 3 syncs
makestep 1.0 3

# Maximum skew allowed before chrony refuses to sync (forensic requirement: < 1s)
maxdistance 1.0

logdir /var/log/chrony
log measurements statistics tracking
EOF

mkdir -p /var/log/chrony

# Start chronyd in background — use & and not exec so startup.sh continues
sleep 5
chronyd -f /etc/chrony.conf &