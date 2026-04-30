# Quick Reference: Notebook-as-a-Service Deployment

## TL;DR - Deploy & Test in 3 Commands

```bash
# 1. Deploy the lab
sudo containerlab deploy -t implementations/frr-containerlab/esi-datacenter.clab.yml

# 2. Wait for services to initialize
sleep 45

# 3. Run verification
bash scripts/tests/verify-notebook-as-a-service.sh
```

## Access JupyterHub

| Method        | URL                                    | Notes                |
| ------------- | -------------------------------------- | -------------------- |
| **From Host** | https://localhost:8888/                | Port 8888→8080       |
| **From Lab**  | https://hpc-jupyter.esi.internal:8080/ | All internal subnets |
| **Container** | 192.168.70.30:8080                     | Direct IP access     |

## Test Credentials (No Password - PAM Auth)

| Username        | Groups                 | Access    |
| --------------- | ---------------------- | --------- |
| `admin`         | admins, gpu-users      | CPU + GPU |
| `student-01`    | students               | CPU only  |
| `researcher-01` | researchers            | CPU only  |
| `researcher-02` | researchers, gpu-users | CPU + GPU |

## Key Container Ports (Internal)

| Service               | Port  | Container          | Description   |
| --------------------- | ----- | ------------------ | ------------- |
| JupyterHub Frontend   | 8080  | server-hpc-jupyter | User access   |
| JupyterHub Controller | 8000  | server-admin-01    | Internal only |
| SLURM Controller      | 6817  | server-admin-01    | Scheduling    |
| SLURM DBD             | 6819  | server-admin-01    | Accounting    |
| SLURM Worker          | 6818  | server-hpc-0X      | Worker daemon |
| MariaDB               | 3306  | server-admin-01    | Metadata      |
| Munge Auth            | 11002 | all                | SLURM auth    |
| NFS Server            | 2049  | server-storage-01  | Storage       |
| RPC Portmap           | 111   | server-storage-01  | NFS support   |

## Pod Organization

```
ADMIN POD (192.168.50.0/24)
  └─ server-admin-01: MariaDB + SLURM Controller + JupyterHub + Munge

HPC POD (192.168.70.0/24)
  ├─ server-hpc-jupyter: JupyterHub Frontend (8080 → 8888 on host)
  ├─ server-hpc-01: SLURM Worker (CPU partition)
  └─ server-hpc-02: SLURM Worker (CPU partition)

STORAGE POD (192.168.80.0/24)
  └─ server-storage-01: NFS Server (/home, /shared)
```

## Verification Steps

```bash
# Run full verification suite
bash scripts/tests/verify-notebook-as-a-service.sh

# Quick checks (one per line):
docker ps | grep -E "admin-01|hpc-01|hpc-02|hpc-jupyter|storage-01"  # All running?
docker exec clab-esi-datacenter-server-admin-01 mysql -u root -e "SHOW DATABASES"  # MariaDB OK?
docker exec clab-esi-datacenter-server-admin-01 sinfo  # SLURM nodes visible?
docker exec clab-esi-datacenter-server-hpc-01 mountpoint /home  # NFS mounted?
docker exec clab-esi-datacenter-server-hpc-jupyter nc -z 192.168.50.10 8000  # Controller reachable?
```

## Troubleshooting Checklist

**Services Not Starting?**

```bash
docker logs clab-esi-datacenter-server-admin-01 | tail -20  # Check Admin logs
sleep 30 && docker ps  # Wait longer, check if running now
```

**NFS Mount Failing?**

```bash
docker exec clab-esi-datacenter-server-storage-01 exportfs -v  # Check exports
docker exec clab-esi-datacenter-server-hpc-01 mount | grep nfs  # Check mounts
```

**SLURM Workers Not Visible?**

```bash
docker exec clab-esi-datacenter-server-admin-01 slurmctld -V  # Check controller
docker exec clab-esi-datacenter-server-hpc-01 slurmd -V  # Check workers
docker exec clab-esi-datacenter-server-admin-01 sinfo  # List nodes
```

**Can't Connect to JupyterHub?**

```bash
docker exec clab-esi-datacenter-server-hpc-jupyter nc -z 192.168.50.10 8000  # Controller reachable?
curl -k https://localhost:8888/  # HTTPS reachable?
```

## Configuration Files Location

