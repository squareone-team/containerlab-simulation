#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB_NAME}-"
BASTION="${CLAB_PREFIX}bastion-01"
STUDENT="${CLAB_PREFIX}server-student-01"
FTP="${CLAB_PREFIX}ftp-server"
FTP_IP="192.168.80.10"

PASS=0
FAIL=0

ok() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "[FAIL] $1"
  FAIL=$((FAIL + 1))
}

for c in "$BASTION" "$STUDENT" "$FTP"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "Container $c is not running" >&2
    exit 1
  fi
done

echo "=== Ring 5 Verification ==="

echo "[1/2] Negative tests (student -> ftp should be blocked)"
if docker exec "$STUDENT" sh -lc "ping -c2 -W1 ${FTP_IP} >/dev/null 2>&1"; then
  fail "student can ping ftp-server"
else
  ok "student ICMP to ftp-server is blocked"
fi

if docker exec "$STUDENT" sh -lc "nc -z -w2 ${FTP_IP} 21 >/dev/null 2>&1"; then
  fail "student can open TCP/21 to ftp-server"
else
  ok "student TCP/21 to ftp-server is blocked"
fi

echo "[2/2] Positive test (bastion -> ftp SSH should remain allowed)"
if docker exec "$BASTION" sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@${FTP_IP} 'echo ring5-ok'" >/tmp/ring5_ssh_ftp.log 2>&1; then
  ok "bastion can SSH to ftp-server"
else
  fail "bastion cannot SSH to ftp-server"
  cat /tmp/ring5_ssh_ftp.log
fi

echo "Results: $PASS passed / $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
