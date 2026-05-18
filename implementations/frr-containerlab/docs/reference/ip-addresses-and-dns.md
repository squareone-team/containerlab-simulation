# ESI Fabric IP And DNS Reference

This reference lists the stable lab addresses. DNS records are hosted on `dns-server` at `192.168.50.30` unless noted otherwise.

## Fabric Loopbacks

| Node | IP | DNS |
| --- | --- | --- |
| spine-01 | `10.1.0.1/32` | `spine-01.esi.internal` |
| spine-02 | `10.1.0.2/32` | `spine-02.esi.internal` |
| leaf-01 | `10.1.0.11/32` | `leaf-01.esi.internal`, `border-leaf-01.esi.internal` |
| leaf-02 | `10.1.0.12/32` | `leaf-02.esi.internal`, `border-leaf-02.esi.internal` |
| leaf-03 | `10.1.0.13/32` | `leaf-03.esi.internal`, `admin-leaf-01.esi.internal` |
| leaf-04 | `10.1.0.14/32` | `leaf-04.esi.internal`, `admin-leaf-02.esi.internal` |
| leaf-05 | `10.1.0.15/32` | `leaf-05.esi.internal`, `hpc-leaf-01.esi.internal` |
| leaf-06 | `10.1.0.16/32` | `leaf-06.esi.internal`, `hpc-leaf-02.esi.internal` |
| leaf-07 | `10.1.0.17/32` | `leaf-07.esi.internal`, `storage-leaf-01.esi.internal` |
| leaf-08 | `10.1.0.18/32` | `leaf-08.esi.internal`, `storage-leaf-02.esi.internal` |
| leaf-09 | `10.1.0.19/32` | `leaf-09.esi.internal`, `student-leaf-01.esi.internal` |
| leaf-10 | `10.1.0.20/32` | `leaf-10.esi.internal`, `student-leaf-02.esi.internal` |

## Border, Firewall, And Internet

| Segment | IPs | DNS |
| --- | --- | --- |
| isp-router-01 to border-router-01 | ISP `203.0.113.2/30`, border `203.0.113.1/30` | none |
| border-router-01 to firewalls | border `203.0.113.9/29`, outside VIP `203.0.113.14/29` | `firewall-outside-vip.esi.internal` |
| Ring 1 firewall inside transit | leaf-01 `192.168.1.252/24`, leaf-02 `192.168.1.253/24`, VIP `192.168.1.254/24` | `firewall-vip.esi.internal` |
| firewall-01 | inside `192.168.1.1/24`, outside `203.0.113.10/29`, campus `10.200.0.3/29` | `firewall-01.esi.internal` |
| firewall-02 | inside `192.168.1.2/24`, outside `203.0.113.11/29`, campus `10.200.0.4/29` | `firewall-02.esi.internal` |
| Public/DMZ gateway | `198.51.100.1/24` | none |
| VPN gateway | `198.51.100.20/24`, VPN pool `10.250.200.10-10.250.200.200` | portal `https://198.51.100.20:8448/` |
| Moodle frontend | `198.51.100.30/24` | `moodle.esi.dz` |
| DMZ web | `198.51.100.10/24` | `dmz-server-01.esi.internal`, `dmz-web.esi.internal` |
| Internet demo web/DNS | `198.18.3.10/24` | external DNS forwarder answers `www.google.com` |
| Internet clients | `198.18.1.10/24`, `198.18.2.10/24`, VPN browser outside `198.18.4.20/24` | use `198.18.3.10` for `www.google.com` |

## Campus And Internal Services

| Node/Segment | IP | DNS |
| --- | --- | --- |
| distribution-switch NAC gateway | `192.168.110.1/24` | portal `https://192.168.110.1:8443/` |
| campus transit to firewall pair | distribution switch `10.200.0.2/29`, firewall VIP `10.200.0.1/29` | `firewall-campus-vip.esi.internal` |
| guest-01 | `192.168.110.30/24` | none |
| student-01 | `192.168.110.31/24` | none |
| admin-01 | `192.168.110.32/24` | none |
| WiFi controller | `192.168.10.100/24` | `wifi-controller.esi.internal`, `wifi.esi.internal` |
| server-student-01 | `192.168.10.10/24` | none |
| server-student-02 | `192.168.10.20/24` | none |
| server-admin-01 | `192.168.50.10/24` | none |
| server-admin-02 | `192.168.60.10/24` | none |
| server-hpc-01 | `192.168.70.10/24` | none |
| server-hpc-02 | `192.168.70.20/24` | none |
| server-hpc-jupyter | `192.168.70.30/24` | `hpc-jupyter.esi.internal` |
| server-storage-01 | `192.168.80.10/24` | none |
| moodle-db | `192.168.80.31/24` | none |
| ntp-server | `192.168.50.20/24` | `ntp-server.esi.internal`, `ntp.esi.internal` |
| dns-server | `192.168.50.30/24` | `dns-server.esi.internal`, `dns.esi.internal` |
| dhcp-server | `192.168.50.40/24` | `dhcp-server.esi.internal`, `dhcp.esi.internal` |
| zabbix-server | `192.168.50.50/24` | `zabbix-server.esi.internal`, `zabbix.esi.internal` |
| prometheus | `192.168.50.60/24` | `prometheus.esi.internal` |
| syslog-server | `192.168.50.70/24` | `syslog-server.esi.internal`, `syslog.esi.internal` |
| auth-server | `192.168.50.80/24` | none |

## OOB Management

OOB uses secondary addresses on the containerlab management interface so the VS Code topology is not cluttered by management fan-out links.

| Node | OOB IP | DNS |
| --- | --- | --- |
| bastion-01 | `172.16.0.50/24` | `bastion-01.esi.internal`, `bastion.esi.internal` |
| spine-01 / spine-02 | `172.16.0.11/24`, `172.16.0.12/24` | none |
| leaf-01 through leaf-10 | `172.16.0.21/24` through `172.16.0.30/24` | none |

## DNS View Notes

Internal and VPN users use `192.168.50.30` and receive `esi.internal`, `moodle.esi.dz`, and `www.google.com` records. DMZ hosts in `198.51.100.0/24` receive the DMZ view, except the VPN gateway NAT source `198.51.100.20`, which is mapped to the internal view so enrolled VPN users can resolve internal service names.
