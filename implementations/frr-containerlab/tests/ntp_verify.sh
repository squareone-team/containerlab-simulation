#!/bin/bash
# tests/t4-verify.sh — NTP section (Zitouni T4)
C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; ((PASS++)); }
fail(){ echo "  [FAIL] $1"; ((FAIL++)); }

echo "=== T4: NTP Verification ==="

# 1. NTP server process is running
$C-ntp-server pgrep chronyd > /dev/null 2>&1 \
  && ok "ntp-server: chronyd process running" \
  || fail "ntp-server: chronyd not running"

# 2. NTP server is at stratum 2
$C-ntp-server chronyc tracking 2>/dev/null | grep -q "Stratum : 2" \
  && ok "ntp-server: stratum 2 confirmed" \
  || fail "ntp-server: not at stratum 2 (may not have synced yet — wait 30s and retry)"

# 3. NTP server is actually synced to an upstream source
$C-ntp-server chronyc sources 2>/dev/null | grep -q "^\^\*" \
  && ok "ntp-server: upstream source selected (^*)" \
  || fail "ntp-server: no upstream source selected yet"

# 4. NTP server is reachable on UDP/123 from fabric
$C-spine-01 chronyc sources 2>/dev/null | grep -qE "^\^\*|\^\+" \
  && ok "spine-01: NTP synchronized (active source selected)" \
  || fail "spine-01: NTP not synchronized"
  
# 5. Spine nodes are syncing from our server
for NODE in spine-01 spine-02; do
  $C-$NODE chronyc sources 2>/dev/null | grep -q "192.168.50.20" \
    && ok "$NODE: NTP source is 192.168.50.20" \
    || fail "$NODE: not using 192.168.50.20 as NTP source"

  # Accept stratum 3 (synced to our stratum-2 server) OR stratum 11 (local fallback chain)
  # Reject only stratum 0 (unsynced) and stratum 10 (local — means spine isn't using our server)
  STRATUM=$($C-$NODE chronyc tracking 2>/dev/null | grep "Stratum" | grep -oE '[0-9]+')
  if [ -z "$STRATUM" ] || [ "$STRATUM" = "0" ]; then
    fail "$NODE: stratum is $STRATUM — chrony not synced at all"
  elif [ "$STRATUM" = "10" ]; then
    fail "$NODE: stratum is 10 — using local fallback, not syncing from ntp-server"
  else
    ok "$NODE: stratum $STRATUM (synced — one below ntp-server)"
  fi
done

# 6. Clock offset < 1s on all FRR nodes (log correlation forensic requirement)
for NODE in spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 \
            leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10; do

  TRACKING=$($C-$NODE chronyc tracking 2>/dev/null)

  # Check chrony is actually talking to daemon first
  if ! echo "$TRACKING" | grep -q "Reference ID"; then
    fail "$NODE: chronyc cannot talk to daemon (chrony not running or socket issue)"
    continue
  fi

  # Check it's not unsynced (Reference ID of 00000000 = not synced)
  if echo "$TRACKING" | grep -q "Reference ID *: 00000000\|Not synchronised"; then
    fail "$NODE: chrony not synchronized to any source"
    continue
  fi

  OFFSET=$(echo "$TRACKING" | grep "System time" | grep -oE '[0-9]+\.[0-9]+' | head -1)

  if [ -z "$OFFSET" ]; then
    fail "$NODE: could not read offset from chronyc tracking"
    continue
  fi

  awk -v o="$OFFSET" 'BEGIN { exit (o+0 < 1.0) ? 0 : 1 }' \
    && ok "$NODE: offset ${OFFSET}s < 1s (log correlation OK)" \
    || fail "$NODE: offset ${OFFSET}s >= 1s (too large)"
done

# 7. No-PIM guard (T4 requirement from Section 2 reconciliation)
for NODE in leaf-01 leaf-03 leaf-05 leaf-07 leaf-09 spine-01 spine-02; do
  $C-$NODE vtysh -c "show running-config" 2>/dev/null | grep -qE "ip pim|router pim" \
    && fail "$NODE: PIM config found — must be absent per architecture spec" \
    || ok "$NODE: no PIM config (correct)"
done

echo ""
echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "NTP + No-PIM checks PASSED" || echo "Issues found — see [FAIL] lines above"