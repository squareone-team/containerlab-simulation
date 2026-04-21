# Core Services: DNS, DHCP, and NTP

This guide explains how to use the shared service nodes on the CORE-INFRA
subnet and how to verify them after a redeploy.

## Service Summary

- DNS server: `192.168.50.30`
- DHCP server: `192.168.50.40`
- NTP server: `192.168.50.20`
- Shared service subnet: `192.168.50.0/24`

## DNS

### What It Does

- `dns-server` runs Unbound on `bond0` at `192.168.50.30`.
- The startup script now prefers the mounted seed config at
  `/etc/unbound/unbound.conf.seed`, then copies it to the live
  `/etc/unbound/unbound.conf`.
- Internal clients can resolve `esi.internal`.
- The campus subnet `192.168.110.0/24` is included in the internal view.
- DMZ hostnames are published for internal and campus clients:
  - `dmz-server-01.esi.internal`
  - `dmz-web.esi.internal`
- DMZ clients in `198.51.100.0/24` still use the DMZ view and should not gain
  visibility into internal `esi.internal` records.

Relevant files:

- [`configs/dns-server/startup.sh`](../implementations/frr-containerlab/configs/dns-server/startup.sh)
- [`configs/dns-server/unbound.conf`](../implementations/frr-containerlab/configs/dns-server/unbound.conf)

### Internal DNS Lookup

```bash
docker exec clab-esi-datacenter-server-student-01 \
  sh -lc 'nslookup dmz-server-01.esi.internal 192.168.50.30'
```

Expected result:

- the answer resolves to `198.51.100.10`

### Campus DNS Lookup

```bash
docker exec clab-esi-datacenter-student-bp-01 \
  sh -lc 'nslookup dmz-server-01.esi.internal 192.168.50.30'
```

### DMZ Split-Horizon Check

```bash
docker exec clab-esi-datacenter-server-dmz-01 \
  sh -lc 'nslookup dns-server.esi.internal 192.168.50.30 || true'
```

Expected result:

- the DMZ client should not receive normal internal DNS visibility

## DHCP

### What It Does

- `dhcp-server` runs Kea DHCPv4 on `bond0` at `192.168.50.40`.
- The service advertises:
  - DNS server option `192.168.50.30`
  - NTP server option `192.168.50.20`
  - domain name `esi.internal`
- Kea is configured with pools and reservations for the service and workload
  subnets.
- Access leaves relay DHCP requests toward `192.168.50.40`.

Relevant file:

- [`configs/dhcp-server/startup.sh`](../implementations/frr-containerlab/configs/dhcp-server/startup.sh)

### Recommended DHCP Smoke Test

Use `lms-staff` for a manual DHCP test because it has a single data-plane
interface and is easier to reset than the bonded server nodes.

Request a lease:

```bash
docker exec clab-esi-datacenter-lms-staff sh -lc '
  ip addr flush dev eth1
  ip route del default 2>/dev/null || true
  udhcpc -n -q -f -i eth1 -t 5 -T 3
'
```

or for bond0:
```bash
docker exec clab-esi-datacenter-server-hpc-01 /bin/sh -lc '
  ip addr flush dev bond0
  udhcpc -f -q -n -t 3 -T 3 -i bond0
'
```
works also with server-student-01/02, server-storage-01, and server-admin-01/02
to recover from a failed DHCP:
```bash
docker exec clab-esi-datacenter-server-student-01 /bin/sh -lc '
  ip addr add 192.168.70.10/24 dev bond0
  ip route del default 2>/dev/null
'
```

Expected result:

- `udhcpc` should obtain a lease from `192.168.50.40`
- the assigned address should come from the `192.168.30.100 - 192.168.30.200`
  pool

Restore the original static address afterward:

```bash
docker exec clab-esi-datacenter-lms-staff sh -lc '
  ip addr flush dev eth1
  ip addr add 192.168.30.10/24 dev eth1
  ip route add default via 192.168.30.1 dev eth1
'
```

Note:

- BusyBox `udhcpc` may print a `resolv.conf` rename warning inside these
  containers. If the lease is obtained, the DHCP path is still working.

### DHCP Server Health Checks

```bash
docker exec clab-esi-datacenter-dhcp-server \
  sh -lc 'pgrep -a kea-dhcp4; ss -lunp | grep ":67"'
```

## NTP

### What It Does

- `ntp-server` provides the shared time source at `192.168.50.20`.
- Server and service nodes start their client hook from
  `configs/ntp-server/server-client-ntp.sh`.
- Representative workload nodes should converge on `192.168.50.20` as their
  active chrony source after startup settles.

### NTP Verification

```bash
docker exec clab-esi-datacenter-server-admin-01 chronyc tracking
docker exec clab-esi-datacenter-server-admin-01 chronyc sources -v
```

Expected result:

- `Reference ID` should map to `192.168.50.20`
- `chronyc sources -v` should show `^* 192.168.50.20`

You can run the same check on other representative nodes:

```bash
docker exec clab-esi-datacenter-server-hpc-01 chronyc sources -v
docker exec clab-esi-datacenter-server-storage-01 chronyc sources -v
docker exec clab-esi-datacenter-server-student-01 chronyc sources -v
```

