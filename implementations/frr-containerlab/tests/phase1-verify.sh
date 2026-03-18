#!/bin/bash
set +e
PASS=0; FAIL=0
C="docker exec clab-esi-datacenter"

ok()  { echo "  [PASS] $1"; ((PASS++)); return 0; }
fail(){ echo "  [FAIL] $1"; ((FAIL++)); return 0; }
chk() {
  eval "$2" 2>/dev/null | grep -Eq "$3" && ok "$1" || fail "$1"
}

echo "=== ESI Phase 1 Verification ==="

chk "spine-01: 10 neighbors present" "$C-spine-01 vtysh -c 'show bgp summary'" "Total number of neighbors 10"
chk "spine-02: 10 neighbors present" "$C-spine-02 vtysh -c 'show bgp summary'" "Total number of neighbors 10"

for IP in 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20; do
  chk "spine-01 has route to $IP/32" "$C-spine-01 vtysh -c 'show ip route $IP/32'" "(bgp|B>)"
done

chk "leaf-09: multipath" "$C-leaf-09 vtysh -c 'show ip bgp 10.1.0.13/32'" "Multipath|2"
chk "spine-01 MD5 present" "$C-spine-01 grep -c 'password ESI-BGP-SECRET' /etc/frr/frr.conf" "1"
chk "leaf-09 BFD Up" "$C-leaf-09 vtysh -c 'show bfd peers'" "Up"
chk "spine-01 eth1 mtu 9000" "$C-spine-01 ip link show eth1" "mtu 9000"
chk "leaf-03 br0 mtu 9000" "$C-leaf-03 ip link show br0" "mtu 9000"
chk "leaf-09 vxlan10010 tos inherit" "$C-leaf-09 ip -d link show vxlan10010" "tos inherit"

for LEAF in leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
  chk "$LEAF EVPN sessions" "$C-$LEAF vtysh -c 'show bgp l2vpn evpn summary'" "Total number of neighbors 2"
done

chk "leaf-09 VNI 10010 has remote VTEPs" "$C-leaf-09 vtysh -c 'show evpn vni 10010'" "Remote VTEPs for this VNI"
chk "leaf-01 VNI 10030 has remote VTEPs" "$C-leaf-01 vtysh -c 'show evpn vni 10030'" "Remote VTEPs for this VNI"
chk "EVPN Type-5 present" "$C-spine-01 vtysh -c 'show bgp l2vpn evpn route type prefix'" "Route Distinguisher"
chk "student inter-subnet ping" "$C-server-student-01 ping -c3 -W2 192.168.20.10" "3 (packets )?received"

r=$($C-server-student-01 ping -c2 -W1 192.168.50.10 2>/dev/null)
echo "$r" | grep -Eq "0 (packets )?received|100% packet loss|unreachable" && ok "VRF isolation student->staff" || fail "VRF isolation broken"

r=$($C-leaf-01 ip route show vrf VRF-PUBLIC 2>/dev/null)
[ -z "$r" ] && ok "VRF-PUBLIC route table empty" || fail "VRF-PUBLIC has routes: $r"

r=$($C-leaf-01 ip route show vrf VRF-ORIENTATION 2>/dev/null)
[ -z "$r" ] && ok "VRF-ORIENTATION empty pre-activation" || fail "VRF-ORIENTATION has routes: $r"

chk "leaf-01 ping isp-router-01" "$C-leaf-01 ping -c2 -W1 203.0.113.2" "2 (packets )?received"
chk "leaf-02 ping isp-router-02" "$C-leaf-02 ping -c2 -W1 203.0.113.6" "2 (packets )?received"
chk "student default in VRF-PEDAGOGY" "$C-leaf-09 ip route show vrf VRF-PEDAGOGY" "^default"
chk "spine-01 ecmp hash policy=1" "$C-spine-01 sysctl net.ipv4.fib_multipath_hash_policy" "= 1"

$C-leaf-09 vtysh -c "clear bgp *" 2>/dev/null || true
sleep 2
MGMT_IP=$(docker inspect clab-esi-datacenter-spine-01 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
ping -c2 -W2 "$MGMT_IP" >/dev/null 2>&1 && ok "OOB reachable during BGP disruption" || fail "OOB not reachable"

echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "Phase 1 STABLE" || echo "Phase 1 NOT ready"
