# Core Services

This page covers the shared infra services on `192.168.50.0/24`: DNS, DHCP, and NTP.

## Service Summary

| Service | Node | Address | Main test script |
| --- | --- | --- | --- |
| DNS | `dns-server` | `192.168.50.30` | `dns_verify.sh` |
| DHCP | `dhcp-server` | `192.168.50.40` | `dhcp_verify.sh` |
| NTP | `ntp-server` | `192.168.50.20` | `ntp_verify.sh` |

## DNS

### Quick Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-dns-server pgrep unbound` | confirms the daemon is alive | PID printed |
| `docker exec clab-esi-datacenter-dns-server ip -4 -o addr show` | confirms service IP is bound | `192.168.50.30` |
| `docker exec clab-esi-datacenter-dns-server ip route show default` | confirms the default gateway | via `192.168.50.1` |
| `docker exec clab-esi-datacenter-server-admin-01 nslookup spine-01.esi.internal 192.168.50.30` | checks internal view | returns `10.1.0.1` |
| `docker exec clab-esi-datacenter-server-admin-01 nslookup ntp-server.esi.internal 192.168.50.30` | checks shared service records | returns `192.168.50.20` |
| `docker exec clab-esi-datacenter-campus-student-01 nslookup dmz-server-01.esi.internal 192.168.50.30` | checks authenticated campus clients can resolve published DMZ records | returns `198.51.100.10` |
| `docker exec clab-esi-datacenter-dns-server grep -A12 'name: \"dmz\"' /etc/unbound/unbound.conf` | checks split-horizon policy without needing a live DMZ-to-DNS path | `refuse` for `esi.internal` |
| `docker exec clab-esi-datacenter-dns-server nft list ruleset` | checks Ring 5 host policy | `policy drop`, bastion SSH, DNS `dport 53` |

### Useful Extra Check

```bash
docker exec clab-esi-datacenter-dns-server grep 'access-control-view' /etc/unbound/unbound.conf
```

- This is the fastest way to confirm which client subnets land in the internal view and which land in the DMZ view.

## DHCP

### Quick Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-dhcp-server pgrep kea-dhcp4` | confirms Kea is alive | PID printed |
| `docker exec clab-esi-datacenter-dhcp-server kea-dhcp4 -t /etc/kea/kea-dhcp4.conf` | validates config before chasing packet issues | exits cleanly |
| `docker exec clab-esi-datacenter-dhcp-server sh -lc 'ss -lunp | grep :67 || netstat -ulnp | grep :67'` | confirms UDP/67 is open | listener on port 67 |
| `docker exec clab-esi-datacenter-dhcp-server grep '192.168.50.30' /etc/kea/kea-dhcp4.conf` | checks DNS option is present | service IP appears |
| `docker exec clab-esi-datacenter-dhcp-server grep '192.168.50.20' /etc/kea/kea-dhcp4.conf` | checks NTP option is present | service IP appears |
| `docker exec clab-esi-datacenter-dhcp-server test -f /var/lib/kea/kea-leases4.csv && echo lease-file-present` | shows Kea has written lease state | `lease-file-present` |

### Manual Lease Test On A Dual-Homed Host

Use a bonded host because the relay and reservation behavior matters there.

```bash
docker exec clab-esi-datacenter-server-student-01 sh -lc '
  ip addr flush dev bond0
  ip route del default 2>/dev/null || true
  udhcpc -f -q -n -t 3 -T 3 -i bond0
'
```

- This proves the request can cross the leaf relay path and reach Kea.
- After the test, restore the expected static settings:

```bash
docker exec clab-esi-datacenter-server-student-01 sh -lc '
  ip addr flush dev bond0
  ip addr add 192.168.10.10/24 dev bond0
  ip route replace default via 192.168.10.1 dev bond0
'
```

## NTP

### Quick Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-ntp-server pgrep chronyd` | confirms the NTP daemon is alive | PID printed |
| `docker exec clab-esi-datacenter-ntp-server chronyc tracking` | shows source and stratum | stratum `2` in normal lab mode |
| `docker exec clab-esi-datacenter-ntp-server chronyc sources` | shows selected source | `^*` or `#*` line present |
| `docker exec clab-esi-datacenter-spine-01 chronyc sources` | checks fabric nodes use the shared NTP server | line for `192.168.50.20` |
| `docker exec clab-esi-datacenter-server-student-01 chronyc tracking` | checks endpoints still follow the lab NTP source | references `192.168.50.20` |

### Architecture Guard

```bash
docker exec clab-esi-datacenter-leaf-03 vtysh -c 'show running-config' | grep -E 'ip pim|router pim'
```

- `ntp_verify.sh` also checks that PIM stays absent.
- No output is the correct result.

## Automation

```bash
bash implementations/frr-containerlab/scripts/tests/dns_verify.sh
bash implementations/frr-containerlab/scripts/tests/dhcp_verify.sh
bash implementations/frr-containerlab/scripts/tests/ntp_verify.sh
```
