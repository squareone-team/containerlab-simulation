# ESI Datacenter — Spine-Leaf Lab

Modern Spine-Leaf datacenter topology for **ESI (École nationale Supérieure d'Informatique)**, built with [ContainerLab](https://containerlab.dev) and designed for future automation via **Ansible**.

## Objective

Deploy and validate a production-grade EVPN/VXLAN Spine-Leaf fabric in a lightweight, reproducible container environment — serving as the foundation for campus network services (pedagogical, research, services, and AI zones).

## Topology Overview

```
                ┌───────────┐   ┌───────────┐
                │  spine-01 │   │  spine-02 │    ASN 65000 (Route Reflectors)
                └─┬──┬──┬──┘   └──┬──┬──┬──┘
                  │  │  │  ╲    ╱  │  │  │
       ┌──────────┘  │  │   ╲╱    │  │  └──────────┐
       │     ┌───────┘  │   ╱╲    │  └───────┐     │
       │     │    ┌─────┘  ╱  ╲   └─────┐   │     │
       ▼     ▼    ▼       ╱    ╲        ▼   ▼     ▼
   ┌──────┬──────┬──────┬──────┬──────────┬──────────┐
   │leaf  │leaf  │leaf  │leaf  │ border   │ border   │
   │ -01  │ -02  │ -03  │ -04  │  -01     │  -02     │
   │65001 │65002 │65003 │65004 │  65005   │  65005   │
   └──┬───┴──┬───┴──┬───┴──┬───┴──────────┴──────────┘
      │      │      │      │
   Pedagogy Research Svc   AI       External uplinks
```

| Zone | Leaf | ASN | VLANs / VNIs | Subnets |
|---|---|---|---|---|
| Pedagogical | leaf-01 | 65001 | VNI 10010, 10020 | 192.168.10.0/24, 192.168.20.0/24 |
| Research | leaf-02 | 65002 | VNI 10030, 10040 | 192.168.30.0/24, 192.168.40.0/24 |
| Services | leaf-03 | 65003 | VNI 10050, 10060 | 192.168.50.0/24, 192.168.60.0/24 |
| AI / GPU | leaf-04 | 65004 | VNI 10080 | 192.168.80.0/24 |
| Border | border-01/02 | 65005 | — | External uplinks |

## Tools & Images

| Component | Image | Size | Purpose |
|---|---|---|---|
| Switches (spines, leaves, borders) | `frrouting/frr:latest` | ~150 MB | Full routing stack — BGP, EVPN, VXLAN |
| Servers (end-hosts) | `alpine:latest` | ~5 MB | Lightweight traffic endpoints |

**ContainerLab** orchestrates the topology (nodes, links, bind-mounts) from a single YAML file.  
**Ansible** will be used in a later phase to push routing configurations (BGP underlay, EVPN overlay, VXLAN tunnels) to all FRR nodes programmatically.

## Repository Structure

```
esi-datacenter/
├── spin-topology.clab.yml          # ContainerLab topology definition
├── spin-topology.clab.yml.annotations         # saves topology graph and node details after deployment
├── configs/
│   ├── spine-01/                   # Per-node FRR config
│   │   ├── daemons                 #   enabled routing daemons
│   │   └── frr.conf                #   FRR running configuration
│   ├── spine-02/
│   ├── leaf-01/
│   ├── leaf-02/
│   ├── leaf-03/
│   ├── leaf-04/
│   ├── border-01/
│   └── border-02/
└── README.md
```

## Quick Start

```bash
# Prerequisites: containerlab installed (https://containerlab.dev/install/)

# Deploy the lab
cd esi-datacenter
sudo containerlab deploy -t spin-topology.clab.yml

# Verify
sudo containerlab inspect -t spin-topology.clab.yml

# Access a switch
docker exec -it clab-esi-datacenter-spine-01 vtysh

# Access a server
docker exec -it clab-esi-datacenter-host-pedagogy-01 sh

# Destroy the lab ( doesn't delete the config files, so you can redeploy quickly )
sudo containerlab destroy -t spin-topology.clab.yml
```
