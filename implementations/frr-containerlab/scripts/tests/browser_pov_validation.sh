#!/usr/bin/env bash
set -u

LAB="${LAB:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB}"

CAMPUS_BP="${CLAB_PREFIX}-campus-bp"
GUEST_BROWSER="${CLAB_PREFIX}-campus-guest-browser"
STUDENT_BROWSER="${CLAB_PREFIX}-campus-student-browser"
ADMIN_BROWSER="${CLAB_PREFIX}-campus-admin-browser"
VPN_BROWSER="${CLAB_PREFIX}-vpn-browser-01"
VPN_CLIENT="${CLAB_PREFIX}-vpn-client-01"
VPN_GATEWAY="${CLAB_PREFIX}-vpn-gateway"

NAC_URL="https://192.168.110.1:8443/"
NAC_AUTH_URL="https://192.168.110.1:8443/auth"
INTERNET_URL="http://internet.esi.dz/"
DMZ_URL="http://esi.dz/"
JUPYTER_URL="https://hpc-jupyter.esi.internal:8080/hub/login"
JUPYTER_IP_URL="https://192.168.70.30:8080/hub/login"
VPN_ENROLL_HOST="198.51.100.20"
VPN_ENROLL_PORT="8448"
VPN_ENDPOINT="https://198.51.100.20:8448/enroll"
WG_ALLOWED="192.168.10.10/32,192.168.70.10/32,192.168.70.30/32"

failures=0

ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

run_in() {
  docker exec "$1" sh -lc "$2"
}

fetch_url() {
  local node="$1" url="$2"
  docker exec "$node" python3 -c '
import ssl
import sys
import urllib.request
ctx = ssl._create_unverified_context()
with urllib.request.urlopen(sys.argv[1], timeout=8, context=ctx) as response:
    print(response.read().decode("utf-8", "replace"))
' "$url"
}

post_login() {
  local node="$1" user="$2" password="$3"
  docker exec "$node" python3 -c '
import ssl
import sys
import urllib.parse
import urllib.request
ctx = ssl._create_unverified_context()
data = urllib.parse.urlencode({"username": sys.argv[2], "password": sys.argv[3]}).encode()
request = urllib.request.Request(
    sys.argv[1],
    data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=8, context=ctx) as response:
    print(response.read().decode("utf-8", "replace"))
' "$NAC_AUTH_URL" "$user" "$password"
}

parse_json() {
  python3 - <<'PY' "$1" "$2"
import json
import sys
payload = json.loads(sys.argv[1])
print(payload.get(sys.argv[2], ""))
PY
}

expect_page() {
  local node="$1" url="$2" pattern="$3" label="$4"
  local output
  if output="$(fetch_url "$node" "$url" 2>&1)" && echo "$output" | grep -Eq "$pattern"; then
    ok "$label"
  else
    fail "$label"
    echo "$output" | sed -n '1,8p' | sed 's/^/  /'
  fi
}

expect_tcp() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 5 nc -z -w2 ${ip} ${port}" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

expect_tcp_blocked() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 5 nc -z -w2 ${ip} ${port}" >/dev/null 2>&1; then
    fail "$label"
  else
    ok "$label"
  fi
}

