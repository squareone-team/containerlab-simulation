#!/bin/sh
# ==============================================================================
# configs/server-admin-01/startup.sh
# ==============================================================================
# Admin Pod Startup Script
# Initializes:
#   - Networking (bond0, IP address)
#   - Firewall (nftables with SLURM, JupyterHub, MySQL ports)
#   - MariaDB (JupyterHub and SLURM accounting databases)
#   - Munge (SLURM authentication daemon)
#   - SLURM Controller (slurmctld) and Accounting Daemon (slurmdbd)
#   - JupyterHub (notebook server with PAM auth)
#   - PAM users (local accounts for authentication)
#   - Syslog forwarding
#
# Idempotent: Safe to run multiple times
# ==============================================================================

set -e

log() { echo "[ADMIN-STARTUP] $*"; }
die() { echo "[ADMIN-STARTUP] ERROR: $*" >&2; exit 1; }

NOLOGIN_SHELL="$(command -v nologin || echo /sbin/nologin)"

# ==============================================================================
# 1. NETWORK SETUP
# ==============================================================================

log "Setting up network (bond0: 192.168.50.10/24)..."
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
ip addr add 192.168.50.10/24 dev bond0 2>/dev/null || true
ip route del default 2>/dev/null || true
ip route add default via 192.168.50.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

log "Network configured"

# ==============================================================================
# 2. FIREWALL (nftables) - Allow SLURM, JupyterHub, MySQL, Munge ports
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
		
		# Admin pod to admin pod
		ip saddr 192.168.50.0/24 accept
		
		# Bastion SSH
		ip saddr 172.16.0.50 tcp dport 22 accept
		
		# HPC pod to Admin pod: SLURM controller (6817), SLURM dbd (6819), MySQL (3306)
		ip saddr 192.168.70.0/24 tcp dport { 6817, 6819, 3306, 8000, 8001 } accept
		
		# Munge port (for HPC workers)
		ip saddr 192.168.70.0/24 tcp dport 11002 accept
		ip saddr 192.168.70.0/24 udp dport 11002 accept
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
# 3. MARIADB SETUP
# ==============================================================================

log "Initializing MariaDB..."
mkdir -p /var/lib/mysql /var/log/mysql
if ! command -v mariadbd >/dev/null 2>&1 && ! command -v mysqld >/dev/null 2>&1; then
	die "MariaDB server not installed (build esi/naas:bookworm)"
fi
if ! command -v mysql >/dev/null 2>&1; then
	die "MariaDB client not installed (build esi/naas:bookworm)"
fi

# Initialize MariaDB data directory if empty
if [ ! -d /var/lib/mysql/mysql ]; then
	log "Initializing MariaDB data directory..."
	if command -v mysql_install_db >/dev/null 2>&1; then
		mysql_install_db --user=mysql --datadir=/var/lib/mysql --default-storage-engine=MyISAM || true
	else
		mariadb-install-db --user=mysql --datadir=/var/lib/mysql || true
	fi
fi

# Start MariaDB
log "Starting MariaDB..."
mysqld_safe --user=mysql --datadir=/var/lib/mysql --skip-grant-tables >/dev/null 2>&1 &
sleep 3

# Initialize databases and users
log "Creating JupyterHub and SLURM databases..."
mysql -u root << 'MYSQLEOF' || true
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE DATABASE IF NOT EXISTS jupyterhub CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'slurm'@'192.168.50.%' IDENTIFIED BY 'slurm_pass';
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY 'slurm_pass';
CREATE USER IF NOT EXISTS 'jupyterhub'@'192.168.50.%' IDENTIFIED BY 'jupyterhub_pass';
CREATE USER IF NOT EXISTS 'jupyterhub'@'localhost' IDENTIFIED BY 'jupyterhub_pass';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'192.168.50.%';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';
GRANT ALL PRIVILEGES ON jupyterhub.* TO 'jupyterhub'@'192.168.50.%';
GRANT ALL PRIVILEGES ON jupyterhub.* TO 'jupyterhub'@'localhost';
FLUSH PRIVILEGES;
MYSQLEOF

log "MariaDB initialized"

# ==============================================================================
# 4. SLURM SETUP
# ==============================================================================

log "Initializing SLURM..."

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

# Install SLURM if not present
if ! command -v slurmctld >/dev/null 2>&1 || ! command -v slurmdbd >/dev/null 2>&1; then
	die "SLURM not installed (build esi/naas:bookworm)"
fi
if ! command -v sacctmgr >/dev/null 2>&1; then
	die "SLURM accounting tools not installed (build esi/naas:bookworm)"
fi

