#!/bin/bash
# ==============================================================================
# scripts/tests/verify-naas-advanced.sh
# ==============================================================================
# Advanced Verification script for Notebook-as-a-Service deployment
# Performs functional testing of:
#   - Database connectivity and schema
#   - SLURM Controller and Accounting DB (sinfo, sacctmgr)
#   - User-owned srun/sbatch submissions through the cpu partition
#   - JupyterHub login page and SLURM-backed notebook spawning
#   - Distributed NFS read/write functionality and notebook persistence
#
# Usage: bash scripts/tests/verify-naas-advanced.sh
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ADMIN_POD="clab-esi-datacenter-server-admin-01"
HPC_01="clab-esi-datacenter-server-hpc-01"
HPC_02="clab-esi-datacenter-server-hpc-02"
HPC_JUPYTER="clab-esi-datacenter-server-hpc-jupyter"
STORAGE="clab-esi-datacenter-server-storage-01"

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE="$(mktemp)"
NOTEBOOK_PAYLOAD="$(mktemp)"
NOTEBOOK_RESPONSE="$(mktemp)"
SPAWNED_SERVER=false
JH_TOKEN=""
NOTEBOOK_NAME="naas-slurm-verification.ipynb"

cleanup() {
	if [ "$SPAWNED_SERVER" = true ] && [ -n "$JH_TOKEN" ]; then
		curl -k -sS -o /dev/null -X DELETE \
			-H "Authorization: token $JH_TOKEN" \
			"https://localhost:18880/hub/api/users/student-01/server" || true
	fi
	rm -f "$COOKIE_JAR" "$LOGIN_PAGE" "$NOTEBOOK_PAYLOAD" "$NOTEBOOK_RESPONSE"
}
trap cleanup EXIT

docker_mountpoint() {
	local node="$1"
	local mount_path="$2"

	docker exec "$node" sh -c "mountpoint -q '$mount_path'"
}

wait_for_jupyter_server_ready() {
	local retries=60
	local body

	while [ "$retries" -gt 0 ]; do
		body="$(curl -k -sS -H "Authorization: token $JH_TOKEN" \
			"https://localhost:18880/hub/api/users/student-01" || true)"
		if printf '%s' "$body" | grep -Eq '"ready"[[:space:]]*:[[:space:]]*true'; then
			return 0
		fi
		sleep 2
		retries=$((retries - 1))
	done

	return 1
}

stop_student_server_if_running() {
	local code

	code="$(curl -k -sS -o /dev/null -w "%{http_code}" -X DELETE \
		-H "Authorization: token $JH_TOKEN" \
		"https://localhost:18880/hub/api/users/student-01/server" || true)"

	case "$code" in
		202|204|404)
			;;
		*)
			log_fail "Unexpected status while stopping existing student-01 server: $code"
			;;
	esac

	for _ in $(seq 1 30); do
		if curl -k -sS -H "Authorization: token $JH_TOKEN" \
			"https://localhost:18880/hub/api/users/student-01" | grep -Eq '"server"[[:space:]]*:[[:space:]]*null'; then
			return 0
		fi
		sleep 1
	done

	return 1
}

# ==============================================================================
# 1. Database & Accounting Verification
# ==============================================================================
log_info "=== 1. DATABASE & ACCOUNTING ==="

if docker exec "$ADMIN_POD" sh -c 'mysql -u jupyterhub -pjupyterhub_pass -h localhost -e "SELECT 1" jupyterhub 2>/dev/null' | grep -q 1; then
	log_pass "JupyterHub database is accessible with credentials"
else
	log_fail "Failed to connect to JupyterHub database"
fi

if docker exec "$ADMIN_POD" sh -c 'mysql -u slurm -pslurm_pass -h localhost -e "SELECT 1" slurm_acct_db 2>/dev/null' | grep -q 1; then
	log_pass "SLURM accounting database is accessible with credentials"
else
	log_fail "Failed to connect to SLURM accounting database"
fi

if docker exec "$ADMIN_POD" sh -c 'sacctmgr show cluster -p 2>/dev/null' | grep -q "esi-hpc"; then
	log_pass "SLURM Database Daemon (slurmdbd) is responding and cluster is registered"
else
	log_fail "SLURM Database Daemon is not responding or cluster not found"
fi

# ==============================================================================
# 2. SLURM Controller Verification
# ==============================================================================
log_info "=== 2. SLURM CONTROLLER ==="

if docker exec "$ADMIN_POD" sh -c 'sinfo -h -o "%R"' | grep -q "cpu"; then
	log_pass "SLURM Controller is active and 'cpu' partition exists"
else
	log_fail "SLURM Controller is down or partition missing"
fi

