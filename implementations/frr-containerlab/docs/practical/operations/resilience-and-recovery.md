# Resilience And Recovery

Use this page when you want to simulate a failure without destroying the whole lab.

## Main Helper

```bash
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --list
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --status
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --node leaf-01
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --node leaf-01 --restore
```

- `--list` shows valid node names and link counts.
- `--status` shows what is currently isolated.
- `--node <name>` administratively drops that node's topology links.
- `--restore` brings those links back.

## Safe Variants

```bash
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --node firewall-01 --dry-run
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --node leaf-03 --wait 30
bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --node leaf-03 --no-wait
```

- `--dry-run` is the safest way to see what would be touched.
- `--wait` gives the control plane longer to settle after the event.
- `--no-wait` is useful when you want to run your own timing loop.

## Post-Restore Sanity Suite

```bash
bash implementations/frr-containerlab/scripts/tests/resilience_postcheck.sh
```

This checks:

- Ring 1 transit routes on both firewalls
- `keepalived` on both firewalls
- single ownership of VIP `192.168.1.254`
- at least one established BGP session on each spine
- `eth1` and `eth2` state on each leaf
- `bond0` health on dual-homed servers

## Manual Spot Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-firewall-01 ip -4 route show 192.168.0.0/16` | restore can sometimes drop this static route | via `192.168.1.252` or `.253` dev `bond0` |
| `docker exec clab-esi-datacenter-firewall-02 ip -4 route show 192.168.0.0/16` | same check on firewall 2 | via `192.168.1.252` or `.253` dev `bond0` |
| `docker exec clab-esi-datacenter-firewall-01 ip -4 addr show eth1` | grep 192.168.1.254/24` | checks VIP ownership after failover | exactly one firewall matches |
| `docker exec clab-esi-datacenter-spine-01 vtysh -c 'show bgp summary json'` | confirms spine sessions reconverged | neighbors back to `Established` |
| `docker exec clab-esi-datacenter-leaf-01 ip -o link show dev eth1` | confirms uplink is operational again | state `UP` or `UNKNOWN` |
| `docker exec clab-esi-datacenter-server-student-01 cat /proc/net/bonding/bond0` | confirms host-side bond recovered | `MII Status: up` and active slave present |

## Good Habits During Failure Testing

- Isolate one node at a time unless you are intentionally testing split or paired failures.
- Run `--dry-run` first on border leaves and firewalls.
- After restoring a firewall, always recheck the transit route and VIP ownership.
- After restoring a leaf, always recheck BGP first and `bond0` second.
