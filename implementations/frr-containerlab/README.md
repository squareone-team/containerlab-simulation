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

## Monitoring Stack (Prometheus + Grafana)

The lab includes an engineer-focused monitoring profile for simulation telemetry.

- Prometheus: `http://localhost:9090`
- Grafana: `http://localhost:3000`
- Grafana credentials: `admin / admin`

### What Is Preconfigured

- Auto-provisioned Prometheus datasource in Grafana.
- Auto-provisioned dashboard: **ESI Datacenter - Fabric Observability**.
- Prometheus alert rules for:
	- exporter or dashboard scrape failures
	- border BGP session loss
	- spine/leaf uplink failure
	- pod health degradation
	- high simulated router CPU
- Simulation telemetry includes BGP, EVPN VNI state, VRF route counts, pod health, and node resource metrics.

### Reconfigure After Monitoring Changes

The baseline is considered ready only when the script reports:

- `Phase 1 STABLE`

