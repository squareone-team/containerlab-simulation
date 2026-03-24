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
}

fail() {
  echo "  [FAIL] $1"
  ((FAIL++))
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

echo "[1/3] Verify VXLAN allowlist and drop rule on leaf-01"
VTEP_LIST="10.1.0.1 10.1.0.2 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20"
IPT_RULES=$($C-leaf-01 iptables -S INPUT 2>/dev/null)

for VTEP in $VTEP_LIST; do
  echo "$IPT_RULES" | grep -Eq -- "-A INPUT .* -s ${VTEP}/32 .* -p udp .* --dport 4789 .* -j ACCEPT" \
    && ok "leaf-01 allows VXLAN from authorized VTEP $VTEP" \
    || fail "leaf-01 missing VXLAN allow rule for $VTEP"
done

echo "$IPT_RULES" | grep -Eq -- "-A INPUT .* -p udp .* --dport 4789 .* -j DROP" \
  && ok "leaf-01 drops non-authorized VXLAN traffic" \
  || fail "leaf-01 missing VXLAN default drop rule"

echo "[2/3] Validate BGP scan timeout from server-student-01 -> leaf-01:179"
timeout_scan "server-student-01" "$LEAF_BGP_TARGET" "179" \
  && ok "student BGP scan times out as expected" \
  || fail "student BGP scan did not timeout"

echo "[3/3] Validate SSH timeout from server-admin-01 -> leaf-01:22"
timeout_scan "server-admin-01" "$LEAF_SSH_TARGET" "22" \
  && ok "admin SSH attempt times out as expected" \
  || fail "admin SSH attempt did not timeout"

echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "Ring 3 verification PASSED" || echo "Ring 3 verification FAILED"
[ $FAIL -eq 0 ]