```
configs/
  admin/
    ├── slurm.conf              ← Cluster definition, partitions, QoS
    ├── slurmdbd.conf           ← Accounting daemon config
    ├── jupyterhub_config.py    ← Controller config, auth, spawner
    ├── mariadb-init.sql        ← DB initialization
    └── pam-users-init.sh       ← Users/groups setup

  server-admin-01/startup.sh    ← Admin pod initialization
  server-hpc-01/startup.sh      ← HPC worker #1
  server-hpc-02/startup.sh      ← HPC worker #2
  server-hpc-jupyter/startup.sh ← JupyterHub frontend
  server-storage-01/startup.sh  ← NFS server
  storage-01/exports            ← NFS export definitions
```

## Common Operations

**Add New User**

```bash
docker exec clab-esi-datacenter-server-admin-01 \
  useradd -m -u 3010 -G students alice

# Verify
docker exec clab-esi-datacenter-server-admin-01 id alice
```

**Submit Test Job via SLURM**

```bash
docker exec clab-esi-datacenter-server-admin-01 \
  srun -p cpu --wrap="echo 'Hello from SLURM' && sleep 5"

# Check job status
docker exec clab-esi-datacenter-server-admin-01 squeue
```

**View NFS Exports**

```bash
docker exec clab-esi-datacenter-server-storage-01 exportfs -v
```

**Check User Notebook Home**

```bash
docker exec clab-esi-datacenter-server-hpc-01 ls -la /home/student-01/
```

**View SLURM Accounting**

```bash
docker exec clab-esi-datacenter-server-admin-01 sacct
```

## Key Differences from Previous Jupyter

| Feature         | Old (Token)         | New (JupyterHub)        |
| --------------- | ------------------- | ----------------------- |
| **Auth**        | Static shared token | PAM local users         |
| **Multi-user**  | Single user         | Full multi-user         |
| **Scheduling**  | None                | SLURM with partitions   |
| **Storage**     | Local bind mount    | NFS persistent          |
| **Database**    | None                | MariaDB tracking        |
| **GPU**         | No                  | Yes, via gpu partition  |
| **Scalability** | Hard-coded          | Add workers dynamically |

## Persistence

**Notebooks persist via NFS** - All notebooks saved to `/home/{username}` on
Storage pod

- Survive pod restarts ✅
- Survive HPC worker restarts ✅
- Survive entire lab redeploy (if Storage pod persists) ✅

**JupyterHub metadata** - Stored in MariaDB on Admin pod (in-memory for lab)

- User sessions tracked ✅
- Kernel state tracked ✅
- Lost on Admin pod restart (OK for lab) ⚠️

## Limits per User Group (QoS)

```
students:       Max 16 CPUs, 10 jobs, 8h runtime
researchers:    Max 16 CPUs, 100 jobs
gpu-users:      Max 8 CPUs, 5 GPU jobs, 4h runtime
admins:         Unlimited
```

## Documentation References

- **Full Guide**:
  [NOTEBOOK_AS_A_SERVICE.md](implementations/frr-containerlab/docs/NOTEBOOK_AS_A_SERVICE.md)
- **Implementation Details**:
  [NAAS_IMPLEMENTATION_SUMMARY.md](NAAS_IMPLEMENTATION_SUMMARY.md)
- **Verification Script**:
  [verify-notebook-as-a-service.sh](scripts/tests/verify-notebook-as-a-service.sh)
- **Main Lab README**:
  [implementations/frr-containerlab/README.md](implementations/frr-containerlab/README.md)

## Git Commits for This Feature

```
645bc0f docs: Add comprehensive Notebook-as-a-Service implementation summary
c5f725b docs: Add verification script and Notebook-as-a-Service documentation
97c71ff feat: Update topology to bind Notebook-as-a-Service configs
0ff446d feat: Update Storage pod startup script for NFS server
a096810 feat: Update JupyterHub frontend proxy startup script
fe36a4d feat: Update HPC pod startup scripts for SLURM workers + NFS mounts
f70d39b feat: Update Admin pod startup script for JupyterHub + SLURM + MariaDB
f8fdc95 feat: Add NFS server exports configuration
44f7b66 feat: Add MariaDB initialization and PAM user setup scripts
1ebf551 feat: Add SLURM and JupyterHub configuration templates
```

---

**Total Implementation**: 10 tasks, 10 commits, ~2500 lines of code+config
**Status**: Ready for deployment and testing
