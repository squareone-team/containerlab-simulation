#!/bin/bash
# tests/t4-verify.sh — NTP section (Zitouni T4)
C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); return 0; }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); return 0; }
info(){ echo "  [INFO] $1"; return 0; }

echo "=== T4: NTP Verification ==="

# 1. NTP server process is running
$C-ntp-server pgrep chronyd > /dev/null 2>&1 \
  && ok "ntp-server: chronyd process running" \
  || fail "ntp-server: chronyd not running"

# 2. NTP server is at stratum 2
$C-ntp-server chronyc tracking 2>/dev/null | grep -qE "Stratum\s*: 2" \
  && ok "ntp-server: stratum 2 confirmed" \
  || fail "ntp-server: not at stratum 2 (may not have synced yet — wait 30s and retry)"

# 3. NTP server is actually synced to an upstream source
if $C-ntp-server chronyc sources 2>/dev/null | grep -qE "\^\*|#\*"; then
  ok "ntp-server: upstream source selected (^*)"
else
  fail "ntp-server: no upstream source selected yet"
  info "ntp-server: if running in isolated lab (no internet), pool.ntp.org/cloudflare are unreachable"
  info "ntp-server: use 'local stratum 2 orphan' only (no server lines) until ISP part is merged"
  info "ntp-server: after merging Tati's ISP topology, internet sources will resolve and this will pass"
fi

# 4. NTP server is reachable on UDP/123 from fabric
$C-spine-01 chronyc sources 2>/dev/null | grep -qE "\^\*|\^\+" \
  && ok "spine-01: NTP synchronized (active source selected)" \
  || fail "spine-01: NTP not synchronized"

# 5. Spine nodes are syncing from our server
for NODE in spine-01 spine-02; do
  $C-$NODE chronyc sources 2>/dev/null | grep -q "192.168.50.20" \
    && ok "$NODE: NTP source is 192.168.50.20" \
    || fail "$NODE: not using 192.168.50.20 as NTP source"

  STRATUM=$($C-$NODE chronyc tracking 2>/dev/null | grep "Stratum" | grep -oE '[0-9]+')
  if [ -z "$STRATUM" ] || [ "$STRATUM" = "0" ]; then
    fail "$NODE: stratum is $STRATUM — chrony not synced at all"
  elif [ "$STRATUM" = "10" ]; then
    fail "$NODE: stratum is 10 — using local fallback, not syncing from ntp-server"
    info "$NODE: check that 192.168.50.20 is reachable — verify ip rule and VRF-STAFF route leak on leaf-03"
  else
    ok "$NODE: stratum $STRATUM (synced — one below ntp-server)"
  fi
done

# 6. Clock offset < 1s on all FRR nodes (log correlation forensic requirement)
info "checking clock offset on all FRR nodes (forensic requirement: offset < 1s for log correlation)"
for NODE in spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 \
            leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10; do

  TRACKING=$($C-$NODE chronyc tracking 2>/dev/null)

  if ! echo "$TRACKING" | grep -q "Reference ID"; then
    fail "$NODE: chronyc cannot talk to daemon (chrony not running or socket issue)"
    info "$NODE: ensure chronyd is started in startup.sh with: chronyd -f /etc/chrony.conf &"
    continue
  fi

  if echo "$TRACKING" | grep -q "Reference ID *: 00000000\|Not synchronised"; then
    fail "$NODE: chrony not synchronized to any source"
    info "$NODE: check that 192.168.50.20 (ntp-server) is reachable from this node via underlay"
    continue
  fi

  OFFSET=$(echo "$TRACKING" | grep "System time" | grep -oE '[0-9]+\.[0-9]+' | head -1)

  if [ -z "$OFFSET" ]; then
    fail "$NODE: could not read offset from chronyc tracking"
    continue
  fi

  awk -v o="$OFFSET" 'BEGIN { exit (o+0 < 1.0) ? 0 : 1 }' \
    && ok "$NODE: offset ${OFFSET}s < 1s (log correlation OK)" \
    || { fail "$NODE: offset ${OFFSET}s >= 1s (too large)"; \
         info "$NODE: large offset usually means node just started — wait 30s and retry"; }
done

# 7. No-PIM guard (T4 requirement from Section 2 reconciliation)
info "verifying PIM is absent on all fabric nodes (multicast not used in this architecture)"
for NODE in leaf-01 leaf-03 leaf-05 leaf-07 leaf-09 spine-01 spine-02; do
  $C-$NODE vtysh -c "show running-config" 2>/dev/null | grep -qE "ip pim|router pim" \
    && fail "$NODE: PIM config found — must be absent per architecture spec" \
    || ok "$NODE: no PIM config (correct)"
done

echo ""
echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "NTP + No-PIM checks PASSED" || echo "Issues found — see [FAIL] lines above"