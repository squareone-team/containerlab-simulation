# ESI Datacenter Lab

EVPN/VXLAN spine-leaf datacenter simulation for ESI using ContainerLab and FRR.

## Current Implementation

- Active implementation: `implementations/frr-containerlab/`
- Topology file: `implementations/frr-containerlab/esi-datacenter.clab.yml`
- Fabric nodes: 2 spines, 10 leafs (border/admin/hpc/storage/student), 3 ISP routers
- Services: Alpine-based server and infrastructure placeholders for later theme work

## Phase 1 Status

Phase 1 baseline is implemented and validated with the current verifier:

- Verification script: `implementations/frr-containerlab/tests/phase1-verify.sh`
- Latest result: `35 passed / 0 failed` (`Phase 1 STABLE`)

## Quick Start

Prerequisites: Docker + ContainerLab.

```bash
cd implementations/frr-containerlab

# Deploy
sudo containerlab deploy -t esi-datacenter.clab.yml

# Run baseline validation
bash tests/phase1-verify.sh

# Inspect
sudo containerlab inspect -t esi-datacenter.clab.yml

# Destroy
sudo containerlab destroy -t esi-datacenter.clab.yml --cleanup
```

## Repository Layout

```text
esi-datacenter/
├── context.md
├── implementations/
│   ├── frr-containerlab/                # Active implementation
│   │   ├── esi-datacenter.clab.yml
│   │   ├── configs/
│   │   └── tests/
│   ├── arista-containerlab/             # Alternate implementation path
│   ├── arista-containerlab-lightweight/ # Alternate implementation path
│   └── arista-ansible/                  # Automation path
└── scripts/
```

## Notes

- `context.md` is the authoritative collaboration and architecture contract for this project.
- Theme work (T1-T4) must branch from the validated Phase 1 baseline.

