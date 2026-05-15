#!/usr/bin/env bash
set -u

LAB="${LAB:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB}"

AUTH_SERVER="${CLAB_PREFIX}-auth-server"
CAMPUS_BP="${CLAB_PREFIX}-campus-bp"
CAMPUS_STUDENT="${CLAB_PREFIX}-campus-student-01"
CAMPUS_ADMIN="${CLAB_PREFIX}-campus-admin-01"
STUDENT_BP="${CLAB_PREFIX}-student-bp-01"
SERVER_STUDENT="${CLAB_PREFIX}-server-student-01"
SERVER_ADMIN="${CLAB_PREFIX}-server-admin-01"
SERVER_HPC="${CLAB_PREFIX}-server-hpc-01"

STUDENT_TARGET="192.168.10.10"
ADMIN_TARGET="192.168.50.10"
HPC_TARGET="192.168.70.10"
JUPYTER_TARGET="192.168.70.30"
AUTH_IP="192.168.50.80"
RADIUS_SECRET_CAMPUS="EsiCampusNacRadius#2026"

NAC_STUDENT_IP="192.168.110.31"
NAC_ADMIN_IP="192.168.110.32"
NAC_ATTACKER_IP="192.168.110.30"
NAC_GATEWAY_IP="192.168.110.1"

failures=0

ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
info() { echo "INFO: $*"; }

run_in() {
  docker exec "$1" sh -lc "$2"
}

wait_for_tcp() {
  local node="$1" ip="$2" port="$3" label="$4"
  local i
  for i in $(seq 1 24); do
    if run_in "$node" "timeout 4 nc -z -w2 ${ip} ${port}" >/dev/null 2>&1; then
      ok "$label reachable at ${ip}:${port}"
      return 0
    fi
    sleep 5
  done
  fail "$label not reachable at ${ip}:${port}"
  return 1
}

expect_radius_role() {
  local node="$1" user="$2" password="$3" expected_role="$4" label="$5"
  local output
  output=$(run_in "$node" "printf 'User-Name = \"${user}\"\\nUser-Password = \"${password}\"\\nNAS-Identifier = \"campus-nac\"\\n' | radclient -x ${AUTH_IP}:1812 auth ${RADIUS_SECRET_CAMPUS} 2>&1")
  if echo "$output" | grep -q "Access-Accept" && echo "$output" | grep -q "Filter-Id" && echo "$output" | grep -q "$expected_role"; then
    ok "$label"
  else
    fail "$label failed: ${output}"
  fi
}

wait_for_nac_set() {
  local node="$1" set_name="$2" ip="$3" label="$4"
  local i
  for i in $(seq 1 20); do
    if run_in "$node" "nft list set inet campus_nac ${set_name} 2>/dev/null | grep -q '${ip}'"; then
      ok "$label"
      return 0
    fi
    sleep 3
  done
  fail "$label"
  return 1
}

expect_nac_absent() {
  local node="$1" set_name="$2" ip="$3" label="$4"
  if run_in "$node" "nft list set inet campus_nac ${set_name} 2>/dev/null | grep -q '${ip}'"; then
    fail "$label"
  else
    ok "$label"
  fi
}

expect_tcp_blocked() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 4 nc -z -w2 ${ip} ${port}" >/dev/null 2>&1; then
    fail "$label unexpectedly reachable at ${ip}:${port}"
  else
    ok "$label blocked at ${ip}:${port}"
  fi
}

expect_runtime_rule() {
  local node="$1" fragment="$2" label="$3"
  if run_in "$node" "nft list ruleset 2>/dev/null | grep -F '${fragment}' >/dev/null"; then
    ok "$label"
  else
    fail "$label missing runtime rule fragment: ${fragment}"
  fi
}

expect_runtime_absent() {
  local node="$1" fragment="$2" label="$3"
  if run_in "$node" "nft list ruleset 2>/dev/null | grep -F '${fragment}' >/dev/null"; then
    fail "$label still has runtime fragment: ${fragment}"
  else
    ok "$label"
  fi
}

ssh_attempt() {
  local client="$1" user="$2" password="$3" target="$4"
  run_in "$client" "sshpass -p '${password}' ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=keyboard-interactive \
    -o KbdInteractiveAuthentication=yes \
    -o PasswordAuthentication=no \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=8 \
    ${user}@${target} 'cat /etc/esi-auth-resource'"
}

expect_ssh_success() {
  local label="$1" client="$2" user="$3" password="$4" target="$5" expected_resource="$6"
  local output
  if output="$(ssh_attempt "$client" "$user" "$password" "$target" 2>&1)"; then
    if printf '%s' "$output" | grep -qx "$expected_resource"; then
      ok "$label"
    else
      fail "$label returned unexpected resource: ${output}"
    fi
  else
    fail "$label denied unexpectedly: ${output}"
  fi
}

