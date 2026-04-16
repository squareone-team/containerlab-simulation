#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB_NAME}-"
LEAF="${CLAB_PREFIX}leaf-01"
SYSLOG="${CLAB_PREFIX}syslog-server"
TOKEN="RING6_VERIFICATION_TEST"

if ! docker ps --format '{{.Names}}' | grep -qx "$LEAF"; then
  echo "Container $LEAF is not running" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$SYSLOG"; then
  echo "Container $SYSLOG is not running" >&2
  exit 1
fi

echo "=== Ring 6 Verification ==="
echo "[1/2] Injecting test log from $LEAF"
docker exec "$LEAF" sh -lc "logger '$TOKEN'"

echo "[2/2] Waiting for $SYSLOG to persist the log"
for _ in $(seq 1 30); do
  if docker exec "$SYSLOG" sh -lc "grep -q '$TOKEN' /var/log/messages" 2>/dev/null; then
    echo "[PASS] $SYSLOG captured $TOKEN in /var/log/messages"
    exit 0
  fi
  if docker exec "$SYSLOG" sh -lc "grep -q '$TOKEN' /var/log/syslog" 2>/dev/null; then
    echo "[PASS] $SYSLOG captured $TOKEN in /var/log/syslog"
    exit 0
  fi
  sleep 1
done

echo "[FAIL] $SYSLOG did not capture $TOKEN" >&2

docker exec "$SYSLOG" sh -lc "tail -n 20 /var/log/messages 2>/dev/null || tail -n 20 /var/log/syslog 2>/dev/null || true" >&2
exit 1
