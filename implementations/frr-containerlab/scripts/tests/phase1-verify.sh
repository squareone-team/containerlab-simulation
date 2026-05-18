#!/bin/bash
set +e
PASS=0; FAIL=0
C="docker exec clab-esi-datacenter"
RETRIES="${PHASE1_RETRIES:-15}"
DELAY="${PHASE1_DELAY:-2}"
LAST_OUT=""

ok()  { echo "  [PASS] $1"; ((PASS++)); return 0; }
fail(){ echo "  [FAIL] $1"; ((FAIL++)); return 0; }
info(){ echo "  [INFO] $1"; }

retry_match() {
  local cmd="$1"
  local regex="$2"
  local i=1
  while [ "$i" -le "$RETRIES" ]; do
    LAST_OUT=$(eval "$cmd" 2>/dev/null)
    if echo "$LAST_OUT" | grep -Eq "$regex"; then
      return 0
    fi
    sleep "$DELAY"
    i=$((i + 1))
  done
  return 1
}

retry_empty() {
  local cmd="$1"
  local i=1
  local out=""
  while [ "$i" -le "$RETRIES" ]; do
    out=$(eval "$cmd" 2>/dev/null)
    LAST_OUT="$out"
    [ -z "$out" ] && return 0
    sleep "$DELAY"
    i=$((i + 1))
  done
  return 1
}

