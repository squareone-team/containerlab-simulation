#!/bin/sh
apk add --no-cache chrony 2>/dev/null
mkdir -p /var/log/chrony /var/run/chrony

cat > /etc/chrony.conf << 'EOF'
server 192.168.50.20 iburst prefer
local stratum 10
makestep 1.0 3
maxdistance 16.0
logdir /var/log/chrony
EOF

/usr/sbin/chronyd -f /etc/chrony.conf