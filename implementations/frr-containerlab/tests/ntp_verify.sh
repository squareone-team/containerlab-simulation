#!/bin/bash
# tests/t4-verify.sh — NTP section (Zitouni T4)
C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); return 0; }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); return 0; }
info(){ echo "  [INFO] $1"; return 0; }

discover_nodes() {
  local pattern="$1"
  docker ps --format '{{.Names}}' 2>/dev/null \
    | sed -n -E "s/^clab-esi-datacenter-(${pattern})$/\1/p" \
    | sort
}

wait_for_spine_sync() {
  local node="$1"
  local retries=30
  while [ $retries -gt 0 ]; do
    if $C-$node chronyc sources 2>/dev/null | grep -qE '^\^\*.*192\.168\.50\.20'; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  return 1
}

SPINE_NODES="$(discover_nodes 'spine-[0-9]+')"
[ -z "$SPINE_NODES" ] && SPINE_NODES="spine-01 spine-02"

FABRIC_NODES="$(discover_nodes 'spine-[0-9]+|leaf-[0-9]+')"
[ -z "$FABRIC_NODES" ] && FABRIC_NODES="spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10"

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
NTP_SOURCES="$($C-ntp-server chronyc sources 2>/dev/null)"
NTP_TRACKING="$($C-ntp-server chronyc tracking 2>/dev/null)"

if echo "$NTP_SOURCES" | grep -qE "\^\*|#\*"; then
  ok "ntp-server: source selected (upstream or local clock)"
elif echo "$NTP_TRACKING" | grep -qE "Reference ID\s*: 7F7F0101"; then
  ok "ntp-server: local orphan clock active (isolated lab mode)"
  info "ntp-server: internet upstreams are optional until ISP/internet path is available"
else
  fail "ntp-server: no usable source selected"
  info "ntp-server: if isolated, ensure 'local stratum 2 orphan' remains configured"
fi

# 4. NTP server is reachable on UDP/123 from fabric
FIRST_SPINE="$(echo "$SPINE_NODES" | awk 'NR==1')"
if [ -n "$FIRST_SPINE" ] && wait_for_spine_sync "$FIRST_SPINE"; then
  ok "$FIRST_SPINE: NTP synchronized (active source selected)"
else
  fail "${FIRST_SPINE:-spine}: NTP not synchronized"
fi

# 5. Spine nodes are syncing from our server
for NODE in $SPINE_NODES; do
  wait_for_spine_sync "$NODE" >/dev/null 2>&1 || true

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
for NODE in $FABRIC_NODES; do

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
for NODE in $FABRIC_NODES; do
  $C-$NODE vtysh -c "show running-config" 2>/dev/null | grep -qE "ip pim|router pim" \
    && fail "$NODE: PIM config found — must be absent per architecture spec" \
    || ok "$NODE: no PIM config (correct)"
done

echo ""
echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "NTP + No-PIM checks PASSED" || echo "Issues found — see [FAIL] lines above"