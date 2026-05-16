#!/usr/bin/env bash
set -u

LAB="${LAB:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB}"

VPN_GATEWAY="${CLAB_PREFIX}-vpn-gateway"
VPN_CLIENT="${CLAB_PREFIX}-vpn-client-01"
SERVER_STUDENT="${CLAB_PREFIX}-server-student-01"
SERVER_HPC="${CLAB_PREFIX}-server-hpc-01"
INTERNET_ROUTERS=(
  "${CLAB_PREFIX}-isp-router-01"
  "${CLAB_PREFIX}-isp-router-04"
  "${CLAB_PREFIX}-internet-router-01"
  "${CLAB_PREFIX}-internet-router-02"
)

VPN_ENDPOINT="https://198.51.100.20:8448/enroll"
VPN_HEALTH_URL="https://198.51.100.20:8448/health"
WG_ALLOWED="192.168.50.30/32,192.168.10.10/32,192.168.70.10/32,192.168.70.30/32,198.51.100.30/32"

failures=0

ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

run_in() {
  docker exec "$1" sh -lc "$2"
}

wait_for_vpn_health() {
  local label="$1"
  local output
  local attempt
  for attempt in 1 2 3 4 5; do
    output="$(run_in "$VPN_CLIENT" "curl -ks ${VPN_HEALTH_URL}" 2>/dev/null || true)"
    if echo "$output" | grep -q '"ok": true'; then
      ok "$label"
      return 0
    fi
    sleep 2
  done
  fail "$label"
  echo "$output" | sed -n '1,6p' | sed 's/^/  /'
  return 1
}

expect_tcp() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 6 nc -z -w3 ${ip} ${port}" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

expect_tcp_wait() {
  local node="$1" ip="$2" port="$3" label="$4"
  local retries="${5:-120}"
  local delay="${6:-5}"
  local attempt=1

  while [ "$attempt" -le "$retries" ]; do
    if run_in "$node" "timeout 6 nc -z -w3 ${ip} ${port}" >/dev/null 2>&1; then
      ok "$label"
      return 0
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
  done

  fail "$label"
}

expect_tcp_blocked() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 6 nc -z -w3 ${ip} ${port}" >/dev/null 2>&1; then
    fail "$label"
  else
    ok "$label"
  fi
}

expect_dns() {
  local node="$1" name="$2" server="$3" pattern="$4" label="$5"
  if run_in "$node" "timeout 8 nslookup ${name} ${server}" 2>/dev/null | grep -Eq "$pattern"; then
    ok "$label"
  else
    fail "$label"
  fi
}

expect_no_private_routes() {
  local node="$1"
  local output
  output=$(run_in "$node" "vtysh -c 'show ip bgp' 2>/dev/null" || true)
  if echo "$output" | grep -Eq '(^|[[:space:]])(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'; then
    fail "$node has private BGP route leakage"
  else
    ok "$node has no RFC1918 or VPN-pool BGP route leakage"
  fi
}

