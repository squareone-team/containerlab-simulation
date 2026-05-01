# Notebook-as-a-Service (NaaS) in ESI Datacenter Lab

## Overview

This document explains the Notebook-as-a-Service deployment in the ESI
Datacenter Lab. It replaces the previous shared-token Jupyter model with a
production-like system using:

- **JupyterHub**: Multi-user notebook server with PAM authentication
- **SLURM**: Job scheduler for notebook execution (CPU and GPU partitions)
- **NFS**: Persistent shared storage for notebook files
- **MariaDB**: Accounting database for SLURM and metadata for JupyterHub

## Architecture

### Pod Organization

```
┌─────────────────────────────────────────────────────┐
│              Admin Pod (192.168.50.0/24)             │
├─────────────────────────────────────────────────────┤
│  server-admin-01:                                   │
│    - JupyterHub Controller (8000 internal)          │
│    - JupyterHub Hub API (8081, worker callbacks)    │
│    - SLURM Controller slurmctld (6817)              │
│    - SLURM Accounting Daemon slurmdbd (6819)        │
│    - MariaDB (3306)                                 │
│    - Munge Auth Daemon (11002)                      │
│    - NFS Client (/home, /shared mounts)             │
└─────────────────────────────────────────────────────┘
                         ↕ (internal)
┌─────────────────────────────────────────────────────┐
│              HPC Pod (192.168.70.0/24)               │
├─────────────────────────────────────────────────────┤
│  server-hpc-jupyter (192.168.70.30):                │
│    - JupyterHub Frontend Proxy (8080)               │
│    - Exposed on host: localhost:18880               │
│                                                     │
│  server-hpc-01 (192.168.70.10):                    │
│  server-hpc-02 (192.168.70.20):                    │
│    - SLURM Worker Daemon slurmd (6818)              │
│    - CPU & GPU partition nodes                      │
│    - Matching Linux users/groups for SLURM setuid   │
│    - NFS Client mounts                              │
└─────────────────────────────────────────────────────┘
                         ↕ (NFS + metadata)
┌─────────────────────────────────────────────────────┐
│            Storage Pod (192.168.80.0/24)             │
├─────────────────────────────────────────────────────┤
│  server-storage-01 (192.168.80.10):                │
│    - NFS Server                                     │
│    - /home exports (user notebook homes)            │
│    - /shared exports (shared projects/courses)      │
└─────────────────────────────────────────────────────┘
```

## User Access Flow

### 1. User Login

```
User Browser
    ↓
https://localhost:18880/ or https://hpc-jupyter.esi.internal:8080
    ↓
server-hpc-jupyter (frontend proxy)
    ↓
JupyterHub Controller (192.168.50.10:8000 on server-admin-01)
    ↓
PAM Authentication (local Linux users)
    ↓
User approved → Session created
```

### 2. Notebook Execution

```
User starts a notebook server
    ↓
JupyterHub BatchSpawner/SlurmSpawner submits a SLURM job
    ↓
sbatch → SLURM Controller slurmctld
    ↓
SLURM routes to CPU or GPU partition:
  - CPU: hpc-01, hpc-02
  - GPU: hpc-01 (if configured)
    ↓
Notebook server and kernels run as the user on a SLURM worker
    ↓
/home/{username} NFS mount
    ↓
Notebook files persisted on Storage pod
```

## User Management

### User Groups

Four user groups are created with different permissions:

| Group       | GID  | Access    | Partition | QoS                    |
| ----------- | ---- | --------- | --------- | ---------------------- |
| students    | 5001 | CPU only  | cpu       | cpu_default (limited)  |
| researchers | 5002 | CPU only  | cpu       | cpu_default            |
| gpu-users   | 5003 | CPU + GPU | both      | gpu_standard (limited) |
| admins      | 5004 | All       | all       | admin_qos (unlimited)  |

### Pre-created Test Users

Users are initialized with the same UID/GID on server-admin-01,
server-hpc-01, and server-hpc-02 during startup:

```
Admin users:
  admin (uid=1000, groups: admins, gpu-users)
  administrator (uid=1001, groups: admins)

Researcher users:
  researcher-01 (uid=2001, groups: researchers)
  researcher-02 (uid=2002, groups: researchers, gpu-users)

Student users:
  student-01 (uid=3001, groups: students)
  student-02 (uid=3002, groups: students)
  student-03 (uid=3003, groups: students)
```

### Adding New Users

On server-admin-01:

```bash
# Add new user and groups
useradd -m -u <uid> -G <groups> <username>

# Example: Add new researcher with GPU access
useradd -m -u 2010 -G researchers,gpu-users alice
```

## Storage Organization

### NFS Mount Points

All nodes mount the same storage paths:

- **`/home`**: User home directories
  - Contains per-user Jupyter notebooks, data, configs
  - Path: `/home/{username}`
  - Ownership: `{uid}:{gid}` (matches PAM user)

