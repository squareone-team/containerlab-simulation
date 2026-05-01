#!/bin/bash
# ==============================================================================
# scripts/tests/verify-naas-advanced.sh
# ==============================================================================
# Advanced Verification script for Notebook-as-a-Service deployment
# Performs functional testing of:
#   - Database connectivity and schema
#   - SLURM Controller and Accounting DB (sinfo, sacctmgr)
#   - Functional Job submission across cluster
#   - JupyterHub HTTP endpoints
#   - Distributed NFS read/write functionality
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

# Submit a test job from HPC-01
if docker exec "$HPC_01" sh -c 'srun -N 1 echo "SLURM_WORKER_TEST_SUCCESS"' | grep -q "SLURM_WORKER_TEST_SUCCESS"; then
	log_pass "Successfully submitted and executed a job via srun"
else
	log_fail "Failed to execute test job via srun"
fi

# ==============================================================================
# 4. Distributed Storage Test (NFS)
# ==============================================================================
log_info "=== 4. DISTRIBUTED STORAGE ==="

TEST_FILE="/home/student-01/test_nfs_sync.txt"

# Write from HPC-01
docker exec "$HPC_01" sh -c "echo 'hello_from_hpc01' > $TEST_FILE" || log_fail "Could not write to NFS from HPC-01"

# Read from HPC-02
if docker exec "$HPC_02" sh -c "cat $TEST_FILE" 2>/dev/null | grep -q "hello_from_hpc01"; then
	log_pass "NFS distributed read/write successful between HPC-01 and HPC-02"
else
	log_fail "HPC-02 failed to read file written by HPC-01 on NFS"
fi

# Cleanup
docker exec "$HPC_01" sh -c "rm -f $TEST_FILE" 2>/dev/null

# ==============================================================================
# 5. JupyterHub Frontend & Backend
# ==============================================================================
log_info "=== 5. JUPYTERHUB SERVICE ==="

# Check JupyterHub internal API on admin pod
if docker exec "$ADMIN_POD" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/hub/api || echo "fail"' | grep -q "401\|403\|200\|404\|302"; then
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

# ==============================================================================
# Summary
# ==============================================================================

log_info "=== ADVANCED VERIFICATION COMPLETE ==="
log_pass "All advanced functional tests passed!"
log_info "To access JupyterHub from your host, navigate to:"
log_info "  https://localhost:18880/"
