# IDS/IPS DDoS Prevention

This runbook validates the lightweight inline IPS wall on `ids-01`.

`ids-01` is a transparent Layer-2 bridge between `isp-router-01` and `leaf-01`.
It keeps the existing BGP/IP design unchanged while `tc` ingress policing drops
excess TCP SYN traffic to the DMZ web service at `198.51.100.10:80`.

## Quick Checks

```bash
docker exec clab-esi-datacenter-ids-01 ids-ips-summary
docker exec clab-esi-datacenter-leaf-01 vtysh -c 'show bgp vrf VRF-PUBLIC neighbors 203.0.113.2'
docker exec clab-esi-datacenter-internet-client-01 wget -q -T 5 -O - http://198.51.100.10/
```

The summary should show `br-ips`, a `flower` match for `198.51.100.10:80`, and
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