- **`/shared`**: Shared project directories
  - Course materials, team projects, shared datasets
  - Paths:
    - `/shared/course-001/` - Course 1 materials
    - `/shared/course-002/` - Course 2 materials
    - `/shared/team-research/` - Research team collaboration

### Storage Consistency

- server-admin-01 and the SLURM workers mount the same `/home` and `/shared`
  paths from server-storage-01
- uid/gid mapping is consistent across all nodes
- NFS exports preserve user UID/GID; user-created files are not squashed to root
- Notebooks saved by one user are visible to that user from any node
- Shared directories are readable/writable by designated groups

## Persistence Model

### Notebook Persistence

1. **User creates notebook** → saved to `/home/{username}/` on NFS
2. **Container restarts** → NFS mounts reconnect, files are still there
3. **Pod redeploy** → If Storage pod persists, all notebooks are intact

### Database Persistence (current design)

- SLURM accounting database is in MariaDB (in-memory in this lab setup)
- On prod deployment, export/backup snapshots recommended:
  ```bash
  mysqldump -u slurm -p slurm_acct_db > /backups/slurm_acct_$(date +%Y%m%d).sql
  ```

## Network & Security

### DNS

- `hpc-jupyter.esi.internal` resolves to 192.168.70.30 (frontend proxy)
- Configured in existing `dns-server` (unbound.conf)

### Firewall Rules

Firewall rules are configured in nftables:

**Admin Pod** (server-admin-01):

- Allow HPC pod (192.168.70.0/24) → MySQL (3306), SLURM controller (6817), SLURM
  dbd (6819), JupyterHub public proxy (8000), and Hub API callbacks (8081)

**HPC Pods** (workers):

- Allow Admin pod → SLURM daemon (6818), Munge (11002)
- Allow Admin pod → notebook server callback ports (1024-65535)
- Allow Storage pod → NFS (2049, 111)

**Storage Pod** (server-storage-01):

- Allow HPC + Admin pods → NFS (2049, 111), RPC (111)

### TLS

- TLS terminates on server-hpc-jupyter via configurable-http-proxy
- Certificate: `/etc/jupyterhub-proxy/ssl/server.crt`
- Key: `/etc/jupyterhub-proxy/ssl/server.key`
- Valid for: hpc-jupyter.esi.internal

## JupyterHub Configuration

### Key Settings

| Setting               | Value               | Notes                                            |
| --------------------- | ------------------- | ------------------------------------------------ |
| Authenticator         | PAM                 | Local Linux accounts                             |
| Spawner               | BatchSpawner SlurmSpawner | Submits notebook servers to SLURM workers |
| Database              | MariaDB             | Persistent session tracking                      |
| Hub Port (internal)   | 8000                | On Admin pod                                     |
| Hub API Port          | 8081                | Reachable by notebook jobs on workers            |
| Proxy Port (frontend) | 8080                | On JupyterHub frontend (exposed as 18880 on host) |
| Cookie Age            | 7 days              | User session timeout                             |
| Idle Timeout          | 1 hour              | Notebook server idle timeout                     |

### Kernel Specs

Users can select notebook server profiles:

- **Python 3 (CPU)** → routed to cpu partition
- **Python 3 (GPU)** → routed to gpu partition (gpu-users only)

## SLURM Configuration

### Partitions

```
cpu: Default partition
  Nodes: hpc-01, hpc-02
  CPUs: 4 per node
  Memory: 7500 MB per node

gpu: GPU partition
  Nodes: hpc-01 (if GPU present)
  Max Time: 4 hours (gpu_standard QoS)
```

### QoS (Quality of Service)

Limits applied per user group:

```
cpu_default:      Max 16 CPUs, 100 jobs submitted, 10 running, 8 hours max
gpu_standard:     Max 8 CPUs, 50 jobs submitted, 5 running, 4 hours max
admin_qos:        Unlimited
```

## Startup and Verification

### Deployment

```bash
# Deploy lab
sudo containerlab deploy -t esi-datacenter.clab.yml

# Wait for services to start (~60 seconds)
sleep 60

# Run verification
bash scripts/tests/verify-notebook-as-a-service.sh
```

### Verification Checks

The verification script (`verify-notebook-as-a-service.sh`) tests:

- Admin pod services (MariaDB, SLURM, JupyterHub)
- HPC worker connectivity
- NFS mounts on admin and workers
- Matching Linux users/groups on workers
- Normal-user SLURM client access
- JupyterHub frontend connectivity
- Network DNS resolution

The advanced verifier (`verify-naas-advanced.sh`) additionally logs into the
Hub API, spawns a student notebook through SLURM, confirms the active SLURM job,
and creates a notebook file under storage-backed `/home/student-01`.

### Troubleshooting Startup

**Admin pod slow to start**

- MariaDB initialization takes ~10-15 seconds
- SLURM daemons take ~5 seconds
- Check: `docker logs clab-esi-datacenter-server-admin-01`

