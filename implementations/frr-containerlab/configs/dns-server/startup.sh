#!/bin/sh
# =============================================================================
# configs/dns-server/setup.sh
# Node    : dns-server  (192.168.50.30 | VNI 10050 CORE-INFRA | VRF-STAFF)
# Role    : Recursive DNS resolver (Unbound) + authoritative for esi.internal
# Owner   : Zitouni - T4 (feature/protocols-monitoring)
#
# Implements:
#   Change 7 : DNS split-horizon (NXDOMAIN for esi.internal from VRF-PUBLIC)
#   Change 8 : rsyslog TCP/514 forwarding
#   Ring 5   : nftables per-host micro-segmentation baseline
#
# Dependencies:
#   eth1 = CORE-INFRA data-plane (leaf-03/04 VLAN50 bridge)
#   eth0 = ContainerLab OOB management (172.16.0.0/24)
# =============================================================================

set -e

# ======================================================
# THEME T4 - PROTOCOL EXTENSIONS & MONITORING - Zitouni
# Branch: feature/protocols-monitoring
# ======================================================

NODE="dns-server"
log() { echo "[${NODE}] $*"; }

log "Starting DNS server configuration..."

# ---------------------------------------------------------------------------
# 1. Install packages
# ---------------------------------------------------------------------------
log "Installing packages..."
apk add --no-cache unbound nftables rsyslog bind-tools > /dev/null 2>&1

# ---------------------------------------------------------------------------
# 2. Network: eth1 = CORE-INFRA (192.168.50.30/24)
#    Default gateway = 192.168.50.1 (anycast GW on admin-leaf VLAN50 SVI)
# ---------------------------------------------------------------------------
log "Configuring eth1 (192.168.50.30/24)..."
ip addr flush dev eth1 2>/dev/null || true
ip addr add 192.168.50.30/24 dev eth1
ip link set eth1 up
ip route replace default via 192.168.50.1 dev eth1 2>/dev/null || \
ip route add    default via 192.168.50.1 dev eth1
log "eth1 ready: $(ip addr show eth1 | grep 'inet ')"

# ---------------------------------------------------------------------------
# 3. Write Unbound config (split-horizon: internal view + dmz view)
# ---------------------------------------------------------------------------
log "Writing Unbound configuration..."
UNBOUND_DIR="/etc/unbound"
mkdir -p "${UNBOUND_DIR}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/unbound.conf" ]; then
    cp "${SCRIPT_DIR}/unbound.conf" "${UNBOUND_DIR}/unbound.conf"
    log "Copied unbound.conf from script directory"
else
    log "Writing inline unbound.conf..."
    cat > "${UNBOUND_DIR}/unbound.conf" << 'UNBOUNDEOF'
server:
  verbosity: 1
  interface: 0.0.0.0
  port: 53
  do-ip4: yes
  do-ip6: no
  do-udp: yes
  do-tcp: yes
  access-control: 127.0.0.0/8       allow
  access-control: 10.0.0.0/8        allow
  access-control: 172.16.0.0/12     allow
  access-control: 192.168.0.0/16    allow
  num-threads: 2
  msg-cache-size: 16m
  rrset-cache-size: 32m
  cache-min-ttl: 30
  prefetch: yes
  hide-identity: yes
  hide-version: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
  use-caps-for-id: yes
  module-config: "iterator"
  # Split-horizon routing by source address
  access-control-view: 192.168.10.0/24  internal
  access-control-view: 192.168.20.0/24  internal
  access-control-view: 192.168.30.0/24  internal
  access-control-view: 192.168.40.0/24  internal
  access-control-view: 192.168.50.0/24  internal
  access-control-view: 192.168.60.0/24  internal
  access-control-view: 192.168.70.0/24  internal
  access-control-view: 192.168.80.0/24  internal
  access-control-view: 192.168.90.0/24  internal
  access-control-view: 10.0.0.0/8       internal
  access-control-view: 172.16.0.0/24    internal
  access-control-view: 192.168.100.0/24 dmz
  access-control-view: 127.0.0.0/8      internal

