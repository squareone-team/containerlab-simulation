#!/bin/sh
# ==============================================================================
# configs/server-hpc-jupyter/startup.sh
# ==============================================================================
# JupyterHub Frontend Node
# Role: TLS-terminating reverse proxy for JupyterHub users
# - Accepts HTTPS on port 8080 (mapped to host port 9000)
# - Forwards to JupyterHub controller on Admin pod (192.168.50.10:8000)
# - Uses configurable-http-proxy (already in image) for TLS + WebSocket support
#
# Idempotent: Safe to run multiple times
# ==============================================================================

set -e

log() { echo "[JUPYTER-FRONTEND-STARTUP] $*"; }
die() { echo "[JUPYTER-FRONTEND-STARTUP] ERROR: $*" >&2; exit 1; }

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

		# Allow JupyterHub frontend (port 8080) from any source
		# (Docker host NAT uses 0.0.0.0 DNAT for port 9000->8080)
		tcp dport 8080 accept

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
# 3. TLS CERTIFICATE (self-signed for https on port 8080)
# ==============================================================================

log "Generating self-signed TLS certificate..."
mkdir -p /etc/jupyterhub-proxy/ssl

if ! [ -f /etc/jupyterhub-proxy/ssl/server.crt ]; then
	openssl req -x509 -newkey rsa:2048 \
		-keyout /etc/jupyterhub-proxy/ssl/server.key \
		-out    /etc/jupyterhub-proxy/ssl/server.crt \
		-days 365 -nodes \
		-subj "/C=FR/ST=Lab/L=ESI/O=ESI/CN=hpc-jupyter.esi.internal" \
		2>/dev/null
	log "TLS certificate generated"
else
	log "TLS certificate already exists"
fi

# ==============================================================================
# 4. TLS REVERSE PROXY via configurable-http-proxy
# ==============================================================================
# configurable-http-proxy is installed with JupyterHub (npm package).
# It supports TLS termination and full WebSocket proxying - perfect for JupyterHub.
# Port 8080 (HTTPS) --> http://192.168.50.10:8000 (JupyterHub on admin pod)
# ==============================================================================

log "Starting configurable-http-proxy (TLS on :8080 -> http://192.168.50.10:8000)..."

if ! command -v configurable-http-proxy >/dev/null 2>&1; then
	die "configurable-http-proxy not found (build esi/naas:bookworm)"
fi

# Kill any existing proxy
pkill -f "configurable-http-proxy" 2>/dev/null || true
sleep 1

configurable-http-proxy \
	--port 8080 \
	--api-port 8090 \
	--default-target http://192.168.50.10:8000 \
	--ssl-key  /etc/jupyterhub-proxy/ssl/server.key \
	--ssl-cert /etc/jupyterhub-proxy/ssl/server.crt \
	--log-level info \
	>> /var/log/jupyterhub-proxy.log 2>&1 &

PROXY_PID=$!
sleep 3

if kill -0 $PROXY_PID 2>/dev/null; then
	log "configurable-http-proxy started (pid=$PROXY_PID)"
	log "HTTPS proxy listening on port 8080"
else
	log "ERROR: configurable-http-proxy failed to start"
	log "Last log lines:"
	tail -10 /var/log/jupyterhub-proxy.log 2>/dev/null || true
fi

# ==============================================================================
# 5. WAIT FOR JUPYTERHUB CONTROLLER (background health check)
# ==============================================================================

log "Starting background health check for JupyterHub controller (192.168.50.10:8000)..."
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
		sleep 5
	done
	log "JupyterHub controller reachable at 192.168.50.10:8000"
) &

# ==============================================================================
# 6. REMOTE SYSLOG FORWARDING
# ==============================================================================

log "Configuring remote syslog..."
if command -v rsyslogd >/dev/null 2>&1; then
	cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@172.20.20.70:514
RSYSLOG
	/usr/sbin/rsyslogd &
	log "rsyslogd started"
elif command -v syslogd >/dev/null 2>&1; then
	mkdir -p /var/log
	touch /var/log/messages
	syslogd -L -O /var/log/messages -R 172.20.20.70:514 &
	log "syslogd started with remote forwarding"
else
	log "WARN: no syslog daemon found"
fi

# ==============================================================================
# 7. FINAL STARTUP
# ==============================================================================

log "JupyterHub frontend startup complete"
log "Services ready:"
log "  - configurable-http-proxy (HTTPS) on port 8080"
log "  - Forwarding to JupyterHub at http://192.168.50.10:8000"
log "  - Host access: https://localhost:9000/"
