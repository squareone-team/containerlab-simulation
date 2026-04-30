# Notebook-as-a-Service Implementation Summary

## Completion Status: ✅ COMPLETE

All tasks for implementing Notebook-as-a-Service (NaaS) with JupyterHub + SLURM + NFS persistence have been completed and committed to the repository.

## What Was Implemented

### 1. Configuration Templates
- ✅ **slurm.conf** - HPC cluster definition with cpu/gpu partitions, node definitions, QoS per group
- ✅ **slurmdbd.conf** - SLURM accounting daemon configuration
- ✅ **jupyterhub_config.py** - JupyterHub controller with PAM auth, TLS, MariaDB persistence
- ✅ **mariadb-init.sql** - Database initialization for SLURM accounting and JupyterHub metadata
- ✅ **pam-users-init.sh** - User/group creation (students, researchers, gpu-users, admins)
- ✅ **exports** - NFS server export configuration for /home and /shared

### 2. Infrastructure Startup Scripts (Completely Redesigned)
- ✅ **server-admin-01/startup.sh** - Admin pod with MariaDB, SLURM controller, JupyterHub, Munge
- ✅ **server-hpc-01/startup.sh** - SLURM worker with NFS mounts
- ✅ **server-hpc-02/startup.sh** - SLURM worker with NFS mounts
- ✅ **server-hpc-jupyter/startup.sh** - JupyterHub frontend proxy (replaced token model)
- ✅ **server-storage-01/startup.sh** - NFS server for persistent notebook storage

### 3. Orchestration
- ✅ **esi-datacenter.clab.yml** - Updated topology with config binds and capabilities

### 4. Testing & Documentation
- ✅ **verify-notebook-as-a-service.sh** - Comprehensive verification script
- ✅ **NOTEBOOK_AS_A_SERVICE.md** - Complete architecture and usage guide

## Architecture Summary

```
┌──────────────────────────────────────────────────────────┐
│ User Browser → https://hpc-jupyter.esi.internal:8080    │
└──────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│     HPC Pod: server-hpc-jupyter (192.168.70.30)          │
│     JupyterHub Frontend Proxy on port 8080               │
└──────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│   Admin Pod: server-admin-01 (192.168.50.10)             │
│  - JupyterHub Controller (8000 internal)                 │
│  - SLURM Controller slurmctld (6817)                     │
│  - SLURM Accounting slurmdbd (6819)                      │
│  - MariaDB (3306)                                        │
│  - Munge Auth (11002)                                    │
└──────────────────────────────────────────────────────────┘
              ↓                        ↓
    ┌─────────────────┐    ┌──────────────────┐
    │  HPC-01/02      │    │  Storage-01      │
    │  SLURM Workers  │←──→│  NFS Server      │
    │  (6818)         │    │  (/home, /shared)│
    └─────────────────┘    └──────────────────┘
```

## Key Features

### Authentication & Authorization
- **Model**: PAM local accounts (configurable for LDAP/AD)
- **User Groups**: students, researchers, gpu-users, admins
- **Pre-created Test Users**:
  - admin (1000), administrator (1001)
  - researcher-01 (2001), researcher-02 (2002)
  - student-01 (3001), student-02 (3002), student-03 (3003)

### Compute Scheduling
- **Scheduler**: SLURM Workload Manager
- **Partitions**: cpu (hpc-01, hpc-02), gpu (hpc-01)
- **QoS Limits Per Group**:
  - students: cpu, 16 CPUs max, 10 jobs max, 8h timeout
  - researchers: cpu, 16 CPUs max, 100 jobs max
  - gpu-users: gpu, 8 CPUs max, 5 jobs max, 4h timeout
  - admins: unlimited

### Storage Model
- **Location**: server-storage-01 (NFS server)
- **Mount Points**: /home (user notebooks), /shared (projects)
- **Persistence**: Survives pod restarts if Storage pod persists
- **Ownership**: Consistent uid/gid across all nodes

