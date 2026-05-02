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

tmp_hosts="$(mktemp)"
grep -vE '[[:space:]](server-admin-01|server-hpc-01|server-hpc-02)([[:space:]]|$)' /etc/hosts > "$tmp_hosts" || true
{
	echo "192.168.50.10 server-admin-01"
	echo "192.168.70.10 server-hpc-01"
	echo "192.168.70.20 server-hpc-02"
	cat "$tmp_hosts"
} > /etc/hosts
rm -f "$tmp_hosts"

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
		
		# Admin pod to HPC worker: SLURM daemon, Munge, and notebook callback ports
		ip saddr 192.168.50.0/24 tcp dport { 6818, 11002 } accept
		ip saddr 192.168.50.0/24 udp dport 11002 accept
		ip saddr 192.168.50.0/24 tcp dport 1024-65535 accept
		
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
mkdir -p /var/spool/slurm-llnl /var/log/slurm /run/slurm /var/spool/slurmd
chown -R slurm:slurm /var/spool/slurm-llnl /var/log/slurm /run/slurm /var/spool/slurmd

# Copy SLURM config
cp /shared-configs/slurm.conf /etc/slurm/slurm.conf
chown slurm:slurm /etc/slurm/slurm.conf
chmod 644 /etc/slurm/slurm.conf

log "SLURM worker configured"

# ==============================================================================
# 4. MUNGE SETUP
# ==============================================================================

log "Initializing Munge (SLURM auth)..."
mkdir -p /var/run/munge /etc/munge /var/log/munge

# Fetch munge key from Admin pod's shared configs
MUNGE_KEY_SRC="/shared-configs/munge.key"
if [ -f "$MUNGE_KEY_SRC" ]; then
	log "Copying munge.key from shared-configs"
	cp "$MUNGE_KEY_SRC" /etc/munge/munge.key
elif ! [ -f /etc/munge/munge.key ]; then
	log "WARN: No shared munge.key found - generating local key"
	dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
fi

chmod 400 /etc/munge/munge.key 2>/dev/null || true
chown munge:munge /etc/munge/munge.key 2>/dev/null || true

chown -R munge:munge /var/run/munge /etc/munge /var/log/munge
chmod 0755 /var/run/munge /etc/munge /var/log/munge
chmod 0711 /var/lib/munge 2>/dev/null || true

su munge -s /bin/sh -c "munged --log-file=/var/log/munge/munged.log" &
sleep 1
log "Munge started"

# ==============================================================================
# 5. NFS MOUNTS
# ==============================================================================

log "Setting up NFS mounts..."

if ! command -v mount.nfs >/dev/null 2>&1; then
	die "NFS client not installed (build esi/naas:bookworm)"
fi

mkdir -p /home /shared

# Mount /home from storage (retry up to 5 times)
if ! is_mounted /home; then
	for i in 1 2 3 4 5; do
		log "Mounting /home from 192.168.80.10:/home (attempt $i/5)..."
		if mount -t nfs -o rw,soft,timeo=30,retrans=3,nolock 192.168.80.10:/home /home 2>/dev/null; then
			log "/home mounted successfully"
			break
		fi
		[ $i -lt 5 ] && sleep 5
	done
	is_mounted /home || die "Failed to mount /home after 5 attempts"
fi

# Mount /shared from storage (retry up to 5 times)
if ! is_mounted /shared; then
	for i in 1 2 3 4 5; do
		log "Mounting /shared from 192.168.80.10:/shared (attempt $i/5)..."
		if mount -t nfs -o rw,soft,timeo=30,retrans=3,nolock 192.168.80.10:/shared /shared 2>/dev/null; then
			log "/shared mounted successfully"
			break
		fi
		[ $i -lt 5 ] && sleep 5
	done
	is_mounted /shared || die "Failed to mount /shared after 5 attempts"
fi

log "NFS mounts configured"

# ==============================================================================
# 6. PAM USERS INITIALIZATION
# ==============================================================================

log "Initializing PAM users and groups..."
if [ -f /shared-configs/pam-users-init.sh ]; then
	sh /shared-configs/pam-users-init.sh
else
	die "PAM user initialization script not mounted"
fi

# ==============================================================================
# 7. SLURM WORKER DAEMON
# ==============================================================================

log "Starting SLURM worker daemon (slurmd)..."
# Fix cgroup v2 dbus crash
echo "IgnoreSystemd=yes" > /etc/slurm/cgroup.conf
mkdir -p /sys/fs/cgroup/system.slice 2>/dev/null || true

slurmd -Dv &
sleep 2

log "SLURM worker daemon started"

# ==============================================================================
# 8. REMOTE SYSLOG
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
# 9. FINAL STARTUP
# ==============================================================================

log "HPC-02 startup complete"
log "Services running:"
log "  - SLURM worker (6818)"
log "  - Munge auth (11002)"
log "  - NFS mounts (/home, /shared)"