# -----------------------------------------------------------------------
# INTERNAL VIEW: full esi.internal resolution
# Clients: all VRFs except VRF-PUBLIC
# -----------------------------------------------------------------------
view:
  name: "internal"
  local-zone: "." transparent
  local-zone: "esi.internal." static
  local-zone: "50.168.192.in-addr.arpa." static
  # Spines
  local-data: "spine-01.esi.internal.       300 IN A 10.1.0.1"
  local-data: "spine-02.esi.internal.       300 IN A 10.1.0.2"
  # Border leafs (leaf-01/02)
  local-data: "leaf-01.esi.internal.        300 IN A 10.1.0.11"
  local-data: "border-leaf-01.esi.internal. 300 IN A 10.1.0.11"
  local-data: "leaf-02.esi.internal.        300 IN A 10.1.0.12"
  local-data: "border-leaf-02.esi.internal. 300 IN A 10.1.0.12"
  # Admin leafs (leaf-03/04)
  local-data: "leaf-03.esi.internal.        300 IN A 10.1.0.13"
  local-data: "admin-leaf-01.esi.internal.  300 IN A 10.1.0.13"
  local-data: "leaf-04.esi.internal.        300 IN A 10.1.0.14"
  local-data: "admin-leaf-02.esi.internal.  300 IN A 10.1.0.14"
  # HPC leafs (leaf-05/06)
  local-data: "leaf-05.esi.internal.        300 IN A 10.1.0.15"
  local-data: "hpc-leaf-01.esi.internal.    300 IN A 10.1.0.15"
  local-data: "leaf-06.esi.internal.        300 IN A 10.1.0.16"
  local-data: "hpc-leaf-02.esi.internal.    300 IN A 10.1.0.16"
  # Storage leafs (leaf-07/08)
  local-data: "leaf-07.esi.internal.        300 IN A 10.1.0.17"
  local-data: "storage-leaf-01.esi.internal. 300 IN A 10.1.0.17"
  local-data: "leaf-08.esi.internal.        300 IN A 10.1.0.18"
  local-data: "storage-leaf-02.esi.internal. 300 IN A 10.1.0.18"
  # Student leafs (leaf-09/10)
  local-data: "leaf-09.esi.internal.        300 IN A 10.1.0.19"
  local-data: "student-leaf-01.esi.internal. 300 IN A 10.1.0.19"
  local-data: "leaf-10.esi.internal.        300 IN A 10.1.0.20"
  local-data: "student-leaf-02.esi.internal. 300 IN A 10.1.0.20"
  # ISP routers
  local-data: "isp-router-01.esi.internal.  300 IN A 100.64.0.1"
  local-data: "isp-router-02.esi.internal.  300 IN A 100.64.0.2"
  local-data: "isp-router-03.esi.internal.  300 IN A 100.64.0.3"
  # Firewalls
  local-data: "firewall-01.esi.internal.    300 IN A 192.168.1.1"
  local-data: "firewall-02.esi.internal.    300 IN A 192.168.1.2"
  local-data: "firewall-vip.esi.internal.   300 IN A 192.168.1.254"
  # OOB / Bastion / IDS
  local-data: "bastion-01.esi.internal.     300 IN A 172.16.0.50"
  local-data: "bastion.esi.internal.        300 IN A 172.16.0.50"
  local-data: "ids-01.esi.internal.         300 IN A 172.16.0.51"
  local-data: "ids.esi.internal.            300 IN A 172.16.0.51"
  # CORE-INFRA (192.168.50.0/24)
  local-data: "ntp-server.esi.internal.     300 IN A 192.168.50.20"
  local-data: "ntp.esi.internal.            300 IN A 192.168.50.20"
  local-data: "dns-server.esi.internal.     300 IN A 192.168.50.30"
  local-data: "dns.esi.internal.            300 IN A 192.168.50.30"
  local-data: "dhcp-server.esi.internal.    300 IN A 192.168.50.40"
  local-data: "dhcp.esi.internal.           300 IN A 192.168.50.40"
  local-data: "zabbix-server.esi.internal.  300 IN A 192.168.50.50"
  local-data: "zabbix.esi.internal.         300 IN A 192.168.50.50"
  local-data: "prometheus.esi.internal.     300 IN A 192.168.50.60"
  local-data: "syslog-server.esi.internal.  300 IN A 192.168.50.70"
  local-data: "syslog.esi.internal.         300 IN A 192.168.50.70"
  # Storage pod
  local-data: "ftp-server.esi.internal.     300 IN A 192.168.80.10"
  local-data: "ftp.esi.internal.            300 IN A 192.168.80.10"
  # WiFi controller
  local-data: "wifi-controller.esi.internal. 300 IN A 192.168.10.100"
  local-data: "wifi.esi.internal.           300 IN A 192.168.10.100"
  # PTR records (CORE-INFRA reverse zone)
  local-data-ptr: "192.168.50.20  ntp-server.esi.internal."
  local-data-ptr: "192.168.50.30  dns-server.esi.internal."
  local-data-ptr: "192.168.50.40  dhcp-server.esi.internal."
  local-data-ptr: "192.168.50.50  zabbix-server.esi.internal."
  local-data-ptr: "192.168.50.60  prometheus.esi.internal."
  local-data-ptr: "192.168.50.70  syslog-server.esi.internal."
  local-zone: "1.10.in-addr.arpa." static