### Security
- **TLS**: Self-signed certificates on JupyterHub frontend
- **Firewall**: nftables rules on all pods (restrictive inbound)
- **Port Mapping**: Only 8080 (JupyterHub) exposed to users
- **Internal Ports**:
  - 6817 (SLURM controller), 6819 (SLURM dbd)
  - 3306 (MariaDB), 11002 (Munge)
  - 2049 (NFS), 111 (RPC)

## Git Commits Made

```
1. feat: Add SLURM and JupyterHub configuration templates
2. feat: Add MariaDB initialization and PAM user setup scripts
3. feat: Add NFS server exports configuration
4. feat: Update Admin pod startup script for JupyterHub + SLURM + MariaDB
5. feat: Update HPC pod startup scripts for SLURM workers + NFS mounts
6. feat: Update JupyterHub frontend proxy startup script
7. feat: Update Storage pod startup script for NFS server
8. feat: Update topology to bind Notebook-as-a-Service configs
9. docs: Add verification script and Notebook-as-a-Service documentation
```

## File Structure

```
configs/
  admin/
    ├── slurm.conf                    # SLURM cluster definition
    ├── slurmdbd.conf                 # SLURM accounting daemon
    ├── jupyterhub_config.py          # JupyterHub controller config
    ├── mariadb-init.sql              # Database initialization
    └── pam-users-init.sh             # User/group setup
  storage-01/
    └── exports                        # NFS server exports
  server-admin-01/
    └── startup.sh                     # Admin pod initialization
  server-hpc-01/
    └── startup.sh                     # HPC worker #1 initialization
  server-hpc-02/
    └── startup.sh                     # HPC worker #2 initialization
  server-hpc-jupyter/
    └── startup.sh                     # JupyterHub frontend proxy
  server-storage-01/
    └── startup.sh                     # NFS server initialization

docs/
  └── NOTEBOOK_AS_A_SERVICE.md         # Complete usage guide

scripts/tests/
  └── verify-notebook-as-a-service.sh  # Verification script

esi-datacenter.clab.yml               # Updated topology (binds & caps)
```

## Deployment Steps

### 1. Deploy the Lab
```bash
cd implementations/frr-containerlab
sudo containerlab deploy -t esi-datacenter.clab.yml
```

### 2. Wait for Initialization (30-45 seconds)
```bash
sleep 30
```

### 3. Run Verification
```bash
bash ../../scripts/tests/verify-notebook-as-a-service.sh
```

### 4. Access JupyterHub
- **From host**: https://localhost:8888/ (port 8888 → container 8080)
- **From lab nodes**: https://hpc-jupyter.esi.internal:8080/
- **Login**: Use pre-created user (student-01, researcher-01, admin) with empty password

### 5. Submit Notebook Jobs
- Create notebook cell
- Select kernel (Python 3 CPU or GPU)
- Jupyter kernel runs as SLURM job
- Notebooks saved to `/home/{username}` on NFS

## Verification Checklist

Run the verification script and check:

- ✅ Admin pod running (MariaDB, SLURM, JupyterHub)
- ✅ MariaDB slurm_acct_db and jupyterhub databases created
- ✅ SLURM controller slurmctld running
- ✅ SLURM workers registered (sinfo shows 2 nodes)
- ✅ PAM users created (student-01, researcher-01, admin exist)
- ✅ HPC workers can reach Admin pod (port 6817)
- ✅ Storage pod NFS exports configured
- ✅ HPC workers NFS mounts active (/home, /shared)
- ✅ JupyterHub frontend accessible on port 8080
- ✅ DNS resolves hpc-jupyter.esi.internal

## Existing Repository Conventions Preserved

✅ **Topology**
- Kept existing pod structure (Admin, HPC, Storage)
- Maintained VLAN assignments and interface bonding
- Preserved ntp-server integration

