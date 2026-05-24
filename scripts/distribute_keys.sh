#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="${LAB_NAME:-esi-datacenter}"
CLAB_PREFIX="clab-${LAB_NAME}-"
BASTION_CONTAINER="${CLAB_PREFIX}bastion-01"

TARGETS=(
  spine-01 spine-02
  leaf-01 leaf-02 leaf-03 leaf-04 leaf-05 leaf-06 leaf-07 leaf-08 leaf-09 leaf-10
  server-student-01 server-student-02
  server-admin-01 server-admin-02
  server-hpc-01 server-hpc-02
  server-storage-01 public-web-server
  lms-staff services-web
)

if ! docker ps --format '{{.Names}}' | grep -qx "${BASTION_CONTAINER}"; then
  echo "Bastion container ${BASTION_CONTAINER} is not running. Start the lab first." >&2
  exit 1
fi

PUBKEY="$(docker exec "${BASTION_CONTAINER}" cat /root/.ssh/id_ed25519.pub)"
if [[ -z "${PUBKEY}" ]]; then
  echo "Bastion public key is empty. Ensure bastion startup generated keys." >&2
  exit 1
fi

for node in "${TARGETS[@]}"; do
  container="${CLAB_PREFIX}${node}"
  if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
    echo "Skipping ${node}: container not running"
    continue
  fi

  docker exec "${container}" sh -lc 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'
  docker exec "${container}" sh -lc "grep -qxF '${PUBKEY}' /root/.ssh/authorized_keys || echo '${PUBKEY}' >> /root/.ssh/authorized_keys"
  echo "Key installed on ${node}"
done

echo "Key distribution complete."
