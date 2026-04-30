#!/bin/sh
# ==============================================================================
# configs/server-hpc-01/startup.sh
# ==============================================================================
# HPC Pod Compute Node #1 Startup Script
# Initializes:
#   - Networking (bond0, IP 192.168.70.10)
#   - Firewall (nftables allowing SLURM, NFS)
#   - SLURM worker daemon (slurmd) connected to controller on Admin pod
#   - Munge authentication daemon
#   - NFS mounts for /home and /shared from Storage pod
#   - Syslog forwarding
#
# Idempotent: Safe to run multiple times
# ==============================================================================

set -e

log() { echo "[HPC-01-STARTUP] $*"; }
die() { echo "[HPC-01-STARTUP] ERROR: $*" >&2; exit 1; }

NOLOGIN_SHELL="$(command -v nologin || echo /sbin/nologin)"

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

log "Setting up network (bond0: 192.168.70.10/24)..."
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
ip addr add 192.168.70.10/24 dev bond0 2>/dev/null || true
ip route del default 2>/dev/null || true
ip route add default via 192.168.70.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

log "Network configured"

# ==============================================================================
# 2. FIREWALL (nftables) - Allow SLURM, NFS, Admin communication
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
		
		# HPC pod to HPC pod
		ip saddr 192.168.70.0/24 accept
		
		# Bastion SSH
		ip saddr 172.16.0.50 tcp dport 22 accept
		
		# Admin pod to HPC worker: SLURM daemon (6818)
		ip saddr 192.168.50.0/24 tcp dport { 6818, 11002 } accept
		ip saddr 192.168.50.0/24 udp dport 11002 accept
		
		# Storage pod to HPC: NFS (2049), RPC (111)
		ip saddr 192.168.80.0/24 tcp dport { 111, 2049 } accept
		ip saddr 192.168.80.0/24 udp dport { 111, 2049 } accept
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
# 3. SLURM WORKER SETUP
# ==============================================================================

log "Initializing SLURM worker (slurmd)..."

if ! command -v slurmd >/dev/null 2>&1; then
	die "SLURM worker not installed (build esi/naas:bookworm)"
fi
if ! command -v munged >/dev/null 2>&1; then
	die "Munge not installed (build esi/naas:bookworm)"
fi

# Create slurm user if not exists
if ! id slurm >/dev/null 2>&1; then
	if command -v useradd >/dev/null 2>&1; then
		groupadd -r slurm 2>/dev/null || true
		useradd -r -m -d /var/spool/slurm-llnl -s "$NOLOGIN_SHELL" -g slurm slurm
	else
		grep -q '^slurm:' /etc/group 2>/dev/null || addgroup -S slurm
		adduser -D -H -G slurm -s "$NOLOGIN_SHELL" -h /var/spool/slurm-llnl slurm
	fi
fi

# Create directories
mkdir -p /var/spool/slurm-llnl /var/log/slurm /run/slurm
chown -R slurm:slurm /var/spool/slurm-llnl /var/log/slurm /run/slurm

# Copy SLURM config (same as controller, but only used for node registration)
cp /shared-configs/slurm.conf /etc/slurm/slurm.conf
chown slurm:slurm /etc/slurm/slurm.conf
chmod 640 /etc/slurm/slurm.conf

log "SLURM worker configured"

# ==============================================================================
# 4. MUNGE SETUP (SLURM authentication)
# ==============================================================================

log "Initializing Munge (SLURM auth)..."
mkdir -p /var/run/munge /etc/munge /var/log/munge

# Wait for munge key from controller (will be provided via shared volume)
# For lab purposes, generate one if not present
if ! [ -f /etc/munge/munge.key ]; then
	log "Waiting for munge.key from shared volume..."
	sleep 5
	if ! [ -f /etc/munge/munge.key ]; then
		log "Generating local munge.key (expected from Admin pod)"
		dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
	fi
fi

chmod 400 /etc/munge/munge.key 2>/dev/null || true
chown munge:munge /etc/munge/munge.key 2>/dev/null || true

# Start munge daemon
munged -L /var/log/munge/munged.log &
sleep 1
log "Munge started"

# ==============================================================================
# 5. NFS MOUNTS (from Storage pod)
# ==============================================================================

log "Setting up NFS mounts..."

if ! command -v mount.nfs >/dev/null 2>&1; then
	die "NFS client not installed (build esi/naas:bookworm)"
fi

# Create mount points
mkdir -p /home /shared

# Mount /home from storage
if ! is_mounted /home; then
	log "Mounting /home from 192.168.80.10:/home..."
	mount -t nfs -o rw,soft,timeo=5,retrans=1 192.168.80.10:/home /home || \
		log "WARN: Failed to mount /home (storage may not be ready yet)"
fi

# Mount /shared from storage
if ! is_mounted /shared; then
	log "Mounting /shared from 192.168.80.10:/shared..."
	mount -t nfs -o rw,soft,timeo=5,retrans=1 192.168.80.10:/shared /shared || \
		log "WARN: Failed to mount /shared (storage may not be ready yet)"
fi

log "NFS mounts configured"

# ==============================================================================
# 6. SLURM WORKER DAEMON
# ==============================================================================

log "Starting SLURM worker daemon (slurmd)..."
slurmd -Dv &
sleep 2

log "SLURM worker daemon started"

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
else
	log "WARN: rsyslogd not found, using BusyBox syslogd"
fi

# ==============================================================================
# 8. FINAL STARTUP
# ==============================================================================

log "HPC-01 startup complete"
log "Services running:"
log "  - SLURM worker (6818)"
log "  - Munge auth (11002)"
log "  - NFS mounts (/home, /shared)"


