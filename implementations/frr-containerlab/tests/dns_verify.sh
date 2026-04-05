#!/bin/bash
# =============================================================================
# tests/dns_verify.sh
# Theme   : T4 — Protocol Extensions & Monitoring
# Section : DNS Verification 
# Run as  : bash tests/dns_verify.sh
# =============================================================================

set +o pipefail

C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "  [INFO] $1"; }

chk() {
    local label="$1" cmd="$2" pattern="$3"
    if eval "$cmd" 2>/dev/null | grep -Eq "$pattern"; then
        ok "$label"
    else
        fail "$label"
    fi
}

echo ""
echo "=== T4: DNS Split-Horizon Verification ==="
echo "    dns-server: 192.168.50.30 | VNI 10050 | VRF-STAFF"
echo ""

# ---------------------------------------------------------------------------
# 1. Unbound process health
# ---------------------------------------------------------------------------
echo "--- 1. Service health ---"

chk "Unbound process running on dns-server" \
    "$C-dns-server pgrep unbound" \
    "[0-9]+"

chk "Unbound listening on UDP/53" \
    "$C-dns-server grep -i '00350000\|0035 ' /proc/net/udp" "."

chk "Unbound listening on TCP/53" \
    "$C-dns-server grep -i '00350000\|0035 ' /proc/net/tcp" "."

# ---------------------------------------------------------------------------
# 2. Network reachability
# ---------------------------------------------------------------------------
echo ""
echo "--- 2. Network reachability ---"

chk "dns-server has 192.168.50.30 configured" \
    "$C-dns-server ip addr show eth1" \
    "192.168.50.30"

chk "dns-server default route via 192.168.50.1" \
    "$C-dns-server ip route show default" \
    "192.168.50.1"

chk "dns-server reachable from admin server (ping)" \
    "$C-server-admin-01 ping -c2 -W2 192.168.50.30" \
    "2 (packets )?received"

# ---------------------------------------------------------------------------
# 3. Internal view — esi.internal zone resolution
#    Clients in VRF-STAFF / VRF-PEDAGOGY should resolve all esi.internal names
# ---------------------------------------------------------------------------
echo ""
echo "--- 3. Internal view (full esi.internal) ---"

# Spine lookup from admin server (VRF-STAFF)
chk "Internal: spine-01.esi.internal resolves from admin server" \
    "$C-server-admin-01 nslookup spine-01.esi.internal 192.168.50.30" \
    "Address.*10\.1\.0\.1"

chk "Internal: spine-02.esi.internal resolves correctly" \
    "$C-server-admin-01 nslookup spine-02.esi.internal 192.168.50.30" \
    "Address.*10\.1\.0\.2"

chk "Internal: dns-server.esi.internal self-resolves" \
    "$C-dns-server nslookup dns-server.esi.internal 127.0.0.1" \
    "Address.*192\.168\.50\.30"

chk "Internal: ntp-server.esi.internal resolves" \
    "$C-server-admin-01 nslookup ntp-server.esi.internal 192.168.50.30" \
    "Address.*192\.168\.50\.20"

chk "Internal: bastion-01.esi.internal resolves" \
    "$C-server-admin-01 nslookup bastion-01.esi.internal 192.168.50.30" \
    "Address.*172\.16\.0\.50"

chk "Internal: wifi-controller.esi.internal resolves" \
    "$C-server-admin-01 nslookup wifi-controller.esi.internal 192.168.50.30" \
    "Address.*192\.168\.10\.100"

# PTR record verification
chk "Reverse PTR: 192.168.50.30 -> dns-server.esi.internal" \
    "$C-server-admin-01 nslookup 192.168.50.30 192.168.50.30" \
    "dns-server.esi.internal"

# Resolution from student VRF (VRF-PEDAGOGY - should also get internal view)
info "PREREQ T3: student→DNS cross-VRF requires firewall — skipped until T3 merged"
# chk "Internal view also works from VRF-PEDAGOGY (student server)" \
#     "$C-server-student-01 nslookup spine-01.esi.internal 192.168.50.30" \
#     "Address.*10\.1\.0\.1"

