# Resiliancy Helpers

## simulate_node_down.sh

`simulate_node_down.sh` simulates a node outage without stopping containers.
It administratively toggles every topology-defined interface on the target
node, so the node is isolated while the ContainerLab deployment remains up.

## What It Does

- Parses `esi-datacenter.clab.yml` and finds all links attached to a node.
- Disables only the target side of each matched link (`shutdown`/`ip link down`).
- Restores those links with `--restore`.
- Maintains an isolated-node state file and supports `--status` output.
- Applies a convergence wait timer after isolate/restore (unless `--no-wait`).

## Interface Handling

- FRR path: uses `vtysh` for `leaf-*`, `spine-*`, `router-*`, `pe-*`, `p-*`, `rr-*`
  and for nodes where `vtysh` is detected dynamically.
- Non-FRR path: uses kernel `ip link set`.
- Fallback: if `vtysh` fails, the script retries with kernel `ip link`.

## Usage

```bash
# List valid topology nodes and link counts
bash scripts/resiliancy/simulate_node_down.sh --list

# Show currently isolated nodes from state file
bash scripts/resiliancy/simulate_node_down.sh --status

# Isolate a node (recommended form)
bash scripts/resiliancy/simulate_node_down.sh --node leaf-01

# Isolate a node (positional form also supported)
bash scripts/resiliancy/simulate_node_down.sh leaf-01

# Restore node connectivity
bash scripts/resiliancy/simulate_node_down.sh --node leaf-01 --restore

# Dry-run (show docker/vtysh/ip commands only)
bash scripts/resiliancy/simulate_node_down.sh --node firewall-01 --dry-run

# Override convergence wait (seconds)
bash scripts/resiliancy/simulate_node_down.sh --node leaf-03 --wait 30

# Skip convergence wait entirely
bash scripts/resiliancy/simulate_node_down.sh --node leaf-03 --no-wait
```

## Options

- `--node <name>`: Target node to isolate or restore.
- `--restore`: Bring all topology links for the target node back up.
- `--dry-run`: Print commands without making changes.
- `--list`: List topology nodes and link counts.
- `--status`: Show nodes currently marked as isolated.
- `--wait <seconds>`: Override the auto convergence wait.
- `--no-wait`: Skip convergence wait.
- `--force`: Allow isolating a node that shares links with already-isolated peers.
- `--topology <file>`: Use a custom topology file.

## Operational Notes

- Management connectivity (`eth0`) is not touched unless it appears in topology `links:`.
- OOB and service links are included if they are declared under topology links.
- Docker access is resolved as `docker`, then `sudo -n docker` fallback.
- Isolated-node state is stored at `${XDG_RUNTIME_DIR:-/tmp}/clab-resilience/<lab>.json`.
- In `--dry-run` mode, the script does not update state files and does not wait
  for convergence timers.
- For Ring 1 firewalls, restore automatically re-applies the static transit route
  (`192.168.0.0/16 via 192.168.1.252|253 dev eth1`) because some kernels drop
  static routes when interfaces are toggled down/up.

## Post-Resilience Sanity Check

After isolate/restore cycles, run:

```bash
bash scripts/tests/resilience_postcheck.sh
```

This validates:

- Ring 1 firewall static transit routes
- keepalived process and single VIP owner
- spine BGP sessions established
- leaf uplink interface state (`eth1`/`eth2`)
- dual-homed host bond0 health (active slave + MII up)
- During staged restores, an interface can be admin-up but operationally down
  until the peer node is restored; this is expected for shared links.

## Common Mistakes

- Invalid flag form: `--firewall-01` is not a valid option.
- Correct forms are:
  - `--node firewall-01`
  - `firewall-01` (positional)
