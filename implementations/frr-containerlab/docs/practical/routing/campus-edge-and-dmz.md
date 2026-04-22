# Campus Edge And DMZ

This page is for the campus test segment, the WiFi management path, and the DMZ web server.

## Runtime Layout

| Node | Important addresses | Why it matters |
| --- | --- | --- |
| `campus-bp` | `100.10.0.2/30` on `eth1`, `10.200.0.2/30` on `eth3`, `192.168.110.1/24` on `br-student` | upstream edge, service transit, and campus gateway |
| `student-bp-01` | `192.168.110.30/24` | stable campus client for manual tests |
| `wifi-controller` | `192.168.10.100/24` | target behind `VRF-WIFI-CTRL` |
| `server-dmz-01` | `198.51.100.10/24` | DMZ web service |
| `leaf-01` | `10.200.0.1/30`, `192.168.1.252/24`, `VRF-WIFI-CTRL` | policy-routing pivot between campus, firewall, and WiFi path |

## Campus Client Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-student-bp-01 ip -4 addr show dev eth1` | confirms the campus client is on the right subnet | `192.168.110.30/24` |
| `docker exec clab-esi-datacenter-student-bp-01 cat /etc/resolv.conf` | confirms DNS is prepointed to core services | nameserver `192.168.50.30` |
| `docker exec clab-esi-datacenter-student-bp-01 nslookup dmz-server-01.esi.internal 192.168.50.30` | checks campus-to-DNS path | returns `198.51.100.10` |
| `docker exec clab-esi-datacenter-student-bp-01 curl -s http://dmz-server-01.esi.internal` | checks campus-to-DMZ HTTP | returns the DMZ page |
| `docker exec clab-esi-datacenter-student-bp-01 ping -c2 -W2 192.168.50.20` | checks allowed reachability to NTP | succeeds |
| `docker exec clab-esi-datacenter-student-bp-01 ping -c2 -W2 192.168.50.30` | checks allowed reachability to DNS | succeeds |
| `docker exec clab-esi-datacenter-student-bp-01 ping -c2 -W2 192.168.50.40` | checks allowed reachability to DHCP | succeeds |

## Campus Border Checks

```bash
docker exec clab-esi-datacenter-campus-bp ip -4 addr show
docker exec clab-esi-datacenter-campus-bp ip route show
docker exec clab-esi-datacenter-campus-bp ping -c2 -W2 192.168.10.100
docker exec clab-esi-datacenter-campus-bp wget -qO- http://198.51.100.10
```

- The route table should show the narrow service routes via `10.200.0.1`.
- The WiFi controller ping proves the micro-VRF path on `leaf-01` is usable.
- `wget` to the DMZ IP checks the routed path without depending on campus DNS.

## WiFi Management Micro-VRF

```bash
docker exec clab-esi-datacenter-leaf-01 ip route show vrf VRF-WIFI-CTRL
docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show evpn vni 10120'
docker exec clab-esi-datacenter-wifi-controller ip -4 addr show dev eth1
```

- `VRF-WIFI-CTRL` should contain the WiFi controller route and the campus route, but not a default route.
- VNI `10120` proves the management segment exists in the overlay.
- The controller itself should stay at `192.168.10.100/24`.

## DMZ Host Checks

```bash
docker exec clab-esi-datacenter-server-dmz-01 ip -4 addr show dev eth1
docker exec clab-esi-datacenter-server-dmz-01 nft list ruleset
docker exec clab-esi-datacenter-server-dmz-01 sh -lc 'wget -qO- http://127.0.0.1'
```

- The DMZ host should use `198.51.100.10/24`.
- Its local `nftables` policy should show a tight input policy.
- Local HTTP proves the web service is alive even before you debug routing.

## Related Automation

```bash
bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh
```

- T1 already includes the strongest campus-and-DMZ behavioral checks.
- Use this page when you want to inspect only one hop or one allowed service quickly.
