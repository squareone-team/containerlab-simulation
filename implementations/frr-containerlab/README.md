# FRR ContainerLab Implementation

FRR-based EVPN/VXLAN fabric running in ContainerLab for the ESI datacenter project.

## Topology File

- `esi-datacenter.clab.yml`

## Quick Commands

```bash
# Deploy lab
sudo containerlab deploy -t esi-datacenter.clab.yml

# Reconfigure running lab after config changes
sudo containerlab deploy -t esi-datacenter.clab.yml --reconfigure

# Validate Phase 1 baseline
bash tests/phase1-verify.sh

# Destroy lab
sudo containerlab destroy -t esi-datacenter.clab.yml --cleanup
```

## Validation

- Baseline verification script: `tests/phase1-verify.sh`
- Companion note: `tests/README-tests.md`

The baseline is considered ready only when the script reports:

- `Phase 1 STABLE`

