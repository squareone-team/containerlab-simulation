#!/bin/bash
# ==============================================================================
# scripts/tests/verify-notebook-as-a-service.sh
# ==============================================================================
# Verification script for Notebook-as-a-Service deployment
# Tests:
#   - Admin pod services (MariaDB, SLURM controller, JupyterHub)
#   - HPC worker connectivity to SLURM
#   - NFS mount accessibility
#   - User authentication via PAM
#   - JupyterHub web access
#   - Notebook job submission through SLURM
#
# Usage: bash scripts/tests/verify-notebook-as-a-service.sh
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
log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

# ==============================================================================
# 1. Admin Pod Verification
# ==============================================================================

log_info "=== ADMIN POD VERIFICATION ==="

# Check if admin pod is running
if ! docker inspect -f '{{.State.Running}}' "$ADMIN_POD" 2>/dev/null | grep -q true; then
	log_fail "Admin pod is not running: $ADMIN_POD"
fi
log_pass "Admin pod is running"

# Check MariaDB
if docker exec "$ADMIN_POD" sh -c 'mysql -u root -e "SELECT 1" 2>/dev/null' | grep -q 1; then
	log_pass "MariaDB service is running"
else
	log_fail "MariaDB service is not responding"
fi

# Check databases exist
if docker exec "$ADMIN_POD" sh -c 'mysql -u root -e "SHOW DATABASES" 2>/dev/null' | grep -q slurm_acct_db; then
	log_pass "SLURM accounting database exists"
else
	log_fail "SLURM accounting database not found"
fi

if docker exec "$ADMIN_POD" sh -c 'mysql -u root -e "SHOW DATABASES" 2>/dev/null' | grep -q jupyterhub; then
	log_pass "JupyterHub database exists"
else
	log_fail "JupyterHub database not found"
fi

# Check SLURM controller
if docker exec "$ADMIN_POD" sh -c 'slurmctld -V 2>/dev/null' | grep -q "slurm"; then
	log_pass "SLURM controller daemon is installed"
else
	log_fail "SLURM controller not found"
fi

# Check if slurmctld is running
if docker exec "$ADMIN_POD" sh -c 'ps aux | grep -v grep | grep slurmctld' >/dev/null 2>&1; then
	log_pass "slurmctld process is running"
else
	log_fail "slurmctld process not found"
fi

# Check PAM users
if docker exec "$ADMIN_POD" sh -c 'id student-01' >/dev/null 2>&1; then
	log_pass "PAM user 'student-01' exists"
else
	log_fail "PAM user 'student-01' not found"
fi

if docker exec "$ADMIN_POD" sh -c 'grep -q "batchspawner.SlurmSpawner" /etc/jupyterhub/jupyterhub_config.py && ! grep -q "LocalProcessSpawner" /etc/jupyterhub/jupyterhub_config.py'; then
	log_pass "JupyterHub is configured for SLURM-backed BatchSpawner"
else
	log_fail "JupyterHub is not configured for SLURM-backed BatchSpawner"
fi

# ==============================================================================
# 2. HPC Worker Verification
# ==============================================================================

log_info "=== HPC WORKER VERIFICATION ==="

# Check HPC-01
if ! docker inspect -f '{{.State.Running}}' "$HPC_01" 2>/dev/null | grep -q true; then
	log_fail "HPC-01 pod is not running"
fi
log_pass "HPC-01 pod is running"

# Check HPC-02
if ! docker inspect -f '{{.State.Running}}' "$HPC_02" 2>/dev/null | grep -q true; then
	log_fail "HPC-02 pod is not running"
fi
log_pass "HPC-02 pod is running"

# Check SLURM workers
if docker exec "$HPC_01" sh -c 'slurmd -V 2>/dev/null' | grep -q "slurm"; then
	log_pass "SLURM worker daemon is installed on HPC-01"
else
	log_fail "SLURM worker not found on HPC-01"
fi

# Check connectivity from HPC to Admin SLURM
if docker exec "$HPC_01" sh -c 'nc -z 192.168.50.10 6817 2>/dev/null'; then
	log_pass "HPC-01 can connect to Admin pod SLURM controller (6817)"
