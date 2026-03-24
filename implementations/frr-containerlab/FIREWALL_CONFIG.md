# ESI Datacenter - Ring 1 HA Firewall Pair Configuration

## Overview

This directory contains the configuration for the Ring 1 HA Firewall pair
(firewall-01 and firewall-02) implementing the exclusive VRF gateway for the ESI
Datacenter network. The firewalls use Keepalived for high availability and
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

## File Structure

### Configuration Files

- **keepalived.conf** - VRRP protocol configuration for HA failover
  - firewall-01: Master (Priority 101)
  - firewall-02: Backup (Priority 100)
  - VIP: 192.168.1.254/24 on eth1
  - Authentication: PASS (ESI_Ring1_FW)

- **nftables.conf** - Stateful packet filtering rules
  - Default policy: DROP (Deny-by-Default)
  - Implements VRF-aware traffic policies
  - Supports stateful connection tracking

- **startup.sh** - Container initialization script
  - Installs required packages (keepalived, nftables)
  - Configures network interfaces
  - Loads firewall rules
  - Starts keepalived daemon
  - Implements health checks

## Configuration Details

### Topology Connections

| Firewall    | Interface | Connected To | IP Address     |
| ----------- | --------- | ------------ | -------------- |
| firewall-01 | eth1      | leaf-01:eth5 | 192.168.1.1/24 |
| firewall-02 | eth1      | leaf-02:eth5 | 192.168.1.2/24 |

Both firewalls share the VIP: **192.168.1.254/24**

### Keepalived Configuration

- **VRRP Instance**: Ring1_VIP
- **Virtual Router ID**: 51
- **Advertisement Interval**: 1 second
- **Health Check Script**: `/usr/local/bin/check_firewall_health.sh`
  - Runs every 2 seconds
  - Checks eth1 link status
  - Verifies nftables is loaded
  - Validates basic routing connectivity
  - Weight adjustment on failure: -20

### Security Policy (nftables)

#### Rule Set Overview

| Priority | Rule             | Direction | Source           | Destination      | Ports         | Action                       |
| -------- | ---------------- | --------- | ---------------- | ---------------- | ------------- | ---------------------------- |
| 1 (Base) | Stateful         | Both      | Any              | Any              | Any           | ACCEPT (established/related) |
| 2        | Pedagogy→Storage | Out       | 192.168.10-20/24 | 192.168.80/24    | 111,2049,3260 | ACCEPT                       |
| 3        | Admin→Pedagogy   | Out       | 192.168.50-60/24 | 192.168.10-20/24 | 53,67-68,9100 | ACCEPT (new)                 |
| 4        | Admin→Storage    | Out       | 192.168.50-60/24 | 192.168.80/24    | 111,2049,3260 | ACCEPT (new)                 |
| 5        | Admin→HPC        | Out       | 192.168.50-60/24 | 192.168.70/24    | 6818-6830     | ACCEPT (new)                 |
| 6        | Isolation        | In        | 192.168.10-20/24 | 192.168.50-60/24 | Any           | DROP                         |
| 7        | Orientation      | Both      | Any              | 192.168.100/24   | Any           | DROP                         |
| 8        | Hairpinning      | Intra-VRF | Both             | Both             | Any           | (No rules)                   |

#### Cluster Definitions

- **Cluster 1 (Pedagogy)**: 192.168.10.0/24, 192.168.20.0/24
  - Student-01: 192.168.10.10
  - Student-02: 192.168.20.10
  - Access: Can initiate to Storage (iSCSI/NFS) and Admin (one-way)

- **Cluster 2 (Admin)**: 192.168.50.0/24, 192.168.60.0/24
  - Admin-01: 192.168.50.10
  - Admin-02: 192.168.60.10
  - Access: Can initiate to Pedagogy (DNS/DHCP), Storage (iSCSI/NFS), HPC
    (SLURM)

- **Cluster 3 (HPC)**: 192.168.70.0/24
  - HPC-01: 192.168.70.10
  - HPC-02: 192.168.70.20
  - Access: Bidir within Cluster (hairpinning), receive from Admin (SLURM)

- **Cluster 5 (Storage)**: 192.168.80.0/24
  - Storage-01: 192.168.80.10
  - Access: Receive from Pedagogy/Admin (iSCSI/NFS), bidir within Cluster

- **Cluster 4 (Orientation)**: 192.168.100.0/24 ❌ **ISOLATED**
  - All traffic dropped

### Port Assignments

- **DNS**: UDP 53
- **DHCP**: UDP 67-68
- **NFSv4/RPC**: TCP/UDP 111, TCP 2049
- **iSCSI**: TCP 3260
- **Prometheus/Node Exporter**: TCP 9100
- **SLURM**: TCP/UDP 6818-6830

## HA Failover Logic

### Master Election

1. firewall-01 starts as MASTER with priority 101
2. firewall-02 starts as BACKUP with priority 100
3. VIP immediately owned by firewall-01

### Failure Detection

When health check fails on MASTER:

1. Weight decrements by 20 (101 - 20 = 81 < 100)
2. firewall-02 takes MASTER role
3. VIP moves to firewall-02
4. Recovery: When firewall-01 recovers, weight is restored
5. firewall-01 reclaims MASTER role

