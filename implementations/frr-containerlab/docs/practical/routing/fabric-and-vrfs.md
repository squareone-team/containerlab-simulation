# Fabric And VRFs

This runbook is for the routed fabric itself: underlay BGP, EVPN/VXLAN, VRFs, and the dual-homed host model.

## What You Are Checking

- The spines see every leaf over eBGP.
- Leaf pairs have EVPN sessions to both spines.
- VNIs are attached to the correct pods.
- `VRF-WIFI-CTRL` stays intentionally narrow.
- Dual-homed hosts still have a healthy `bond0`.

## Underlay And BFD

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-spine-01 vtysh -c 'show bgp summary'` | spine-side view of all leaf neighbors | 10 neighbors total |
| `docker exec clab-esi-datacenter-spine-02 vtysh -c 'show bgp summary'` | second spine view of the fabric | 10 neighbors total |
| `docker exec clab-esi-datacenter-leaf-09 vtysh -c 'show ip bgp 10.1.0.13/32'` | confirms ECMP/multipath reachability to another leaf loopback | output mentions `Multipath` or `2` |
| `docker exec clab-esi-datacenter-leaf-09 vtysh -c 'show bfd peers'` | confirms fast liveness detection | peer states are `Up` |
| `docker exec clab-esi-datacenter-spine-01 sysctl net.ipv4.fib_multipath_hash_policy` | confirms the expected ECMP hash behavior | value is `1` |

## EVPN And VXLAN

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-leaf-09 vtysh -c 'show bgp l2vpn evpn summary'` | EVPN control-plane adjacency on student pod | 2 neighbors |
| `docker exec clab-esi-datacenter-leaf-09 vtysh -c 'show evpn vni 10010'` | student VNI has remote VTEPs | remote VTEPs listed |
| `docker exec clab-esi-datacenter-leaf-03 vtysh -c 'show evpn vni 10030'` | LMS VNI sits on the admin pod | VNI `10030` present |
| `docker exec clab-esi-datacenter-leaf-03 vtysh -c 'show evpn vni 10040'` | services-web VNI sits on the admin pod | VNI `10040` present |
| `docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show evpn vni 10120'` | WiFi controller management VNI exists on border leaf | VNI `10120` present |
| `docker exec clab-esi-datacenter-leaf-09 ip -d link show vxlan10010` | verifies VXLAN data-plane details | `tos inherit` appears |

## VRF Boundaries

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-leaf-01 ip vrf show` | lists the border leaf VRFs | includes `VRF-PUBLIC`, `VRF-ORIENTATION`, `VRF-WIFI-CTRL` |
| `docker exec clab-esi-datacenter-leaf-01 ip route show vrf VRF-WIFI-CTRL` | checks the WiFi management micro-VRF | route to `192.168.10.100/32`, no default route |
| `docker exec clab-esi-datacenter-leaf-01 ip route show vrf VRF-ORIENTATION` | checks if orientation is currently active | empty until runbook activation |
| `docker exec clab-esi-datacenter-leaf-01 ip route show vrf VRF-PUBLIC` | checks public VRF isolation | no internal route leaks outside the DMZ segment |
| `docker exec clab-esi-datacenter-server-student-01 ping -c3 -W2 192.168.10.20` | same-VRF student reachability | succeeds |
| `docker exec clab-esi-datacenter-server-student-01 ping -c2 -W1 192.168.50.10` | student to staff isolation | fails |

## Dual-Homed Hosts

Use these when you suspect ESI or host bonding problems:

```bash
docker exec clab-esi-datacenter-server-student-01 cat /proc/net/bonding/bond0
docker exec clab-esi-datacenter-server-admin-01 cat /proc/net/bonding/bond0
docker exec clab-esi-datacenter-server-hpc-01 cat /proc/net/bonding/bond0
docker exec clab-esi-datacenter-server-storage-01 cat /proc/net/bonding/bond0
```

- `MII Status: up` means the bond is alive.
- `Currently Active Slave` should not be `None`.

## Fast Failure Triage

- If BGP is down on multiple leaves, start with the spines and underlay links.
- If only one VNI is wrong, compare `show evpn vni` with the pod that should own it.
- If only dual-homed servers are failing, inspect `bond0` before touching EVPN.
- If WiFi or campus management fails, jump to [Campus edge and DMZ](./campus-edge-and-dmz.md).