parse_json() {
  python3 - <<'PY' "$1" "$2"
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print("")
    raise SystemExit(0)
key = sys.argv[2]
value = payload.get(key, "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

echo "=== VPN Access Validation ==="

for node in "$VPN_GATEWAY" "$VPN_CLIENT" "$SERVER_STUDENT" "$SERVER_HPC" "${INTERNET_ROUTERS[@]}"; do
  if docker inspect "$node" >/dev/null 2>&1; then
    ok "$node exists"
  else
    fail "$node missing"
  fi
done

run_in "$VPN_CLIENT" "ip link del wg0 2>/dev/null || true; rm -f /tmp/vpn-client.key /tmp/vpn-client.pub" >/dev/null 2>&1 || true
run_in "$VPN_GATEWAY" "wg show wg0 peers 2>/dev/null | while read peer; do wg set wg0 peer \"\$peer\" remove; done" >/dev/null 2>&1 || true
run_in "$VPN_CLIENT" "umask 077; wg genkey | tee /tmp/vpn-client.key | wg pubkey > /tmp/vpn-client.pub" >/dev/null 2>&1 || true

wait_for_vpn_health "VPN enrollment portal health is OK"

RESP=""
for attempt in 1 2 3 4 5; do
  RESP=$(run_in "$VPN_CLIENT" "PUB=\$(cat /tmp/vpn-client.pub); curl -ks -X POST -H 'Content-Type: application/json' -d '{\"username\":\"amine.kadri@esi.dz\",\"password\":\"AmineLab#2026\",\"public_key\":\"'\"\${PUB}\"'\"}' ${VPN_ENDPOINT}" 2>/dev/null || true)
  if echo "$RESP" | grep -q '"ok": true'; then
    break
  fi
  sleep 2
done

if echo "$RESP" | grep -q '"ok": true'; then
  ok "student VPN enrollment accepted"
else
  fail "student VPN enrollment rejected: ${RESP}"
fi

VPN_ADDR=$(parse_json "$RESP" "address")
SERVER_PUB=$(parse_json "$RESP" "server_pubkey")

if [ -n "$VPN_ADDR" ] && [ -n "$SERVER_PUB" ]; then
  run_in "$VPN_CLIENT" "ip link add wg0 type wireguard 2>/dev/null || true"
  run_in "$VPN_CLIENT" "ip addr replace ${VPN_ADDR} dev wg0"
  run_in "$VPN_CLIENT" "wg set wg0 private-key /tmp/vpn-client.key peer ${SERVER_PUB} endpoint 198.51.100.20:51820 allowed-ips ${WG_ALLOWED} persistent-keepalive 25"
  run_in "$VPN_CLIENT" "ip link set wg0 up"
  run_in "$VPN_CLIENT" "ip route replace 192.168.10.10/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 192.168.70.10/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 192.168.70.30/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 192.168.50.30/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 198.51.100.30/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 192.168.50.10/32 dev wg0"
else
  fail "missing VPN address or server key from enrollment"
fi

expect_tcp "$VPN_CLIENT" "192.168.10.10" "22" "VPN client can reach student SSH"
expect_tcp "$VPN_CLIENT" "192.168.70.10" "22" "VPN client can reach HPC SSH"
expect_tcp "$VPN_CLIENT" "192.168.70.30" "8080" "VPN client can reach Jupyter frontend"
expect_dns "$VPN_CLIENT" "hpc-jupyter.esi.internal" "192.168.50.30" "Address.*192\\.168\\.70\\.30" "VPN client resolves Jupyter through datacenter DNS"
expect_dns "$VPN_CLIENT" "moodle.esi.dz" "192.168.50.30" "Address.*198\\.51\\.100\\.30" "VPN client resolves Moodle through datacenter DNS"
expect_tcp_wait "$VPN_CLIENT" "198.51.100.30" "80" "VPN client can reach Moodle frontend" "${VPN_MOODLE_RETRIES:-120}" "${VPN_MOODLE_DELAY:-5}"
expect_tcp_blocked "$VPN_CLIENT" "192.168.50.10" "22" "VPN client cannot reach admin SSH"

RESP_ADMIN=$(run_in "$VPN_CLIENT" "PUB=\$(cat /tmp/vpn-client.pub); curl -ks -X POST -H 'Content-Type: application/json' -d '{\"username\":\"squareone.admin@esi.dz\",\"password\":\"SquareOneRoot#2026\",\"public_key\":\"'\"\${PUB}\"'\"}' ${VPN_ENDPOINT}")
if echo "$RESP_ADMIN" | grep -q '"ok": false'; then
  ok "admin VPN enrollment rejected"
else
  fail "admin VPN enrollment unexpectedly accepted: ${RESP_ADMIN}"
fi

RESP_LOGOUT=$(run_in "$VPN_CLIENT" "PUB=\$(cat /tmp/vpn-client.pub); curl -ks -X POST -H 'Content-Type: application/json' -d '{\"public_key\":\"'\"\${PUB}\"'\"}' https://198.51.100.20:8448/logout" 2>/dev/null || true)
if echo "$RESP_LOGOUT" | grep -q '"ok": true'; then
  ok "student VPN logout accepted"
else
  fail "student VPN logout rejected: ${RESP_LOGOUT}"
fi
run_in "$VPN_CLIENT" "ip link del wg0 2>/dev/null || true" >/dev/null 2>&1 || true
expect_tcp_blocked "$VPN_CLIENT" "192.168.70.30" "8080" "VPN client cannot reach Jupyter after logout"

RESP_IMPLICIT=""
for attempt in 1 2 3 4 5; do
  RESP_IMPLICIT=$(run_in "$VPN_CLIENT" "curl -ks -X POST -H 'Content-Type: application/json' -d '{\"username\":\"amine.kadri@esi.dz\",\"password\":\"AmineLab#2026\"}' ${VPN_ENDPOINT}" 2>/dev/null || true)
  if echo "$RESP_IMPLICIT" | grep -q '"ok": true'; then
    break
  fi
  sleep 2
done

IMPLICIT_PUB=$(parse_json "$RESP_IMPLICIT" "client_public_key")
IMPLICIT_PRIVATE=$(parse_json "$RESP_IMPLICIT" "client_private_key")
IMPLICIT_GENERATED=$(parse_json "$RESP_IMPLICIT" "generated_key")
IMPLICIT_INSTALLED=$(parse_json "$RESP_IMPLICIT" "client_installed")

if [ -n "$IMPLICIT_PUB" ] && [ -n "$IMPLICIT_PRIVATE" ] && [ "$IMPLICIT_GENERATED" = "true" ]; then
  ok "student VPN enrollment generates a keypair implicitly"
else
  fail "student VPN implicit key enrollment incomplete: ${RESP_IMPLICIT}"
fi

if [ "$IMPLICIT_INSTALLED" = "true" ] && run_in "$VPN_CLIENT" "ip link show wg0 >/dev/null 2>&1 && ip route get 192.168.70.30 2>/dev/null | grep -q wg0 && grep -q '192.168.50.30' /etc/resolv.conf"; then
  ok "student VPN implicit browser-style enrollment auto-installs client tunnel"
else
  fail "student VPN implicit browser-style enrollment did not install client tunnel: ${RESP_IMPLICIT}"
fi

expect_tcp "$VPN_CLIENT" "192.168.70.30" "8080" "VPN client can reach Jupyter after implicit browser-style enrollment"
expect_dns "$VPN_CLIENT" "hpc-jupyter.esi.internal" "192.168.50.30" "Address.*192\\.168\\.70\\.30" "VPN implicit tunnel uses datacenter DNS for Jupyter name"
expect_dns "$VPN_CLIENT" "moodle.esi.dz" "192.168.50.30" "Address.*198\\.51\\.100\\.30" "VPN implicit tunnel uses datacenter DNS for Moodle name"

RESP_IMPLICIT_LOGOUT=$(run_in "$VPN_CLIENT" "curl -ks -X POST -H 'Content-Type: application/json' -d '{\"public_key\":\"${IMPLICIT_PUB}\"}' https://198.51.100.20:8448/logout" 2>/dev/null || true)
if echo "$RESP_IMPLICIT_LOGOUT" | grep -q '"ok": true'; then
  ok "student VPN implicit lease logout accepted"
else
  fail "student VPN implicit lease logout rejected: ${RESP_IMPLICIT_LOGOUT}"
fi
run_in "$VPN_CLIENT" "ip link del wg0 2>/dev/null || true" >/dev/null 2>&1 || true
expect_tcp_blocked "$VPN_CLIENT" "192.168.70.30" "8080" "VPN client cannot reach Jupyter after implicit VPN logout"

for node in "${INTERNET_ROUTERS[@]}"; do
  expect_no_private_routes "$node"
done

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi

echo "RESULT: FAIL (${failures} failure(s))"
exit 1