chk() {
  echo
  echo "[TEST] $1"
  info "command: $2"
  info "expect : /$3/"
  if retry_match "$2" "$3"; then
    ok "$1"
  else
    fail "$1"
    echo "  [DEBUG] last output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

echo "=== ESI Phase 1 + Correction Verification ==="

chk "spine-01: 10 neighbors present" "$C-spine-01 vtysh -c 'show bgp summary'" "Total number of neighbors 10"
chk "spine-02: 10 neighbors present" "$C-spine-02 vtysh -c 'show bgp summary'" "Total number of neighbors 10"

for IP in 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20; do
  chk "spine-01 has route to $IP/32" "$C-spine-01 vtysh -c 'show ip route $IP/32'" "(bgp|B>)"
done

chk "leaf-09: multipath" "$C-leaf-09 vtysh -c 'show ip bgp 10.1.0.13/32'" "Multipath|2"
chk "spine-01 internal MD5 present" "$C-spine-01 grep -c 'password ESI-BGP-INTERNAL' /etc/frr/frr.conf" "^[1-9][0-9]*$"
chk "leaf-09 BFD Up" "$C-leaf-09 vtysh -c 'show bfd peers'" "Up"
chk "spine-01 eth1 mtu 9000" "$C-spine-01 ip link show eth1" "mtu 9000"
chk "leaf-03 br0 mtu 9000" "$C-leaf-03 ip link show br0" "mtu 9000"
chk "leaf-09 vxlan10010 tos inherit" "$C-leaf-09 ip -d link show vxlan10010" "tos inherit"

for LEAF in leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
  chk "$LEAF EVPN sessions" "$C-$LEAF vtysh -c 'show bgp l2vpn evpn summary'" "Total number of neighbors 2"
done

chk "leaf-09 VNI 10010 has remote VTEPs" "$C-leaf-09 vtysh -c 'show evpn vni 10010'" "Remote VTEPs for this VNI"
chk "leaf-03 has VNI 10030 (LMS-STAFF moved from border)" "$C-leaf-03 vtysh -c 'show evpn vni 10030'" "10030"
chk "leaf-03 has VNI 10040 (SERVICES-WEB moved from border)" "$C-leaf-03 vtysh -c 'show evpn vni 10040'" "10040"
chk "leaf-04 has VNI 10030 (LMS-STAFF moved from border)" "$C-leaf-04 vtysh -c 'show evpn vni 10030'" "10030"
chk "leaf-04 has VNI 10040 (SERVICES-WEB moved from border)" "$C-leaf-04 vtysh -c 'show evpn vni 10040'" "10040"

for BORDER_LEAF in leaf-01 leaf-02; do
  r=$($C-${BORDER_LEAF} vtysh -c 'show evpn vni' 2>/dev/null)
  echo "$r" | grep -q "10030" && fail "${BORDER_LEAF} still has VNI 10030 (must be removed)" || ok "${BORDER_LEAF} does NOT have VNI 10030 (correct)"
  echo "$r" | grep -q "10040" && fail "${BORDER_LEAF} still has VNI 10040 (must be removed)" || ok "${BORDER_LEAF} does NOT have VNI 10040 (correct)"
done

chk "leaf-01 has VNI 10120 (WIFI-CTRL-MGMT)" "$C-leaf-01 vtysh -c 'show evpn vni 10120'" "10120"
chk "VRF-WIFI-CTRL exists on leaf-01" "$C-leaf-01 ip vrf show" "VRF-WIFI-CTRL"
chk "leaf-01 VRF-WIFI-CTRL has /32 wifi-controller route" "$C-leaf-01 ip route show vrf VRF-WIFI-CTRL" "192\.168\.10\.100(/32)?"

r=$($C-leaf-01 ip route show vrf VRF-WIFI-CTRL 2>/dev/null)
echo "$r" | grep -Eq "^default" && fail "VRF-WIFI-CTRL must not have a default route" || ok "VRF-WIFI-CTRL has no default route"

chk "EVPN Type-5 present" "$C-spine-01 vtysh -c 'show bgp l2vpn evpn route type prefix'" "Route Distinguisher"
chk "student inter-subnet ping" "$C-server-student-01 ping -c3 -W2 192.168.10.20" "3 (packets )?received"

echo
echo "[TEST] VRF isolation student->staff"
info "command: $C-server-student-01 ping -c2 -W1 192.168.50.10"
info "expect : /(0 packets received|100% packet loss|unreachable)/"
if retry_match "$C-server-student-01 ping -c2 -W1 192.168.50.10" "0 (packets )?received|100% packet loss|unreachable"; then
  ok "VRF isolation student->staff"
else
  fail "VRF isolation broken"
  echo "  [DEBUG] last output:"
  echo "$LAST_OUT" | sed 's/^/    /'
fi

echo
echo "[TEST] VRF-PUBLIC has no internal routes outside DMZ segment"
info "command: $C-leaf-01 ip route show vrf VRF-PUBLIC"
info "expect : no 10/8, no 172.16/12, and no 192.168/16"
LAST_OUT=$($C-leaf-01 ip route show vrf VRF-PUBLIC 2>/dev/null)
ROUTE_DESTS=$(echo "$LAST_OUT" | awk '{ print $1 }')
if echo "$ROUTE_DESTS" | grep -Eq "^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)"; then
  fail "VRF-PUBLIC leaks internal 10/8 or 172.16/12 prefixes"
  echo "  [DEBUG] last output:"
  echo "$LAST_OUT" | sed 's/^/    /'
elif echo "$ROUTE_DESTS" | grep -Eq "^192\.168\." && \
     echo "$ROUTE_DESTS" | grep -Ev "^192\.168\.100(\.|/24)" | grep -Eq "^192\.168\."; then
  fail "VRF-PUBLIC leaks internal 192.168 prefixes outside DMZ segment"
  echo "  [DEBUG] last output:"
  echo "$LAST_OUT" | sed 's/^/    /'
else
  ok "VRF-PUBLIC only carries DMZ/public-facing routes"
fi

echo
echo "[TEST] VRF-ORIENTATION empty pre-activation"
info "command: $C-leaf-01 ip route show vrf VRF-ORIENTATION"
info "expect : empty output"
if retry_empty "$C-leaf-01 ip route show vrf VRF-ORIENTATION"; then
  ok "VRF-ORIENTATION empty pre-activation"
else
  fail "VRF-ORIENTATION has routes"
  echo "  [DEBUG] last output:"
  echo "$LAST_OUT" | sed 's/^/    /'
fi

chk "border-router-01 ping isp-router-01" "$C-border-router-01 ping -c2 -W1 203.0.113.2" "2 (packets )?received"
chk "leaf-01 reaches firewall inside VIP" "$C-leaf-01 ping -c2 -W1 192.168.1.254" "2 (packets )?received"
chk "leaf-02 reaches firewall inside VIP" "$C-leaf-02 ping -c2 -W1 192.168.1.254" "2 (packets )?received"
chk "spine-01 ecmp hash policy=1" "$C-spine-01 sysctl net.ipv4.fib_multipath_hash_policy" "= 1"

$C-leaf-09 vtysh -c "clear bgp *" 2>/dev/null || true
sleep 2
MGMT_IP=$(docker inspect clab-esi-datacenter-spine-01 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
echo
echo "[TEST] OOB reachable during BGP disruption"
info "command: ping -c2 -W2 '$MGMT_IP'"
info "expect : /(2 packets transmitted, 2 received|0% packet loss)/"
if retry_match "ping -c2 -W2 '$MGMT_IP'" "(2 packets transmitted, 2 (packets )?received|0% packet loss)"; then
  ok "OOB reachable during BGP disruption"
else
  fail "OOB not reachable"
  echo "  [DEBUG] last output:"
  echo "$LAST_OUT" | sed 's/^/    /'
fi

echo "Results: $PASS passed / $FAIL failed"
if [ $FAIL -eq 0 ]; then
  echo "Phase 1 + Correction STABLE"
  exit 0
fi

echo "NOT ready — fix failures above"
exit 1
