# ESI Datacenter - Ring 1 HA Firewall Pair Configuration

## Overview

This directory contains the configuration for the Ring 1 HA firewall pair
(`firewall-01` and `firewall-02`) implementing the shared transit gateway
`192.168.1.254/24`. The firewalls use Keepalived for high availability and
nftables for stateful packet filtering.

## Architecture

```
                          ┌─────────────────┐
                          │   VIP Gateway   │
                          │   192.168.1.254 │
                          └────────┬────────┘
                                   │
                  ┌────────────────┴────────────────┐
                  │                                 │
         ┌────────▼─────────┐          ┌────────────▼──────┐
         │  firewall-01     │          │   firewall-02     │
         │  (MASTER Pr:101) │◄─────────►│  (BACKUP Pr:100) │
         │  192.168.1.1/24  │  VRRP    │  192.168.1.2/24  │
         └────────┬─────────┘          └────────┬──────────┘
                  │                             │
         ┌────────▼──────────┐        ┌─────────▼────────┐
         │    leaf-01:eth5   │        │   leaf-02:eth5   │
         └───────────────────┘        └──────────────────┘
```

The two border leaves are joined by `leaf-01:eth9 <-> leaf-02:eth9`, creating
the shared Ring 1 transit segment used by the firewalls and the VIP.

## File Structure

### Configuration Files

- `configs/firewall-01/keepalived.conf`
- `configs/firewall-02/keepalived.conf`
  - firewall-01: MASTER (priority 101)
  - firewall-02: BACKUP (priority 100)
  - VIP: `192.168.1.254/24` on `eth1`
  - Authentication: `ESI_Ring1_FW`

- `configs/firewall-01/nftables.conf`
- `configs/firewall-02/nftables.conf`
  - Default policy: DROP (deny-by-default)
  - Stateful filtering via conntrack
  - Explicit inter-cluster allow/deny rules

- `configs/firewall-common/startup-common.sh`
  - Shared package install and interface bootstrap
  - Health-check and Keepalived notifier generation
  - Common nftables/Keepalived startup path

- `configs/firewall-01/startup.sh`
- `configs/firewall-02/startup.sh`
  - Thin wrappers that set node-specific Ring 1 IP and border transit gateway

## Topology Connections

| Firewall    | Interface | Connected To | IP Address     |
| ----------- | --------- | ------------ | -------------- |
| firewall-01 | eth1      | leaf-01:eth5 | 192.168.1.1/24 |
| firewall-02 | eth1      | leaf-02:eth5 | 192.168.1.2/24 |

Both firewalls share the VIP: `192.168.1.254/24`.

## Keepalived Configuration

- VRRP instance: `Ring1_VIP`
- Virtual Router ID: `51`
- Advertisement interval: `1` second
- Health-check script: `/usr/local/bin/check_firewall_health.sh`
  - Runs every 2 seconds
  - Checks `eth1` link state
  - Verifies nftables is loaded
  - Validates basic route presence
  - Applies weight `-20` on failure

## Security Policy (nftables)

### Address Groups

- `cluster_1_pedagogy`: `192.168.10.0/24`, `192.168.20.0/24`
- `cluster_2_admin`: `192.168.50.0/24`, `192.168.60.0/24`
- `cluster_3_hpc`: `192.168.70.0/24`
- `cluster_5_storage`: `192.168.80.0/24`
- `cluster_4_orientation`: `192.168.90.0/24`
- `cluster_public_dmz`: `198.51.100.0/24`
- `cluster_lms_staff`: `192.168.30.0/24`

### Rule Set Overview

