#!/bin/sh
# ==============================================================================
# configs/server-storage-01/startup.sh
# ==============================================================================
# Storage Pod NFS Server Startup Script
# Initializes:
#   - Networking (bond0, IP 192.168.80.10)
#   - Firewall (nftables allowing NFS, RPC)
#   - NFS server with /home and /shared exports
#   - Directory structure for user homes and shared projects
#   - Consistent uid/gid mapping
#   - Syslog forwarding
#
# Idempotent: Safe to run multiple times
# ==============================================================================

set -e

log() { echo "[STORAGE-STARTUP] $*"; }
die() { echo "[STORAGE-STARTUP] ERROR: $*" >&2; exit 1; }

is_mounted() {
	if command -v mountpoint >/dev/null 2>&1; then
		mountpoint -q "$1"
	else
		grep -qs " $1 " /proc/mounts
	fi
}

# ==============================================================================
# 1. NETWORK SETUP
# ==============================================================================

log "Setting up network (bond0: 192.168.80.10/24)..."
ip link add bond0 type bond mode active-backup miimon 100 primary eth1 2>/dev/null || true
ip link set eth1 down 2>/dev/null || true
ip link set eth2 down 2>/dev/null || true
ip link set eth1 master bond0 2>/dev/null || true
ip link set eth2 master bond0 2>/dev/null || true
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up
echo 1 > /sys/class/net/bond0/bonding/all_slaves_active
sleep 2
ip addr add 192.168.80.10/24 dev bond0 2>/dev/null || true
ip route del default 2>/dev/null || true
ip route add default via 192.168.80.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

log "Network configured"

# ==============================================================================
# 2. FIREWALL (nftables) - Allow NFS, RPC from HPC and Admin pods
# ==============================================================================

log "Configuring firewall rules (nftables)..."
if command -v nft >/dev/null 2>&1; then
	cat > /etc/nftables.conf << 'NFT'
flush ruleset
table inet filter {
	chain input {
		type filter hook input priority 0;
		policy drop;
		iif "lo" accept
		ct state established,related accept
		ip protocol icmp accept
		
		# Storage pod internal
		ip saddr 192.168.80.0/24 accept
		
		# Bastion SSH
		ip saddr 172.16.0.50 tcp dport 22 accept
		
		# HPC pod to Storage: NFS (2049), RPC (111), Portmapper (111)
		ip saddr 192.168.70.0/24 accept
		
		# Admin pod to Storage: NFS, RPC
		ip saddr 192.168.50.0/24 accept
	}

	chain forward {
		type filter hook forward priority 0;
		policy drop;
	}

	chain output {
		type filter hook output priority 0;
		policy accept;
	}
}
NFT

	nft -f /etc/nftables.conf
	log "Firewall rules loaded"
else
	log "WARN: nft not found, skipping nftables policy setup"
fi

# ==============================================================================
# 3. NFS SERVER SETUP
# ==============================================================================

log "Installing and configuring NFS server..."
if ! command -v rpc.nfsd >/dev/null 2>&1 && ! command -v nfsd >/dev/null 2>&1; then
	die "NFS server not installed (build esi/alpine-naas:3.20)"
fi
if ! command -v exportfs >/dev/null 2>&1; then
	die "exportfs not installed (build esi/alpine-naas:3.20)"
fi
if ! command -v rpcbind >/dev/null 2>&1; then
	die "rpcbind not installed (build esi/alpine-naas:3.20)"
fi

# Create export directories
log "Creating NFS export directories..."
mkdir -p /home /shared

# Mount as tmpfs to bypass OverlayFS NFS export restrictions
is_mounted /home || mount -t tmpfs tmpfs /home
is_mounted /shared || mount -t tmpfs tmpfs /shared

# Set up ownership and permissions for /home
# /home will contain per-user directories
chown -R root:root /home || true
chmod 755 /home || true
mkdir -p /home/admin /home/administrator /home/researcher-01 /home/researcher-02 \
	/home/student-01 /home/student-02 /home/student-03
chown 1000:1000 /home/admin || true
chown 1001:1001 /home/administrator || true
chown 2001:2001 /home/researcher-01 || true
chown 2002:2002 /home/researcher-02 || true
chown 3001:3001 /home/student-01 || true
chown 3002:3002 /home/student-02 || true
chown 3003:3003 /home/student-03 || true
chmod 755 /home/admin /home/administrator /home/researcher-01 /home/researcher-02 \
	/home/student-01 /home/student-02 /home/student-03 || true

# Set up shared directories
# /shared will contain course and team directories
mkdir -p /shared/course-001 /shared/course-002 /shared/team-research
chown -R root:root /shared || true
chmod 755 /shared /shared/course-001 /shared/course-002 || true
chown -R 2001:5002 /shared/team-research || true
chmod 770 /shared/team-research || true

log "NFS directories initialized"

# ==============================================================================
# 4. NFS EXPORTS CONFIGURATION
# ==============================================================================

log "NFS exports are provided via read-only mount..."

# ==============================================================================
# 5. START NFS DAEMONS
# ==============================================================================

log "Starting NFS server daemons..."

mkdir -p /proc/fs/nfsd
if ! grep -qs ' nfsd ' /proc/mounts; then
	mount -t nfsd nfsd /proc/fs/nfsd
fi

# Start RPC portmapper (if not already running)
if ! pgrep -x rpcbind >/dev/null 2>&1; then
	rpcbind &
	sleep 1
	log "RPC portmapper started"
fi

# Start NFS server
if command -v rpc.nfsd >/dev/null 2>&1; then
	log "Starting NFS daemon..."
	rpc.nfsd 8
	sleep 1
elif command -v nfsd >/dev/null 2>&1; then
	log "Starting NFSD..."
	nfsd 8
	sleep 1
fi

if ! rpcinfo -p 127.0.0.1 2>/dev/null | grep -q '100003.*2049'; then
	die "NFS daemon did not register on port 2049"
fi

# Start mount daemon
if ! pgrep -x rpc.mountd >/dev/null 2>&1; then
	log "Starting mount daemon..."
	rpc.mountd &
	sleep 1
fi

# Export NFS filesystems
log "Exporting NFS filesystems..."
exportfs -ra || log "WARN: exportfs command failed"

log "NFS server started"

# ==============================================================================
# 6. VERIFY NFS EXPORTS
# ==============================================================================

log "Verifying NFS exports..."
exportfs -v | while read line; do
	log "  $line"
done

# ==============================================================================
# 7. REMOTE SYSLOG FORWARDING
# ==============================================================================

log "Configuring remote syslog..."
if command -v rsyslogd >/dev/null 2>&1; then
	cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

	/usr/sbin/rsyslogd &
	log "rsyslogd started"
elif command -v syslogd >/dev/null 2>&1; then
	mkdir -p /var/log
	touch /var/log/messages
	syslogd -L -O /var/log/messages -R 192.168.50.70:514 &
	log "syslogd started with remote forwarding"
else
	log "WARN: no syslog daemon found"
fi

# ==============================================================================
# 8. FINAL STARTUP
# ==============================================================================

log "STORAGE-01 startup complete"
log "Services running:"
log "  - NFS server (2049)"
log "  - RPC portmapper (111)"
log "  - Mount daemon"
log "Exports:"
log "  - /home (HPC + Admin pods)"
log "  - /shared (HPC + Admin pods)"
