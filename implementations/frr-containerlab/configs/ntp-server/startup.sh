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
    # Add fabric-specific routes 
    ip route add 192.168.0.0/16 via 192.168.50.1 dev eth1 2>/dev/null || true
    ip route add 10.0.0.0/8    via 192.168.50.1 dev eth1 2>/dev/null || true
    ip route add 172.16.0.0/12 via 192.168.50.1 dev eth1 2>/dev/null || true
else
    echo "[ntp-server] WARNING: eth1 never appeared"
fi

mkdir -p /var/log/chrony /var/run/chrony

cat > /etc/chrony.conf << 'EOF'
# Upstream time sources (reachable via eth0 management — ContainerLab default route)
server pool.ntp.org iburst
server time.cloudflare.com iburst

# Step the clock on first 3 syncs if offset > 1s, then slew only
makestep 1.0 3

# Maximum allowed distance from source (1s = log correlation requirement)
maxdistance 1.0

# Serve time to all internal networks
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12

# Announce stratum 2 even before synced (fallback for isolated lab)
local stratum 2 orphan

# Admin/query interface
cmdallow 192.168.0.0/16
cmdallow 10.0.0.0/8
cmdallow 172.16.0.0/12
bindcmdaddress 0.0.0.0

# Logging
logdir /var/log/chrony
log measurements statistics tracking
EOF

echo "[ntp-server] starting chronyd..."
# Use -n (no daemon) NOT -d (debug) — -d changes socket behavior in some Alpine versions
chronyd -n -f /etc/chrony.conf &
CHRONY_PID=$!

# Give chrony 3 seconds to initialize socket before script exits
sleep 3
echo "[ntp-server] chronyd started, PID=$CHRONY_PID"
wait $CHRONY_PID