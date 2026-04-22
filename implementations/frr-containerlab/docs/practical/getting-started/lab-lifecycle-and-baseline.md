# Lab Lifecycle And Baseline

Use this page first after pulling changes or rebuilding the lab.

## First Deploy

```bash
./implementations/frr-containerlab/images/build.sh
sudo containerlab deploy -t implementations/frr-containerlab/esi-datacenter.clab.yml
```

- Build the local images once on a fresh machine.
- Deploy the topology from the repo root so all relative bind mounts resolve correctly.

## Reconfigure After Config Changes

```bash
sudo containerlab deploy -t implementations/frr-containerlab/esi-datacenter.clab.yml --reconfigure
```

- Reuses the running lab and reapplies changed configs.
- This is the fastest way to retest docs, startup scripts, and FRR changes.

## Baseline Automation

```bash
bash implementations/frr-containerlab/scripts/tests/phase1-verify.sh
```

- This is the broadest baseline script.
- A clean run ends with `Phase 1 + Correction STABLE`.

## Manual Baseline Checks

| Command | What it tells you | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-spine-01 vtysh -c 'show bgp summary'` | underlay neighbors on spine 1 | 10 total neighbors |
| `docker exec clab-esi-datacenter-spine-02 vtysh -c 'show bgp summary'` | underlay neighbors on spine 2 | 10 total neighbors |
| `docker exec clab-esi-datacenter-leaf-09 vtysh -c 'show bfd peers'` | fast fabric liveliness | peers are `Up` |
| `docker exec clab-esi-datacenter-leaf-09 vtysh -c 'show bgp l2vpn evpn summary'` | EVPN sessions to both spines | 2 neighbors |
| `docker exec clab-esi-datacenter-leaf-03 vtysh -c 'show evpn vni 10030'` | LMS VNI lives on admin pod | VNI `10030` exists |
| `docker exec clab-esi-datacenter-leaf-03 vtysh -c 'show evpn vni 10040'` | services-web VNI moved off the border leaf | VNI `10040` exists |
| `docker exec clab-esi-datacenter-leaf-01 ip route show vrf VRF-WIFI-CTRL` | WiFi micro-VRF state | route to `192.168.10.100/32`, no default |
| `docker exec clab-esi-datacenter-server-student-01 ping -c3 -W2 192.168.10.20` | local pedagogy traffic | succeeds |
| `docker exec clab-esi-datacenter-server-student-01 ping -c2 -W1 192.168.50.10` | student to staff isolation | fails |

## Focused Suites

Run these when you do not want the full baseline:

```bash
bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh
bash implementations/frr-containerlab/scripts/tests/theme-t3-ring1_all_validation.sh
bash implementations/frr-containerlab/scripts/tests/dns_verify.sh
bash implementations/frr-containerlab/scripts/tests/dhcp_verify.sh
bash implementations/frr-containerlab/scripts/tests/ntp_verify.sh
bash implementations/frr-containerlab/scripts/tests/snmp_verify.sh
```

## Clean Destroy

```bash
sudo containerlab destroy -t implementations/frr-containerlab/esi-datacenter.clab.yml --cleanup
```

- Use this when bind-mounted state or stale containers are getting in the way.
- Rebuild images again only if a Dockerfile or image package set changed.

## If The Baseline Looks Wrong

- Fabric issues: go to [Fabric and VRFs](../routing/fabric-and-vrfs.md)
- Border or DMZ issues: go to [Border routing and internet](../routing/border-routing-and-internet.md)
- Service issues: go to [Core services](../services/core-services.md)
- Firewall issues: go to [Firewall HA and policy](../security/firewall-ha-and-policy.md)
