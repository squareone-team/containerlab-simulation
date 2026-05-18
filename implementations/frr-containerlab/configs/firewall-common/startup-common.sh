#!/bin/sh
# Shared startup logic for Ring 1 firewalls.
# Node-specific wrappers set:
# - FW_NAME
# - FW_RING1_IP
# - FW_TRANSIT_GW
# - FW_OUTSIDE_IP
# - FW_CAMPUS_IP

set -e

FW_NAME="${FW_NAME:-firewall}"
FW_RING1_IP="${FW_RING1_IP:-192.168.1.1}"
FW_TRANSIT_GW="${FW_TRANSIT_GW:-192.168.1.252}"
FW_LEAF1_GW="${FW_LEAF1_GW:-192.168.1.252}"
FW_LEAF2_GW="${FW_LEAF2_GW:-192.168.1.253}"
FW_INSIDE_VIP="${FW_INSIDE_VIP:-192.168.1.254}"
FW_OUTSIDE_IF="${FW_OUTSIDE_IF:-eth4}"
FW_OUTSIDE_IP="${FW_OUTSIDE_IP:-203.0.113.10}"
FW_OUTSIDE_GW="${FW_OUTSIDE_GW:-203.0.113.9}"
FW_OUTSIDE_VIP="${FW_OUTSIDE_VIP:-203.0.113.14}"
FW_CAMPUS_IF="${FW_CAMPUS_IF:-eth5}"
FW_CAMPUS_IP="${FW_CAMPUS_IP:-10.200.0.3}"
FW_CAMPUS_VIP="${FW_CAMPUS_VIP:-10.200.0.1}"
FW_CAMPUS_GW="${FW_CAMPUS_GW:-10.200.0.2}"
FW_INSIDE_IF="bond0"

echo "[*] ${FW_NAME} startup script starting..."

sysctl -w net.ipv4.ip_forward=1

echo "[*] Configuring inside bond0 toward border leafs..."
modprobe bonding 2>/dev/null || true
ip link add "${FW_INSIDE_IF}" type bond mode active-backup miimon 100 primary eth1 2>/dev/null || true
ip link set "${FW_INSIDE_IF}" down 2>/dev/null || true
for iface in eth1 eth2; do
    if ip link show "$iface" >/dev/null 2>&1; then
        ip addr flush dev "$iface" 2>/dev/null || true
        ip link set "$iface" down 2>/dev/null || true
        ip link set dev "$iface" mtu 9000 2>/dev/null || true
        ip link set "$iface" master "${FW_INSIDE_IF}" 2>/dev/null || true
        ip link set "$iface" up
    fi
done
ip link set dev "${FW_INSIDE_IF}" mtu 9000 2>/dev/null || true
ip link set "${FW_INSIDE_IF}" up
ip addr replace "${FW_RING1_IP}/24" dev "${FW_INSIDE_IF}"

echo "[*] Bringing up additional interfaces..."
for i in 3 4 5 6 7 8 9; do
    if ip link show eth$i >/dev/null 2>&1; then
        ip link set dev eth$i mtu 9000 2>/dev/null || true
        ip link set eth$i up
    fi
done
if ip link show "${FW_OUTSIDE_IF}" >/dev/null 2>&1; then
    ip addr replace "${FW_OUTSIDE_IP}/29" dev "${FW_OUTSIDE_IF}"
fi
if ip link show "${FW_CAMPUS_IF}" >/dev/null 2>&1; then
    ip addr replace "${FW_CAMPUS_IP}/29" dev "${FW_CAMPUS_IF}"
fi

echo "[*] Applying nftables configuration..."
if [ -f /etc/nftables.conf ]; then
    nft -f /etc/nftables.conf
    echo "[+] nftables rules loaded successfully"
else
    echo "[-] nftables.conf not found!"
fi

echo "[*] Creating health check script..."
mkdir -p /usr/local/bin

