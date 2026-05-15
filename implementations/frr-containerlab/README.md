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

## Resilience Testing

Use the node-isolation helper to simulate outages without destroying containers.

```bash
# List available nodes from topology
bash scripts/resiliancy/simulate_node_down.sh --list

# Isolate a node
bash scripts/resiliancy/simulate_node_down.sh --node leaf-01

# Restore the node
bash scripts/resiliancy/simulate_node_down.sh --node leaf-01 --restore

# Show currently isolated nodes
bash scripts/resiliancy/simulate_node_down.sh --status

# Run post-resilience health checks (firewall/spine/leaf/bond)
bash scripts/tests/resilience_postcheck.sh
```

Detailed usage and troubleshooting: `scripts/resiliancy/README.md`

## Monitoring Stack (Prometheus + Grafana)

The lab includes an engineer-focused monitoring profile for simulation telemetry.

- Prometheus: `http://localhost:9090`
- Grafana: `http://localhost:3000`
- Grafana credentials: `squareone.admin / SquareOneGrafana#2026`

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
- Browser-facing demos include NAC at `https://192.168.110.1:8443/`, VPN enrollment at `https://198.51.100.20:8448/`, same-container VPN browser tunnel install, `www.google.com` on the simulated Internet webserver, and Moodle at `http://moodle.esi.dz/`.

### Reconfigure After Monitoring Changes

The baseline is considered ready only when the script reports:

- `Phase 1 STABLE`
