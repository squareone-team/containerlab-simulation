# Management Access And Logging

This page groups the practical checks for Ring 3, Ring 4, Ring 5, and Ring 6.

## Ring 3: Control-Plane Protection

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-leaf-01 iptables -S INPUT` | shows the leaf input ACLs | explicit allow rules for BGP/BFD/VXLAN/SSH and default drops |
| `docker exec clab-esi-datacenter-server-student-01 sh -lc 'nc -zvw5 10.1.0.11 179'` | tests unauthorized BGP access from a server | times out |
| `docker exec clab-esi-datacenter-server-admin-01 sh -lc 'nc -zvw5 10.1.0.11 22'` | tests unauthorized SSH to a fabric loopback | times out |
| `docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show bgp summary'` | positive control-plane check | fabric sessions stay established |

## Ring 4: Bastion And OOB Access

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-bastion-01 sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@172.16.0.11 'hostname'"` | OOB SSH from bastion to spine 1 | hostname returned |
| `docker exec clab-esi-datacenter-bastion-01 sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@172.16.0.21 'hostname'"` | OOB SSH from bastion to leaf 1 | hostname returned |
| `docker exec clab-esi-datacenter-leaf-01 ip -4 addr show dev eth10` | confirms the OOB address exists on the node | `172.16.0.21/24` |
| `docker exec clab-esi-datacenter-bastion-01 cat /root/.ssh/id_ed25519.pub` | confirms the bastion key exists | public key text printed |

## Ring 5: Host Micro-Segmentation

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-server-student-01 sh -lc 'ping -c2 -W1 192.168.80.11 >/dev/null 2>&1 && echo open || echo blocked'` | tests that a student host cannot reach the FTP data IP | `blocked` |
| `docker exec clab-esi-datacenter-server-student-01 sh -lc 'nc -z -w2 192.168.80.11 21 >/dev/null 2>&1 && echo open || echo blocked'` | tests that student TCP/21 is blocked | `blocked` |
| `docker exec clab-esi-datacenter-bastion-01 sh -lc "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@172.16.0.61 'echo ring5-ok'"` | positive control: bastion can still manage the FTP host | `ring5-ok` |
| `docker exec clab-esi-datacenter-dns-server nft list chain inet filter input` | quick example of host-side nftables policy | `policy drop` with explicit service allows |

## Ring 6: Central Syslog

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-syslog-server ss -tlnp | grep 514` | confirms the syslog server listens for TCP/514 | listener present |
| `docker exec clab-esi-datacenter-server-admin-01 logger -t MANUAL 'RING6_MANUAL_TEST'` | injects a known log line from a reachable node | command succeeds |
| `docker exec clab-esi-datacenter-syslog-server grep 'RING6_MANUAL_TEST' /var/log/messages` | checks delivery to the collector | line appears |
| `docker exec -it clab-esi-datacenter-syslog-server tail -f /var/log/messages` | live tail for repeated tests | new lines stream in |
| `docker exec clab-esi-datacenter-leaf-01 tail -20 /var/log/messages` | checks local logging on a node | local log file still exists |

## Useful Notes

- Central syslog is reachable only through same-VRF routing or the explicit Ring 1 TCP/514 log-export policy.
- `server-admin-01` is the safest default source for Ring 6 manual log injection.
- `oob-sw` is only a Layer 2 bridge, so bastion/OOB debugging is mostly about SSH and addressing, not routing.

## Automation

```bash
bash implementations/frr-containerlab/scripts/tests/theme-t3-ring3_test.sh
bash implementations/frr-containerlab/scripts/tests/theme-t3-ring4_test.sh
bash implementations/frr-containerlab/scripts/tests/theme-t3-ring5_verify.sh
bash implementations/frr-containerlab/scripts/tests/theme-t3-ring6_verify.sh
```
