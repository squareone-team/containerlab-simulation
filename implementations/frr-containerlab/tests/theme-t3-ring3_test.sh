#!/bin/bash
set +e


PASS=0
FAIL=0
C="docker exec clab-esi-datacenter"
LEAF_BGP_TARGET="10.1.0.11"
LEAF_SSH_TARGET="10.1.0.11"


ok() {
  echo "  [PASS] $1"
  ((PASS++))
  return 0
}


fail() {
  echo "  [FAIL] $1"
  ((FAIL++))
  return 0
}


timeout_scan() {
  local SRC_NODE="$1"
  local DST_IP="$2"
  local DST_PORT="$3"
  local OUTPUT


  OUTPUT=$(timeout 8 $C-"$SRC_NODE" sh -lc "nc -zvw5 $DST_IP $DST_PORT" 2>&1)
  if echo "$OUTPUT" | grep -Eiq "timed out|timeout"; then
    return 0
  fi
  return 1
}


echo "=== Ring 3 (Control Plane & Infrastructure Protection) Verification ==="


echo "[1/4] Verify VXLAN allowlist and drop rule on leaf-01"
VTEP_LIST="10.1.0.1 10.1.0.2 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20"
IPT_RULES=$($C-leaf-01 sh -lc "iptables -S INPUT" 2>/dev/null)


for VTEP in $VTEP_LIST; do
  if echo "$IPT_RULES" | grep -Fq -- "-A INPUT -s ${VTEP}/32 -p udp -m udp --dport 4789 -j ACCEPT"; then
    ok "leaf-01 allows VXLAN from authorized VTEP $VTEP"
  else
    fail "leaf-01 missing VXLAN allow rule for $VTEP"
  fi
done


if echo "$IPT_RULES" | grep -Fq -- "-A INPUT -p udp -m udp --dport 4789 -j DROP"; then
  ok "leaf-01 drops non-authorized VXLAN traffic"
else
  fail "leaf-01 missing VXLAN default drop rule"
fi


echo "[2/4] Validate BGP scan timeout from server-student-01 -> leaf-01:179"
if timeout_scan "server-student-01" "$LEAF_BGP_TARGET" "179"; then
  ok "student BGP scan times out as expected"
else
  fail "student BGP scan did not timeout"
fi


echo "[3/4] Validate SSH timeout from server-admin-01 -> leaf-01:22"
if timeout_scan "server-admin-01" "$LEAF_SSH_TARGET" "22"; then
  ok "admin SSH attempt times out as expected"
else
  fail "admin SSH attempt did not timeout"
fi


echo "[4/4] Verify Internal Fabric BGP (Positive Test)"
BGP_SUMMARY=$($C-leaf-01 vtysh -c "show bgp summary" 2>/dev/null)
FABRIC_LINES=$(echo "$BGP_SUMMARY" | grep -E '^10\.0\.[0-9]{1,3}\.[0-9]{1,3}[[:space:]]')


if [ -n "$FABRIC_LINES" ] && ! echo "$FABRIC_LINES" | grep -Eq 'Idle|Active|Connect|OpenSent|OpenConfirm'; then
  ok "leaf-01 fabric BGP neighbors (10.0.0.0/16) are established"
else
  fail "Fabric internal BGP appears down/blocked (check 10.0.0.0/16 allow rule)"
fi


echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "Ring 3 verification PASSED" || echo "Ring 3 verification FAILED"
[ $FAIL -eq 0 ]