# -----------------------------------------------------------------------
# DMZ VIEW: NXDOMAIN for esi.internal
# Clients: VRF-PUBLIC (192.168.100.0/24)
# Change 7: "query for an internal hostname from the DMZ returns NXDOMAIN"
# -----------------------------------------------------------------------
view:
  name: "dmz"
  local-zone: "esi.internal."             refuse
  local-zone: "50.168.192.in-addr.arpa."  refuse
  local-zone: "1.10.in-addr.arpa."        refuse
  local-zone: "16.172.in-addr.arpa."      refuse
  local-zone: "168.192.in-addr.arpa."     refuse
  local-zone: "." transparent
UNBOUNDEOF
fi

# ---------------------------------------------------------------------------
# 4. Validate config
# ---------------------------------------------------------------------------
log "Validating Unbound configuration..."
unbound-checkconf "${UNBOUND_DIR}/unbound.conf"
log "Config OK"

# ---------------------------------------------------------------------------
# 5. Ring 5 nftables micro-segmentation
#    Baseline: INPUT DROP; ESTABLISHED accept; DNS from all internal VRFs;
#              SSH only from bastion-01 (172.16.0.50)
# ---------------------------------------------------------------------------
log "Applying Ring 5 nftables..."

nft flush ruleset 2>/dev/null || true

nft -- add table inet filter
nft -- add chain inet filter input  '{ type filter hook input  priority 0; policy drop; }'
nft -- add chain inet filter output '{ type filter hook output priority 0; policy accept; }'
nft -- add chain inet filter forward '{ type filter hook forward priority 0; policy drop; }'

# Established/related - must be first
nft -- add rule inet filter input ct state established,related accept
nft -- add rule inet filter input ct state invalid drop

# Loopback
nft -- add rule inet filter input iif lo accept

# ICMP ping from internal address space
nft -- add rule inet filter input ip protocol icmp \
    ip saddr '{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }' \
    icmp type echo-request accept

# SSH from bastion only (Ring 4 enforcement)
nft -- add rule inet filter input tcp dport 22 ip saddr 172.16.0.50 accept

# DNS UDP/53 from internal VRFs
nft -- add rule inet filter input udp dport 53 \
    ip saddr '{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }' accept

# DNS TCP/53 from internal VRFs (large responses, zone transfers)
nft -- add rule inet filter input tcp dport 53 \
    ip saddr '{ 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }' accept

# Prometheus node_exporter scrape (from prometheus at 192.168.50.60)
nft -- add rule inet filter input tcp dport 9100 ip saddr 192.168.50.60 accept

log "Ring 5 nftables ruleset applied"
nft list ruleset | head -40

# ---------------------------------------------------------------------------
# 6. rsyslog TCP/514 forwarding (Change 8)
#    @@ = TCP (reliable); @ = UDP
# ---------------------------------------------------------------------------
log "Configuring rsyslog TCP/514 forwarding to 192.168.50.70..."

if command -v rsyslogd > /dev/null 2>&1; then
    # Remove any prior syslog forward lines to avoid duplicates
    grep -v "192.168.50.70" /etc/rsyslog.conf > /tmp/rsyslog_new.conf 2>/dev/null \
        || cp /etc/rsyslog.conf /tmp/rsyslog_new.conf

    cat >> /tmp/rsyslog_new.conf << 'RSYSEOF'

# ======================================================
# THEME T4 - PROTOCOL EXTENSIONS - Zitouni
# Change 8: TCP/514 preferred over UDP (@@ = TCP)
# ======================================================
*.* @@192.168.50.70:514
RSYSEOF

    mv /tmp/rsyslog_new.conf /etc/rsyslog.conf
    rsyslogd -n &
    log "rsyslogd started (PID $!)"
else
    log "WARNING: rsyslogd not found"
fi

# ---------------------------------------------------------------------------
# 7. Start Unbound in foreground
# ---------------------------------------------------------------------------
log "====================================================="
log "DNS server 192.168.50.30 starting Unbound..."
log "  Internal view : full esi.internal resolution"
log "  DMZ view      : NXDOMAIN for esi.internal (Change 7)"
log "====================================================="

id unbound > /dev/null 2>&1 || adduser -S -D -H unbound 2>/dev/null || true
chown -R unbound:unbound "${UNBOUND_DIR}" 2>/dev/null || true

exec unbound -c "${UNBOUND_DIR}/unbound.conf" -d