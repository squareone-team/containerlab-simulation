#!/usr/bin/env bash
set -euo pipefail

CLAB_PREFIX="${CLAB_PREFIX:-clab-esi-datacenter}"
TARGET_IP="198.51.100.10"
TARGET_URL="http://${TARGET_IP}/"
TARGET_TEXT="ESI Datacenter DMZ test service is reachable"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo "[INFO] $1"; }

run_in_container() {
  local node="$1"
  shift
  docker exec "${CLAB_PREFIX}-${node}" sh -lc "$*"
}

container_exists() {
  docker ps --format '{{.Names}}' | grep -qx "${CLAB_PREFIX}-$1"
}

require_container() {
  local node="$1"
  if container_exists "$node"; then
    pass "container present: $node"
  else
    fail "container missing: $node"
  fi
}

master_firewall() {
  if run_in_container "firewall-01" "ip -4 addr show bond0 | grep -q '192.168.1.254/24'"; then
    echo "firewall-01"
  elif run_in_container "firewall-02" "ip -4 addr show bond0 | grep -q '192.168.1.254/24'"; then
    echo "firewall-02"
  fi
}

http_fetch_cmd() {
  local url="$1"
  cat <<EOF
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 5 "$url"
elif command -v wget >/dev/null 2>&1; then
  wget -q -T 5 -O - "$url"
elif command -v nc >/dev/null 2>&1; then
  printf 'GET / HTTP/1.0\r\nHost: ${TARGET_IP}\r\n\r\n' | nc -w 5 ${TARGET_IP} 80
else
  echo 'no HTTP client available' >&2
  exit 127
fi
EOF
}

http_ok_from() {
  local node="$1"
  run_in_container "$node" "$(http_fetch_cmd "$TARGET_URL")" | grep -Fq "$TARGET_TEXT"
}

get_drop_packets() {
  local fw="$1"
  run_in_container "$fw" "tc -s filter show dev eth4 ingress 2>/dev/null | sed -n 's/.*(dropped \\([0-9][0-9]*\\),.*/\\1/p' | head -n1"
}

show_ips_counters() {
  local fw="$1"
  run_in_container "$fw" "tc -s filter show dev eth4 ingress" | sed 's/^/  /'
}

bgp_established() {
  run_in_container "border-router-01" "vtysh -c 'show bgp neighbors 203.0.113.2' 2>/dev/null | grep -q 'BGP state = Established'" &&
    run_in_container "isp-router-01" "vtysh -c 'show bgp neighbors 203.0.113.1' 2>/dev/null | grep -q 'BGP state = Established'"
}

vrf_public_clean() {
  ! run_in_container "leaf-01" "ip route show vrf VRF-PUBLIC 2>/dev/null | grep -Eq '192\\.168\\.(10|20|30|40|50|60|70|80)\\.'"
}

attack_snippet() {
  cat <<'ATTACK'
rm -f /tmp/edge-ddos-counts.log
end=$(( $(date +%s) + 8 ))
target="198.51.100.10"

worker() {
  id="$1"
  count=0
  while [ "$(date +%s)" -lt "$end" ]; do
    if command -v wget >/dev/null 2>&1; then
      wget -q -T 1 -O /dev/null "http://${target}/" >/dev/null 2>&1 || true
    elif command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 1 "http://${target}/" >/dev/null 2>&1 || true
    elif command -v nc >/dev/null 2>&1; then
      printf 'GET / HTTP/1.0\r\nHost: 198.51.100.10\r\n\r\n' | nc -w 1 "$target" 80 >/dev/null 2>&1 || true
    else
      echo "no HTTP client available" >&2
      exit 127
    fi
    count=$((count + 1))
  done
  echo "worker-${id} requests=${count}" >> /tmp/edge-ddos-counts.log
}

for worker_id in 1 2 3 4 5 6; do
  worker "$worker_id" &
done
wait
cat /tmp/edge-ddos-counts.log
ATTACK
}

