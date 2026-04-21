# Campus Edge and DMZ Access

This guide explains how the campus test segment reaches shared services and the
DMZ web endpoint.

## What This Feature Adds

- `campus-bp` now owns the campus client subnet `192.168.110.0/24`.
- `student-bp-01` is a long-lived test client on `192.168.110.30/24`.
- `server-dmz-01` now runs as a real DMZ web node at `198.51.100.10/24`.
- `leaf-01`, `leaf-02`, and the HA firewall pair provide narrow policy and
  routing for campus access to:
  - DNS at `192.168.50.30`
  - NTP at `192.168.50.20`
  - DHCP at `192.168.50.40`
  - HTTP to the DMZ subnet `198.51.100.0/24`

## Components

- Campus border node:
  [`configs/campus-bp/startup.sh`](../implementations/frr-containerlab/configs/campus-bp/startup.sh)
- Campus client:
  [`configs/student-bp-01/startup.sh`](../implementations/frr-containerlab/configs/student-bp-01/startup.sh)
- DMZ server:
  [`configs/server-dmz-01/startup.sh`](../implementations/frr-containerlab/configs/server-dmz-01/startup.sh)
- Border leaf policy and routing:
  [`configs/leaf-01/startup.sh`](../implementations/frr-containerlab/configs/leaf-01/startup.sh),
  [`configs/leaf-01/frr.conf`](../implementations/frr-containerlab/configs/leaf-01/frr.conf),
  [`configs/leaf-02/startup.sh`](../implementations/frr-containerlab/configs/leaf-02/startup.sh)
- Firewall policy:
  [`configs/firewall-01/nftables.conf`](../implementations/frr-containerlab/configs/firewall-01/nftables.conf),
  [`configs/firewall-02/nftables.conf`](../implementations/frr-containerlab/configs/firewall-02/nftables.conf)

## Addressing

- Campus client segment: `192.168.110.0/24`
- Campus gateway on `campus-bp`: `192.168.110.1`
- Campus client test host: `192.168.110.30`
- Campus service transit to `leaf-01`: `10.200.0.2/30`
- DMZ web server: `198.51.100.10`

## How To Use It

### 1. Redeploy the topology

```bash
sudo containerlab deploy -t implementations/frr-containerlab/esi-datacenter.clab.yml --reconfigure
```

### 2. Resolve the DMZ hostname from the campus client

`student-bp-01` is configured with `192.168.50.30` as its resolver and a
`search esi.internal` domain.

```bash
docker exec clab-esi-datacenter-student-bp-01 \
  sh -lc 'nslookup dmz-server-01.esi.internal 192.168.50.30'
```

Expected result:

- the answer should resolve to `198.51.100.10`

### 3. Reach the DMZ web page from the campus client

```bash
docker exec clab-esi-datacenter-student-bp-01 \
  sh -lc 'curl -s http://dmz-server-01.esi.internal'
```

Expected result:

- the response contains the `dmz-server-01` HTML page

### 4. Reach the DMZ service directly from the campus border node

This is useful when you want to test the routed path without relying on the
client resolver.

```bash
docker exec clab-esi-datacenter-campus-bp \
  sh -lc 'wget -qO- http://198.51.100.10'
```

Expected result:

- the command returns the DMZ page HTML

## What Is Intentionally Allowed

- Campus hosts can reach DNS, NTP, and DHCP on the CORE-INFRA subnet.
- Campus hosts can reach the DMZ test web service on TCP/80.
- Student VRFs can also reach the DMZ test web service on TCP/80.

## What Is Still Intentionally Restricted

- The DMZ is not a general-purpose internal access zone.
- Firewall policy still blocks broad DMZ-to-internal access.
- Only the explicitly routed and permitted service IPs are exposed to the
  campus edge.

## Implementation Notes

- `student-bp-01` uses `cmd: sleep infinity` plus `exec: sh /startup.sh` in
  the topology so the container stays alive for interactive testing.
- `campus-bp` bridges the campus client port on `eth4`, uses `eth3` as the
  service transit toward `leaf-01`, and uses `eth1` as its upstream/default
  route side.

