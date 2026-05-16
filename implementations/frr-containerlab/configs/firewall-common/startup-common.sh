#!/bin/sh
# Shared startup logic for Ring 1 firewalls.
# Node-specific wrappers set:
# - FW_NAME
# - FW_RING1_IP
# - FW_TRANSIT_GW

set -e

FW_NAME="${FW_NAME:-firewall}"
FW_RING1_IP="${FW_RING1_IP:-192.168.1.1}"
FW_TRANSIT_GW="${FW_TRANSIT_GW:-192.168.1.252}"

echo "[*] ${FW_NAME} startup script starting..."

sysctl -w net.ipv4.ip_forward=1

echo "[*] Configuring eth1 (Ring 1 interface)..."
ip addr replace "${FW_RING1_IP}/24" dev eth1
ip link set eth1 up

echo "[*] Bringing up additional interfaces..."
for i in 2 3 4 5 6 7 8 9; do
    if ip link show eth$i >/dev/null 2>&1; then
        ip link set eth$i up
    fi
done

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

ip addr replace "${FW_RING1_IP}/24" dev eth1

# Route datacenter, campus, DMZ, and lab Internet prefixes via the local
# border-leaf transit IP. Link isolation removes routes on some kernels, so this
# script is called at startup and on every keepalived state transition.
ip route replace default via "${FW_TRANSIT_GW}" dev eth1
ip route replace 192.168.0.0/16 via "${FW_TRANSIT_GW}" dev eth1
ip route replace 10.200.0.0/30 via "${FW_TRANSIT_GW}" dev eth1
ip route replace 198.51.100.0/24 via "${FW_TRANSIT_GW}" dev eth1
ip route replace 198.18.0.0/15 via "${FW_TRANSIT_GW}" dev eth1
EOF
chmod +x /usr/local/bin/install_firewall_routes.sh
/usr/local/bin/install_firewall_routes.sh

cat > /usr/local/bin/check_firewall_health.sh << 'HEALTH_CHECK'
#!/bin/sh
if ! ip link show eth1 | grep -q UP; then
    exit 1
fi
if ! nft list ruleset 2>/dev/null | grep -q "table inet filter"; then
    exit 1
fi
for prefix in default 192.168.0.0/16 10.200.0.0/30 198.51.100.0/24 198.18.0.0/15; do
    ip route show "$prefix" | grep -q . || exit 1
done
exit 0
HEALTH_CHECK
chmod +x /usr/local/bin/check_firewall_health.sh

cat > /usr/local/bin/notify_master.sh << EOF
#!/bin/sh
/usr/local/bin/install_firewall_routes.sh
for i in 1 2 3; do
    arping -q -U -c 2 -I eth1 192.168.1.254 >/dev/null 2>&1 || true
    arping -q -A -c 2 -I eth1 192.168.1.254 >/dev/null 2>&1 || true
    sleep 1
done
echo "[+] ${FW_NAME} became MASTER for Ring1_VIP - VIP 192.168.1.254 is now active" | logger -t keepalived
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
echo "Ring 1 IP (eth1): $(ip addr show eth1 | grep 'inet ' | awk '{print $2}')"
echo "VIP (when MASTER): 192.168.1.254/24"
echo "nftables rules: $(nft list ruleset 2>/dev/null | grep -c 'rule ' || echo 'Not loaded')"
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