# ---------------------------------------------------------------------------
# 4. DMZ view — NXDOMAIN for esi.internal (Change 7)
#    VRF-PUBLIC clients (192.168.100.0/24) must get NXDOMAIN
# ---------------------------------------------------------------------------
echo ""
echo "--- 4. DMZ view (NXDOMAIN enforcement - Change 7) ---"

# Primary test: server-dmz-01 is in VRF-PUBLIC (192.168.100.0/24)
chk "Change 7: DMZ view configured to refuse esi.internal" \
    "$C-dns-server grep -A20 'name.*dmz' /etc/unbound/unbound.conf" \
    "refuse"

info "Change 7 live test (NXDOMAIN from server-dmz-01) requires firewall T3 — skipped"
# chk "Change 7: DMZ gets NXDOMAIN for spine-01.esi.internal" \
#     "$C-server-dmz-01 nslookup spine-01.esi.internal 192.168.50.30" \
#     "NXDOMAIN\|server can't find\|can.t find"

# chk "Change 7: DMZ gets NXDOMAIN for dns-server.esi.internal" \
#     "$C-server-dmz-01 nslookup dns-server.esi.internal 192.168.50.30" \
#     "NXDOMAIN\|server can't find\|can.t find"

# chk "Change 7: DMZ gets NXDOMAIN for firewall-01.esi.internal" \
#     "$C-server-dmz-01 nslookup firewall-01.esi.internal 192.168.50.30" \
#     "NXDOMAIN\|server can't find\|can.t find"

# Verify DMZ can still resolve public names (transparent for public DNS)
info "Checking DMZ can resolve public DNS (google.com) — may fail if no upstream..."
$C-server-dmz-01 nslookup google.com 192.168.50.30 2>/dev/null | grep -q "Address" \
    && ok  "DMZ view: public DNS (google.com) resolves for VRF-PUBLIC" \
    || info "DMZ view: public DNS not reachable (expected in isolated lab — not a FAIL)"

# ---------------------------------------------------------------------------
# 5. Config file verification
# ---------------------------------------------------------------------------
echo ""
echo "--- 5. Configuration file checks ---"

chk "Unbound config exists" \
    "$C-dns-server ls /etc/unbound/unbound.conf" \
    "unbound.conf"

chk "Unbound config has internal view" \
    "$C-dns-server grep -c 'name.*internal' /etc/unbound/unbound.conf" \
    "[1-9]"

chk "Unbound config has dmz view" \
    "$C-dns-server grep -c 'name.*dmz' /etc/unbound/unbound.conf" \
    "[1-9]"

chk "DMZ view has refuse for esi.internal" \
    "$C-dns-server grep 'esi.internal' /etc/unbound/unbound.conf" \
    "refuse"

chk "access-control-view maps 192.168.100.0/24 to dmz" \
    "$C-dns-server grep 'access-control-view' /etc/unbound/unbound.conf" \
    "192.168.100.0.*dmz"

# ---------------------------------------------------------------------------
# 6. Ring 5 nftables
# ---------------------------------------------------------------------------
echo ""
echo "--- 6. Ring 5 nftables micro-segmentation ---"

chk "Ring 5: nftables input chain has default drop policy" \
    "$C-dns-server nft list chain inet filter input" \
    "policy drop"

chk "Ring 5: SSH only from bastion (172.16.0.50)" \
    "$C-dns-server nft list ruleset" \
    "172.16.0.50"

chk "Ring 5: DNS port 53 in nftables accept rules" \
    "$C-dns-server nft list ruleset" \
    "dport 53"

# ---------------------------------------------------------------------------
# 7. rsyslog TCP/514 (Change 8)
# ---------------------------------------------------------------------------
echo ""
echo "--- 7. rsyslog TCP/514 forwarding (Change 8) ---"

chk "rsyslogd running on dns-server" \
    "$C-dns-server pgrep rsyslogd" \
    "[0-9]+"

chk "rsyslog config uses TCP (@@) to syslog-server" \
    "$C-dns-server grep '@@192.168.50.70:514' /etc/rsyslog.conf" \
    "@@192.168.50.70:514"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================"
echo "DNS Test Results: ${PASS} passed / ${FAIL} failed"
[ "${FAIL}" -eq 0 ] \
    && echo "DNS split-horizon READY" \
    || echo "NOT ready — fix failures above"
echo "======================================"

exit "${FAIL}"