**HPC workers not connecting to SLURM**

- Check Munge key exists:
  `docker exec clab-esi-datacenter-server-admin-01 ls -la /etc/munge/munge.key`
- Check firewall rules:
  `docker exec clab-esi-datacenter-server-hpc-01 nft list ruleset`

**NFS mounts failing**

- Check Storage pod is running: `docker ps | grep storage`
- Check NFS exports:
  `docker exec clab-esi-datacenter-server-storage-01 exportfs -v`
- Check mount attempt:
  `docker logs clab-esi-datacenter-server-hpc-01 | grep NFS`

## Accessing JupyterHub

### From Lab Nodes

```bash
# From any lab node (e.g., bastion-01)
curl -k https://hpc-jupyter.esi.internal:8080/
```

### From Host Machine

```bash
# Via Docker port mapping (localhost:18880)
https://localhost:18880/

# Or via container network (if configured)
https://192.168.70.30:8080/
```

### Login

- **Username**: Any PAM user (e.g., `student-01`, `researcher-01`, `admin`)
- **Password**: Same as username in the lab (for example `student-01` /
  `student-01`)
- **First Access**: Select kernel profile (CPU or GPU)

## Submitting Jobs to SLURM

### From JupyterHub Notebook

```python
import subprocess

# Submit a notebook cell as SLURM job
result = subprocess.run(['sbatch', 'script.sh'], capture_output=True)
job_id = result.stdout.decode().split()[-1]
print(f"Job submitted: {job_id}")

# Check job status
subprocess.run(['squeue', '-j', job_id])

# Check accounting
subprocess.run(['sacct', '-j', job_id])
```

### From Command Line (inside a container)

```bash
# List nodes
sinfo

# Check job queue
squeue

# Submit a test job
sbatch -p cpu --wrap="sleep 10"

# Check job accounting
sacct
```

## Limits and Quotas

### Resource Limits Per User

Applied via QoS:

- **CPU students**: Max 16 CPUs, 10 concurrent jobs, 8 hours runtime
- **GPU researchers**: Max 8 CPUs, 5 concurrent GPU jobs, 4 hours runtime
- **Admins**: Unlimited

### Storage Quotas

Not enforced in lab setup. In production, configure NFS quotas on Storage pod:

```bash
# Set quota for student-01
setquota -u student-01 10000000 12000000 0 0 /home
```

## Backup and Recovery

### Notebook Files

All notebooks are on persistent NFS (server-storage-01 `/home` and `/shared`).

**Daily backup strategy**:

```bash
# On storage pod
tar -czf /backups/notebooks-$(date +%Y%m%d).tar.gz /home /shared

# Weekly snapshot (if using ZFS/LVM)
lvcreate -L 1G -s -n backup_$(date +%Y%m%d) /dev/storage/notebooks
```

### SLURM Accounting Database

```bash
# Backup MariaDB
mysqldump -u slurm -pslurm_pass slurm_acct_db > /backups/slurm_acct_$(date +%Y%m%d).sql

# Restore
mysql -u slurm -pslurm_pass slurm_acct_db < /backups/slurm_acct_20260430.sql
```

## Advanced Configuration

### Adding GPU Support

If GPU is available on server-hpc-01:

```bash
# In SLURM config (slurm.conf on server-admin-01)
NodeName=hpc-01 ... Gres=gpu:1
PartitionName=gpu Nodes=hpc-01 ...

# Reload config
slurmctld reconfigure
```

### Using Alternative Auth (LDAP/AD)

Instead of PAM local accounts:

```python
# In jupyterhub_config.py
c.JupyterHub.authenticator_class = 'ldapauthenticator.LDAPAuthenticator'
c.LDAPAuthenticator.server_address = 'ldap.example.com'
c.LDAPAuthenticator.bind_dn_template = 'cn={username},cn=users,dc=example,dc=com'
```

### Scaling Compute Nodes

Add more HPC workers following the same pattern as server-hpc-01/02:

1. Create new configs in `configs/server-hpc-0X/`
2. Add node definition to topology (`esi-datacenter.clab.yml`)
3. Update SLURM config (`slurm.conf`) to register new nodes
4. Run verification script

## Performance Notes

### Typical Notebook Launch Time

- Login: 2-3 seconds
- Notebook spawn: 5-10 seconds (sbatch + kernel startup)
- First cell execution: 1-2 seconds

### Storage Performance

- NFS write latency: 10-50ms (depends on network)
- Shared filesystem may have concurrent access contention
- In production, consider:
  - NFS tuning (read/write buffer sizes)
  - Distributed storage (GlusterFS, Ceph)
  - Local caching on compute nodes

## References

- [JupyterHub Documentation](https://jupyterhub.readthedocs.io/)
- [SLURM Workload Manager](https://slurm.schedmd.com/)
- [NFS Exports](https://linux.die.net/man/5/exports)
- ESI Datacenter Lab [README.md](./README.md)
