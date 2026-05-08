#!/bin/sh
set -eu

wait_for_iface() {
    iface="$1"
    retries="${2:-20}"
    while [ "$retries" -gt 0 ]; do
        if ip link show "$iface" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    return 1
}

hostname campus-bp

ip link add br-student type bridge 2>/dev/null || true
ip link set br-student up
ip addr replace 192.168.110.1/24 dev br-student

wait_for_iface eth1
ip link set eth1 up
ip addr replace 100.10.0.2/30 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 100.10.0.1 dev eth1

wait_for_iface eth3
ip link set eth3 up
ip addr replace 10.200.0.2/30 dev eth3
ip route replace 192.168.10.100/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.20/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.30/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.40/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.70/32 via 10.200.0.1 dev eth3
# Use the campus SVI as the RADIUS client identity. The transit /30 stays a
# routing link; policy and RADIUS client trust bind to the NAC gateway address.
ip route replace 192.168.50.80/32 via 10.200.0.1 dev eth3 src 192.168.110.1
ip route replace 192.168.10.10/32 via 10.200.0.1 dev eth3
ip route replace 192.168.50.10/32 via 10.200.0.1 dev eth3
ip route replace 192.168.70.10/32 via 10.200.0.1 dev eth3

for IFACE in eth4 eth5 eth6; do
    wait_for_iface "$IFACE"
    ip link set "$IFACE" up
    ip link set "$IFACE" master br-student
done

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [ -f /etc/nftables.conf ]; then
    nft -f /etc/nftables.conf
fi

iptables -t nat -C POSTROUTING -s 192.168.110.0/24 -o eth1 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 192.168.110.0/24 -o eth1 -j MASQUERADE

mkdir -p /var/log
if [ -f /usr/local/bin/esi-nac-server.py ]; then
    ESI_RADIUS_HOST="192.168.50.80" \
    ESI_RADIUS_SECRET="CampusRadiusSecret@2026" \
    ESI_NAC_LISTEN="192.168.110.1" \
    ESI_NAC_PORT="8085" \
    nohup python3 /usr/local/bin/esi-nac-server.py >/var/log/esi-nac-server.log 2>&1 &
fi
