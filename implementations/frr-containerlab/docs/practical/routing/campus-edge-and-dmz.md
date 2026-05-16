# Campus Edge And DMZ

This page is for the campus test segment, the WiFi management path, and the DMZ web services.

## Runtime Layout

| Node | Important addresses | Why it matters |
| --- | --- | --- |
| `campus-bp` | `10.200.0.2/30` on `eth3`, `192.168.110.1/24` on `br-student` | campus NAC gateway; default traffic goes to `leaf-01`, not directly to an ISP |
| `guest-01` | `192.168.110.30/24` | stable campus client for manual tests |
| `student-01` | `192.168.110.31/24` | student browser/client, unauthenticated until NAC login |
| `admin-01` | `192.168.110.32/24` | admin browser/client, unauthenticated until NAC login |
| `wifi-controller` | `192.168.10.100/24` | target behind `VRF-WIFI-CTRL` |
| `server-dmz-01` | `198.51.100.10/24` | DMZ web service |
| `moodle` | `198.51.100.30/24` | Moodle LMS at `moodle.esi.dz` |
| `moodle-db` | `192.168.80.31/24` on a storage-pod bond | MariaDB backend for Moodle, multihomed to `leaf-07`/`leaf-08` |
| `leaf-01` | `10.200.0.1/30`, `192.168.1.252/24`, `VRF-WIFI-CTRL` | policy-routing pivot between campus, firewall, WiFi, DMZ, and Internet paths |

## Campus Client Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-guest-01 ip -4 addr show dev eth1` | confirms the campus client is on the right subnet | `192.168.110.30/24` |
| `docker exec clab-esi-datacenter-guest-01 cat /etc/resolv.conf` | confirms the unauthenticated client is configured like a campus host | nameserver `192.168.50.30` |
| `docker exec clab-esi-datacenter-guest-01 nc -z -w3 198.51.100.10 80 || echo blocked` | proves unauthenticated campus cannot reach DMZ HTTP | prints `blocked` |
| `docker exec clab-esi-datacenter-guest-01 nc -z -w3 198.51.100.30 80 || echo blocked` | proves unauthenticated campus cannot reach Moodle | prints `blocked` |
| `docker exec clab-esi-datacenter-guest-01 nc -z -w3 198.18.3.10 80 || echo blocked` | proves unauthenticated campus cannot reach Internet HTTP | prints `blocked` |
| `docker exec clab-esi-datacenter-student-01 nslookup dmz-server-01.esi.internal 192.168.50.30` | checks authenticated campus-to-DNS path | returns `198.51.100.10` |
| `docker exec clab-esi-datacenter-student-01 nslookup moodle.esi.dz 192.168.50.30` | checks public LMS name | returns `198.51.100.30` |
| `docker exec clab-esi-datacenter-student-01 wget -qO- http://dmz-server-01.esi.internal` | checks authenticated campus-to-DMZ HTTP | returns the DMZ page |
| `docker exec clab-esi-datacenter-student-01 wget -qO- http://moodle.esi.dz/` | checks authenticated campus-to-Moodle HTTP | returns Moodle HTML |
| `docker exec clab-esi-datacenter-student-01 nslookup ntp-server.esi.internal 192.168.50.30` | checks authenticated campus DNS service access | returns `192.168.50.20` |
| `docker exec clab-esi-datacenter-campus-bp ip route get 192.168.50.80` | checks NAC RADIUS source identity | contains `src 192.168.110.1` |

## Campus NAC Checks

```bash
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_students
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_admins
```

- Before login, neither `192.168.110.31` nor `192.168.110.32` should appear in a NAC role set.
- After student login, `campus_students` should include `192.168.110.31`.
- After admin login, `campus_admins` should include `192.168.110.32`.
- `guest-01` should not appear in either set.
- `guest-01` should reach the NAC portal only; Google demo, DMZ, Moodle, Jupyter, SSH, TACACS+, and LDAP are blocked until authentication.
- Protected servers accept the campus subnet as a possible SSH source; role separation is enforced at `campus-bp`, not by fixed endpoint IPs on the servers.

## Campus Border Checks

```bash
docker exec clab-esi-datacenter-campus-bp ip -4 addr show
docker exec clab-esi-datacenter-campus-bp ip route show
docker exec clab-esi-datacenter-campus-bp ping -c2 -W2 192.168.10.100
docker exec clab-esi-datacenter-campus-bp wget -qO- http://198.51.100.10
```

- The route table should show a default route and narrow service routes via `10.200.0.1`; there is no `100.10.0.0/30` ISP shortcut.
- The auth-server route should keep the NAC identity source as `192.168.110.1`; `10.200.0.2` is only transit.
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
docker exec clab-esi-datacenter-moodle sh -lc 'wget -qO- http://127.0.0.1 | grep -Ei "Moodle|TP - NAC"'
```

- The DMZ host should use `198.51.100.10/24`.
- Its local `nftables` policy should show a tight input policy.
- Local HTTP proves the web service is alive even before you debug routing.
- Moodle local HTTP proves the application container is alive before you debug NAC or DNS.

## Related Automation

```bash
bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh
```

- T1 already includes the strongest campus-and-DMZ behavioral checks.
- Use this page when you want to inspect only one hop or one allowed service quickly.
