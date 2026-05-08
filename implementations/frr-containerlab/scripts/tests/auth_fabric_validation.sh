#!/usr/bin/env bash
set -u

LAB="${LAB:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB}"

AUTH_SERVER="${CLAB_PREFIX}-auth-server"
CAMPUS_STUDENT="${CLAB_PREFIX}-campus-student-01"
CAMPUS_ADMIN="${CLAB_PREFIX}-campus-admin-01"
STUDENT_BP="${CLAB_PREFIX}-student-bp-01"
SERVER_STUDENT="${CLAB_PREFIX}-server-student-01"
SERVER_ADMIN="${CLAB_PREFIX}-server-admin-01"
SERVER_HPC="${CLAB_PREFIX}-server-hpc-01"

STUDENT_TARGET="192.168.10.10"
ADMIN_TARGET="192.168.50.10"
HPC_TARGET="192.168.70.10"
AUTH_IP="192.168.50.80"

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

expect_tcp_blocked() {
  local node="$1" ip="$2" port="$3" label="$4"
  if run_in "$node" "timeout 4 nc -z -w2 ${ip} ${port}" >/dev/null 2>&1; then
    fail "$label unexpectedly reachable at ${ip}:${port}"
  else
    ok "$label blocked at ${ip}:${port}"
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

for node in "$AUTH_SERVER" "$CAMPUS_STUDENT" "$CAMPUS_ADMIN" "$STUDENT_BP" "$SERVER_STUDENT" "$SERVER_ADMIN" "$SERVER_HPC"; do
  if docker inspect "$node" >/dev/null 2>&1; then
    ok "$node exists"
  else
    fail "$node missing"
  fi
done

if run_in "$AUTH_SERVER" "ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=student1)' dn | grep -q 'uid=student1'"; then
  ok "OpenLDAP directory contains student1"
else
  fail "OpenLDAP directory missing student1"
fi

if run_in "$AUTH_SERVER" "ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(cn=admins)' memberUid | grep -q 'memberUid: admin1'"; then
  ok "OpenLDAP directory contains admins group"
else
  fail "OpenLDAP directory missing admins group"
fi

wait_for_tcp "$SERVER_STUDENT" "$AUTH_IP" 49 "student server to TACACS+"
wait_for_tcp "$SERVER_ADMIN" "$AUTH_IP" 49 "admin server to TACACS+"
wait_for_tcp "$SERVER_HPC" "$AUTH_IP" 49 "HPC server to TACACS+"

wait_for_tcp "$CAMPUS_STUDENT" "$STUDENT_TARGET" 22 "campus student to student pod SSH"
wait_for_tcp "$CAMPUS_STUDENT" "$HPC_TARGET" 22 "campus student to HPC pod SSH"
expect_tcp_blocked "$CAMPUS_STUDENT" "$ADMIN_TARGET" 22 "campus student to admin pod SSH before auth prompt"

wait_for_tcp "$CAMPUS_ADMIN" "$STUDENT_TARGET" 22 "campus admin to student pod SSH"
wait_for_tcp "$CAMPUS_ADMIN" "$HPC_TARGET" 22 "campus admin to HPC pod SSH"
wait_for_tcp "$CAMPUS_ADMIN" "$ADMIN_TARGET" 22 "campus admin to admin pod SSH"

expect_tcp_blocked "$STUDENT_BP" "$STUDENT_TARGET" 22 "student-bp attacker to student pod SSH"
expect_tcp_blocked "$STUDENT_BP" "$HPC_TARGET" 22 "student-bp attacker to HPC pod SSH"
expect_tcp_blocked "$STUDENT_BP" "$ADMIN_TARGET" 22 "student-bp attacker to admin pod SSH"
expect_tcp_blocked "$STUDENT_BP" "$AUTH_IP" 49 "student-bp attacker to TACACS+"
expect_tcp_blocked "$CAMPUS_STUDENT" "$AUTH_IP" 49 "campus student direct TACACS+ probing"
expect_tcp_blocked "$CAMPUS_STUDENT" "$AUTH_IP" 389 "campus student direct LDAP probing"

expect_ssh_success "student identity can access server-student through TACACS+ authorization" \
  "$CAMPUS_STUDENT" student1 Student@2026 "$STUDENT_TARGET" student

expect_ssh_success "student identity can access server-hpc through TACACS+ authorization" \
  "$CAMPUS_STUDENT" student1 Student@2026 "$HPC_TARGET" hpc

expect_ssh_denied "student identity cannot access server-admin even if routing changes" \
  "$CAMPUS_ADMIN" student1 Student@2026 "$ADMIN_TARGET"

expect_ssh_success "admin identity can access server-student through TACACS+ authorization" \
  "$CAMPUS_ADMIN" admin1 Admin@2026 "$STUDENT_TARGET" student

expect_ssh_success "admin identity can access server-hpc through TACACS+ authorization" \
  "$CAMPUS_ADMIN" admin1 Admin@2026 "$HPC_TARGET" hpc

expect_ssh_success "admin identity can access server-admin through TACACS+ authorization" \
  "$CAMPUS_ADMIN" admin1 Admin@2026 "$ADMIN_TARGET" admin

expect_ssh_denied "wrong password is rejected by LDAP-backed TACACS+" \
  "$CAMPUS_ADMIN" admin1 WrongPassword "$HPC_TARGET"

info "Recent TACACS+ decisions:"
docker exec "$AUTH_SERVER" sh -lc "tail -n 20 /var/log/esi-tacacs.log 2>/dev/null || true"

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi

echo "RESULT: FAIL (${failures} failure(s))"
exit 1
