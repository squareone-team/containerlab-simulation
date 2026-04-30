#!/bin/sh
# ==============================================================================
# configs/server-hpc-02/startup.sh
# ==============================================================================
# HPC Pod Compute Node #2 Startup Script
# (Same as server-hpc-01, but with IP 192.168.70.20)
# ==============================================================================

set -e

log() { echo "[HPC-02-STARTUP] $*"; }
die() { echo "[HPC-02-STARTUP] ERROR: $*" >&2; exit 1; }

# ==============================================================================
# 1. NETWORK SETUP
# ==============================================================================

log "Setting up network (bond0: 192.168.70.20/24)..."
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
ip addr add 192.168.70.20/24 dev bond0 2>/dev/null || true
ip route del default 2>/dev/null || true
ip route add default via 192.168.70.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

log "Network configured"

# ==============================================================================
# 2. FIREWALL (nftables)
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
		
		# Admin pod to HPC worker: SLURM daemon (6818), Munge (11002)
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

# Create slurm user if not exists
id slurm >/dev/null 2>&1 || useradd -r -m -d /var/spool/slurm-llnl slurm

# Create directories
mkdir -p /var/spool/slurm-llnl /var/log/slurm /run/slurm
chown -R slurm:slurm /var/spool/slurm-llnl /var/log/slurm /run/slurm

# Install SLURM if not present
if ! command -v slurmd >/dev/null 2>&1; then
	log "Installing SLURM..."
	apk add --no-cache slurm slurm-dev munge 2>/dev/null || \
	(apt-get update -qq && apt-get install -y slurm-wlm slurm-wlm-basic-plugins munge 2>/dev/null) || \
	die "Failed to install SLURM"
fi

# Copy SLURM config
cp /shared-configs/slurm.conf /etc/slurm/slurm.conf
chown slurm:slurm /etc/slurm/slurm.conf
chmod 640 /etc/slurm/slurm.conf

log "SLURM worker configured"

# ==============================================================================
# 4. MUNGE SETUP
# ==============================================================================

log "Initializing Munge (SLURM auth)..."
mkdir -p /var/run/munge /etc/munge /var/log/munge

if ! [ -f /etc/munge/munge.key ]; then
	log "Generating munge.key"
	dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
fi

chmod 400 /etc/munge/munge.key 2>/dev/null || true
chown munge:munge /etc/munge/munge.key 2>/dev/null || true

munged -L /var/log/munge/munged.log &
sleep 1
log "Munge started"

# ==============================================================================
# 5. NFS MOUNTS
# ==============================================================================

log "Setting up NFS mounts..."

if ! command -v mount.nfs >/dev/null 2>&1; then
	log "Installing NFS client..."
	apk add --no-cache nfs-utils 2>/dev/null || \
	(apt-get update -qq && apt-get install -y nfs-common 2>/dev/null) || \
	die "Failed to install NFS client"
fi

mkdir -p /home /shared

if ! mountpoint -q /home; then
	log "Mounting /home from 192.168.80.10:/home..."
	mount -t nfs -o rw,soft,timeo=30,retrans=3 192.168.80.10:/home /home || \
		log "WARN: Failed to mount /home"
fi

if ! mountpoint -q /shared; then
	log "Mounting /shared from 192.168.80.10:/shared..."
	mount -t nfs -o rw,soft,timeo=30,retrans=3 192.168.80.10:/shared /shared || \
		log "WARN: Failed to mount /shared"
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
# 7. REMOTE SYSLOG
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
	log "WARN: rsyslogd not found"
fi

# ==============================================================================
# 8. FINAL STARTUP
# ==============================================================================

log "HPC-02 startup complete"
log "Services running:"
log "  - SLURM worker (6818)"
log "  - Munge auth (11002)"
log "  - NFS mounts (/home, /shared)"

# Keep container running
tail -f /dev/null