expect_ssh_denied() {
  local label="$1" client="$2" user="$3" password="$4" target="$5"
  local output
  if output="$(ssh_attempt "$client" "$user" "$password" "$target" 2>&1)"; then
    fail "$label succeeded unexpectedly: ${output}"
  else
    ok "$label"
  fi
}

echo "=== Fabric Authentication and Authorization Validation ==="
echo "Lab: ${LAB}"

for node in "$AUTH_SERVER" "$CAMPUS_BP" "$CAMPUS_STUDENT" "$CAMPUS_ADMIN" "$STUDENT_BP" "$SERVER_STUDENT" "$SERVER_ADMIN" "$SERVER_HPC"; do
  if docker inspect "$node" >/dev/null 2>&1; then
    ok "$node exists"
  else
    fail "$node missing"
  fi
done

if run_in "$AUTH_SERVER" "ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=amine.kadri@esi.dz)' dn | grep -q 'uid=amine.kadri@esi.dz'"; then
  ok "OpenLDAP directory contains amine.kadri@esi.dz"
else
  fail "OpenLDAP directory missing amine.kadri@esi.dz"
fi

if run_in "$AUTH_SERVER" "ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=tati.youcef@esi.dz)' dn | grep -q 'uid=tati.youcef@esi.dz'"; then
  ok "OpenLDAP directory contains tati.youcef@esi.dz"
else
  fail "OpenLDAP directory missing tati.youcef@esi.dz"
fi

if run_in "$AUTH_SERVER" "ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(cn=squareone-admins)' memberUid | grep -q 'memberUid: squareone.admin@esi.dz'"; then
  ok "OpenLDAP directory contains SquareOne admin group"
else
  fail "OpenLDAP directory missing SquareOne admin group"
fi

wait_for_tcp "$SERVER_STUDENT" "$AUTH_IP" 49 "student server to TACACS+"
wait_for_tcp "$SERVER_ADMIN" "$AUTH_IP" 49 "admin server to TACACS+"
wait_for_tcp "$SERVER_HPC" "$AUTH_IP" 49 "HPC server to TACACS+"

expect_radius_role "${CAMPUS_BP}" "amine.kadri@esi.dz" "AmineLab#2026" "campus-student" "campus student RADIUS returns student role"
expect_radius_role "${CAMPUS_BP}" "tati.youcef@esi.dz" "TatiLab#2026" "campus-student" "new student RADIUS returns student role"
expect_radius_role "${CAMPUS_BP}" "hamani.nacer@esi.dz" "HamaniTPs#2026" "campus-student" "new professor RADIUS returns student role"
expect_radius_role "${CAMPUS_BP}" "squareone.admin@esi.dz" "SquareOneRoot#2026" "campus-admin" "campus SquareOne admin RADIUS returns admin role"

wait_for_nac_set "${CAMPUS_BP}" "campus_students" "${NAC_STUDENT_IP}" "campus student registered in NAC set"
wait_for_nac_set "${CAMPUS_BP}" "campus_admins" "${NAC_ADMIN_IP}" "campus admin registered in NAC set"
expect_nac_absent "${CAMPUS_BP}" "campus_students" "${NAC_ATTACKER_IP}" "student-bp not registered as campus student"
expect_nac_absent "${CAMPUS_BP}" "campus_admins" "${NAC_ATTACKER_IP}" "student-bp not registered as campus admin"

expect_runtime_rule "$SERVER_STUDENT" "ip saddr 192.168.110.0/24 tcp dport 22" "student server trusts campus subnet behind NAC, not fixed device IPs"
expect_runtime_rule "$SERVER_ADMIN" "ip saddr 192.168.110.0/24 tcp dport 22" "admin server trusts campus subnet behind NAC, not fixed admin IP"
expect_runtime_rule "$SERVER_HPC" "ip saddr 192.168.110.0/24 tcp dport 22" "HPC server trusts campus subnet behind NAC, not fixed device IPs"
expect_runtime_absent "$SERVER_STUDENT" "192.168.110.31" "student server no longer hardcodes campus-student IP"
expect_runtime_absent "$SERVER_HPC" "192.168.110.31" "HPC server no longer hardcodes campus-student IP"
expect_runtime_absent "$SERVER_ADMIN" "192.168.110.32" "admin server no longer hardcodes campus-admin IP"
expect_runtime_rule "$SERVER_STUDENT" "ip saddr 198.51.100.20 tcp dport 22" "student server accepts only VPN gateway NAT source for VPN SSH"
expect_runtime_rule "$SERVER_HPC" "ip saddr 198.51.100.20 tcp dport 22" "HPC server accepts only VPN gateway NAT source for VPN SSH"
expect_runtime_absent "$SERVER_ADMIN" "198.51.100.20" "admin server does not accept VPN gateway SSH source"
expect_runtime_rule "$AUTH_SERVER" "ip saddr { 192.168.110.1, 198.51.100.20 } udp dport 1812" "auth server accepts RADIUS only from NAC gateway and VPN gateway"
expect_runtime_absent "$AUTH_SERVER" "10.200.0.2" "auth server does not trust campus transit /30 as RADIUS client"

