#!/bin/bash
# tests/dhcp_verify.sh — DHCP section (Zitouni T4)
C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); return 0; }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); return 0; }
info(){ echo "  [INFO] $1"; return 0; }

restore_bond_static() {
  local NODE="$1"
  local STATIC_IP="$2"
  local GW="$3"

  $C-$NODE sh -lc "
    ip addr flush dev bond0
    ip addr add ${STATIC_IP}/24 dev bond0
    ip route replace default via ${GW} dev bond0
  " >/dev/null 2>&1 \
    && ok "$NODE: restored static ${STATIC_IP}/24" \
    || fail "$NODE: failed to restore static ${STATIC_IP}/24"
}

bond_dhcp_smoke() {
  local NODE="$1"
  local SUBNET_PREFIX="$2"
  local PEER_IP="$3"
  local STATIC_IP="$4"
  local GW="$5"

  local OUT
  OUT="$($C-$NODE sh -lc '
    ip addr flush dev bond0
    ip route del default 2>/dev/null || true
    udhcpc -f -q -n -t 3 -T 3 -i bond0
  ' 2>&1)"

  if [ $? -eq 0 ]; then
    ok "$NODE: udhcpc obtained lease on bond0"
  else
    fail "$NODE: udhcpc failed to obtain lease on bond0"
    info "$NODE udhcpc output:"
    echo "$OUT" | sed 's/^/    /'
  fi

  $C-$NODE sh -lc "ip -4 -o addr show dev bond0" 2>/dev/null | grep -Eq "inet ${SUBNET_PREFIX}\\." \
    && ok "$NODE: bond0 received ${SUBNET_PREFIX}.x address" \
    || fail "$NODE: bond0 did not receive ${SUBNET_PREFIX}.x address"

  $C-$NODE ping -c2 -W2 "$PEER_IP" >/dev/null 2>&1 \
    && ok "$NODE: can reach peer ${PEER_IP} after DHCP lease" \
    || fail "$NODE: cannot reach peer ${PEER_IP} after DHCP lease"

  restore_bond_static "$NODE" "$STATIC_IP" "$GW"
}

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
  
# 7. Bonded endpoint DHCP smoke tests (udhcpc applies lease on bond0)
bond_dhcp_smoke "server-student-01" "192.168.10" "192.168.10.20" "192.168.10.10" "192.168.10.1"
bond_dhcp_smoke "server-hpc-01" "192.168.70" "192.168.70.20" "192.168.70.10" "192.168.70.1"

# 8. Static reservations: infrastructure IPs are in config
for HOST_IP in 192.168.50.20 192.168.50.30 192.168.50.40 192.168.50.60; do
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
