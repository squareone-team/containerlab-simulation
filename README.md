# ESI Data Center — Architecture Simulation

A data center network redesign for École Nationale Supérieure d'Informatique (ESI Algiers), covering network architecture, ContainerLab simulation, Ansible automation on Arista EOS, and security/QoS modeling. It runs as a working lab in ContainerLab with Docker.

For architecture documentation, see the [architecture-specification](https://github.com/squareone-team/architecture-specification) repository.

## Architecture Overview

The fabric is a two-tier Clos (Spine-Leaf) topology: 2 Spines, 5 Leaf pairs (10 production Leaves), 1 OOB switch, with redundant Layer 3 uplinks from every Leaf to both Spines. No Leaf-to-Leaf links; Layer 2 switching is confined within each pod boundary.

Spines run AS 65000. Each pod pairs two Leaves under its own AS: Edge Pod (L01/L02, AS 65001), Core Pod (L03/L04, AS 65002), Storage Pod (L05/L06, AS 65003), Compute Pod (L07/L08, AS 65004), Ultra Compute Pod (L09/L10, AS 65005). Every Leaf pair connects to both Spines.

Five production pods serve distinct workload profiles:

| Pod | Leaves | Sub. Ratio | Role |
|-----|--------|-----------|------|
| Edge | L01/L02 | 2:1 | ISP edge, HA firewall pair, DMZ, BAC Orientation |
| Core | L03/L04 | 3:1 | Identity, DNS/DHCP, NTP, observability, JupyterHub |
| Storage | L05/L06 | 1:1–1.5:1 | Ceph RBD/CephFS/RGW cluster |
| Compute | L07/L08 | 4:1 | OpenStack/KVM multi-tenant VMs |
| Ultra Compute | L09/L10 | 1:1 | Bare-metal GPU/HPC with 100 Gb/s + RDMA |

## Protocol Stack

| Layer | Technology |
|-------|-----------|
| Macro-segmentation | 5 VRFs (one per communication domain), one L3VNI per domain |
| Overlay control | MP-BGP EVPN (Types 1, 2, 3, 5) |
| Overlay data | VXLAN over UDP; 9000-byte fabric MTU; host MTU 8950 (VXLAN overhead) |
| Underlay control | eBGP with BFD (min-rx/min-tx 100 ms, multiplier 3 → 300 ms detection) |
| Physical underlay | Two-tier Clos; /31 P2P links; 100G Spine↔Edge/Ultra Compute; 25G standard uplinks |

Design points: symmetric IRB with anycast gateways, next-hop-unchanged on Spines so VXLAN tunnels terminate on Leaf VTEPs, head-end replication (no PIM), ESI multihoming with LACP (no MLAG peer-link).

## Macro-Segmentation — 5 Communication Domains

Security is enforced at the routing layer via VRF isolation. A missing route is a stronger guarantee than a firewall rule.

| Domain | L3VNI | Segments | Intent |
|--------|-------|---------|--------|
| Pedagogy | 10000 | STUDENT-TP (10010), STUDENT-PROJ (10020) | Untrusted student workloads |
| Staff | 20000 | LMS-STAFF (10030), SERVICES-WEB (10040), CORE-INFRA (10050), AI-GPU (10070), STORAGE-SAN (10080) | Production platform services |
| Administration | 30000 | HR-FINANCE (10060) | HR/Finance with encrypted storage |
| Orientation | 40000 | BAC-ORIENT (10090) | Seasonal, zero production routes, dedicated ISP |
| Public | 50000 | DMZ-WEB (10100) | Internet-facing; no RFC1918 routes imported |

All authorized cross-domain traffic hairpins through the Edge Pod HA firewall pair for stateful Layer 7 inspection.

## Security Model — 5 Defense Rings

| Ring | Scope | Implementation |
|------|-------|---------------|
| Ring 1 — Perimeter | North-south + authorized cross-domain | HA firewall pair (nftables), stateful Layer 7, all denied flows logged |
| Ring 2 — BGP Hardening | Routing fabric | TCP MD5 on all sessions; ISP peers: default-route import only, RFC1918 blocked outbound, max-prefix guard (4 prefixes) |
| Ring 3 — Control-Plane ACLs | Switch CPU + tunnel endpoints | BGP TCP/179 and BFD UDP/3784 from fabric loopbacks only; VXLAN UDP/4789 from Leaf VTEPs only; SSH from Bastion 172.16.0.50 only |
| Ring 4 — Bastion Access | Admin access path | ed25519 keys only; AllowUsers; MaxAuthTries 3; LoginGraceTime 30 |
| Ring 5 — Host Micro-Segmentation | Per-server | nftables; INPUT DROP by default; ESTABLISHED/RELATED allowed; role-specific service exceptions |

Supporting controls: Suricata IDS on Edge mirror feed, centralized syslog (90 days + 1-year RGW archive), Chrony NTP (sub-1s skew target), OpenLDAP + TACACS+ + FreeRADIUS auth stack.

## Quality of Service

Pod-aware 8-class DiffServ model. DSCP is set at Leaf ingress and preserved across VXLAN encapsulation (`tos inherit` on VXLAN interfaces). Spines schedule already-marked traffic; no re-marking in transit.

| Prio | Class | DSCP | Treatment | Min BW |
|------|-------|------|-----------|--------|
| 1 | Network Control | CS6 | Strict priority | — |
| 2 | Real-Time | EF | Strict priority, rate-limited | — |
| 3 | Critical Applications | AF41 | WFQ high | 20% |
| 4 | HPC / AI | AF31 | WFQ high | 25% |
| 5 | Academic / Interactive | AF21 | WFQ medium | 20% |
| 6 | General Student | AF11 | WFQ low | 10% |
| 7 | Bulk / Backup | CS1 | Scavenger | 5% |
| 8 | Best Effort | DF | Residual | — |

RoCEv2 transport uses ECN + DCQCN as the primary congestion signal; PFC (802.1Qbb) is scoped to Ultra Compute Pod (L09/L10) only to avoid fabric-wide head-of-line blocking.

## Services Simulated in ContainerLab

The `frr-containerlab` implementation runs a full lab topology with working services:

- **Fabric**: 2 FRR Spines + 10 FRR Leaves with full eBGP underlay and EVPN/VXLAN overlay
- **Infrastructure**: NTP (Chrony), DNS (Unbound), DHCP relay, AAA (TACACS+ + OpenLDAP + FreeRADIUS)
- **Security**: HA firewall pair (nftables + keepalived), Bastion, Suricata IDS, syslog
- **Observability**: Prometheus + Grafana (auto-provisioned ESI Fabric Observability dashboard), Zabbix
- **Compute services**: Moodle LMS, JupyterHub + SLURM, VPN gateway (WireGuard enrollment portal)
- **Edge**: 3 ISP routers (primary, secondary, BAC-dedicated), border routers, DMZ web server, VPN client
- **Automation**: Ansible/AWX control node

Demo endpoints (post-deploy): NAC portal at `https://192.168.110.1:8443/` · VPN enrollment at `https://198.51.100.20:8448/` · Moodle at `http://moodle.esi.dz/`

## Repository Layout

```
datacenter-containerlab-esi/
├── implementations/
│   ├── frr-containerlab/               # Primary implementation (active)
│   │   ├── esi-datacenter.clab.yml     # Main topology file
│   │   ├── configs/                    # Per-node startup configs
│   │   ├── images/                     # Custom Docker images (Dockerfiles)
│   │   ├── docs/                       # Detailed operational docs
│   │   │   ├── theory/                 # Architecture theory docs
│   │   │   ├── practical/              # Lab guides (routing, security, services)
│   │   │   └── reference/             # IP tables, credentials, firewall matrix
│   │   └── scripts/
│   │       ├── tests/                  # Validation scripts per theme
│   │       └── resiliancy/             # Resilience simulation scripts
│   ├── arista-containerlab/            # Arista EOS ContainerLab topology
│   ├── arista-containerlab-lightweight/ # Lightweight Arista topology (4-leaf subset)
│   └── arista-ansible/                 # Ansible automation for Arista EOS
│       └── ansible/
│           ├── playbooks/              # Underlay, overlay, validation playbooks
│           ├── roles/                  # arista-common, arista-underlay, arista-evpn
│           └── group_vars/host_vars/   # Per-pod and per-node variables
└── scripts/                            # Cross-implementation utilities
```

## Quick Start (FRR ContainerLab)

### Prerequisites

- Docker
- ContainerLab

### Build Instructions

```bash
git clone https://github.com/squareone-team/datacenter-containerlab-esi.git
cd datacenter-containerlab-esi/implementations/frr-containerlab

# Build custom images (first time only)
bash images/build.sh

# Deploy the full topology
sudo containerlab deploy -t esi-datacenter.clab.yml

# Run Phase 1 baseline validation (35 checks)
bash scripts/tests/phase1-verify.sh
# Expected: Phase 1 STABLE — 35 passed / 0 failed

# Inspect running nodes
sudo containerlab inspect -t esi-datacenter.clab.yml

# Destroy
sudo containerlab destroy -t esi-datacenter.clab.yml --cleanup
```

Output: Grafana at `http://localhost:3000`, Prometheus at `http://localhost:9090`.

## Validation

The lab includes a test suite covering all security rings and operational scenarios:

```bash
# Core fabric
bash scripts/tests/phase1-verify.sh          # 35-check baseline

# Security rings
bash scripts/tests/firewall_e2e_validation.sh
bash scripts/tests/theme-t3-ring1_all_validation.sh
bash scripts/tests/theme-t3-ring3_test.sh    # Control-plane ACLs
bash scripts/tests/theme-t3-ring4_test.sh    # Bastion enforcement
bash scripts/tests/theme-t3-ring5_verify.sh  # Host micro-segmentation

# Services
bash scripts/tests/dns_verify.sh
bash scripts/tests/ntp_verify.sh
bash scripts/tests/dhcp_verify.sh
bash scripts/tests/qos_verify.sh

# Resilience
bash scripts/resiliancy/simulate_node_down.sh --node leaf-01
bash scripts/tests/resilience_postcheck.sh
bash scripts/resiliancy/simulate_node_down.sh --node leaf-01 --restore
```

## Ansible Automation (Arista EOS)

The `arista-ansible` implementation automates Arista EOS device configuration across the full fabric.

### Build Instructions

```bash
cd implementations/arista-ansible/ansible

# Full site deployment
ansible-playbook playbooks/site.yml -i hosts.yml

# Underlay only (eBGP)
ansible-playbook playbooks/fabric-underlay.yml -i hosts.yml

# Overlay only (EVPN/VXLAN)
ansible-playbook playbooks/fabric-overlay.yml -i hosts.yml

# Validate
ansible-playbook playbooks/validate-fabric.yml -i hosts.yml
```

Roles: `arista-common` (base config), `arista-underlay` (eBGP + BFD), `arista-evpn` (VXLAN, VRFs, ESI LAGs).
AWX support: `awx-ee/` contains the Execution Environment Dockerfile for AWX/Tower deployment.