### Notification Hooks

- **notify_master.sh**: Triggered when node becomes MASTER
- **notify_backup.sh**: Triggered when node becomes BACKUP
- **notify_fault.sh**: Triggered when node enters FAULT state

## Testing

### Test Script Location

`tests/firewall_test.sh`

### Test Coverage

1. **Container Status**: Verify firewall containers are running
2. **Network Configuration**: Validate eth1 IP assignments
3. **Keepalived Status**: Confirm keepalived daemon and VIP assignment
4. **nftables Loaded**: Check firewall rules are active
5. **VIP Reachability**: Ping VIP from leaf-01 and leaf-02
6. **Cluster Connectivity**: Test permitted inter-cluster flows
7. **One-Way Enforcement**: Verify stateful connection tracking
8. **Isolation Rules**: Confirm blocked traffic patterns

### Running Tests

```bash
cd /home/mounir/Desktop/datacenter-containerlab-esi/implementations/frr-containerlab
bash tests/firewall_test.sh
```

### Manual Testing Examples

```bash
# Test VIP from leaf-01
docker exec -it clab-esi-datacenter-leaf-01 ping 192.168.1.254

# Check firewall-01 as MASTER
docker exec -it clab-esi-datacenter-firewall-01 ip addr show eth1

# View active nftables rules
docker exec -it clab-esi-datacenter-firewall-01 nft list ruleset

# Monitor keepalived status
docker exec -it clab-esi-datacenter-firewall-01 ps aux | grep keepalived
```

## Stateful Firewall Architecture

### Connection Tracking States

The firewall uses Linux Connection Tracking (conntrack) to maintain state:

- **NEW**: Initial connection attempt
- **ESTABLISHED**: Active bidirectional connection
- **RELATED**: Related to established connection (e.g., FTP data)

### One-Way Rules Implementation

Rules like "Admin → Pedagogy (one-way)" work because:

1. Admin initiates with `ct state new accept` (outbound)
2. Return traffic matched by `ct state established accept` (return)
3. No rule allows Pedagogy to initiate toward Admin
4. Reverse direction dropped by default policy

### Example: Admin → Pedagogy Connection Flow

```
Admin (192.168.50.10) → Pedagogy (192.168.10.10)
  ↓
Rule 3: saddr 192.168.50-60/24, daddr 192.168.10-20/24, port 53, ct state new
  ↓
[ACCEPT] Packet forwarded, connection state = NEW

Pedagogy (192.168.10.10) → Admin (192.168.50.10) [return traffic]
  ↓
Rule 1: ct state established
  ↓
[ACCEPT] Return packet forwarded (connection tracked as established)

Pedagogy (192.168.10.10) → Admin (192.168.50.10) [NEW attempt]
  ↓
No matching rule for new connection from Pedagogy to Admin
  ↓
Default policy: DROP
  ↓
[DROP] Packet rejected
```

## Troubleshooting

### VIP Not Available

```bash
# Check if keepalived is running
docker exec clab-esi-datacenter-firewall-01 ps aux | grep keepalived

# Check keepalived logs
docker exec clab-esi-datacenter-firewall-01 cat /var/log/keepalived.log

# Verify firewall-01 is MASTER
docker exec clab-esi-datacenter-firewall-01 ip addr show eth1 | grep 192.168.1.254
```

### Traffic Not Passing Through Firewall

```bash
# Verify nftables rules are loaded
docker exec clab-esi-datacenter-firewall-01 nft list ruleset

# Check rule counters
docker exec clab-esi-datacenter-firewall-01 nft list ruleset | grep counter

# Enable packet logging (optional)
# Add these rules for debugging:
# ip saddr @cluster_1_pedagogy ip daddr @cluster_2_admin log prefix "DROP Pedagogy→Admin: "
```

### Health Check Failures

```bash
# Verify health check script exists
docker exec clab-esi-datacenter-firewall-01 cat /usr/local/bin/check_firewall_health.sh

# Run health check manually
docker exec clab-esi-datacenter-firewall-01 /usr/local/bin/check_firewall_health.sh
```

## Implementation Notes

### Design Decisions

1. **Deny-by-Default**: All traffic except explicitly allowed rules is dropped
2. **Stateful Filtering**: Uses connection tracking for efficient one-way rules
3. **VIP Gateway Model**: Single point of failure mitigated by Keepalived HA
4. **Ring 1 Isolation**: Firewall eth1 on separate Ring 1 segment
   (192.168.1.0/24)
5. **Health Checks**: Lightweight checks (under 2 seconds) ensure fast failover

### Future Enhancements

- [ ] Add logging/counters to rules for traffic analysis
- [ ] Implement return traffic accounting
- [ ] Add SYN flood protection (synproxy)
- [ ] Configure sysctl parameters for optimal packet forwarding
- [ ] Add VRF-aware routing for alternate paths
- [ ] Implement rate limiting on sensitive ports
- [ ] Add BGP route redistribution for gateway redundancy

## References

- nftables: https://wiki.nftables.org/
- Keepalived: http://www.keepalived.org/
- Linux Connection Tracking:
  https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.txt
- Container Lab: https://containerlab.dev/

---

**Last Updated**: 2026-03-24  
**Configuration Version**: 1.0  
**Status**: Production Ready