expect_plain_http_auth_rejected() {
  local node="$1" label="$2"
  if docker exec "$node" python3 -c '
import sys
import urllib.error
import urllib.parse
import urllib.request
data = urllib.parse.urlencode({"username": "dev-campus-student-01", "password": "DeviceStudent@2026"}).encode()
request = urllib.request.Request(
    "http://192.168.110.1/auth",
    data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"},
    method="POST",
)
try:
    urllib.request.urlopen(request, timeout=5)
except urllib.error.HTTPError as exc:
    sys.exit(0 if exc.code == 400 else 1)
except Exception:
    sys.exit(1)
sys.exit(1)
' >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

expect_nac_member() {
  local set_name="$1" ip="$2" label="$3"
  if run_in "$CAMPUS_BP" "nft list set inet campus_nac ${set_name} 2>/dev/null | grep -q '${ip}'"; then
    ok "$label"
  else
    fail "$label"
  fi
}

clear_browser_roles() {
  for ip in 192.168.110.30 192.168.110.31 192.168.110.32; do
    run_in "$CAMPUS_BP" "nft delete element inet campus_nac campus_students { ${ip} } 2>/dev/null || true; nft delete element inet campus_nac campus_admins { ${ip} } 2>/dev/null || true" >/dev/null 2>&1 || true
  done
}

setup_vpn_tunnel() {
  local response vpn_addr server_pub

  run_in "$VPN_CLIENT" "ip link del wg0 2>/dev/null || true; rm -f /tmp/browser-vpn.key /tmp/browser-vpn.pub" >/dev/null 2>&1 || true
  run_in "$VPN_GATEWAY" "wg show wg0 peers 2>/dev/null | while read peer; do wg set wg0 peer \"\$peer\" remove; done" >/dev/null 2>&1 || true
  run_in "$VPN_CLIENT" "umask 077; wg genkey | tee /tmp/browser-vpn.key | wg pubkey > /tmp/browser-vpn.pub" >/dev/null 2>&1 || true

  response=$(run_in "$VPN_CLIENT" "PUB=\$(cat /tmp/browser-vpn.pub); curl -ks -X POST -H 'Content-Type: application/json' -d '{\"username\":\"student1\",\"password\":\"Student@2026\",\"public_key\":\"'\"\${PUB}\"'\"}' ${VPN_ENDPOINT}" 2>/dev/null || true)
  if ! echo "$response" | grep -q '"ok": true'; then
    fail "student VPN enrollment for browser rejected"
    echo "$response" | sed -n '1,4p' | sed 's/^/  /'
    return 1
  fi

  vpn_addr=$(parse_json "$response" "address")
  server_pub=$(parse_json "$response" "server_pubkey")
  if [ -z "$vpn_addr" ] || [ -z "$server_pub" ]; then
    fail "student VPN enrollment for browser returned incomplete tunnel config"
    return 1
  fi

  run_in "$VPN_CLIENT" "ip link add wg0 type wireguard 2>/dev/null || true"
  run_in "$VPN_CLIENT" "ip addr replace ${vpn_addr} dev wg0"
  run_in "$VPN_CLIENT" "wg set wg0 private-key /tmp/browser-vpn.key peer ${server_pub} endpoint 198.51.100.20:51820 allowed-ips ${WG_ALLOWED} persistent-keepalive 25"
  run_in "$VPN_CLIENT" "ip link set wg0 up"
  run_in "$VPN_CLIENT" "ip route replace 192.168.10.10/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 192.168.70.10/32 dev wg0"
  run_in "$VPN_CLIENT" "ip route replace 192.168.70.30/32 dev wg0"
  ok "student VPN enrollment for browser installed tunnel"
}

echo "=== Browser POV NAC Validation ==="

for node in "$CAMPUS_BP" "$GUEST_BROWSER" "$STUDENT_BROWSER" "$ADMIN_BROWSER" "$VPN_BROWSER" "$VPN_CLIENT" "$VPN_GATEWAY"; do
  if docker inspect "$node" >/dev/null 2>&1; then
    ok "$node exists"
  else
    fail "$node missing"
  fi
done

clear_browser_roles

expect_page "$GUEST_BROWSER" "$NAC_URL" "ESI Campus Access" "unauthenticated browser can load NAC portal"
expect_tcp "$GUEST_BROWSER" "192.168.110.1" 80 "unauthenticated browser can reach NAC HTTP redirect"
expect_plain_http_auth_rejected "$GUEST_BROWSER" "NAC rejects credential POST over plain HTTP"
expect_tcp_blocked "$GUEST_BROWSER" "198.18.3.10" 80 "unauthenticated browser cannot reach Internet web"
expect_tcp_blocked "$GUEST_BROWSER" "198.51.100.10" 80 "unauthenticated browser cannot reach DMZ web"
expect_tcp_blocked "$GUEST_BROWSER" "192.168.70.30" 8080 "unauthenticated browser cannot reach Jupyter"

if post_login "$STUDENT_BROWSER" "dev-campus-student-01" "DeviceStudent@2026" | grep -q "campus-student"; then
  ok "student browser login accepted by NAC"
else
  fail "student browser login rejected by NAC"
fi
expect_nac_member "campus_students" "192.168.110.31" "student browser appears in NAC student set"
expect_page "$STUDENT_BROWSER" "$INTERNET_URL" "internet\\.esi\\.dz" "student browser can load Internet site after NAC"
expect_page "$STUDENT_BROWSER" "$DMZ_URL" "ESI\\.dz DMZ Portal" "student browser can load DMZ portal after NAC"
expect_page "$STUDENT_BROWSER" "$JUPYTER_URL" "JupyterHub|jupyterhub" "student browser can load JupyterHub after NAC"
expect_tcp_blocked "$STUDENT_BROWSER" "192.168.50.10" 22 "student browser cannot open admin SSH"

if post_login "$ADMIN_BROWSER" "dev-campus-admin-01" "DeviceAdmin@2026" | grep -q "campus-admin"; then
  ok "admin browser login accepted by NAC"
else
  fail "admin browser login rejected by NAC"
fi
expect_nac_member "campus_admins" "192.168.110.32" "admin browser appears in NAC admin set"
expect_page "$ADMIN_BROWSER" "$JUPYTER_URL" "JupyterHub|jupyterhub" "admin browser can load JupyterHub after NAC"
expect_tcp "$ADMIN_BROWSER" "192.168.50.10" 22 "admin browser can open admin SSH transport"

expect_tcp "$VPN_BROWSER" "$VPN_ENROLL_HOST" "$VPN_ENROLL_PORT" "VPN browser can reach HTTPS enrollment portal"
if setup_vpn_tunnel; then
  expect_page "$VPN_BROWSER" "$JUPYTER_IP_URL" "JupyterHub|jupyterhub" "VPN browser can load JupyterHub after WireGuard enrollment"
fi

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi

echo "RESULT: FAIL (${failures} failure(s))"
exit 1
