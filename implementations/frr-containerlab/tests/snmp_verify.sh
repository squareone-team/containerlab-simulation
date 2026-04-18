#!/bin/bash
# tests/snmp_verify.sh — SNMP section (Zitouni T4)
C="docker exec clab-esi-datacenter"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); return 0; }
fail(){ echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); return 0; }
info(){ echo "  [INFO] $1"; return 0; }

echo "=== T4: SNMP Verification ==="
echo "    zabbix-server: 192.168.50.50 | VNI 10050 | VRF-STAFF"
echo ""

# ── 1. snmpd process on each FRR node ──────────────────────────────────────
echo "--- 1. snmpd process check ---"
for NODE in spine-01 spine-02 \
            leaf-01 leaf-02 leaf-03 leaf-04 \
            leaf-05 leaf-06 leaf-07 leaf-08 \
            leaf-09 leaf-10; do
    $C-$NODE pgrep snmpd > /dev/null 2>&1 \
        && ok "$NODE: snmpd running" \
        || fail "$NODE: snmpd not running"
done

# ── 2. FRR agentx enabled in frr.conf ──────────────────────────────────────
echo ""
echo "--- 2. FRR agentx config ---"
for NODE in spine-01 spine-02 \
            leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
    $C-$NODE grep -q "^agentx" /etc/frr/frr.conf 2>/dev/null \
        && ok "$NODE: agentx directive in frr.conf" \
        || fail "$NODE: agentx missing from frr.conf"
done

# ── 3. AgentX socket exists (snmpd master + FRR subagent connected) ─────────
echo ""
echo "--- 3. AgentX socket ---"
for NODE in spine-01 spine-02 \
            leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
    $C-$NODE ls /var/agentx/master > /dev/null 2>&1 \
        && ok "$NODE: agentx socket present" \
        || fail "$NODE: agentx socket missing — snmpd or FRR agentx not connected"
done

# ── Wait for zabbix-server to finish package installation ──────────────────
echo "--- 0. Waiting for zabbix-server net-snmp tools to be ready ---"
RETRIES=30
until docker exec clab-esi-datacenter-zabbix-server \
    which snmpget > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
    echo "  [INFO] waiting for snmpget on zabbix-server... ($RETRIES left)"
    sleep 5
    RETRIES=$((RETRIES - 1))
done
if [ $RETRIES -eq 0 ]; then
    echo "  [WARN] snmpget never appeared — sections 4/6 will likely fail"
else
    echo "  [INFO] zabbix-server net-snmp ready"
fi

# ── 4. SNMP v2c polling from zabbix-server to all switch loopbacks ──────────
echo ""
echo "--- 4. SNMP v2c reachability from zabbix-server ---"

declare -A NODES
NODES=(
    [spine-01]=10.1.0.1
    [spine-02]=10.1.0.2
    [leaf-01]=10.1.0.11
    [leaf-02]=10.1.0.12
    [leaf-03]=10.1.0.13
    [leaf-04]=10.1.0.14
    [leaf-05]=10.1.0.15
    [leaf-06]=10.1.0.16
    [leaf-07]=10.1.0.17
    [leaf-08]=10.1.0.18
    [leaf-09]=10.1.0.19
    [leaf-10]=10.1.0.20
)

for NODE in "${!NODES[@]}"; do
    IP="${NODES[$NODE]}"
    RESULT=$($C-zabbix-server snmpget -v2c -c esi-read -t 3 -r 1 \
        "$IP" 1.3.6.1.2.1.1.1.0 2>/dev/null)
    if echo "$RESULT" | grep -qiE "Linux|FRR|STRING"; then
        ok "$NODE ($IP): SNMP sysDescr reachable"
    else
        fail "$NODE ($IP): SNMP not responding — check snmpd and routing"
    fi
done

# ── 5. FRR BGP MIB reachable via agentx ────────────────────────────────────
echo ""
echo "--- 5. FRR BGP MIB via agentx ---"
# BGP4-MIB: 1.3.6.1.2.1.15.3 = bgpPeerTable
for NODE in spine-01 spine-02; do
    IP="${NODES[$NODE]}"
    RESULT=$($C-zabbix-server snmpwalk -v2c -c esi-read -t 3 -r 1 \
        "$IP" 1.3.6.1.2.1.15.3 2>/dev/null | head -3)
    if [ -n "$RESULT" ]; then
        ok "$NODE: BGP4-MIB bgpPeerTable readable via agentx"
    else
        fail "$NODE: BGP4-MIB not available — FRR agentx may not have connected yet"
        info "$NODE: try: docker exec clab-esi-datacenter-$NODE vtysh -c 'show agentx'"
    fi
done

# ── 6. Interface counters MIB (ifTable) ─────────────────────────────────────
echo ""
echo "--- 6. Interface MIB ---"
for NODE in leaf-03 leaf-09; do
    IP="${NODES[$NODE]}"
    RESULT=$($C-zabbix-server snmpwalk -v2c -c esi-read -t 3 -r 1 \
        "$IP" 1.3.6.1.2.1.2.2 2>/dev/null | wc -l)
    if [ "$RESULT" -gt 5 ] 2>/dev/null; then
        ok "$NODE: ifTable has $RESULT entries"
    else
        fail "$NODE: ifTable empty or unreachable"
    fi
done

# --- 7. Zabbix server health ---
RETRIES=36
until docker exec clab-esi-datacenter-zabbix-server \
    mysql -u zabbix -pzabbix-lab-pass -h 127.0.0.1 \
    -e "SELECT 1;" zabbix > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
    echo "  [INFO] waiting for MariaDB... ($RETRIES retries left)"
    sleep 5
    RETRIES=$((RETRIES - 1))
done

if [ $RETRIES -eq 0 ]; then
    fail "zabbix-server: MariaDB not reachable after 3 min"
else
    ok "zabbix-server: MariaDB database accessible"
    docker exec clab-esi-datacenter-zabbix-server \
        pgrep zabbix_server > /dev/null 2>&1 \
        && ok "zabbix-server: zabbix_server process running" \
        || fail "zabbix-server: zabbix_server not running"
fi

# ── 8. Zabbix can reach all targets ─────────────────────────────────────────
echo ""
echo "--- 8. Zabbix network reachability to switches ---"
for NODE in "${!NODES[@]}"; do
    IP="${NODES[$NODE]}"
    $C-zabbix-server ping -c1 -W2 "$IP" > /dev/null 2>&1 \
        && ok "zabbix-server: reachable to $NODE ($IP)" \
        || fail "zabbix-server: cannot reach $NODE ($IP) — check VRF-STAFF routes"
done

# ── 9. Community string is "esi-read" (not default "public") ────────────────
echo ""
echo "--- 9. Security: community string ---"
for NODE in spine-01 leaf-03; do
    IP="${NODES[$NODE]}"
    # Should fail with wrong community
    BAD=$($C-zabbix-server snmpget -v2c -c public -t 2 -r 0 \
        "$IP" 1.3.6.1.2.1.1.1.0 2>&1)
    if echo "$BAD" | grep -qiE "Timeout|No response|Unknown"; then
        ok "$NODE: default 'public' community rejected"
    else
        fail "$NODE: accepting 'public' community — change to 'esi-read' only"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "======================================"
echo "SNMP Test Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "SNMP checks PASSED" || echo "Issues found — see [FAIL] lines above"
echo "======================================"