# Copy SLURM config
cp /shared-configs/slurm.conf /etc/slurm/slurm.conf
cp /shared-configs/slurmdbd.conf /etc/slurm/slurmdbd.conf
chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/slurmdbd.conf
chmod 640 /etc/slurm/slurm.conf
chmod 600 /etc/slurm/slurmdbd.conf

log "SLURM files configured"

# ==============================================================================
# 5. MUNGE SETUP (SLURM authentication)
# ==============================================================================

log "Initializing Munge (SLURM auth)..."
mkdir -p /var/run/munge /etc/munge /var/log/munge
if ! command -v munged >/dev/null 2>&1; then
	die "Munge not installed (build esi/naas:bookworm)"
fi
if ! [ -f /etc/munge/munge.key ]; then
	dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key 2>/dev/null
	chmod 400 /etc/munge/munge.key
	chown munge:munge /etc/munge/munge.key
fi

# Start munge daemon
munged -L /var/log/munge/munged.log &
sleep 1
log "Munge started"

# ==============================================================================
# 6. SLURM DAEMONS
# ==============================================================================

log "Starting SLURM daemons..."

# Start slurmdbd (accounting daemon)
log "Starting slurmdbd..."
slurmdbd -Dv &
sleep 2

# Create default accounting associations
log "Creating SLURM associations..."
sacctmgr -i add cluster esi-hpc || true
sacctmgr -i add account admin,research,student Cluster=esi-hpc || true
sacctmgr -i add user admin Account=admin Cluster=esi-hpc || true
sacctmgr -i add user researcher-01,researcher-02 Account=research Cluster=esi-hpc || true
sacctmgr -i add user student-01,student-02,student-03 Account=student Cluster=esi-hpc || true

# Start slurmctld (controller daemon)
log "Starting slurmctld..."
slurmctld -Dv &
sleep 2

log "SLURM daemons started"

# ==============================================================================
# 7. PAM USERS INITIALIZATION
# ==============================================================================

log "Initializing PAM users and groups..."
sh /shared-configs/pam-users-init.sh

# ==============================================================================
# 8. JUPYTERHUB SETUP
# ==============================================================================

log "Setting up JupyterHub..."

if ! command -v jupyterhub >/dev/null 2>&1; then
	die "JupyterHub not installed (build esi/naas:bookworm)"
fi
if ! command -v configurable-http-proxy >/dev/null 2>&1; then
	die "configurable-http-proxy not installed (build esi/naas:bookworm)"
fi

if ! id jupyterhub >/dev/null 2>&1; then
	if command -v useradd >/dev/null 2>&1; then
		groupadd -r jupyterhub 2>/dev/null || true
		useradd -r -m -d /var/lib/jupyterhub -s "$NOLOGIN_SHELL" -g jupyterhub jupyterhub
	else
		grep -q '^jupyterhub:' /etc/group 2>/dev/null || addgroup -S jupyterhub
		adduser -D -H -G jupyterhub -s "$NOLOGIN_SHELL" -h /var/lib/jupyterhub jupyterhub
	fi
fi

# Create JupyterHub directories
mkdir -p /etc/jupyterhub /var/log/jupyterhub /var/lib/jupyterhub
chown -R jupyterhub:jupyterhub /etc/jupyterhub /var/lib/jupyterhub /var/log/jupyterhub

# Generate self-signed certificate if not present
if ! [ -f /etc/jupyterhub/jupyterhub.crt ]; then
	log "Generating self-signed TLS certificate..."
	openssl req -x509 -newkey rsa:2048 -keyout /etc/jupyterhub/jupyterhub.key \
		-out /etc/jupyterhub/jupyterhub.crt -days 365 -nodes \
		-subj "/C=FR/ST=Lab/L=ESI/O=ESI/CN=hpc-jupyter.esi.internal" \
		2>/dev/null || true
	chmod 600 /etc/jupyterhub/jupyterhub.key
	chown jupyterhub:jupyterhub /etc/jupyterhub/jupyterhub.crt /etc/jupyterhub/jupyterhub.key
fi

# Copy JupyterHub config
cp /shared-configs/jupyterhub_config.py /etc/jupyterhub/jupyterhub_config.py
chown jupyterhub:jupyterhub /etc/jupyterhub/jupyterhub_config.py

log "JupyterHub configured"

# ==============================================================================
# 9. REMOTE SYSLOG FORWARDING
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
# 10. FINAL STARTUP
# ==============================================================================

log "ADMIN-01 startup complete"
log "Services running:"
log "  - MariaDB (3306)"
log "  - SLURM Controller (6817)"
log "  - SLURM DBD (6819)"
log "  - Munge auth (11002)"
log "  - JupyterHub (8080)"