# Wait for nodes to be IDLE instead of UNKNOWN
MAX_RETRIES=5
RETRY=0
NODES_UP=false
while [ $RETRY -lt $MAX_RETRIES ]; do
	if docker exec "$ADMIN_POD" sh -c 'sinfo -h -o "%T"' | grep -v "unk" | grep -q "idle"; then
		NODES_UP=true
		break
	fi
	log_info "Waiting for SLURM nodes to become idle (Attempt $((RETRY+1))/$MAX_RETRIES)..."
	sleep 5
	RETRY=$((RETRY+1))
done

if [ "$NODES_UP" = true ]; then
	log_pass "SLURM worker nodes are registered and idle"
else
	log_warn "SLURM worker nodes are not yet idle (could still be initializing)"
fi

# ==============================================================================
# 3. Job Submission Test (Compute)
# ==============================================================================
log_info "=== 3. COMPUTE & JOB SUBMISSION ==="

# Submit test jobs as the real notebook user from the Admin pod.
if docker exec "$ADMIN_POD" sh -c 'su - student-01 -c "srun -N 1 -p cpu echo SLURM_SRUN_STUDENT_SUCCESS"' | grep -q "SLURM_SRUN_STUDENT_SUCCESS"; then
	log_pass "student-01 successfully executed a job via srun"
else
	log_fail "student-01 failed to execute test job via srun"
fi

if docker exec "$ADMIN_POD" sh -c 'printf "%s\n" "#!/bin/sh" "echo SLURM_SBATCH_STUDENT_SUCCESS" > /tmp/naas-sbatch-test.sh && chown student-01:student-01 /tmp/naas-sbatch-test.sh && su - student-01 -c "sbatch -p cpu --wait --output=/home/student-01/naas-sbatch-test.out /tmp/naas-sbatch-test.sh" >/tmp/naas-sbatch-submit.out && cat /home/student-01/naas-sbatch-test.out' | grep -q "SLURM_SBATCH_STUDENT_SUCCESS"; then
	log_pass "student-01 successfully submitted and completed a job via sbatch"
	docker exec "$ADMIN_POD" sh -c 'rm -f /tmp/naas-sbatch-test.sh /tmp/naas-sbatch-submit.out /home/student-01/naas-sbatch-test.out' 2>/dev/null || true
else
	log_fail "student-01 failed to submit or complete test job via sbatch"
fi

# ==============================================================================
# 4. Distributed Storage Test (NFS)
# ==============================================================================
log_info "=== 4. DISTRIBUTED STORAGE ==="

TEST_FILE="/home/student-01/test_nfs_sync.txt"

for node in "$ADMIN_POD" "$HPC_01" "$HPC_02"; do
	for mount_path in /home /shared; do
		if docker_mountpoint "$node" "$mount_path"; then
			log_pass "$node has $mount_path mounted from NFS"
		else
			log_fail "$node does not have $mount_path mounted from NFS"
		fi
	done
done

if docker exec "$ADMIN_POD" sh -c 'su - student-01 -c "test -r /etc/slurm/slurm.conf && squeue -h >/dev/null"'; then
	log_pass "student-01 can read slurm.conf and run squeue as a normal user"
else
	log_fail "student-01 cannot read slurm.conf or run squeue"
fi

# Write as student-01 from HPC-01 so UID/GID preservation is tested.
docker exec "$HPC_01" sh -c "su - student-01 -c \"echo hello_from_hpc01 > $TEST_FILE\"" || log_fail "Could not write to NFS from HPC-01 as student-01"

# Read from HPC-02
if docker exec "$HPC_02" sh -c "cat $TEST_FILE" 2>/dev/null | grep -q "hello_from_hpc01"; then
	log_pass "NFS distributed read/write successful between HPC-01 and HPC-02"
else
	log_fail "HPC-02 failed to read file written by HPC-01 on NFS"
fi

if docker exec "$STORAGE" sh -c "stat -c '%u:%g' $TEST_FILE" | grep -q '^3001:3001$'; then
	log_pass "NFS preserves student-01 UID/GID on storage-backed files"
else
	log_fail "NFS did not preserve student-01 UID/GID on storage-backed files"
fi

# Cleanup
docker exec "$HPC_01" sh -c "su - student-01 -c \"rm -f $TEST_FILE\"" 2>/dev/null || true

# ==============================================================================
# 5. JupyterHub Frontend & Backend
# ==============================================================================
log_info "=== 5. JUPYTERHUB SERVICE ==="

# Check JupyterHub internal API on admin pod
if docker exec "$ADMIN_POD" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://192.168.50.10:8081/hub/api || echo "fail"' | grep -q "401\|403\|200\|404\|302"; then
	log_pass "JupyterHub API is responding on Admin Pod"
else
	log_fail "JupyterHub API is not responding"
fi

# Check JupyterHub external TLS frontend proxy
if docker exec "$HPC_JUPYTER" sh -c 'curl -k -s -o /dev/null -w "%{http_code}" https://localhost:8080/hub/login' | grep -q "200"; then
	log_pass "JupyterHub frontend proxy is serving TLS login page"
