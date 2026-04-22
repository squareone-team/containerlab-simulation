#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB_NAME}-"
BASTION="${CLAB_PREFIX}bastion-01"

NODES=(
  "spine-01:172.16.0.11"
  "spine-02:172.16.0.12"
  "leaf-01:172.16.0.21"
  "leaf-02:172.16.0.22"
  "leaf-03:172.16.0.23"
  "leaf-04:172.16.0.24"
  "leaf-05:172.16.0.25"
  "leaf-06:172.16.0.26"
  "leaf-07:172.16.0.27"
  "leaf-08:172.16.0.28"
  "leaf-09:172.16.0.29"
  "leaf-10:172.16.0.30"
)

if ! docker ps --format '{{.Names}}' | grep -qx "${BASTION}"; then
  echo "Container ${BASTION} is not running" >&2
  exit 1
fi

echo "[1/3] Validating all target containers are running"
for entry in "${NODES[@]}"; do
  node="${entry%%:*}"
  container="${CLAB_PREFIX}${node}"
  if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
    echo "FAIL: missing running container ${container}" >&2
    exit 1
  fi
  echo "PASS: ${container} is running"
done

echo "[2/3] Installing bastion public key on all leaf/spine nodes"
PUBKEY="$(docker exec "${BASTION}" sh -lc 'cat /root/.ssh/id_ed25519.pub')"
if [[ -z "${PUBKEY}" ]]; then
  echo "FAIL: bastion public key missing" >&2
  exit 1
fi

for entry in "${NODES[@]}"; do
  node="${entry%%:*}"
  container="${CLAB_PREFIX}${node}"
  docker exec "${container}" sh -lc "mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && grep -qxF '${PUBKEY}' /root/.ssh/authorized_keys || echo '${PUBKEY}' >> /root/.ssh/authorized_keys"
  echo "PASS: key present on ${node}"
done

echo "[3/3] Verifying bastion passwordless SSH to all leaf/spine OOB IPs"
failures=0
for entry in "${NODES[@]}"; do
  node="${entry%%:*}"
  ip="${entry##*:}"
  if docker exec "${BASTION}" sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@${ip} 'hostname'" >/tmp/ring4_ssh_${node}.log 2>&1; then
    echo "PASS: bastion -> ${node} (${ip})"
  else
    echo "FAIL: bastion cannot ssh ${node} (${ip})"
    cat /tmp/ring4_ssh_${node}.log
    failures=$((failures + 1))
  fi
done

if [[ "${failures}" -ne 0 ]]; then
  echo "Ring 4 test completed with ${failures} failure(s)" >&2
  exit 1
fi

echo "Ring 4 test completed successfully."
