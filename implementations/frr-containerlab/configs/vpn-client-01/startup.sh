#!/bin/sh
set -eu

hostname vpn-client-01

ip link set eth1 up
ip addr replace 198.18.4.20/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 198.18.4.1 dev eth1

ip link del wg0 2>/dev/null || true

mkdir -p /var/log
if [ -f /usr/local/bin/esi-vpn-client-agent.py ]; then
    ESI_VPN_CLIENT_AGENT_LISTEN="198.18.4.20" \
    ESI_VPN_CLIENT_AGENT_PORT="15814" \
    ESI_VPN_GATEWAY_IP="198.51.100.20" \
    nohup python3 /usr/local/bin/esi-vpn-client-agent.py >/var/log/esi-vpn-client-agent.log 2>&1 &
fi
