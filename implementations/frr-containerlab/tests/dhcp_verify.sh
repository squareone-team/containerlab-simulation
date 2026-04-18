#!/bin/bash
# tests/dhcp_verify.sh — DHCP section (Zitouni T4)
C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); return 0; }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); return 0; }
info(){ echo "  [INFO] $1"; return 0; }

echo "=== T4: DHCP Verification ==="

# 1. Kea process running
$C-dhcp-server pgrep kea-dhcp4 > /dev/null 2>&1 \
  && ok "dhcp-server: kea-dhcp4 process running" \
  || fail "dhcp-server: kea-dhcp4 not running"

# 2. Kea config passes validation
$C-dhcp-server kea-dhcp4 -t /etc/kea/kea-dhcp4.conf > /dev/null 2>&1 \
  && ok "dhcp-server: kea config valid" \
  || fail "dhcp-server: kea config invalid — run: docker exec clab-esi-datacenter-dhcp-server kea-dhcp4 -t /etc/kea/kea-dhcp4.conf"

# 3. Kea listening on UDP/67
$C-dhcp-server netstat -ulnp 2>/dev/null | grep -q ":67" \
  || $C-dhcp-server cat /proc/net/udp 2>/dev/null | grep -qi ":0043" \
  && ok "dhcp-server: listening on UDP/67" \
  || fail "dhcp-server: not listening on UDP/67"

# 4. IP address assigned and reachable
$C-dhcp-server ip -4 -o addr show 2>/dev/null | grep -q "192.168.50.40" \
  && ok "dhcp-server: 192.168.50.40 address is configured" \
  || fail "dhcp-server: 192.168.50.40 not assigned"

# 5. Reachable from fabric (leaf-03 is on same VLAN 50)
$C-leaf-03 ping -c2 -W2 192.168.50.40 > /dev/null 2>&1 \
  && ok "dhcp-server: reachable from leaf-03 (same subnet)" \
  || fail "dhcp-server: not reachable from leaf-03"

# 6. Reachable from remote leaf (relay path through EVPN)
$C-leaf-09 ping -c2 -W2 192.168.50.40 > /dev/null 2>&1 \
  && ok "dhcp-server: reachable from leaf-09 (EVPN relay path)" \
  || { fail "dhcp-server: not reachable from leaf-09 (relay path broken)"; \
       info "check: ip route show vrf VRF-STAFF on leaf-09 — 192.168.50.0/24 must be present via EVPN Type-5"; }

# 7. DHCP relay running on leaf SVIs
for NODE in leaf-03 leaf-09; do
  $C-$NODE pgrep -x dhcrelay > /dev/null 2>&1 \
    && ok "$NODE: dhcrelay process running" \
    || { fail "$NODE: dhcrelay not running"; \
         info "$NODE: dhcrelay must forward client DISCOVER packets to 192.168.50.40"; }
done

# 8. Static reservations: infrastructure IPs are in config
for HOST_IP in 192.168.50.20 192.168.50.30 192.168.50.40 192.168.50.50 192.168.50.60 192.168.50.70; do
  $C-dhcp-server grep -q "\"$HOST_IP\"" /etc/kea/kea-dhcp4.conf 2>/dev/null \
    && ok "dhcp-server: static reservation present for $HOST_IP" \
    || fail "dhcp-server: missing static reservation for $HOST_IP"
done

# 9. All VNI subnets have a subnet block defined
info "verifying all VNI subnets are declared in Kea config"
for SUBNET in "192.168.10.0/24" "192.168.20.0/24" "192.168.30.0/24" \
              "192.168.40.0/24" "192.168.50.0/24" "192.168.60.0/24" \
              "192.168.70.0/24" "192.168.80.0/24"; do
  $C-dhcp-server grep -q "\"subnet\": \"$SUBNET\"" /etc/kea/kea-dhcp4.conf 2>/dev/null \
    && ok "dhcp-server: subnet $SUBNET declared" \
    || fail "dhcp-server: subnet $SUBNET missing from kea config"
done

# 10. NTP and DNS options present globally
$C-dhcp-server grep -q "192.168.50.20" /etc/kea/kea-dhcp4.conf 2>/dev/null \
  && ok "dhcp-server: NTP option (192.168.50.20) configured" \
  || fail "dhcp-server: NTP server option missing"

$C-dhcp-server grep -q "192.168.50.30" /etc/kea/kea-dhcp4.conf 2>/dev/null \
  && ok "dhcp-server: DNS option (192.168.50.30) configured" \
  || fail "dhcp-server: DNS server option missing"

# 11. Lease file exists (Kea has been handling requests)
$C-dhcp-server test -f /var/lib/kea/kea-leases4.csv 2>/dev/null \
  && ok "dhcp-server: lease file exists" \
  || { fail "dhcp-server: lease file missing — no leases issued yet"; \
       info "trigger a DHCP request with: docker exec clab-esi-datacenter-server-student-01 udhcpc -i eth1 -n -t 5"; }

echo ""
echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "DHCP checks PASSED" || echo "Issues found — see [FAIL] lines above"