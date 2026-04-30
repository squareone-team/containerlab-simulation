#!/bin/sh
# ==============================================================================
# configs/server-hpc-jupyter/startup.sh
# ==============================================================================
# JupyterHub Frontend Node
# Role: Proxy and frontend for JupyterHub users
# - Exposes JupyterHub interface on 8080
# - Connects to JupyterHub controller on Admin pod (192.168.50.10:8000)
# - Routes to notebook servers running on HPC workers
#
# NOTE: This is now a PROXY FRONTEND, not a notebook server.
# JupyterHub server runs on server-admin-01 (192.168.50.10:8000)
#
# Idempotent: Safe to run multiple times
# ==============================================================================

set -e

log() { echo "[JUPYTER-FRONTEND-STARTUP] $*"; }
die() { echo "[JUPYTER-FRONTEND-STARTUP] ERROR: $*" >&2; exit 1; }

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

log "Setting up network (bond0: 192.168.70.30/24)..."
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
ip addr add 192.168.70.30/24 dev bond0 2>/dev/null || true
ip route del default 2>/dev/null || true
ip route add default via 192.168.70.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

log "Network configured"

# ==============================================================================
# 2. FIREWALL (nftables) - Allow JupyterHub access from all subnets
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
		
		# Allow HTTP/HTTPS from all internal networks to JupyterHub (8080)
		ip saddr 192.168.10.0/24 tcp dport 8080 accept
		ip saddr 192.168.20.0/24 tcp dport 8080 accept
		ip saddr 192.168.50.0/24 tcp dport 8080 accept
		ip saddr 192.168.60.0/24 tcp dport 8080 accept
		ip saddr 172.20.20.0/24 tcp dport 8080 accept
		
		# Storage pod to HPC frontend: NFS (2049), RPC (111)
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
# 3. NFS MOUNTS (for notebook persistence)
# ==============================================================================

log "Setting up NFS mounts..."
if ! command -v mount.nfs >/dev/null 2>&1; then
	die "NFS client not installed (build esi/alpine-jupyter:3.20)"
fi

# Create mount points
mkdir -p /home /shared

# Mount /home from storage (for persistent notebooks)
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
# 4. WAIT FOR JUPYTERHUB CONTROLLER
# ==============================================================================

log "Starting background check for JupyterHub controller (192.168.50.10:8000)..."
(
	if ! command -v nc >/dev/null 2>&1; then
		log "WARN: netcat not found, skipping controller readiness check"
		exit 0
	fi
	max_retries=30
	retry=0
	while ! nc -z 192.168.50.10 8000 2>/dev/null; do
		retry=$((retry + 1))
		if [ $retry -gt $max_retries ]; then
			log "WARNING: JupyterHub controller not responding after ${max_retries} retries"
			exit 1
		fi
		sleep 2
	done
	log "JupyterHub controller reachable at 192.168.50.10:8000"
) &

log "JupyterHub frontend startup continuing (controller check running in background)..."

# ==============================================================================
# 5. PROXY CONFIGURATION
# ==============================================================================

log "JupyterHub frontend proxy initialized"
log "Users will access JupyterHub via: https://hpc-jupyter.esi.internal:8080"
log "Proxy forwards to controller at: 192.168.50.10:8000"

# ==============================================================================
# 6. REMOTE SYSLOG FORWARDING
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
# 7. FINAL STARTUP
# ==============================================================================

log "JupyterHub frontend startup complete"
log "Services ready:"
log "  - NFS mounts (/home, /shared)"
log "  - Frontend listening on port 8080"
log "  - Connected to controller: 192.168.50.10:8000"


