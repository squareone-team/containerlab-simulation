#!/usr/bin/env bash
set -u

LAB="${LAB:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBDRIVER_PROBE="${SCRIPT_DIR}/browser_webdriver_probe.py"

CAMPUS_BP="${CLAB_PREFIX}-campus-bp"
GUEST_BROWSER="${CLAB_PREFIX}-guest-01"
STUDENT_BROWSER="${CLAB_PREFIX}-student-01"
ADMIN_BROWSER="${CLAB_PREFIX}-admin-01"
VPN_BROWSER="${CLAB_PREFIX}-vpn-client-01"
VPN_CLIENT="$VPN_BROWSER"
VPN_GATEWAY="${CLAB_PREFIX}-vpn-gateway"

NAC_URL="https://192.168.110.1:8443/"
NAC_LOGOUT_URL="https://192.168.110.1:8443/logout"
INTERNET_URL="http://www.google.com/"
MOODLE_URL="http://moodle.esi.dz/"
JUPYTER_URL="https://hpc-jupyter.esi.internal:8080/hub/login"
JUPYTER_IP_URL="https://192.168.70.30:8080/hub/login"
VPN_ENROLL_HOST="198.51.100.20"
VPN_ENROLL_PORT="8448"
VPN_URL="https://198.51.100.20:8448/"
VPN_LOGOUT_URL="https://198.51.100.20:8448/logout"
VPN_HEALTH_URL="https://198.51.100.20:8448/health"
WG_ALLOWED="192.168.50.30/32,192.168.10.10/32,192.168.70.10/32,192.168.70.30/32,198.51.100.30/32"

failures=0

ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
info() { echo "INFO: $*"; }

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

run_in() {
  docker exec "$1" sh -lc "$2"
}

webdriver() {
  local node="$1"
  shift
  docker exec -i "$node" python3 - "$@" < "$WEBDRIVER_PROBE"
}