cat > /usr/local/bin/install_firewall_routes.sh << EOF
#!/bin/sh
set -e

ip addr replace "${FW_RING1_IP}/24" dev "${FW_INSIDE_IF}"
ip addr replace "${FW_OUTSIDE_IP}/29" dev "${FW_OUTSIDE_IF}"
ip addr replace "${FW_CAMPUS_IP}/29" dev "${FW_CAMPUS_IF}"

inside_gw="${FW_LEAF1_GW}"
if [ -r "/sys/class/net/${FW_INSIDE_IF}/bonding/active_slave" ]; then
    active_slave="\$(cat /sys/class/net/${FW_INSIDE_IF}/bonding/active_slave 2>/dev/null || true)"
    if [ "\$active_slave" = "eth2" ]; then
        inside_gw="${FW_LEAF2_GW}"
    fi
fi

# Route data-center and DMZ prefixes toward the active border-leaf leg, campus
# prefixes toward the distribution switch, and everything else to the border router.
ip route replace default via "${FW_OUTSIDE_GW}" dev "${FW_OUTSIDE_IF}"
ip route replace 192.168.0.0/16 via "\$inside_gw" dev "${FW_INSIDE_IF}"
ip route replace 198.51.100.0/24 via "\$inside_gw" dev "${FW_INSIDE_IF}"
ip route replace 192.168.110.0/24 via "${FW_CAMPUS_GW}" dev "${FW_CAMPUS_IF}"
ip route replace 10.200.0.0/29 dev "${FW_CAMPUS_IF}"
ip route replace 198.18.0.0/15 via "${FW_OUTSIDE_GW}" dev "${FW_OUTSIDE_IF}"
EOF
chmod +x /usr/local/bin/install_firewall_routes.sh
/usr/local/bin/install_firewall_routes.sh

cat > /usr/local/bin/start_firewall_route_sync.sh << 'ROUTE_SYNC'
#!/bin/sh
pidfile="/run/firewall-route-sync.pid"
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi
(
    while true; do
        /usr/local/bin/install_firewall_routes.sh >/dev/null 2>&1 || true
        sleep 2
    done
) &
echo $! > "$pidfile"
ROUTE_SYNC
chmod +x /usr/local/bin/start_firewall_route_sync.sh
/usr/local/bin/start_firewall_route_sync.sh

echo "[*] Installing firewall NAT and inline IPS controls..."
nft delete table ip edge_nat 2>/dev/null || true
nft add table ip edge_nat
nft add chain ip edge_nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
nft add rule ip edge_nat postrouting oifname "${FW_OUTSIDE_IF}" ip saddr 192.168.0.0/16 snat to "${FW_OUTSIDE_VIP}"

tc qdisc del dev "${FW_OUTSIDE_IF}" clsact 2>/dev/null || true
tc qdisc add dev "${FW_OUTSIDE_IF}" clsact 2>/dev/null || true
tc filter add dev "${FW_OUTSIDE_IF}" ingress protocol ip pref 10 flower \
  ip_proto tcp dst_ip 198.51.100.10 dst_port 80 tcp_flags 0x02/0x02 \
  action police rate 4kbit burst 1k conform-exceed drop 2>/dev/null || true

cat > /usr/local/bin/check_firewall_health.sh << 'HEALTH_CHECK'
#!/bin/sh
if ! ip link show bond0 | grep -q UP; then
    exit 1
fi
if ! ip link show eth4 | grep -q UP; then
    exit 1
fi
if ! ip link show eth5 | grep -q UP; then
    exit 1
fi
if ! nft list ruleset 2>/dev/null | grep -q "table inet filter"; then
    exit 1
fi
for prefix in default 192.168.0.0/16 192.168.110.0/24 198.51.100.0/24 198.18.0.0/15; do
    ip route show "$prefix" | grep -q . || exit 1
