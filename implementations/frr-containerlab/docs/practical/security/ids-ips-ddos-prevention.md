# IDS/IPS DDoS Prevention

This runbook validates the lightweight inline IPS wall now hosted on the firewall pair.

The standalone IDS bridge has been removed. Firewall `eth4` is the outside
leg toward `border-router-01`, and `tc` ingress policing drops excess TCP SYN
traffic to the DMZ web service at `198.51.100.10:80`.

## Quick Checks

```bash
docker exec clab-esi-datacenter-firewall-01 tc -s filter show dev eth4 ingress
docker exec clab-esi-datacenter-border-router-01 vtysh -c 'show bgp neighbors 203.0.113.2'
docker exec clab-esi-datacenter-internet-client-01 wget -q -T 5 -O - http://198.51.100.10/
```

The filter output should show a `flower` match for `198.51.100.10:80` and
police action counters for dropped excessive SYN traffic.

## Automated Proof

```bash
bash implementations/frr-containerlab/scripts/tests/ids_ips_ddos_validation.sh
```

The script checks normal HTTP access, runs a controlled short HTTP flood from two
internet clients, prints a second-by-second counter trace, and verifies the DMZ
service and BGP adjacency are still healthy afterward.

## Suricata Note

Suricata plus a GUI such as EveBox is useful for signature-based alerting, but it
is not required for this v1 prevention proof. Adding it later should be treated
as a detection enhancement on top of the current inline wall, not as the first
packet-prevention mechanism.
