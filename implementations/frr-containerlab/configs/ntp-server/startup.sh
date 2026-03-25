#!/bin/sh

# Wait for eth1 to appear (up to 30s) — handles ContainerLab race conditions
wait_for_iface() {
    local iface=$1
    local retries=15
    while [ $retries -gt 0 ]; do
        ip link show "$iface" > /dev/null 2>&1 && return 0
        echo "[ntp-server] waiting for $iface..."
        sleep 2
        retries=$((retries - 1))
    done
    return 1
}

echo "[ntp-server] installing chrony..."
apk add --no-cache chrony

if wait_for_iface eth1; then
    ip addr add 192.168.50.20/24 dev eth1 2>/dev/null || true
    ip link set eth1 up
else
    echo "[ntp-server] WARNING: eth1 never appeared, NTP fabric IP not set"
fi

cat > /etc/chrony.conf << 'EOF'
server pool.ntp.org iburst
server time.cloudflare.com iburst
makestep 1.0 3
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
local stratum 2
cmdallow 192.168.0.0/16
cmdallow 10.0.0.0/8
cmdallow 172.16.0.0/12
bindcmdaddress 0.0.0.0
logdir /var/log/chrony
log measurements statistics tracking
EOF

mkdir -p /var/log/chrony

# Add fabric default route AFTER chrony install (uses eth0/mgmt for apk)
ip route add default via 192.168.50.1 dev eth1 
ip route add 10.0.0.0/8 via 192.168.50.1 dev eth1

echo "[ntp-server] starting chronyd..."
exec chronyd -d -f /etc/chrony.conf