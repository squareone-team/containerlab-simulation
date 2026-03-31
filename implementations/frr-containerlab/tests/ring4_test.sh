#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB_NAME}-"
BASTION="${CLAB_PREFIX}bastion-01"
LEAF01="${CLAB_PREFIX}leaf-01"
SERVER_ADMIN="${CLAB_PREFIX}server-admin-01"

for c in "${BASTION}" "${LEAF01}" "${SERVER_ADMIN}"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${c}"; then
    echo "Container ${c} is not running" >&2
    exit 1
  fi
done

LEAF01_MGMT_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${LEAF01}")"
if [[ -z "${LEAF01_MGMT_IP}" ]]; then
  echo "Unable to resolve leaf-01 management IP" >&2
  exit 1
fi

echo "[1/2] Verifying bastion-01 passwordless SSH to leaf-01"
if docker exec "${BASTION}" sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@${LEAF01_MGMT_IP} 'echo bastion-ok'" >/dev/null 2>&1; then
  echo "PASS: bastion-01 can SSH to leaf-01 without password"
else
  echo "FAIL: bastion-01 could not SSH to leaf-01 without password" >&2
  exit 1
fi

echo "[2/2] Verifying server-admin-01 is blocked from SSH to leaf-01"
# Install ssh client in server-admin container if needed for the test command.
docker exec "${SERVER_ADMIN}" sh -lc "command -v ssh >/dev/null || apk add --no-cache openssh-client >/dev/null"
if docker exec "${SERVER_ADMIN}" sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@${LEAF01_MGMT_IP} 'echo server-admin-should-not-pass'" >/dev/null 2>&1; then
  echo "FAIL: server-admin-01 unexpectedly reached leaf-01 over SSH" >&2
  exit 1
else
  echo "PASS: server-admin-01 is blocked from SSH to leaf-01"
fi

echo "Ring 4 test completed successfully."
