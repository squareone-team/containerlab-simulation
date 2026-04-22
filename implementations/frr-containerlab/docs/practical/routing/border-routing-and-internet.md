# Border Routing And Internet

Use this page for the north-south edge: ISP sessions, route filtering, orientation mode, and end-to-end DMZ or internet checks.

## External BGP And Route Filtering

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC neighbors 203.0.113.2'` | checks ISP session on `leaf-01` | `BGP state = Established` |
| `docker exec clab-esi-datacenter-leaf-02 vtysh -c 'show bgp neighbors 203.0.113.6'` | checks ISP session on `leaf-02` | `BGP state = Established` |
| `docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show bgp neighbors 203.0.114.2'` | checks the third ISP adjacency | `BGP state = Established` |
| `docker exec clab-esi-datacenter-leaf-01 ping -c2 -W1 203.0.113.2` | simple data-plane sanity to ISP 1 | 2 packets received |
| `docker exec clab-esi-datacenter-leaf-02 ping -c2 -W1 203.0.113.6` | simple data-plane sanity to ISP 2 | 2 packets received |
| `docker exec clab-esi-datacenter-leaf-01 ping -c2 -W1 203.0.114.2` | simple data-plane sanity to ISP 3 | 2 packets received |
| `docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC ipv4 unicast neighbors 203.0.113.2 routes'` | verifies what is being learned inbound | only `0.0.0.0/0` |
| `docker exec clab-esi-datacenter-isp-router-01 vtysh -c 'show ip bgp neighbors 203.0.113.1 received-routes'` | checks what the ISP sees from the border leaf | no RFC1918 leaks |

## Policy Controls On The Border Leafs

```bash
docker exec clab-esi-datacenter-leaf-01 grep 'ESI-BGP-EXTERNAL' /etc/frr/frr.conf
docker exec clab-esi-datacenter-leaf-01 grep 'ESI-BGP-INTERNAL' /etc/frr/frr.conf
docker exec clab-esi-datacenter-leaf-01 grep -n 'prefix-list ISP-IN\\|prefix-list ISP-OUT\\|maximum-prefix' /etc/frr/frr.conf
docker exec clab-esi-datacenter-leaf-02 grep -n 'prefix-list ISP-IN\\|prefix-list ISP-OUT\\|maximum-prefix' /etc/frr/frr.conf
```

- The external and internal MD5 secrets should both exist, but they should be distinct.
- `ISP-IN` is meant to keep inbound learning narrow.
- `ISP-OUT` is meant to prevent RFC1918 leaks.
- `maximum-prefix` is the guardrail against runaway advertisements from an ISP peer.

## Orientation Runbook

```bash
bash implementations/frr-containerlab/configs/orientation-runbook.sh --status
bash implementations/frr-containerlab/configs/orientation-runbook.sh --activate
docker exec clab-esi-datacenter-leaf-01 ip route show vrf VRF-ORIENTATION
bash implementations/frr-containerlab/configs/orientation-runbook.sh --deactivate
```

- `--status` shows the current `VRF-ORIENTATION` routing view.
- `--activate` adds the orientation default on `leaf-01`.
- `--deactivate` removes it again so the VRF goes back to empty.

## End-To-End Internet And DMZ Checks

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-student-bp-01 ping -c2 -W2 198.18.3.10` | campus test client can reach the simulated internet web server | succeeds |
| `docker exec clab-esi-datacenter-student-bp-01 ping -c2 -W2 198.51.100.10` | campus test client can reach the DMZ server | succeeds |
| `docker exec clab-esi-datacenter-student-bp-01 nslookup dmz-server-01.esi.internal 192.168.50.30` | DNS path to the DMZ service | resolves to `198.51.100.10` |
| `docker exec clab-esi-datacenter-student-bp-01 curl -fsS --max-time 5 http://dmz-server-01.esi.internal` | checks HTTP data plane to DMZ | returns the DMZ test page |
| `docker exec clab-esi-datacenter-internet-client-01 ping -c2 -W2 198.51.100.10` | external client can reach the DMZ IP | succeeds |
| `docker exec clab-esi-datacenter-server-dmz-01 ip -4 -o addr show dev eth1` | confirms the DMZ host uses public/testnet addressing | `198.51.100.10/24` |

## Prometheus And Grafana Checks

```bash
curl -s http://localhost:9090/api/v1/targets
curl -s http://localhost:3000/api/health
docker exec clab-esi-datacenter-frr-exporter head -40 /srv/www/metrics/metrics
```

- Prometheus should show `frr-exporter:9342` as an up target.
- Grafana should return a health payload without authentication errors.
- The exporter file is the quickest place to see whether routing telemetry is still being generated.

## Automation

```bash
bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh
```

- This script already bundles the most important edge checks on one run.
- Use the manual commands above when you want to isolate a single symptom faster.
