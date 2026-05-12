#!/usr/bin/env bash
set -Eeuo pipefail

TOPOLOGY="${TOPOLOGY:-arista-ansible.clab.yml}"
LAB_NAME="${LAB_NAME:-esi-datacenter}"
ANSIBLE_CONTAINER="clab-${LAB_NAME}-ansible"

FABRIC_NODES=(
  spine-01 spine-02
  leaf-01 leaf-02 leaf-03 leaf-04 leaf-05
  leaf-06 leaf-07 leaf-08 leaf-09 leaf-10
)

MGMT_IPS=(
  172.20.20.11 172.20.20.12
  172.20.20.21 172.20.20.22 172.20.20.23 172.20.20.24 172.20.20.25
  172.20.20.26 172.20.20.27 172.20.20.28 172.20.20.29 172.20.20.30
)

log() {
  printf '\n==> %s\n' "$*"
}

run() {
  log "$*"
  "$@"
}

run_in_ansible() {
  docker exec "$ANSIBLE_CONTAINER" sh -lc "$*"
}

wait_for_container() {
  local name="$1"
  local deadline=$((SECONDS + 240))

  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == "true" ]]; then
      return 0
    fi
    sleep 2
  done

  docker ps -a --format '{{.Names}} {{.Status}}' | grep "clab-${LAB_NAME}-" || true
  printf 'Container %s did not reach running state\n' "$name" >&2
  return 1
}

wait_for_ssh() {
  local ip="$1"
  local deadline=$((SECONDS + 600))

  while (( SECONDS < deadline )); do
    if run_in_ansible "nc -z -w 2 '$ip' 22 >/dev/null 2>&1"; then
      return 0
    fi
    sleep 5
  done

  printf 'EOS SSH did not become reachable at %s\n' "$ip" >&2
  return 1
}

main() {
  if [[ "${REDEPLOY:-0}" == "1" ]]; then
    run containerlab destroy -t "$TOPOLOGY" --cleanup
    run containerlab deploy -t "$TOPOLOGY"
  elif [[ "$(docker inspect -f '{{.State.Running}}' "$ANSIBLE_CONTAINER" 2>/dev/null || true)" == "true" ]]; then
    log "Existing lab containers detected; skipping containerlab deploy"
  else
    run containerlab deploy -t "$TOPOLOGY"
  fi

  log "Checking fabric and Ansible containers are running"
  for node in "${FABRIC_NODES[@]}" ansible; do
    wait_for_container "clab-${LAB_NAME}-${node}"
  done

  log "Installing/checking Ansible dependencies inside ${ANSIBLE_CONTAINER}"
  run_in_ansible "cd /ansible && ansible-galaxy collection install -r requirements.yml -p /ansible/collections"
  run_in_ansible "python3 -c 'import netaddr' >/dev/null 2>&1 || pip3 install netaddr"
  run_in_ansible "python3 -c 'import ansible_pylibssh' >/dev/null 2>&1 || apk add --no-cache gcc musl-dev python3-dev libffi-dev openssl-dev libssh-dev"
  run_in_ansible "python3 -c 'import ansible_pylibssh' >/dev/null 2>&1 || pip3 install ansible-pylibssh"

  log "Waiting for EOS management SSH on all spines/leaves"
  for ip in "${MGMT_IPS[@]}"; do
    wait_for_ssh "$ip"
  done

  log "Running fabric syntax checks"
  run_in_ansible "cd /ansible && ansible-playbook --syntax-check playbooks/fabric-common.yml"
  run_in_ansible "cd /ansible && ansible-playbook --syntax-check playbooks/fabric-underlay.yml"
  run_in_ansible "cd /ansible && ansible-playbook --syntax-check playbooks/fabric-overlay.yml"
  run_in_ansible "cd /ansible && ansible-playbook --syntax-check playbooks/strict-fabric-validate.yml"

  log "Deploying spine-leaf fabric automation"
  run_in_ansible "cd /ansible && ansible-playbook playbooks/fabric-common.yml"
  run_in_ansible "cd /ansible && ansible-playbook playbooks/fabric-underlay.yml"
  run_in_ansible "cd /ansible && ansible-playbook playbooks/fabric-overlay.yml"

  log "Running strict fabric convergence checks"
  run_in_ansible "cd /ansible && ansible-playbook playbooks/strict-fabric-validate.yml"
}

main "$@"
