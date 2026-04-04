#!/bin/sh
# configs/server-client-ntp.sh
# Reusable NTP client config for all alpine server nodes
# Called at the end of each server's startup sequence

apk add --no-cache chrony 2>/dev/null

mkdir -p /var/log/chrony /var/run/chrony

cat > /etc/chrony.conf << 'EOF'
server clab-esi-datacenter-ntp-server iburst prefer
local stratum 10
makestep 1.0 3
maxdistance 1.0
logdir /var/log/chrony
EOF

/usr/sbin/chronyd -f /etc/chrony.conf