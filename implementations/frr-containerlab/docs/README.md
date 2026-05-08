# FRR ContainerLab Docs

This folder is organized by intent so it is easier to jump between design notes and hands-on validation.

## Sections

- [Theory](./theory/topology-and-feature-map.md): topology, VRFs, security model, and where each feature lives.
- [Identity and access](./theory/identity-and-access.md): TACACS+/LDAP flow, campus NAC, and VPN identity mapping.
- [Practical](./practical/getting-started/lab-lifecycle-and-baseline.md): copy-paste commands for deploy, verification, and troubleshooting.
- [Reference](./reference/README.md): static matrices, image notes, and long-form architecture material.

## Start Here

| If you want to... | Open this doc |
| --- | --- |
| Deploy the lab and run the first health checks | [Lab lifecycle and baseline](./practical/getting-started/lab-lifecycle-and-baseline.md) |
| Check underlay, EVPN, VRFs, WiFi micro-VRF, and dual-homed hosts | [Fabric and VRFs](./practical/routing/fabric-and-vrfs.md) |
| Check ISP peering, route filtering, DMZ reachability, and orientation mode | [Border routing and internet](./practical/routing/border-routing-and-internet.md) |
| Check campus client access, WiFi management path, and DMZ web access | [Campus edge and DMZ](./practical/routing/campus-edge-and-dmz.md) |
| Check Ring 1 firewall HA and policy behavior | [Firewall HA and policy](./practical/security/firewall-ha-and-policy.md) |
| Check inline IDS/IPS DDoS prevention for the DMZ | [IDS/IPS DDoS prevention](./practical/security/ids-ips-ddos-prevention.md) |
| Check DNS, DHCP, and NTP | [Core services](./practical/services/core-services.md) |
| Check SNMP, Zabbix, Prometheus, Grafana, and exporter metrics | [Observability and monitoring](./practical/services/observability-and-monitoring.md) |
| Check bastion SSH, control-plane filtering, host micro-segmentation, and central syslog | [Management access and logging](./practical/security/management-access-and-logging.md) |
| Check TACACS+/LDAP, campus NAC roles, and VPN access | [Identity and access](./practical/security/identity-and-access.md) |
| Manually try student/admin/VPN identity flows end to end | [Identity access manual lab](./practical/security/identity-access-manual-lab.md) |
| Capture identity, VPN, SSH, RADIUS, TACACS+, and VXLAN traffic in Wireshark | [Packet capture and Wireshark](./practical/security/packet-capture-and-wireshark.md) |
| Simulate node failures and verify recovery | [Resilience and recovery](./practical/operations/resilience-and-recovery.md) |

## Quick Feature Map

| Feature area | Main nodes | Automation you can run | Manual runbook |
| --- | --- | --- | --- |
| Fabric baseline | `spine-*`, `leaf-*` | `bash implementations/frr-containerlab/scripts/tests/phase1-verify.sh` | [Fabric and VRFs](./practical/routing/fabric-and-vrfs.md) |
| Border routing and internet | `leaf-01`, `leaf-02`, `isp-router-*`, `internet-*` | `bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh` | [Border routing and internet](./practical/routing/border-routing-and-internet.md) |
| Campus edge and DMZ | `campus-bp`, `student-bp-01`, `server-dmz-01`, `wifi-controller` | `bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh` | [Campus edge and DMZ](./practical/routing/campus-edge-and-dmz.md) |
| Firewall HA and policy | `firewall-01`, `firewall-02`, `leaf-01`, `leaf-02` | `bash implementations/frr-containerlab/scripts/tests/theme-t3-ring1_all_validation.sh` | [Firewall HA and policy](./practical/security/firewall-ha-and-policy.md) |
| IDS/IPS DDoS prevention | `ids-01`, `leaf-01`, `isp-router-01`, `internet-client-*`, `server-dmz-01` | `bash implementations/frr-containerlab/scripts/tests/ids_ips_ddos_validation.sh` | [IDS/IPS DDoS prevention](./practical/security/ids-ips-ddos-prevention.md) |
| DNS | `dns-server` | `bash implementations/frr-containerlab/scripts/tests/dns_verify.sh` | [Core services](./practical/services/core-services.md) |
| DHCP | `dhcp-server`, dual-homed servers | `bash implementations/frr-containerlab/scripts/tests/dhcp_verify.sh` | [Core services](./practical/services/core-services.md) |
| NTP and no-PIM guard | `ntp-server`, all FRR nodes | `bash implementations/frr-containerlab/scripts/tests/ntp_verify.sh` | [Core services](./practical/services/core-services.md) |
| SNMP and Zabbix | `zabbix-server`, FRR nodes | `bash implementations/frr-containerlab/scripts/tests/snmp_verify.sh` | [Observability and monitoring](./practical/services/observability-and-monitoring.md) |
| Bastion and OOB | `bastion-01`, `oob-sw`, spines, leaves, `ftp-server` | `bash implementations/frr-containerlab/scripts/tests/theme-t3-ring4_test.sh` | [Management access and logging](./practical/security/management-access-and-logging.md) |
| Host micro-segmentation | `ftp-server`, `dns-server`, workload hosts | `bash implementations/frr-containerlab/scripts/tests/theme-t3-ring5_verify.sh` | [Management access and logging](./practical/security/management-access-and-logging.md) |
| Centralized logging | `syslog-server`, reachable workload nodes | `bash implementations/frr-containerlab/scripts/tests/theme-t3-ring6_verify.sh` | [Management access and logging](./practical/security/management-access-and-logging.md) |
| Identity and access | `auth-server`, `campus-bp`, `vpn-gateway`, `server-*` | `bash implementations/frr-containerlab/scripts/tests/auth_fabric_validation.sh` + `bash implementations/frr-containerlab/scripts/tests/vpn_access_validation.sh` | [Identity and access](./practical/security/identity-and-access.md), [manual lab](./practical/security/identity-access-manual-lab.md), [Wireshark](./practical/security/packet-capture-and-wireshark.md) |
| Failure simulation | Any node | `bash implementations/frr-containerlab/scripts/resiliancy/simulate_node_down.sh --node leaf-01` and `bash implementations/frr-containerlab/scripts/tests/resilience_postcheck.sh` | [Resilience and recovery](./practical/operations/resilience-and-recovery.md) |

## Notes

- Older top-level markdown files in `docs/` are kept as compatibility shortcuts and now point into this structure.
- The long-form architecture document still lives at [main/FULL_DOC.md](./main/FULL_DOC.md).