| Priority | Rule             | Source           | Destination      | Ports         | Action                       |
| -------- | ---------------- | ---------------- | ---------------- | ------------- | ---------------------------- |
| 1        | Stateful base    | Any              | Any              | Any           | ACCEPT (established/related) |
| 2        | Pedagogy→Storage | 192.168.10-20/24 | 192.168.80.0/24  | 111,2049,3260 | ACCEPT                       |
| 3        | Admin→Pedagogy   | 192.168.50-60/24 | 192.168.10-20/24 | 53,67-68,9100 | ACCEPT                       |
| 4        | Admin→Storage    | 192.168.50-60/24 | 192.168.80.0/24  | 111,2049,3260 | ACCEPT                       |
| 5        | Admin→HPC        | 192.168.50-60/24 | 192.168.70.0/24  | 6818-6830     | ACCEPT                       |
| 6        | Pedagogy→LMS     | 192.168.10-20/24 | 192.168.30.0/24  | 80,443        | ACCEPT                       |
| 7        | Pedagogy→Admin   | 192.168.10-20/24 | 192.168.50-60/24 | Any           | DROP                         |
| 8        | Orientation      | Any              | 192.168.90.0/24  | Any           | DROP                         |
| 9        | DMZ isolation    | 198.51.100.0/24 | Internal clusters | Any           | DROP                         |

### Cluster Notes

- Pedagogy:
  - `server-student-01`: `192.168.10.10`
  - `server-student-02`: `192.168.20.10` in Ring 1 branch documentation
- Admin:
  - `server-admin-01`: `192.168.50.10`
  - `server-admin-02`: `192.168.60.10`
- HPC:
  - `server-hpc-01`: `192.168.70.10`
  - `server-hpc-02`: `192.168.70.20`
- Storage:
  - `server-storage-01`: `192.168.80.10`
- LMS:
  - `lms-staff`: `192.168.30.10`
- DMZ:
  - `server-dmz-01`: `198.51.100.10`

## HA Failover Logic

### Master Election

1. `firewall-01` starts as MASTER with priority 101.
2. `firewall-02` starts as BACKUP with priority 100.
3. The VIP is initially owned by `firewall-01`.

### Failure Detection

When the health check fails on the MASTER:

1. Weight is reduced by 20.
2. `firewall-02` can take the MASTER role.
3. The VIP moves to the surviving node.
4. When `firewall-01` recovers, it can reclaim MASTER based on priority.

### Notification Hooks

- `notify_master.sh`
- `notify_backup.sh`
- `notify_fault.sh`

## Validation Assets

Added test scripts:

- `tests/firewall_policy_validation.sh`
- `tests/firewall_inpath_validation.sh`
- `tests/firewall_e2e_validation.sh`
- `tests/firewall_all_validation.sh`

These focus on:

- VIP reachability from the border leaf
- nftables policy presence
- observable in-path forwarding via firewall `eth1`
- DMZ isolation
- explicit pedagogy/admin/storage/HPC/LMS policy checks

## Stateful Filtering Model

The firewall relies on Linux connection tracking:

- `NEW`: initial session attempt
- `ESTABLISHED`: active bidirectional session
- `RELATED`: protocol-related follow-up traffic

This is what makes one-way rules work:

1. The initiator matches a `ct state new accept` rule.
2. Return traffic is accepted by `ct state established,related`.
3. Reverse-direction new connections still fall through to the default drop.

## Troubleshooting

### VIP Not Present

```bash
docker exec clab-esi-datacenter-firewall-01 ps aux | grep keepalived
docker exec clab-esi-datacenter-firewall-01 ip addr show eth1 | grep 192.168.1.254
docker exec clab-esi-datacenter-firewall-02 ip addr show eth1 | grep 192.168.1.254
```

### Rules Not Loaded

```bash
docker exec clab-esi-datacenter-firewall-01 nft list ruleset
docker exec clab-esi-datacenter-firewall-02 nft list ruleset
```

### Health Check

```bash
docker exec clab-esi-datacenter-firewall-01 cat /usr/local/bin/check_firewall_health.sh
docker exec clab-esi-datacenter-firewall-01 /usr/local/bin/check_firewall_health.sh
```
## 9100 port testing

```bash
# From admin cluster to pedagogy cluster:
# in server-student-01
nc -lvnp 9100

# in server-admin-01
nc -vz 192.168.10.10 9100

# expected result: 192.168.10.10 (192.168.10.10:9100) open
```
## Notes

- This Ring 1 merge must coexist with Theme T1 border-routing:
  - public/testnet DMZ reachability remains owned by T1
  - external BGP secrets/prefix-lists/max-prefix remain owned by T1
  - Prometheus/Grafana/frr-exporter remain owned by T1
- The firewall layer is intentionally added without removing T1 internet and
  observability assets.
