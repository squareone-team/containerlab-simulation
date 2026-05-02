# Observability And Monitoring

Use this page for SNMP, Zabbix, Prometheus, Grafana, and the FRR exporter.

## Runtime Endpoints

| Component | How to reach it | What it does |
| --- | --- | --- |
| Zabbix | `http://localhost:4000` | official web UI, login `Admin / zabbix`, provisioned `ESI Fabric NOC` dashboard |
| `zabbix-server` | `192.168.50.50` | polls switch loopbacks with SNMP and runs local MariaDB |
| Prometheus | `http://localhost:9090` | scrapes exporter and Grafana metrics |
| Grafana | `http://localhost:3000` | dashboards, login `admin / admin` |
| `frr-exporter` | `frr-exporter:9342` inside the lab | serves generated telemetry from live `docker exec` lookups |

## SNMP And Zabbix

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `docker exec clab-esi-datacenter-leaf-03 pgrep snmpd` | confirms node SNMP agent is running | PID printed |
| `docker exec clab-esi-datacenter-leaf-03 grep '^agentx' /etc/frr/frr.conf` | confirms FRR exposes AgentX | `agentx` line exists |
| `docker exec clab-esi-datacenter-leaf-03 ls /var/agentx/master` | confirms AgentX socket exists | file is present |
| `docker exec clab-esi-datacenter-zabbix-server snmpget -v2c -c esi-read 10.1.0.13 1.3.6.1.2.1.1.1.0` | basic end-to-end SNMP poll from Zabbix to a leaf | returns `STRING` data |
| `docker exec clab-esi-datacenter-zabbix-server snmpwalk -v2c -c esi-read 10.1.0.1 1.3.6.1.2.1.15.3 | head` | checks BGP MIB via FRR AgentX on a spine | lines from `bgpPeerTable` |
| `docker exec clab-esi-datacenter-zabbix-server mysql -u zabbix -pzabbix-lab-pass -h 127.0.0.1 -e 'SELECT 1;' zabbix` | confirms the local DB is healthy | query succeeds |
| `docker exec clab-esi-datacenter-zabbix-server pgrep zabbix_server` | confirms the server process is alive | PID printed |
| `curl -s http://localhost:4000/index.php` | confirms the Zabbix frontend is published to the host | Zabbix login HTML returned |

After deploy, open `http://localhost:4000`, log in with `Admin / zabbix`, and open the `ESI Fabric NOC` dashboard. It is provisioned through the Zabbix API and includes the fabric host group, SNMP hosts for spine/leaf loopbacks, BGP peer-state checks, high-severity triggers, and an `ESI Datacenter Fabric` map.

## Prometheus, Grafana, And Exporter

| Command | Why you run it | Good sign |
| --- | --- | --- |
| `curl -s http://localhost:9090/api/v1/targets` | quickest Prometheus scrape-state view | `frr-exporter:9342` target is `up` |
| `curl -s http://localhost:9090/api/v1/rules` | confirms alert rules are loaded | monitoring and fabric rules returned |
| `curl -s http://localhost:3000/api/health` | quick Grafana health check | database and version payload returned |
| `docker exec clab-esi-datacenter-frr-exporter head -40 /srv/www/metrics/metrics` | looks at the generated metrics file directly | gauges such as `frr_bgp_session_up` appear |
| `docker exec clab-esi-datacenter-prometheus grep -n 'job_name' /etc/prometheus/prometheus.yml` | confirms scrape jobs in the live container | exporter, Prometheus, and Grafana jobs appear |

## High-Value Metrics To Spot Check

These are the fastest metrics to grep when the dashboard looks wrong:

```bash
docker exec clab-esi-datacenter-frr-exporter grep 'frr_bgp_session_up' /srv/www/metrics/metrics | head
docker exec clab-esi-datacenter-frr-exporter grep 'fabric_uplink_status' /srv/www/metrics/metrics
docker exec clab-esi-datacenter-frr-exporter grep 'fabric_pod_health_score' /srv/www/metrics/metrics
docker exec clab-esi-datacenter-frr-exporter grep 'frr_evpn_vni_up' /srv/www/metrics/metrics
```

- `frr_bgp_session_up` helps separate control-plane failures from dashboard issues.
- `fabric_uplink_status` and `fabric_pod_health_score` are useful after resilience tests.
- `frr_evpn_vni_up` is useful when a VNI seems to have disappeared from a pod.

## Automation

```bash
bash implementations/frr-containerlab/scripts/tests/snmp_verify.sh
bash implementations/frr-containerlab/scripts/tests/theme-t1-border-routing-verify.sh
```

- `snmp_verify.sh` is the main observability validation script. It checks Zabbix server, MariaDB, PHP-FPM/nginx, host port `4000`, Zabbix API provisioning, FRR AgentX/pass-persist wiring, and end-to-end SNMP/BGP MIB polling from `zabbix-server`.
- The T1 script also checks that Prometheus, Grafana, and the exporter are wired together.