echo "============================================================"
echo " Firewall IDS/IPS DDoS Prevention Validation"
echo "============================================================"

for node in firewall-01 firewall-02 border-router-01 isp-router-01 internet-client-01 internet-client-02 public-web-server leaf-01; do
  require_container "$node"
done

if (( FAIL_COUNT > 0 )); then
  echo "Required containers are missing; deploy the lab before running this test."
  exit 1
fi

MASTER_FW="$(master_firewall)"
if [[ -n "$MASTER_FW" ]]; then
  pass "master firewall detected: $MASTER_FW"
else
  fail "no firewall owns the inside VIP"
fi

if (( FAIL_COUNT > 0 )); then
  exit 1
fi

if run_in_container "$MASTER_FW" "tc filter show dev eth4 ingress | grep -Eq 'dst_ip 198\\.51\\.100\\.10|police'"; then
  pass "firewall IPS DDoS tc police rule is loaded on master"
else
  fail "firewall IPS DDoS tc police rule is missing on master"
fi

if bgp_established; then
  pass "BGP adjacency survives firewall inline IPS placement"
else
  fail "BGP adjacency is not established across ISP and border router"
fi

if http_ok_from "internet-client-01"; then
  pass "baseline internet-client-01 HTTP to DMZ succeeds"
else
  fail "baseline internet-client-01 HTTP to DMZ failed"
fi

before_drop="$(get_drop_packets "$MASTER_FW")"
before_drop="${before_drop:-0}"

echo
echo "---------------- IPS counters before attack ----------------"
show_ips_counters "$MASTER_FW"

echo
echo "---------------- Controlled HTTP flood trace ----------------"
info "Launching 6 workers from internet-client-01 and 6 from internet-client-02 for 8 seconds."
attack_cmd="$(attack_snippet)"
docker exec "${CLAB_PREFIX}-internet-client-01" sh -lc "$attack_cmd" > /tmp/edge-ddos-client-01.log 2>&1 &
pid1=$!
docker exec "${CLAB_PREFIX}-internet-client-02" sh -lc "$attack_cmd" > /tmp/edge-ddos-client-02.log 2>&1 &
pid2=$!

for second in 1 2 3 4 5 6 7 8; do
  sleep 1
  current_drop="$(get_drop_packets "$MASTER_FW")"
  current_drop="${current_drop:-0}"
  printf '[TRACE] second=%s firewall_ips_drops=%s\n' "$second" "$current_drop"
done

wait "$pid1"
wait "$pid2"

echo
echo "internet-client-01 attack workers:"
sed 's/^/  /' /tmp/edge-ddos-client-01.log
echo "internet-client-02 attack workers:"
sed 's/^/  /' /tmp/edge-ddos-client-02.log

after_drop="$(get_drop_packets "$MASTER_FW")"
after_drop="${after_drop:-0}"

echo
echo "---------------- IPS counters after attack ----------------"
show_ips_counters "$MASTER_FW"

if [[ "$after_drop" =~ ^[0-9]+$ && "$before_drop" =~ ^[0-9]+$ && "$after_drop" -gt "$before_drop" ]]; then
  pass "firewall IPS dropped excess DMZ HTTP SYN packets (${before_drop} -> ${after_drop})"
else
  fail "firewall IPS drop counter did not increase (${before_drop} -> ${after_drop})"
fi

sleep 5
if http_ok_from "internet-client-01"; then
  pass "DMZ HTTP remains reachable after mitigation"
else
  fail "DMZ HTTP did not recover after mitigation"
fi

if bgp_established; then
  pass "BGP remains established after the attack test"
else
  fail "BGP dropped during or after the attack test"
fi

if vrf_public_clean; then
  pass "VRF-PUBLIC has no internal route leak"
else
  fail "VRF-PUBLIC contains internal routes"
fi

echo
echo "============================================================"
echo " Results"
echo "============================================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if (( FAIL_COUNT > 0 )); then
  exit 1
fi

echo "Firewall IDS/IPS DDoS prevention validation passed."