parse_json() {
  python3 - <<'PY' "$1" "$2"
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

expect_browser_page() {
  local node="$1" url="$2" pattern="$3" label="$4"
  local output=""
  local attempt
  for attempt in 1 2 3; do
    if output="$(webdriver "$node" page "$url" "$pattern" 2>&1)"; then
      ok "$label"
      return 0
    fi
    sleep 3
  done
  fail "$label"
  echo "$output" | sed -n '1,10p' | sed 's/^/  /'
  return 1
}

expect_browser_nac_login() {
  local node="$1" user="$2" password="$3" expected_role="$4" label="$5"
  local output=""
  local attempt
  for attempt in 1 2 3; do
    if output="$(webdriver "$node" nac-login "$NAC_URL" "$user" "$password" "$expected_role" 2>&1)"; then
      ok "$label"
      return 0
    fi
    sleep 3
  done
  fail "$label"
  echo "$output" | sed -n '1,10p' | sed 's/^/  /'
  return 1
}

expect_browser_ui() {
  local node="$1" port="$2" label="$3"
  if run_in "$node" "ss -lnt 2>/dev/null | grep -q ':5800 '" && docker port "$node" 5800/tcp 2>/dev/null | grep -q "127.0.0.1:${port}"; then
    ok "$label"
  else
    fail "$label"
  fi
}

wait_for_vpn_health() {
  local label="$1"
  local output=""
  local attempt
  for attempt in 1 2 3 4 5 6; do
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

expect_vpn_health_fast() {
  local label="$1"
  local result elapsed
  result="$(run_in "$VPN_CLIENT" "curl -ks -o /dev/null -w '%{time_total}' ${VPN_HEALTH_URL}" 2>/dev/null || true)"
  elapsed="$(python3 - <<'PY' "$result"
import sys
try:
    value = float(sys.argv[1])
except Exception:
    value = 99.0
print("ok" if value < 1.5 else "slow")
PY
)"
  if [ "$elapsed" = "ok" ]; then
    ok "$label"
  else
    fail "$label"
    echo "  health response time: ${result:-unavailable}s"
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

expect_dns() {
  local node="$1" name="$2" server="$3" pattern="$4" label="$5"
  if run_in "$node" "timeout 8 nslookup ${name} ${server}" 2>/dev/null | grep -Eq "$pattern"; then
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
  local code
  code="$(docker exec -i "$node" python3 - <<'PY' 2>/dev/null || true
import urllib.error
import urllib.parse
import urllib.request

data = urllib.parse.urlencode({"username": "amine.kadri@esi.dz", "password": "AmineLab#2026"}).encode()
req = urllib.request.Request(
    "http://192.168.110.1/auth",
    data=data,
    headers={"Content-Type": "application/x-www-form-urlencoded"},
)
try:
    with urllib.request.urlopen(req, timeout=5) as response:
        print(response.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
)"
  if [ "$code" = "400" ]; then
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

expect_nac_absent() {
  local set_name="$1" ip="$2" label="$3"
  if run_in "$CAMPUS_BP" "nft list set inet campus_nac ${set_name} 2>/dev/null | grep -q '${ip}'"; then
    fail "$label"
  else
    ok "$label"
  fi
}

clear_browser_roles() {
  for ip in 192.168.110.30 192.168.110.31 192.168.110.32; do
    run_in "$CAMPUS_BP" "nft delete element inet campus_nac campus_students { ${ip} } 2>/dev/null || true; nft delete element inet campus_nac campus_admins { ${ip} } 2>/dev/null || true" >/dev/null 2>&1 || true
  done
}

nac_logout() {
  local node="$1" label="$2"
  local output
  if output="$(webdriver "$node" page "$NAC_LOGOUT_URL" "Signed out|NAC session was removed" 2>&1)"; then
    ok "$label"
  else
    fail "$label"
    echo "$output" | sed -n '1,8p' | sed 's/^/  /'
  fi
}

vpn_logout() {
  local public_key="$1"
  local label="$2"
  local output
  output="$(docker exec -i "$VPN_CLIENT" python3 - "$VPN_LOGOUT_URL" "$public_key" <<'PY' 2>&1 || true
import json
import ssl
import sys
import urllib.request

ctx = ssl._create_unverified_context()
payload = json.dumps({"public_key": sys.argv[2]}).encode()
req = urllib.request.Request(
    sys.argv[1],
    data=payload,
    headers={"Content-Type": "application/json", "Accept": "application/json"},
)
with urllib.request.urlopen(req, context=ctx, timeout=8) as response:
    sys.stdout.write(response.read().decode("utf-8", "replace"))
PY
)"
  if echo "$output" | grep -q '"ok": true'; then
    ok "$label"
  else
    fail "$label"
    echo "$output" | sed -n '1,6p' | sed 's/^/  /'
  fi
}

setup_vpn_tunnel_from_browser() {
  local response private_key vpn_addr server_pub client_pub client_installed

  run_in "$VPN_CLIENT" "ip link del wg0 2>/dev/null || true; rm -f /tmp/browser-vpn.key" >/dev/null 2>&1 || true
  run_in "$VPN_GATEWAY" "wg show wg0 peers 2>/dev/null | while read peer; do wg set wg0 peer \"\$peer\" remove; done; rm -f /var/lib/esi-vpn/leases.json" >/dev/null 2>&1 || true

  local attempt
  for attempt in 1 2 3; do
    response="$(webdriver "$VPN_BROWSER" vpn-login "$VPN_URL" "amine.kadri@esi.dz" "AmineLab#2026" 2>&1)" && break
    sleep 3
  done
  if ! echo "$response" | python3 -m json.tool >/dev/null 2>&1; then
    fail "VPN browser enrollment with implicit key generation accepted"
    echo "$response" | sed -n '1,12p' | sed 's/^/  /'
    return 1
  fi
  ok "VPN browser enrollment with implicit key generation accepted"

  private_key="$(parse_json "$response" "private_key")"
  vpn_addr="$(parse_json "$response" "address")"
  server_pub="$(parse_json "$response" "server_pubkey")"
  client_pub="$(parse_json "$response" "client_public_key")"
  client_installed="$(parse_json "$response" "client_installed")"
  if [ -z "$private_key" ] || [ -z "$vpn_addr" ] || [ -z "$server_pub" ] || [ -z "$client_pub" ]; then
    fail "VPN browser enrollment returned complete WireGuard config"
    echo "$response" | sed -n '1,4p' | sed 's/^/  /'
    return 1
  fi
  ok "VPN browser enrollment returned complete WireGuard config"

  if [ "$client_installed" != "true" ]; then
    fail "VPN browser enrollment auto-installed the tunnel in vpn-client-01"
    echo "$response" | sed -n '1,4p' | sed 's/^/  /'
    return 1
  fi
  ok "VPN browser enrollment auto-installed the tunnel in vpn-client-01"

  local attempt
  for attempt in 1 2 3 4 5; do
    if run_in "$VPN_CLIENT" "ip link show wg0 >/dev/null 2>&1 && ip route get 192.168.70.30 2>/dev/null | grep -q wg0"; then
      ok "VPN browser-installed WireGuard tunnel is active on the same fabric client"
      VPN_BROWSER_PUBLIC_KEY="$client_pub"
      return 0
    fi
    sleep 1
  done

  fail "VPN browser-installed WireGuard tunnel is active on the same fabric client"
  return 1
}

echo "=== Browser POV Validation ==="

for node in "$CAMPUS_BP" "$GUEST_BROWSER" "$STUDENT_BROWSER" "$ADMIN_BROWSER" "$VPN_BROWSER" "$VPN_GATEWAY"; do
  if container_exists "$node"; then
    ok "$node exists"
  else
    fail "$node missing"
  fi
done

for node in "$GUEST_BROWSER" "$STUDENT_BROWSER" "$ADMIN_BROWSER" "$VPN_BROWSER"; do
  if run_in "$node" "command -v firefox >/dev/null && command -v geckodriver >/dev/null && command -v ip >/dev/null"; then
    ok "$node has Firefox, geckodriver, and fabric tools"
  else
    fail "$node missing browser validation tools"
  fi
done

expect_browser_ui "$STUDENT_BROWSER" 5811 "student browser UI is served by the fabric-connected student-01 container"
expect_browser_ui "$ADMIN_BROWSER" 5812 "admin browser UI is served by the fabric-connected admin-01 container"
expect_browser_ui "$GUEST_BROWSER" 5813 "guest browser UI is served by the fabric-connected guest-01 container"
expect_browser_ui "$VPN_BROWSER" 5814 "VPN browser UI is served by the fabric-connected vpn-client-01 container"

clear_browser_roles

expect_browser_page "$GUEST_BROWSER" "$NAC_URL" "Bienvenus au portail ESI|Sign in to access this network" "guest browser can load NAC portal"
expect_tcp "$GUEST_BROWSER" "192.168.110.1" 80 "guest browser can reach NAC HTTP redirect"
expect_plain_http_auth_rejected "$GUEST_BROWSER" "NAC rejects credential POST over plain HTTP"
expect_tcp_blocked "$GUEST_BROWSER" "198.18.3.10" 80 "guest browser starts without Internet access"
expect_tcp_blocked "$GUEST_BROWSER" "198.51.100.30" 80 "guest browser starts without Moodle access"
expect_tcp_blocked "$GUEST_BROWSER" "192.168.70.30" 8080 "guest browser starts without Jupyter access"
expect_tcp_blocked "$STUDENT_BROWSER" "192.168.70.30" 8080 "student browser starts unauthenticated"
expect_tcp_blocked "$ADMIN_BROWSER" "192.168.50.10" 22 "admin browser starts unauthenticated"

expect_browser_nac_login "$STUDENT_BROWSER" "amine.kadri@esi.dz" "AmineLab#2026" "campus-student" "student browser login accepted by NAC"
expect_nac_member "campus_students" "192.168.110.31" "student browser appears in NAC student set"
expect_browser_page "$STUDENT_BROWSER" "$INTERNET_URL" "Google Search" "student browser can load www.google.com after NAC"
expect_browser_page "$STUDENT_BROWSER" "$MOODLE_URL" "Moodle|TP - NAC" "student browser can load Moodle after NAC"
expect_browser_page "$STUDENT_BROWSER" "$JUPYTER_URL" "JupyterHub|jupyterhub" "student browser can load JupyterHub after NAC"
expect_tcp_blocked "$STUDENT_BROWSER" "192.168.50.10" 22 "student browser cannot open admin SSH"

expect_browser_nac_login "$ADMIN_BROWSER" "squareone.admin@esi.dz" "SquareOneRoot#2026" "campus-admin" "admin browser login accepted by NAC"
expect_nac_member "campus_admins" "192.168.110.32" "admin browser appears in NAC admin set"
expect_browser_page "$ADMIN_BROWSER" "$JUPYTER_URL" "JupyterHub|jupyterhub" "admin browser can load JupyterHub after NAC"
expect_tcp "$ADMIN_BROWSER" "192.168.50.10" 22 "admin browser can open admin SSH transport"

nac_logout "$STUDENT_BROWSER" "student browser logout accepted by NAC"
expect_nac_absent "campus_students" "192.168.110.31" "student browser removed from NAC set after logout"
expect_tcp_blocked "$STUDENT_BROWSER" "192.168.70.30" 8080 "student browser is blocked after NAC logout"
nac_logout "$ADMIN_BROWSER" "admin browser logout accepted by NAC"
expect_nac_absent "campus_admins" "192.168.110.32" "admin browser removed from NAC set after logout"
expect_tcp_blocked "$ADMIN_BROWSER" "192.168.50.10" 22 "admin browser is blocked after NAC logout"

expect_tcp "$VPN_BROWSER" "$VPN_ENROLL_HOST" "$VPN_ENROLL_PORT" "VPN browser can reach HTTPS enrollment portal"
wait_for_vpn_health "VPN enrollment portal health is OK before browser enrollment"
expect_vpn_health_fast "VPN enrollment portal health responds quickly before browser enrollment"
if setup_vpn_tunnel_from_browser; then
  wait_for_vpn_health "VPN enrollment portal remains healthy after browser enrollment"
  expect_vpn_health_fast "VPN enrollment portal remains quick after browser enrollment"
  sleep 5
  wait_for_vpn_health "VPN enrollment portal remains healthy after idle browser session"
  expect_dns "$VPN_BROWSER" "hpc-jupyter.esi.internal" "192.168.50.30" "Address.*192\\.168\\.70\\.30" "VPN browser resolves Jupyter through datacenter DNS"
  expect_dns "$VPN_BROWSER" "moodle.esi.dz" "192.168.50.30" "Address.*198\\.51\\.100\\.30" "VPN browser resolves Moodle through datacenter DNS"
  expect_browser_page "$VPN_BROWSER" "$JUPYTER_URL" "JupyterHub|jupyterhub" "VPN browser can load JupyterHub by DNS name after WireGuard enrollment"
  expect_browser_page "$VPN_BROWSER" "$MOODLE_URL" "Moodle|TP - NAC" "VPN browser can load Moodle by DNS name after WireGuard enrollment"
  vpn_logout "$VPN_BROWSER_PUBLIC_KEY" "VPN browser logout removed WireGuard lease"
  run_in "$VPN_CLIENT" "ip link del wg0 2>/dev/null || true" >/dev/null 2>&1 || true
  expect_tcp_blocked "$VPN_BROWSER" "192.168.70.30" 8080 "VPN browser is blocked after VPN logout and tunnel removal"
fi

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi

echo "RESULT: FAIL (${failures} failure(s))"
exit 1
