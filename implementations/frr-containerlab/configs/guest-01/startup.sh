#!/bin/sh
set -eu

hostname guest-01

ip link set eth1 up
ip addr replace 192.168.110.30/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 192.168.110.1 dev eth1

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF
