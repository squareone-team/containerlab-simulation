#!/bin/bash
set +e

# Theme T1 (Border Routing & Internet) verification gate.
# This script is strict for T1-owned features and intentionally avoids
# validating other members' theme-specific behavior.

LAB="esi-datacenter"
C="docker exec clab-${LAB}"

PASS=0
FAIL=0
WARN=0
LAST_OUT=""

ok()   { echo "  [PASS] $1"; ((PASS++)); return 0; }
fail() { echo "  [FAIL] $1"; ((FAIL++)); return 0; }
warn() { echo "  [WARN] $1"; ((WARN++)); return 0; }
info() { echo "  [INFO] $1"; }

test_banner() {
  echo
  echo "[TEST] $1"
}

cmd_match() {
  local title="$1"
  local cmd="$2"
  local regex="$3"
  test_banner "$title"
  info "command: $cmd"
  info "expect : /$regex/"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$regex"; then
    ok "$title"
  else
    fail "$title"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

cmd_no_match() {
  local title="$1"
  local cmd="$2"
  local regex="$3"
  test_banner "$title"
  info "command: $cmd"
  info "expect : not /$regex/"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$regex"; then
    fail "$title"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  else
    ok "$title"
  fi
}

cmd_ping_no_dup() {
  local title="$1"
  local cmd="$2"
  local received_regex="$3"
  test_banner "$title"
  info "command: $cmd"
  info "expect : /$received_regex/ and no duplicates"
  LAST_OUT=$(eval "$cmd" 2>/dev/null)
  if echo "$LAST_OUT" | grep -Eq "$received_regex" && ! echo "$LAST_OUT" | grep -Eq "\(DUP!\)|duplicates"; then
    ok "$title"
  else
    fail "$title"
    echo "  [DEBUG] output:"
    echo "$LAST_OUT" | sed 's/^/    /'
  fi
}

wait_http_ok() {
  local url="$1"
  local tries="${2:-20}"
  local delay="${3:-2}"
  local n=1

  while [ "$n" -le "$tries" ]; do
    curl -sS "$url" >/dev/null 2>&1 && return 0
    sleep "$delay"
    n=$((n + 1))
  done

  return 1
}

container_ip() {
  docker inspect "clab-${LAB}-$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1
}

container_exists() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

echo "=== ESI Theme T1 Verification (Border Routing & Internet) ==="

# ---------------------------------------------------------------------------
# 0) Preflight
# ---------------------------------------------------------------------------
for node in leaf-01 leaf-02 isp-router-01 isp-router-02 isp-router-03; do
  if container_exists "clab-${LAB}-${node}"; then
    ok "container present: ${node}"
  else
    fail "container missing: ${node}"
  fi
done

for node in internet-web-01 student-bp-01 bp-sw; do
  if container_exists "clab-${LAB}-${node}"; then
    ok "container present: ${node}"
  else
    fail "container missing: ${node}"
  fi
done

# ---------------------------------------------------------------------------
# 1) External eBGP sessions (active links + third ISP reachability)
# ---------------------------------------------------------------------------
cmd_match "leaf-01 eBGP Up to isp-router-01" \
  "$C-leaf-01 vtysh -c 'show ip bgp summary'" \
  "203\\.0\\.113\\.2"

cmd_match "leaf-02 eBGP Up to isp-router-02" \
  "$C-leaf-02 vtysh -c 'show ip bgp summary'" \
  "203\\.0\\.113\\.6"

cmd_match "leaf-01 third ISP neighbor present" \
  "$C-leaf-01 vtysh -c 'show ip bgp summary'" \
  "203\\.0\\.114\\.2"

cmd_match "leaf-01 ping isp-router-01" \
  "$C-leaf-01 ping -c2 -W1 203.0.113.2" \
  "2 (packets )?received"

cmd_match "leaf-02 ping isp-router-02" \
  "$C-leaf-02 ping -c2 -W1 203.0.113.6" \
  "2 (packets )?received"

cmd_match "leaf-01 ping isp-router-03" \
  "$C-leaf-01 ping -c2 -W1 203.0.114.2" \
  "2 (packets )?received"

# ---------------------------------------------------------------------------
# 2) Border policy controls: prefix-lists + max-prefix
# ---------------------------------------------------------------------------
for leaf in leaf-01 leaf-02; do
  for line in \
    "ip prefix-list ISP-IN" \
    "ip prefix-list ISP-OUT" \
    "maximum-prefix"; do
    cmd_match "${leaf} has policy element: ${line}" \
      "$C-${leaf} vtysh -c 'show running-config'" \
      "${line}"
  done
done

cmd_match "leaf-01 applies ISP-IN inbound" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.2 prefix-list ISP-IN in"

cmd_match "leaf-01 applies ISP-OUT outbound" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.2 prefix-list ISP-OUT out"

cmd_match "leaf-02 applies ISP-IN inbound" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.6 prefix-list ISP-IN in"

cmd_match "leaf-02 applies ISP-OUT outbound" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.6 prefix-list ISP-OUT out"

cmd_match "leaf-01 max-prefix on external peer" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.2 maximum-prefix"

cmd_match "leaf-02 max-prefix on external peer" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 203\\.0\\.113\\.6 maximum-prefix"

cmd_no_match "leaf-01 does not set max-prefix on fabric peers" \
  "$C-leaf-01 vtysh -c 'show running-config'" \
  "neighbor 10\\.0\\.[01]\\.0 maximum-prefix"

cmd_no_match "leaf-02 does not set max-prefix on fabric peers" \
  "$C-leaf-02 vtysh -c 'show running-config'" \
  "neighbor 10\\.0\\.[01]\\.2 maximum-prefix"

# ---------------------------------------------------------------------------
# 3) Route acceptance and leakage control
# ---------------------------------------------------------------------------
cmd_match "leaf-01 receives default route from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show ip bgp neighbors 203.0.113.2 routes'" \
  "0\\.0\\.0\\.0/0"

cmd_match "leaf-02 receives default route from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show ip bgp neighbors 203.0.113.6 routes'" \
  "0\\.0\\.0\\.0/0"

cmd_no_match "leaf-01 does not accept non-default from isp-router-01" \
  "$C-leaf-01 vtysh -c 'show ip bgp neighbors 203.0.113.2 routes'" \
  "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]+\\.[0-9]+/[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+/[0-9]+)"

cmd_no_match "leaf-02 does not accept non-default from isp-router-02" \
  "$C-leaf-02 vtysh -c 'show ip bgp neighbors 203.0.113.6 routes'" \
  "(10\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+|172\\.(1[6-9]|2[0-9]|3[0-1])\\.[0-9]+\\.[0-9]+/[0-9]+|192\\.168\\.[0-9]+\\.[0-9]+/[0-9]+)"

cmd_no_match "leaf-01 does not leak RFC1918 to isp-router-01" \
  "$C-isp-router-01 vtysh -c 'show ip bgp neighbors 203.0.113.1 received-routes'" \
  "(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)"

cmd_no_match "leaf-02 does not leak RFC1918 to isp-router-02" \
  "$C-isp-router-02 vtysh -c 'show ip bgp neighbors 203.0.113.5 received-routes'" \
  "(10\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|192\\.168\\.)"

# ---------------------------------------------------------------------------
# 4) VRF default-route behavior (T1 scope)
# ---------------------------------------------------------------------------
cmd_match "border has default in VRF-PEDAGOGY" \
  "$C-leaf-01 ip route show vrf VRF-PEDAGOGY" \
  "default"

cmd_match "border has default in VRF-STAFF" \
  "$C-leaf-01 ip route show vrf VRF-STAFF" \
  "default"

cmd_match "student leaf imports default in VRF-PEDAGOGY" \
  "$C-leaf-09 ip route show vrf VRF-PEDAGOGY" \
  "default"

# ---------------------------------------------------------------------------
# 5) Third ISP isolation + orientation activation runbook
# ---------------------------------------------------------------------------
cmd_no_match "VRF-ORIENTATION empty before activation" \
  "$C-leaf-01 ip route show vrf VRF-ORIENTATION" \
  "."

if [ -f "configs/orientation-runbook.sh" ]; then
  if [ -x "configs/orientation-runbook.sh" ]; then
    ./configs/orientation-runbook.sh --activate >/dev/null 2>&1
    cmd_match "VRF-ORIENTATION receives route after activation" \
      "$C-leaf-01 ip route show vrf VRF-ORIENTATION" \
      "default|203\\.0\\.114"

    ./configs/orientation-runbook.sh --deactivate >/dev/null 2>&1
    cmd_no_match "VRF-ORIENTATION empty after deactivation" \
      "$C-leaf-01 ip route show vrf VRF-ORIENTATION" \
      "."
  else
    fail "orientation runbook exists but is not executable"
  fi
else
  fail "missing configs/orientation-runbook.sh (required by T1)"
fi

# ---------------------------------------------------------------------------
# 6) Monitoring artifacts owned by T1 (Prometheus/Grafana/frr-exporter)
# ---------------------------------------------------------------------------
if container_exists "clab-${LAB}-prometheus"; then
  PROM_IP="$(container_ip prometheus)"
  if [ -n "$PROM_IP" ] && wait_http_ok "http://${PROM_IP}:9090/api/v1/targets" 25 2 && curl -s "http://${PROM_IP}:9090/api/v1/targets" >/tmp/t1-prom-targets.json 2>/dev/null; then
    ok "prometheus API reachable"
    grep -Eq "frr[_-]exporter|frr-exporter" /tmp/t1-prom-targets.json && ok "prometheus has frr exporter target" || fail "prometheus has frr exporter target"
    grep -Eq '"instance":"frr-exporter:9342".*"health":"up"' /tmp/t1-prom-targets.json && ok "prometheus exporter target health is up" || fail "prometheus exporter target health is up"
  else
    fail "prometheus API reachable"
    fail "prometheus has frr exporter target"
    fail "prometheus exporter target health is up"
  fi
else
  fail "prometheus container missing"
  fail "prometheus exporter target health is up"
fi

if container_exists "clab-${LAB}-grafana"; then
  GRAFANA_IP="$(container_ip grafana)"
  [ -n "$GRAFANA_IP" ] && wait_http_ok "http://${GRAFANA_IP}:3000/api/health" 30 2 && ok "grafana HTTP reachable" || fail "grafana HTTP reachable"
else
  fail "grafana container missing"
fi

# ---------------------------------------------------------------------------
# 7) Optional Internet-emulation scenario (your new ISP chain)
# ---------------------------------------------------------------------------
ENABLE_INTERNET_EMULATION="${ENABLE_INTERNET_EMULATION:-0}"
INET_CLIENT_A="${INET_CLIENT_A:-internet-client-01}"
INET_CLIENT_B="${INET_CLIENT_B:-internet-client-02}"
INET_EDGE_A="${INET_EDGE_A:-internet-router-01}"
INET_EDGE_B="${INET_EDGE_B:-internet-router-02}"
INET_NEW_ISP="${INET_NEW_ISP:-isp-router-04}"
FACILITY_PUBLIC_IP="${FACILITY_PUBLIC_IP:-100.64.0.1}"
FACILITY_BLOCKED_IP_1="${FACILITY_BLOCKED_IP_1:-192.168.50.10}"
FACILITY_BLOCKED_IP_2="${FACILITY_BLOCKED_IP_2:-192.168.10.10}"

all_inet_nodes_present=1
for n in "$INET_CLIENT_A" "$INET_CLIENT_B" "$INET_EDGE_A" "$INET_EDGE_B" "$INET_NEW_ISP"; do
  container_exists "clab-${LAB}-${n}" || all_inet_nodes_present=0
done

if [ "$ENABLE_INTERNET_EMULATION" = "1" ] || [ "$all_inet_nodes_present" = "1" ]; then
  [ "$all_inet_nodes_present" = "1" ] || fail "internet-emulation enabled but required nodes are missing"

  cmd_match "internet client A can reach public service IP" \
    "$C-${INET_CLIENT_A} ping -c2 -W1 ${FACILITY_PUBLIC_IP}" \
    "2 (packets )?received"

  cmd_match "internet client B can reach public service IP" \
    "$C-${INET_CLIENT_B} ping -c2 -W1 ${FACILITY_PUBLIC_IP}" \
    "2 (packets )?received"

  cmd_no_match "internet client A blocked from STAFF/internal subnet" \
    "$C-${INET_CLIENT_A} ping -c2 -W1 ${FACILITY_BLOCKED_IP_1}" \
    "2 (packets )?received"

  cmd_no_match "internet client B blocked from PEDAGOGY/internal subnet" \
    "$C-${INET_CLIENT_B} ping -c2 -W1 ${FACILITY_BLOCKED_IP_2}" \
    "2 (packets )?received"
else
  warn "internet-emulation topology not detected (set ENABLE_INTERNET_EMULATION=1 to enforce this block)"
fi

# 8) BP student access + NAT/PAT verification to internet ping target
# ---------------------------------------------------------------------------
INET_PING_TARGET_IP="${INET_PING_TARGET_IP:-198.18.3.10}"

cmd_ping_no_dup "BP student can ping local anycast gateway (no duplicates)" \
  "$C-student-bp-01 ping -c1 -W1 192.168.10.1" \
  "1 (packets )?received"

cmd_ping_no_dup "BP student can ping internet target (no duplicates)" \
  "$C-student-bp-01 ping -c1 -W1 ${INET_PING_TARGET_IP}" \
  "1 (packets )?received"

test_banner "PAT/NAT counters increment for student ICMP toward internet target"
nat_l1_before=$($C-leaf-01 sh -lc "iptables-save -c -t nat | awk '/-A POSTROUTING/ && /-s 192.168.10.0\\/24/ && /-d 198.18.3.0\\/24/ && /-j MASQUERADE/ {gsub(/\\[|\\]/, \"\", \\$1); split(\\$1, a, \":\"); sum += a[1]} END {print sum+0}'" 2>/dev/null)
nat_l2_before=$($C-leaf-02 sh -lc "iptables-save -c -t nat | awk '/-A POSTROUTING/ && /-s 192.168.10.0\\/24/ && /-d 198.18.3.0\\/24/ && /-j MASQUERADE/ {gsub(/\\[|\\]/, \"\", \\$1); split(\\$1, a, \":\"); sum += a[1]} END {print sum+0}'" 2>/dev/null)

# Send one probe to validate NAT counter movement on active egress leaf.
$C-student-bp-01 ping -c1 -W1 ${INET_PING_TARGET_IP} >/dev/null 2>&1 || true

nat_l1_after=$($C-leaf-01 sh -lc "iptables-save -c -t nat | awk '/-A POSTROUTING/ && /-s 192.168.10.0\\/24/ && /-d 198.18.3.0\\/24/ && /-j MASQUERADE/ {gsub(/\\[|\\]/, \"\", \\$1); split(\\$1, a, \":\"); sum += a[1]} END {print sum+0}'" 2>/dev/null)
nat_l2_after=$($C-leaf-02 sh -lc "iptables-save -c -t nat | awk '/-A POSTROUTING/ && /-s 192.168.10.0\\/24/ && /-d 198.18.3.0\\/24/ && /-j MASQUERADE/ {gsub(/\\[|\\]/, \"\", \\$1); split(\\$1, a, \":\"); sum += a[1]} END {print sum+0}'" 2>/dev/null)

nat_l1_before=${nat_l1_before:-0}
nat_l2_before=${nat_l2_before:-0}
nat_l1_after=${nat_l1_after:-0}
nat_l2_after=${nat_l2_after:-0}

info "leaf-01 NAT packets: ${nat_l1_before} -> ${nat_l1_after}"
info "leaf-02 NAT packets: ${nat_l2_before} -> ${nat_l2_after}"

if [[ "$nat_l1_before" =~ ^[0-9]+$ ]] && [[ "$nat_l2_before" =~ ^[0-9]+$ ]] && [[ "$nat_l1_after" =~ ^[0-9]+$ ]] && [[ "$nat_l2_after" =~ ^[0-9]+$ ]] && { [ "$nat_l1_after" -gt "$nat_l1_before" ] || [ "$nat_l2_after" -gt "$nat_l2_before" ]; }; then
  ok "PAT/NAT counters increment for student ICMP toward internet target"
else
  warn "PAT/NAT counters did not visibly increment (ping path still validated)"
fi

echo
echo "Results: ${PASS} passed / ${FAIL} failed / ${WARN} warnings"
if [ "$FAIL" -eq 0 ]; then
  echo "Theme T1 READY"
  exit 0
fi

echo "Theme T1 NOT ready"
exit 1
