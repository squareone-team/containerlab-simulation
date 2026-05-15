# Topology And Feature Map

This page is the shortest high-level map of what exists in `frr-containerlab` and which nodes own each feature.

## Topology Blocks

| Block | Nodes | Why it exists |
| --- | --- | --- |
| Fabric core | `spine-01`, `spine-02` | eBGP underlay, EVPN reflection, reachability between all leaf pairs |
| Border and public edge | `leaf-01`, `leaf-02`, `isp-router-01..04`, `internet-router-01..02`, `internet-client-*`, `internet-web-01`, `server-dmz-01`, `moodle` | Internet edge, default-route intake, DMZ, Moodle frontend, campus service insertion, orientation path |
| Admin and service pod | `leaf-03`, `leaf-04`, `server-admin-*`, `dns-server`, `dhcp-server`, `ntp-server`, `syslog-server`, `zabbix-server` | Shared services, staff workloads, route-leak point for core tooling |
| HPC pod | `leaf-05`, `leaf-06`, `server-hpc-*` | Staff VRF compute workloads |
| Storage pod | `leaf-07`, `leaf-08`, `server-storage-01`, `moodle-db` | Shared storage services and storage-backed Moodle database |
| Student pod | `leaf-09`, `leaf-10`, `server-student-*` | Pedagogy VRF workloads, DHCP relay, dual-homing |
| Security and management | `firewall-01`, `firewall-02`, `bastion-01`, `oob-sw`, `syslog-server` | Ring 1 HA firewall, Ring 4 OOB SSH, Ring 6 central logging |
| Identity and access | `auth-server`, `campus-bp`, `vpn-gateway` | LDAP directory, TACACS+/RADIUS services, campus NAC edge, and remote access VPN |
| Campus edge | `campus-bp`, `student-01`, `admin-01`, `guest-01`, `vpn-client-01`, `wifi-controller` | Campus test subnet, NAC role separation, fabric-attached browser clients, WiFi management micro-VRF |
| Observability | `fabric-telemetry`, `prometheus`, `grafana`, `zabbix-server` | Metrics, alerts, dashboards, SNMP polling |

## VRFs And Main Segments

| VRF | L3 VNI | Segments you will see most often | Main owner |
| --- | --- | --- | --- |
| `VRF-PEDAGOGY` | `50030` | `10010` student TP, `10020` student project | `leaf-09`, `leaf-10` |
| `VRF-STAFF` | `50020` | `10030` LMS, `10040` services-web, `10050` core-infra, `10070` HPC, `10080` storage | `leaf-03`, `leaf-04`, `leaf-05`, `leaf-06`, `leaf-07`, `leaf-08`, `leaf-01` |
| `VRF-ADMINISTRATION` | `50010` | `10060` HR/Finance | `leaf-03`, `leaf-04` |
| `VRF-PUBLIC` | `50040` | `10100` DMZ web, Moodle, VPN gateway | `leaf-01`, `leaf-02` |
| `VRF-ORIENTATION` | `50050` | `10090` orientation segment | `leaf-01`, `leaf-02` |
| `VRF-WIFI-CTRL` | `50060` | `10120` WiFi controller management | `leaf-01` |
| OOB bridge | n/a | `172.16.0.0/24` | `oob-sw`, `bastion-01` |

## Feature Ownership

| Feature | Where it is implemented | Best quick proof |
| --- | --- | --- |
| Underlay eBGP + BFD | `spine-*`, `leaf-*` FRR configs and startup scripts | `show bgp summary`, `show bfd peers` |
| EVPN/VXLAN overlay | Leaf startup scripts + `show evpn vni` | `show bgp l2vpn evpn summary`, `show evpn vni` |
| ESI multihoming | Leaf FRR `evpn mh` blocks + server `bond0` configs | `cat /proc/net/bonding/bond0` on dual-homed servers |
| DHCP relay | `configs/common/esi-dhcp-relay.py`, leaf startup scripts | `udhcpc` on a dual-homed host |
| Border route filtering | `configs/leaf-01/frr.conf`, `configs/leaf-02/frr.conf` | check only `0.0.0.0/0` learned from ISP neighbors |
| Orientation activation | `configs/orientation-runbook.sh`, `leaf-01` | `ip route show vrf VRF-ORIENTATION` before and after activation |
| Ring 1 firewall | `configs/firewall-*` + border leaf policy routes | VIP on exactly one firewall, nftables counters move |
| Ring 3 control-plane protection | leaf/spine `iptables` startup blocks | unauthorized `nc` to TCP/179 or UDP/4789 times out |
| Ring 4 bastion SSH | `bastion-01`, `oob-sw`, SSH hardening in nodes | bastion can SSH to `172.16.0.x`; non-bastion should not |
| Ring 5 host micro-segmentation | host startup scripts using `nftables` | workloads accept only the service ports they own |
| Ring 6 central logging | `syslog-server`, rsyslog config on nodes | `logger` from a reachable node appears on syslog server |
| Identity and access | `auth-server`, `campus-bp`, `vpn-gateway`, TACACS+/RADIUS scripts | `tail /var/log/esi-tacacs.log` on auth-server and `nft list set inet campus_nac campus_students` on campus-bp |
| Moodle LMS | `moodle`, `moodle-db`, DNS `moodle.esi.dz` | `wget -qO- http://moodle.esi.dz/` from an authenticated campus client |
| SNMP and Zabbix | node `snmpd` + FRR `agentx`, `zabbix-server` | `snmpget` from `zabbix-server` to `10.1.0.x` |
| Prometheus/Grafana/fabric telemetry | `configs/prometheus`, `configs/grafana`, telemetry scraper script | `curl http://localhost:9090/api/v1/targets` |

## Where To Read Next

- For behavior and traffic boundaries: [Traffic and security model](./traffic-and-security-model.md)
- For commands: start in [Practical](../practical/getting-started/lab-lifecycle-and-baseline.md)
- For credentials and demo logins: [Credentials](../reference/credentials.md)
