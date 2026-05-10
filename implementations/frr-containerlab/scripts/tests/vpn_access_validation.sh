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
WG_ALLOWED="192.168.10.10/32,192.168.70.10/32,192.168.70.30/32"

failures=0

ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

run_in() {
  docker exec "$1" sh -lc "$2"
}

expect_tcp() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 6 nc -z -w3 ${ip} ${port}" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

expect_tcp_blocked() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 6 nc -z -w3 ${ip} ${port}" >/dev/null 2>&1; then
    fail "$label"
  else
    ok "$label"
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
payload = json.loads(sys.argv[1])
key = sys.argv[2]
value = payload.get(key, "")
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

RESP=$(run_in "$VPN_CLIENT" "PUB=\$(cat /tmp/vpn-client.pub); curl -ks -X POST -H 'Content-Type: application/json' -d '{\"username\":\"student1\",\"password\":\"Student@2026\",\"public_key\":\"'\"\${PUB}\"'\"}' ${VPN_ENDPOINT}")

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
  run_in "$VPN_CLIENT" "ip route replace 192.168.50.10/32 dev wg0"
else
  fail "missing VPN address or server key from enrollment"
fi

expect_tcp "$VPN_CLIENT" "192.168.10.10" "22" "VPN client can reach student SSH"
expect_tcp "$VPN_CLIENT" "192.168.70.10" "22" "VPN client can reach HPC SSH"
expect_tcp "$VPN_CLIENT" "192.168.70.30" "8080" "VPN client can reach Jupyter frontend"
expect_tcp_blocked "$VPN_CLIENT" "192.168.50.10" "22" "VPN client cannot reach admin SSH"

RESP_ADMIN=$(run_in "$VPN_CLIENT" "PUB=\$(cat /tmp/vpn-client.pub); curl -ks -X POST -H 'Content-Type: application/json' -d '{\"username\":\"admin1\",\"password\":\"Admin@2026\",\"public_key\":\"'\"\${PUB}\"'\"}' ${VPN_ENDPOINT}")
if echo "$RESP_ADMIN" | grep -q '"ok": false'; then
  ok "admin VPN enrollment rejected"
else
  fail "admin VPN enrollment unexpectedly accepted: ${RESP_ADMIN}"
fi

for node in "${INTERNET_ROUTERS[@]}"; do
  expect_no_private_routes "$node"
done

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi

echo "RESULT: FAIL (${failures} failure(s))"
exit 1