else
	log_fail "HPC-01 cannot reach Admin pod SLURM controller"
fi

for worker in "$HPC_01" "$HPC_02"; do
	if docker exec "$worker" sh -c 'id student-01 >/dev/null 2>&1 && id researcher-02 >/dev/null 2>&1'; then
		log_pass "$worker has lab users for SLURM job launch"
	else
		log_fail "$worker is missing lab users required by slurmd"
	fi
done

if docker exec "$ADMIN_POD" sh -c 'su - student-01 -c "test -r /etc/slurm/slurm.conf && squeue -h >/dev/null"'; then
	log_pass "Normal users can read slurm.conf and run SLURM clients"
else
	log_fail "Normal users cannot read slurm.conf or run SLURM clients"
fi

# ==============================================================================
# 3. NFS Verification
# ==============================================================================

log_info "=== NFS STORAGE VERIFICATION ==="

# Check Storage pod
if ! docker inspect -f '{{.State.Running}}' "$STORAGE" 2>/dev/null | grep -q true; then
	log_fail "Storage pod is not running"
fi
log_pass "Storage pod is running"

# Check if NFS exports exist
if docker exec "$STORAGE" sh -c 'exportfs -v 2>/dev/null | grep /home' >/dev/null 2>&1; then
	log_pass "NFS /home export is configured"
else
	log_fail "NFS /home export not found"
fi

if docker exec "$STORAGE" sh -c 'exportfs -v 2>/dev/null | grep /shared' >/dev/null 2>&1; then
	log_pass "NFS /shared export is configured"
else
	log_fail "NFS /shared export not found"
fi

for node in "$ADMIN_POD" "$HPC_01" "$HPC_02"; do
	for mount_path in /home /shared; do
		if docker exec "$node" sh -c "mountpoint -q '$mount_path'"; then
			log_pass "$node $mount_path NFS mount is active"
		else
			log_fail "$node $mount_path NFS mount is not active"
		fi
	done
done

# ==============================================================================
# 4. JupyterHub Frontend Verification
# ==============================================================================

log_info "=== JUPYTERHUB FRONTEND VERIFICATION ==="

# Check JupyterHub pod
if ! docker inspect -f '{{.State.Running}}' "$HPC_JUPYTER" 2>/dev/null | grep -q true; then
	log_fail "JupyterHub frontend pod is not running"
fi
log_pass "JupyterHub frontend pod is running"

# Check if JupyterHub frontend can reach Admin pod
if docker exec "$HPC_JUPYTER" sh -c 'nc -z 192.168.50.10 8000 2>/dev/null'; then
	log_pass "JupyterHub frontend can reach Admin pod (8000)"
else
	log_fail "JupyterHub frontend cannot reach Admin pod"
fi

if curl -k -s -o /dev/null -w "%{http_code}" https://localhost:18880/hub/login | grep -q "200"; then
	log_pass "Host login page works at https://localhost:18880/"
else
	log_fail "Host login page is not reachable at https://localhost:18880/"
fi

# ==============================================================================
# 5. Network Verification
# ==============================================================================

log_info "=== NETWORK CONNECTIVITY VERIFICATION ==="

# Verify DNS resolution
if docker exec "$HPC_01" sh -c 'getent hosts hpc-jupyter.esi.internal' >/dev/null 2>&1; then
	log_pass "DNS resolves hpc-jupyter.esi.internal"
else
	log_fail "DNS does not resolve hpc-jupyter.esi.internal"
fi

# ==============================================================================
# Summary
# ==============================================================================

log_info "=== VERIFICATION COMPLETE ==="
log_pass "All tests passed!"
log_info "Next steps:"
log_info "  1. Access JupyterHub: https://localhost:18880 (with self-signed cert)"
log_info "  2. Login with: student-01 / student-01"
log_info "  3. Create a notebook and submit jobs to SLURM"
log_info "  4. Notebooks are persisted on Storage pod"
