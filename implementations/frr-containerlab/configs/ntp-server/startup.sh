#!/bin/sh
set -e

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
    ip route add 192.168.0.0/16 via 192.168.50.1 dev eth1 2>/dev/null || true
    ip route add 10.0.0.0/8    via 192.168.50.1 dev eth1 2>/dev/null || true
    ip route add 172.16.0.0/12 via 192.168.50.1 dev eth1 2>/dev/null || true
else
    echo "[ntp-server] WARNING: eth1 never appeared"
fi

mkdir -p /var/log/chrony /var/run/chrony

# Auto-detect internet: try reaching pool.ntp.org (timeout 3s)
if nc -z -w3 pool.ntp.org 123 2>/dev/null || ping -c1 -W3 pool.ntp.org >/dev/null 2>&1; then
    echo "[ntp-server] internet reachable — using upstream NTP sources"
    cat > /etc/chrony.conf << 'EOF'
server pool.ntp.org iburst
server time.cloudflare.com iburst
local stratum 2 orphan
makestep 1.0 3
maxdistance 16.0
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
cmdallow 0.0.0.0/0
bindcmdaddress 0.0.0.0
logdir /var/log/chrony
log measurements statistics tracking
EOF
else
    echo "[ntp-server] no internet — using local clock (local stratum 2 orphan)"
    cat > /etc/chrony.conf << 'EOF'
local stratum 2 orphan
makestep 1.0 3
maxdistance 16.0
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
cmdallow 0.0.0.0/0
bindcmdaddress 0.0.0.0
logdir /var/log/chrony
log measurements statistics tracking
EOF
fi

echo "[ntp-server] starting chronyd..."
chronyd -f /etc/chrony.conf

sleep 2

echo "[ntp-server] waiting for source selection..."
for i in $(seq 1 15); do
    chronyc sources 2>/dev/null | grep -qE '\^\*|#\*' && break
    sleep 2
done

echo "[ntp-server] ready — $(chronyc tracking 2>/dev/null | grep Stratum)"

# Keep container alive
tail -f /var/log/chrony/measurements.log 2>/dev/null || sleep infinity