else
	log_fail "JupyterHub frontend proxy failed to serve login page"
fi

if curl -k -sS -o "$LOGIN_PAGE" -w "%{http_code}" -c "$COOKIE_JAR" https://localhost:18880/hub/login | grep -q "200" \
	&& grep -qi "jupyterhub" "$LOGIN_PAGE"; then
	log_pass "Host access login page works at https://localhost:18880/"
else
	log_fail "Host access login page failed at https://localhost:18880/"
fi

if docker exec "$ADMIN_POD" sh -c "grep -q \"batchspawner.SlurmSpawner\" /etc/jupyterhub/jupyterhub_config.py && ! grep -q \"LocalProcessSpawner\" /etc/jupyterhub/jupyterhub_config.py"; then
	log_pass "JupyterHub is configured for BatchSpawner SlurmSpawner, not LocalProcessSpawner"
else
	log_fail "JupyterHub config is not using the SLURM-backed spawner"
fi

JH_TOKEN="$(docker exec "$ADMIN_POD" sh -c 'jupyterhub token student-01 --config /etc/jupyterhub/jupyterhub_config.py 2>/dev/null' | tail -n 1 | tr -d '\r')"
if [ -n "$JH_TOKEN" ]; then
	log_pass "Generated JupyterHub API token for student-01"
else
	log_fail "Could not generate JupyterHub API token for student-01"
fi

if stop_student_server_if_running; then
	log_pass "student-01 has no pre-existing notebook server"
else
	log_fail "Could not stop pre-existing student-01 notebook server"
fi

SPAWN_CODE="$(curl -k -sS -o "$NOTEBOOK_RESPONSE" -w "%{http_code}" -X POST \
	-H "Authorization: token $JH_TOKEN" \
	-H "Content-Type: application/json" \
	-d '{"profile":"cpu"}' \
	"https://localhost:18880/hub/api/users/student-01/server")"

case "$SPAWN_CODE" in
	201|202)
		SPAWNED_SERVER=true
		log_pass "JupyterHub accepted a student-01 notebook spawn request"
		;;
	*)
		log_fail "JupyterHub spawn request failed with HTTP $SPAWN_CODE"
		;;
esac

if wait_for_jupyter_server_ready; then
	log_pass "JupyterHub-spawned student-01 notebook server became ready"
else
	log_fail "JupyterHub-spawned notebook server did not become ready"
fi

if docker exec "$ADMIN_POD" sh -c 'squeue -h -u student-01 -o "%j %P %T" | grep -E "jupyter|spawner" | grep -q "cpu"'; then
	log_pass "JupyterHub-spawned notebook server is running as a SLURM job on the cpu partition"
else
	log_fail "No active SLURM notebook job found for student-01"
fi

cat > "$NOTEBOOK_PAYLOAD" <<'JSON'
{
  "type": "notebook",
  "format": "json",
  "content": {
    "cells": [
      {
        "cell_type": "markdown",
        "metadata": {},
        "source": [
          "NaaS SLURM verification\n"
        ]
      }
    ],
    "metadata": {},
    "nbformat": 4,
    "nbformat_minor": 5
  }
}
JSON

NOTEBOOK_CODE="$(curl -k -sS -o "$NOTEBOOK_RESPONSE" -w "%{http_code}" -X PUT \
	-H "Authorization: token $JH_TOKEN" \
	-H "Content-Type: application/json" \
	--data-binary "@$NOTEBOOK_PAYLOAD" \
	"https://localhost:18880/user/student-01/api/contents/$NOTEBOOK_NAME")"

case "$NOTEBOOK_CODE" in
	200|201)
		log_pass "Created notebook through the Jupyter server API"
		;;
	*)
		log_fail "Failed to create notebook through Jupyter server API (HTTP $NOTEBOOK_CODE)"
		;;
esac

if docker exec "$STORAGE" sh -c "test -f /home/student-01/$NOTEBOOK_NAME && stat -c '%u:%g' /home/student-01/$NOTEBOOK_NAME" | grep -q '^3001:3001$'; then
	log_pass "Notebook file landed on storage-backed /home/student-01 with student UID/GID"
else
	log_fail "Notebook file was not found on storage-backed /home/student-01 with student UID/GID"
fi

curl -k -sS -o /dev/null -X DELETE \
	-H "Authorization: token $JH_TOKEN" \
	"https://localhost:18880/user/student-01/api/contents/$NOTEBOOK_NAME" || true

# ==============================================================================
# Summary
# ==============================================================================

log_info "=== ADVANCED VERIFICATION COMPLETE ==="
log_pass "All advanced functional tests passed!"
log_info "To access JupyterHub from your host, navigate to:"
log_info "  https://localhost:18880/"
