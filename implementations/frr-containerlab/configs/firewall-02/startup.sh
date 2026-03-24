#!/bin/sh
# Startup script for firewall-02
# ESI Datacenter - Ring 1 HA Firewall Pair

set -e

echo "[*] Firewall-02 startup script starting..."

# Install required packages
echo "[*] Installing required packages..."
apk add --no-cache keepalived nftables tcpdump curl iputils

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Configure eth1 with IP address for Ring 1
echo "[*] Configuring eth1 (Ring 1 interface)..."
ip addr add 192.168.1.2/24 dev eth1
ip link set eth1 up

# Configure eth2-eth4 for traffic traversal (no IP needed, just up)
echo "[*] Bringing up additional interfaces..."
for i in 2 3 4 5 6 7 8 9; do
    if ip link show eth$i >/dev/null 2>&1; then
        ip link set eth$i up
    fi
done

# Apply nftables configuration
echo "[*] Applying nftables configuration..."
if [ -f /etc/nftables.conf ]; then
    nft -f /etc/nftables.conf
    echo "[+] nftables rules loaded successfully"
else
    echo "[-] nftables.conf not found!"
fi

# Create health check script for keepalived
echo "[*] Creating health check script..."
mkdir -p /usr/local/bin

cat > /usr/local/bin/check_firewall_health.sh << 'HEALTH_CHECK'
#!/bin/sh
# Health check script for keepalived
# Returns 0 if healthy, non-zero if unhealthy

# Check if eth1 is UP
if ! ip link show eth1 | grep -q UP; then
    exit 1
fi

# Check if nftables is loaded
if ! nft list ruleset 2>/dev/null | grep -q "table inet filter"; then
    exit 1
fi

# Check if there's a route (basic connectivity)
if ! ip route show | grep -q "192.168"; then
    exit 1
fi

exit 0
HEALTH_CHECK

chmod +x /usr/local/bin/check_firewall_health.sh

# Create notification scripts for keepalived state changes
cat > /usr/local/bin/notify_master.sh << 'NOTIFY_MASTER'
#!/bin/sh
echo "[+] Firewall-02 became MASTER for Ring1_VIP - VIP 192.168.1.254 is now active" | logger -t keepalived
# Here you could add actions like reloading services, sending alerts, etc.
NOTIFY_MASTER

chmod +x /usr/local/bin/notify_master.sh

cat > /usr/local/bin/notify_backup.sh << 'NOTIFY_BACKUP'
#!/bin/sh
echo "[*] Firewall-02 became BACKUP for Ring1_VIP" | logger -t keepalived
NOTIFY_BACKUP

chmod +x /usr/local/bin/notify_backup.sh

cat > /usr/local/bin/notify_fault.sh << 'NOTIFY_FAULT'
#!/bin/sh
echo "[-] Firewall-02 entered FAULT state for Ring1_VIP" | logger -t keepalived
# Here you could add alert actions
NOTIFY_FAULT

chmod +x /usr/local/bin/notify_fault.sh

# Start keepalived
echo "[*] Starting keepalived daemon..."
if [ -f /etc/keepalived/keepalived.conf ]; then
    # Run keepalived in foreground for container compatibility, but also background it
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

echo "[+] Firewall-02 startup completed successfully"
echo ""
echo "=========================================="
echo "Firewall-02 Status:"
echo "=========================================="
echo "Ring 1 IP (eth1): $(ip addr show eth1 | grep 'inet ' | awk '{print $2}')"
echo "VIP (when MASTER): 192.168.1.254/24"
echo "nftables rules: $(nft list ruleset 2>/dev/null | grep -c 'rule ' || echo 'Not loaded')"
echo "Keepalived: $(ps aux | grep -q '[k]eepalived' && echo 'Running' || echo 'Not running')"
echo "=========================================="

exit 0