if run_in "$CAMPUS_BP" "ip route get ${AUTH_IP} | grep -q 'src ${NAC_GATEWAY_IP}'"; then
  ok "campus-bp uses NAC gateway source for RADIUS"
else
  fail "campus-bp does not source RADIUS from ${NAC_GATEWAY_IP}"
fi

wait_for_tcp "$CAMPUS_STUDENT" "$STUDENT_TARGET" 22 "campus student to student pod SSH"
wait_for_tcp "$CAMPUS_STUDENT" "$HPC_TARGET" 22 "campus student to HPC pod SSH"
wait_for_tcp "$CAMPUS_STUDENT" "$JUPYTER_TARGET" 8080 "campus student to Jupyter frontend after NAC"
expect_tcp_blocked "$CAMPUS_STUDENT" "$ADMIN_TARGET" 22 "campus student to admin pod SSH before auth prompt"

wait_for_tcp "$CAMPUS_ADMIN" "$STUDENT_TARGET" 22 "campus admin to student pod SSH"
wait_for_tcp "$CAMPUS_ADMIN" "$HPC_TARGET" 22 "campus admin to HPC pod SSH"
wait_for_tcp "$CAMPUS_ADMIN" "$JUPYTER_TARGET" 8080 "campus admin to Jupyter frontend after NAC"
wait_for_tcp "$CAMPUS_ADMIN" "$ADMIN_TARGET" 22 "campus admin to admin pod SSH"

expect_tcp_blocked "$STUDENT_BP" "198.18.3.10" 80 "unauthenticated campus device to Internet web"
expect_tcp_blocked "$STUDENT_BP" "198.51.100.10" 80 "unauthenticated campus device to DMZ web"
expect_tcp_blocked "$STUDENT_BP" "$JUPYTER_TARGET" 8080 "unauthenticated campus device to Jupyter frontend"
expect_tcp_blocked "$STUDENT_BP" "$STUDENT_TARGET" 22 "student-bp attacker to student pod SSH"
expect_tcp_blocked "$STUDENT_BP" "$HPC_TARGET" 22 "student-bp attacker to HPC pod SSH"
expect_tcp_blocked "$STUDENT_BP" "$ADMIN_TARGET" 22 "student-bp attacker to admin pod SSH"
expect_tcp_blocked "$STUDENT_BP" "$AUTH_IP" 49 "student-bp attacker to TACACS+"
expect_tcp_blocked "$CAMPUS_STUDENT" "$AUTH_IP" 49 "campus student direct TACACS+ probing"
expect_tcp_blocked "$CAMPUS_STUDENT" "$AUTH_IP" 389 "campus student direct LDAP probing"

expect_ssh_success "student identity can access server-student through TACACS+ authorization" \
  "$CAMPUS_STUDENT" amine.kadri 'AmineLab#2026' "$STUDENT_TARGET" student

expect_ssh_success "student identity can access server-hpc through TACACS+ authorization" \
  "$CAMPUS_STUDENT" amine.kadri 'AmineLab#2026' "$HPC_TARGET" hpc

expect_ssh_denied "student identity cannot access server-admin even if routing changes" \
  "$CAMPUS_ADMIN" amine.kadri 'AmineLab#2026' "$ADMIN_TARGET"

expect_ssh_success "admin identity can access server-student through TACACS+ authorization" \
  "$CAMPUS_ADMIN" squareone.admin 'SquareOneRoot#2026' "$STUDENT_TARGET" student

expect_ssh_success "admin identity can access server-hpc through TACACS+ authorization" \
  "$CAMPUS_ADMIN" squareone.admin 'SquareOneRoot#2026' "$HPC_TARGET" hpc

expect_ssh_success "admin identity can access server-admin through TACACS+ authorization" \
  "$CAMPUS_ADMIN" squareone.admin 'SquareOneRoot#2026' "$ADMIN_TARGET" admin

expect_ssh_denied "wrong password is rejected by LDAP-backed TACACS+" \
  "$CAMPUS_ADMIN" squareone.admin WrongPassword "$HPC_TARGET"

if run_in "$AUTH_SERVER" "tail -n 80 /var/log/esi-tacacs.log 2>/dev/null | grep -q '\"encrypted_body\": true' && ! tail -n 80 /var/log/esi-tacacs.log 2>/dev/null | grep -q '\"encrypted_body\": false'"; then
  ok "TACACS+ exchanges use encrypted packet bodies"
else
  fail "TACACS+ exchanges did not prove encrypted packet bodies"
fi

info "Recent TACACS+ decisions:"
docker exec "$AUTH_SERVER" sh -lc "tail -n 20 /var/log/esi-tacacs.log 2>/dev/null || true"

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi

echo "RESULT: FAIL (${failures} failure(s))"
exit 1
