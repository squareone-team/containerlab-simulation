#!/bin/sh
set -eu

hostname campus-admin-01
ip link set eth1 up
ip addr replace 192.168.110.32/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 192.168.110.1 dev eth1

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

if [ -f /usr/local/bin/esi-nac-client.py ]; then
	ESI_NAC_USER="dev-campus-admin-01" \
	ESI_NAC_PASSWORD="DeviceAdmin@2026" \
	ESI_NAC_URL="https://192.168.110.1:8443/auth" \
	nohup python3 /usr/local/bin/esi-nac-client.py >/var/log/esi-nac-client.log 2>&1 &
fi