done
exit 0
HEALTH_CHECK
chmod +x /usr/local/bin/check_firewall_health.sh

cat > /usr/local/bin/notify_master.sh << EOF
#!/bin/sh
/usr/local/bin/install_firewall_routes.sh
for i in 1 2 3; do
    arping -q -U -c 2 -I "${FW_INSIDE_IF}" "${FW_INSIDE_VIP}" >/dev/null 2>&1 || true
    arping -q -A -c 2 -I "${FW_INSIDE_IF}" "${FW_INSIDE_VIP}" >/dev/null 2>&1 || true
    arping -q -U -c 2 -I "${FW_OUTSIDE_IF}" "${FW_OUTSIDE_VIP}" >/dev/null 2>&1 || true
    arping -q -A -c 2 -I "${FW_OUTSIDE_IF}" "${FW_OUTSIDE_VIP}" >/dev/null 2>&1 || true
    arping -q -U -c 2 -I "${FW_CAMPUS_IF}" "${FW_CAMPUS_VIP}" >/dev/null 2>&1 || true
    arping -q -A -c 2 -I "${FW_CAMPUS_IF}" "${FW_CAMPUS_VIP}" >/dev/null 2>&1 || true
    sleep 1
done
echo "[+] ${FW_NAME} became MASTER for edge VIPs" | logger -t keepalived
EOF
chmod +x /usr/local/bin/notify_master.sh

cat > /usr/local/bin/notify_backup.sh << EOF
#!/bin/sh
/usr/local/bin/install_firewall_routes.sh
echo "[*] ${FW_NAME} became BACKUP for Ring1_VIP" | logger -t keepalived
EOF
chmod +x /usr/local/bin/notify_backup.sh

cat > /usr/local/bin/notify_fault.sh << EOF
#!/bin/sh
echo "[-] ${FW_NAME} entered FAULT state for Ring1_VIP" | logger -t keepalived
EOF
chmod +x /usr/local/bin/notify_fault.sh

echo "[*] Starting keepalived daemon..."
if [ -f /etc/keepalived/keepalived.conf ]; then
    keepalived -f /etc/keepalived/keepalived.conf --vrrp --dont-fork &
    sleep 2

    if ps aux | grep -q "[k]eepalived"; then
        echo "[+] Keepalived started successfully"
    else
        echo "[-] Keepalived failed to start!"
    fi
else
    echo "[-] keepalived.conf not found!"
fi

echo "[+] ${FW_NAME} startup completed successfully"
echo ""
echo "=========================================="
echo "${FW_NAME} Status:"
echo "=========================================="
echo "Inside IP (bond0): $(ip addr show "${FW_INSIDE_IF}" | grep 'inet ' | awk '{print $2}')"
echo "Outside IP (${FW_OUTSIDE_IF}): $(ip addr show "${FW_OUTSIDE_IF}" | grep 'inet ' | awk '{print $2}')"
echo "Campus IP (${FW_CAMPUS_IF}): $(ip addr show "${FW_CAMPUS_IF}" | grep 'inet ' | awk '{print $2}')"
echo "VIPs when MASTER: ${FW_INSIDE_VIP}/24, ${FW_OUTSIDE_VIP}/29, ${FW_CAMPUS_VIP}/29"
echo "nftables rules: $(nft -a list ruleset 2>/dev/null | grep -c 'handle' || echo 'Not loaded')"
echo "Keepalived: $(ps aux | grep -q '[k]eepalived' && echo 'Running' || echo 'Not running')"
if [ -x /usr/local/bin/fw-live-watch.sh ]; then
    echo "Live packet watcher: /usr/local/bin/fw-live-watch.sh"
    echo "Capture log path: /var/log/fw-live-watch.log (overwritten on each run)"
fi
if [ -x /usr/local/bin/fw-summary.sh ]; then
    echo "Traffic summary: /usr/local/bin/fw-summary.sh"
fi
echo "=========================================="

exit 0
