# Firewall HA And Policy

This runbook is for Ring 1: the HA firewall pair, the shared VIP, and the cross-VRF policy path.

## Runtime Summary

| Item | Value |
| --- | --- |
| Firewalls | `firewall-01`, `firewall-02` |
| Ring 1 VIP | `192.168.1.254/24` on `bond0` |
| Outside VIP | `203.0.113.14/29` on `eth4` |
| Campus VIP | `10.200.0.1/29` on `eth5` |
| Border transit IPs | `192.168.1.252` on `leaf-01`, `192.168.1.253` on `leaf-02` |
| HA mechanism | `keepalived` over firewall transit VNI `10199` |
| Policy engine | `nftables` |

The firewall transit is stretched through EVPN/VXLAN, not a direct `leaf-01` to `leaf-02` cable. That keeps `firewall-02` able to own the VIP during failover while avoiding a physical shortcut between the border leaves.

## First Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-firewall-01 ip -4 route show 192.168.0.0/16` | checks the border transit route on firewall 1 | via `192.168.1.252` or `.253` dev `bond0` |
| `docker exec clab-esi-datacenter-firewall-02 ip -4 route show 192.168.0.0/16` | checks the border transit route on firewall 2 | via `192.168.1.252` or `.253` dev `bond0` |
| `docker exec clab-esi-datacenter-firewall-01 ps aux` | grep '[k]eepalived'` | confirms HA daemon on firewall 1 | process exists |
| `docker exec clab-esi-datacenter-firewall-02 ps aux` | grep '[k]eepalived'` | confirms HA daemon on firewall 2 | process exists |
| `docker exec clab-esi-datacenter-firewall-01 ip -4 addr show bond0` | grep 192.168.1.254/24` | checks whether firewall 1 currently owns the VIP | matches on exactly one firewall |
| `docker exec clab-esi-datacenter-firewall-02 ip -4 addr show bond0` | grep 192.168.1.254/24` | checks whether firewall 2 currently owns the VIP | matches on exactly one firewall |
| `docker exec clab-esi-datacenter-leaf-01 ping -c2 -W2 192.168.1.254` | confirms the border leaf reaches the VIP | succeeds |
| `docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show evpn vni 10199'` | confirms the firewall transit VNI exists | VNI `10199` present |

## Inspect The Policy

```bash
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter input
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward | grep -F 'ct state { established, related }'
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward | grep -F 'ip saddr @cluster_2_admin ip daddr @cluster_1_pedagogy tcp dport { 53, 9100 } ct state new'
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward | grep -F 'ip saddr @cluster_1_pedagogy ip daddr @cluster_lms_staff tcp dport { 80, 443 } ct state new'
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward | grep -F 'ip saddr @cluster_public_dmz ip daddr @cluster_2_admin'
```

- `policy drop` on both input and forward chains is expected.
- The admin-to-pedagogy, pedagogy-to-LMS, and DMZ-drop fragments are the quickest sanity checks.

## Manual Allow Test

This reproduces the admin-to-pedagogy payload test from the validation scripts.

```bash
docker exec clab-esi-datacenter-server-student-01 sh -lc "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-student-9100.log; nohup nc -l -p 9100 >/tmp/ring1-student-9100.log 2>&1 </dev/null &"
docker exec clab-esi-datacenter-server-admin-01 sh -lc "printf 'RING1_ALLOW\n' | nc -w 3 192.168.10.10 9100 >/dev/null 2>&1 || true"
docker exec clab-esi-datacenter-server-student-01 grep -Fqx 'RING1_ALLOW' /tmp/ring1-student-9100.log && echo delivered
```

- This should print `delivered`.
- It proves the firewall is passing the allowed admin-to-pedagogy path, not just ping.

## Manual Block Test

This reproduces the pedagogy-to-admin negative test.

```bash
docker exec clab-esi-datacenter-server-admin-01 sh -lc "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-admin-9101.log; nohup nc -l -p 9101 >/tmp/ring1-admin-9101.log 2>&1 </dev/null &"
docker exec clab-esi-datacenter-server-student-01 sh -lc "printf 'RING1_DROP\n' | nc -w 3 192.168.50.10 9101 >/dev/null 2>&1 || true"
docker exec clab-esi-datacenter-server-admin-01 grep -Fqx 'RING1_DROP' /tmp/ring1-admin-9101.log && echo unexpected-delivery || echo blocked
```

- This should print `blocked`.
- It proves the explicit pedagogy-to-admin deny rule is doing the work.

## DMZ Isolation Check

```bash
docker exec clab-esi-datacenter-server-admin-01 sh -lc "pkill nc >/dev/null 2>&1 || true; rm -f /tmp/ring1-admin-9102.log; nohup nc -l -p 9102 >/tmp/ring1-admin-9102.log 2>&1 </dev/null &"
docker exec clab-esi-datacenter-public-web-server sh -lc "printf 'RING1_DMZ\n' | nc -w 3 192.168.50.10 9102 >/dev/null 2>&1 || true"
docker exec clab-esi-datacenter-server-admin-01 grep -Fqx 'RING1_DMZ' /tmp/ring1-admin-9102.log && echo unexpected-delivery || echo blocked
```

- This should also print `blocked`.
- If it does not, jump straight to the DMZ drop rules in `nft list chain inet filter forward`.

## Automation

```bash
bash implementations/frr-containerlab/scripts/tests/firewall_policy_validation.sh
bash implementations/frr-containerlab/scripts/tests/firewall_inpath_validation.sh
bash implementations/frr-containerlab/scripts/tests/firewall_e2e_validation.sh
bash implementations/frr-containerlab/scripts/tests/theme-t3-ring1_all_validation.sh
```

## Related Reference

- [Firewall communication matrix](../../reference/firewall-communication-matrix.md)