✅ **Firewall**
- Extended nftables with SLURM/JupyterHub/MySQL/NFS ports
- Kept existing pod-to-pod firewall rules
- Added capability for service-to-service access

✅ **DNS**
- Used existing DNS resolver (192.168.50.30)
- Maintained hpc-jupyter.esi.internal entry
- No changes to DNS config needed (already has the A record)

✅ **Logging**
- Remote syslog forwarding to 192.168.50.70:514
- Integrated into existing syslog-server

✅ **NTP**
- Kept ntp-server integration (server-client-ntp.sh)
- All nodes sync time with centralized NTP

## Differences from Current Setup

| Aspect | Previous (Token Model) | New (JupyterHub + SLURM) |
|--------|------------------------|--------------------------|
| Auth | Shared static token | PAM local accounts |
| Notebook Server | Standalone on hpc-jupyter | JupyterHub controller on Admin pod |
| Job Scheduling | None (single server) | SLURM with partitions & QoS |
| Storage | Bind mount `/srv/notebooks` | NFS persistent /home & /shared |
| Database | None | MariaDB for SLURM accounting + JupyterHub |
| GPU Support | No | Yes (gpu partition with gpu-users group) |
| Multi-user | Limited (single token) | Full multi-user with per-user homes |
| Scalability | N/A (static server) | Add more HPC workers, retains auth |

## Next Steps for Production

1. **Configure Real Authentication**
   - Replace PAM with LDAP/AD integration
   - Update jupyterhub_config.py with `LDAPAuthenticator`

2. **Add Persistent Backups**
   - Export MariaDB daily
   - Snapshot NFS storage daily/weekly
   - Implement WAL for SLURM accounting

3. **Enable HA/Failover**
   - Secondary slurmctld on server-admin-02
   - DRBD for shared SLURM state
   - Replicated MariaDB (primary-secondary)

4. **Tune NFS Performance**
   - Enable sync mount option (currently async for lab)
   - Tune read/write buffer sizes
   - Consider distributed storage (Ceph, GlusterFS)

5. **Add Resource Enforcement**
   - Implement NFS quotas per user
   - CPU/memory resource limits via cgroups
   - Network bandwidth shaping

6. **Scale Compute**
   - Add more HPC worker nodes (server-hpc-03+)
   - Register in SLURM config
   - Automatic node discovery via config mgmt

## Troubleshooting

### Services Not Starting
```bash
# Check Admin pod logs
docker logs clab-esi-datacenter-server-admin-01

# Check HPC worker logs
docker logs clab-esi-datacenter-server-hpc-01

# Manually start MariaDB (if stuck)
docker exec clab-esi-datacenter-server-admin-01 mysqld_safe &
```

### NFS Mount Failures
```bash
# Check Storage pod NFS daemons
docker exec clab-esi-datacenter-server-storage-01 ps aux | grep nfs

# Restart NFS on storage
docker exec clab-esi-datacenter-server-storage-01 exportfs -ra

# Mount manually on worker
docker exec clab-esi-datacenter-server-hpc-01 \
  mount -t nfs 192.168.80.10:/home /home
```

### SLURM Not Recognizing Workers
```bash
# Check controller logs
docker exec clab-esi-datacenter-server-admin-01 tail -f /var/log/slurm/slurmctld.log

# Check worker registration
docker exec clab-esi-datacenter-server-admin-01 sinfo

# Force worker restart
docker exec clab-esi-datacenter-server-hpc-01 pkill slurmd
docker exec clab-esi-datacenter-server-hpc-01 slurmd -Dv
```

## References

- **JupyterHub**: https://jupyterhub.readthedocs.io/
- **SLURM**: https://slurm.schedmd.com/
- **Munge**: https://dun.github.io/munge/
- **NFS**: https://linux.die.net/man/5/exports
- **MariaDB**: https://mariadb.com/kb/en/

---

**Implementation Date**: 2026-04-30
**Status**: Production-Ready for Lab Use
**Last Updated**: 2026-04-30
