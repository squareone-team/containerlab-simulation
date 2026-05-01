# ESI DATA CENTER
## Architecture Specification

---

## 0. Current State & Migration Context

This section documents the existing ESI infrastructure as collected during the on-site interview (Week 2). It is provided as context for the migration rationale. The target architecture defined from Section 1 onwards is designed independently of legacy constraints — no assumption is made about reusing existing switches or cabling.

| Dimension | Current State |
|---|---|
| Network Topology | Extended star with bus (étoile étendue avec bus). Not a 3-tier model. No distinct Core/Distribution/Access hierarchy. Primary driver for migration. |
| External Uplinks | Two active lines: (1) Algérie Télécom optical fibre, (2) FH microwave link. Both in production simultaneously. A third dedicated fibre line is added during the BAC orientation operation and physically isolated from the school network. |
| Segmentation | Two VLANs: Administrative and Student. No hardware-enforced inter-zone policy. No VRF isolation. |
| Servers | Approximately 40 physical servers. All run VMware ESXi with multiple VMs per host. Veeam Backup & Replication used for VM-level backup across the fleet. |
| Virtualization Plan | Migration to OpenStack is planned but not yet implemented. The target architecture is designed to be hypervisor-agnostic: ESXi hosts connect to Leaf access ports exactly as bare-metal servers would. |
| Scalability Limits | No automated configuration management. Static network paths. Horizontal scaling requires physical re-architecture. Congestion occurs at distribution (BP) switches where EtherChannel is used as a partial mitigation. |
| Monitoring | Cacti (bandwidth monitoring, currently in use). Zabbix (recommended for replacement — infrastructure monitoring, alerting, and threshold-based notifications). |

**Migration principle:** The two existing external uplinks (Algérie Télécom fibre + FH microwave) will terminate on the Border Leaf pair in the new architecture, preserving dual-homed external connectivity. The BAC orientation third line will attach to a dedicated interface on the Border Leafs with routing confined to VRF-ORIENTATION — it has zero routing adjacency with the school's production network by design.

---

## 1. Executive Summary

This document defines the authoritative structural blueprint for the ESI campus data center. The design replaces a fragile legacy Layer-2 flat network with a modern, software-defined routed fabric governed by three non-negotiable principles: minimalism (every component must earn its place), extensibility (scaling must not require redesign), and performance (latency and bandwidth must be deterministic).

The chosen protocol stack — eBGP underlay, VXLAN data-plane, MP-BGP EVPN control plane — represents the current industry standard for campus and enterprise data centers. It is vendor-neutral, RFC-backed, and the only stack that simultaneously delivers L2 extension, L3 routing, and hardware-enforced macro-segmentation without proprietary dependencies.

---

## 2. Design Principles & Constraints

All architectural decisions in this document are evaluated against the following ordered criteria. When a trade-off is required, higher-ranked principles take precedence.

| Priority | Principle | Implication |
|---|---|---|
| 1 | Reasoning Clarity | The full topology must fit in one engineer's head. No component is added unless every member of the team can explain why it exists. |
| 2 | Extensibility | Adding compute, storage, or a new functional pod must require zero re-architecture of the control or data plane. |
| 3 | Performance | Latency must be deterministic. Bandwidth scaling must be horizontal. AI/HPC workloads must never compete for bandwidth with administrative traffic. |
| 4 | Security by Default | Isolation is hardware-enforced via VRFs. Trust is never assumed — all inter-zone traffic must traverse an explicit policy gateway. |

---

## 3. Physical Network Underlay

### 3.1 Topology: Non-Blocking Two-Tier Clos (Spine-Leaf)

All Leaf switches connect to all Spine switches in a full mesh. No Leaf-to-Leaf links exist. This guarantees that any two endpoints are separated by exactly two hops, eliminating the unpredictable latency inherent in legacy three-tier designs. Bandwidth scales horizontally: adding a Spine switch increases aggregate fabric bandwidth without touching existing configurations.

> **Justification:** Traditional three-tier (Access-Distribution-Core) introduces oversubscription and STP instability. Spine-Leaf removes both by design.

### 3.2 Underlay Control Plane: eBGP (RFC 7938)

eBGP is used as the sole underlay routing protocol. Each Spine runs in a shared AS (65000). Each Leaf pair operates in its own unique AS (65001–6500x). Loopback addresses are the only prefixes advertised — no subnets, no host routes. BFD (Bidirectional Forwarding Detection) is enabled on all BGP sessions to achieve sub-second failure detection.

> **Justification for eBGP over OSPF/IS-IS:** Link-state IGPs flood topology changes to the entire network on every link failure. eBGP isolates failure domains at AS boundaries. AS-Path manipulation provides deterministic traffic engineering. eBGP also scales linearly with fabric density, where OSPF LSA storms degrade in large environments.

> **Why not iBGP:** iBGP requires full-mesh or a Route Reflector hierarchy, adding operational complexity. eBGP per-leaf-pair achieves the same result with simpler configuration.

### 3.3 ASN & IP Addressing Summary

| Device Role | AS Number | Loopback Range | Notes |
|---|---|---|---|
| Spine 1 & 2 | 65000 | 10.0.0.1 – 10.0.0.2/32 | Shared AS — prevents path loops |
| Leaf Pair 1 (Border) | 65001 | 10.0.1.1 – 10.0.1.2/32 | ESI L1/L2 |
| Leaf Pair 2 (Admin) | 65002 | 10.0.2.1 – 10.0.2.2/32 | ESI L3/L4 |
| Leaf Pair 3 (AI/HPC) | 65003 | 10.0.3.1 – 10.0.3.2/32 | ESI L5/L6 — 100G uplinks |
| Leaf Pair 4 (Storage) | 65004 | 10.0.4.1 – 10.0.4.2/32 | ESI L7/L8 |
| Leaf Pair 5 (Student) | 65005 | 10.0.5.1 – 10.0.5.2/32 | ESI L9/L10 — 4:1 oversubscription |

### 3.4 Full IP Addressing Plan

All point-to-point inter-switch links use /31 subnets (RFC 3021 — exactly two usable addresses, no broadcast waste). Loopback interfaces use /32. Two address blocks are reserved exclusively for the underlay: 10.0.0.0/16 for P2P links and 10.1.0.0/24 for loopbacks. These blocks must never be advertised externally.

| Node | Loopback0 Address | Role / Notes |
|---|---|---|
| spine-01 | 10.1.0.1/32 | Spine — VTEP source, EVPN RR |
| spine-02 | 10.1.0.2/32 | Spine — VTEP source, EVPN RR |
| border-leaf-01 | 10.1.0.11/32 | Border Leaf pair A — external uplink, VRF-PUBLIC |
| border-leaf-02 | 10.1.0.12/32 | Border Leaf pair B — external uplink, VRF-PUBLIC |
| admin-leaf-01 | 10.1.0.13/32 | Admin pod Leaf A |
| admin-leaf-02 | 10.1.0.14/32 | Admin pod Leaf B |
| hpc-leaf-01 | 10.1.0.15/32 | AI/HPC pod Leaf A — 100G uplinks |
| hpc-leaf-02 | 10.1.0.16/32 | AI/HPC pod Leaf B — 100G uplinks |
| storage-leaf-01 | 10.1.0.17/32 | Storage pod Leaf A |
| storage-leaf-02 | 10.1.0.18/32 | Storage pod Leaf B |
| student-leaf-01 | 10.1.0.19/32 | Student/Lab pod Leaf A |
| student-leaf-02 | 10.1.0.20/32 | Student/Lab pod Leaf B |

P2P links follow a strict /31 allocation within 10.0.0.0/16. Spine-01 uplinks occupy 10.0.0.x; Spine-02 uplinks occupy 10.0.1.x. Within each block, links are assigned in the same order as the loopback table above (border-leaf first, student-leaf last). The .0 address always belongs to the Spine; the .1 address to the Leaf.

| Link | Spine Side | Leaf Side | Subnet |
|---|---|---|---|
| spine-01 ↔ border-leaf-01 | 10.0.0.0 | 10.0.0.1 | 10.0.0.0/31 |
| spine-01 ↔ border-leaf-02 | 10.0.0.2 | 10.0.0.3 | 10.0.0.2/31 |
| spine-01 ↔ admin-leaf-01 | 10.0.0.4 | 10.0.0.5 | 10.0.0.4/31 |
| spine-01 ↔ admin-leaf-02 | 10.0.0.6 | 10.0.0.7 | 10.0.0.6/31 |
| spine-01 ↔ hpc-leaf-01 | 10.0.0.8 | 10.0.0.9 | 10.0.0.8/31 |
| spine-01 ↔ hpc-leaf-02 | 10.0.0.10 | 10.0.0.11 | 10.0.0.10/31 |
| spine-01 ↔ storage-leaf-01 | 10.0.0.12 | 10.0.0.13 | 10.0.0.12/31 |
| spine-01 ↔ storage-leaf-02 | 10.0.0.14 | 10.0.0.15 | 10.0.0.14/31 |
| spine-01 ↔ student-leaf-01 | 10.0.0.16 | 10.0.0.17 | 10.0.0.16/31 |
| spine-01 ↔ student-leaf-02 | 10.0.0.18 | 10.0.0.19 | 10.0.0.18/31 |
| spine-02 ↔ border-leaf-01 | 10.0.1.0 | 10.0.1.1 | 10.0.1.0/31 |
| spine-02 ↔ border-leaf-02 | 10.0.1.2 | 10.0.1.3 | 10.0.1.2/31 |
| spine-02 ↔ (same pattern…) | 10.0.1.4+ | — | 10.0.1.4/31 through 10.0.1.18/31 — mirrors spine-01 block |

Only loopbacks are advertised into eBGP: P2P /31 links are never redistributed into BGP. Only each node's Loopback0 /32 is announced. This keeps the BGP RIB minimal: 12 loopback prefixes total, regardless of fabric growth.

### 3.5 North-South Border Connectivity & Border Leaf Role

The fabric uses a dedicated Border Leaf pair (a distinct role from Access Leafs) as the single attachment point for all external connectivity. Border Leafs connect upward to both Spines and outward to the Border Routers and HA Firewalls. This separation of concerns isolates all external routing churn — BGP reconvergence, DDoS absorption, prefix fluctuations — entirely from the compute-facing Access Leafs.

The school operates three ISP uplinks. Two are active simultaneously during normal operation: Algérie Télécom optical fibre and an FH microwave link. A third dedicated fibre is activated exclusively during the BAC orientation operation. This third uplink terminates on a dedicated Border Leaf interface with routing confined to VRF-ORIENTATION — it has zero routing adjacency with the school's production network by design.

### 3.6 BGP Session Hardening

Beyond basic eBGP peering, two hardening mechanisms are applied to all BGP sessions. These are not optional: an unprotected BGP session is a direct path to fabric-wide routing manipulation.

| Mechanism | Scope | Threat Addressed |
|---|---|---|
| TCP MD5 Authentication (RFC 2385) | All BGP sessions | MD5 adds an HMAC signature to every TCP segment. Any BGP UPDATE not carrying a valid HMAC is silently discarded before the routing daemon processes it. Prevents forged BGP UPDATE injection from a host on the same L2 segment. Two distinct secrets are used: one for external sessions (Border Leafs ↔ ISP), one for internal fabric sessions — a leak of the external secret does not compromise the fabric. |
| Max-Prefix Guard | Border Leafs (external sessions) | Sets a hard ceiling on the number of prefixes accepted from an external BGP peer. If the peer advertises more than the threshold, the session is torn down immediately. Prevents memory exhaustion from a misconfigured or malicious upstream peer sending a full internet routing table. |

---

## 4. Compute Architecture: Functional Pod Design

Workloads are grouped into five functional pods, each served by a dedicated Leaf pair. Pod assignment is determined by traffic profile and security classification, not by administrative convenience. This ensures that hardware oversubscription ratios match actual traffic patterns and that security boundaries are physically expressed in the cabling topology.

| Pod | Leaf Pair | Key Services | Oversubscription | Justification |
|---|---|---|---|---|
| 1 — Border / DMZ | L1/L2 | Border Router, HA Firewalls, DMZ VMs, Sophos, Web Servers | 2:1 | Traffic capped by ISP bandwidth; no need for higher ratio. |
| 2 — Admin / Core Infra | L3/L4 | AD, DNS, DHCP, NTP, HR/Finance, Ansible Tower, Grafana/Prometheus | 3:1 | Chatty but low-volume services. Tight micro-seg keeps it isolated. |
| 3 — AI / HPC | L5/L6 | GPU Servers, SLURM HPC Nodes | 1:1 | Non-blocking mandatory. GPU training saturates 100G links for hours. |
| 4 — Storage / Backup | L7/L8 | SAN (block), NAS (file), FTP, Backup & Replication | 1:1–1.5:1 | Sustained throughput. A single backup can saturate a link for hours. |
| 5 — Student / Lab | L9/L10 | Lab VMs, TP Servers, Teaching Hypervisors, WiFi Controllers, Campus Uplinks, Access Points (APs) | 4:1 | Student traffic is bursty and unpredictable; high oversubscription acceptable. Campus APs (max 30 simultaneous clients each) and building uplinks terminate here. |

In addition to the five compute pods, a dedicated Out-of-Band (OOB) management switch (L11) connects to every device's management port in an isolated Layer-2 segment. This switch is never part of the EVPN fabric and has no route into the production network. Its sole purpose is emergency access when the fabric is unreachable due to a misconfiguration.

> **OOB Justification:** When a Spine or Leaf drops all BGP sessions due to a bad config push, the OOB provides the only path back in. It is the single most cost-effective resilience investment in the entire design.

---

## 5. Network Overlay: EVPN / VXLAN

### 5.1 Data Plane: VXLAN

VXLAN (Virtual eXtensible LAN) encapsulates original Ethernet frames in a UDP header with a 24-bit Network Identifier (VNI), creating up to 16 million logical Layer-2 segments over a standard IP underlay. Each functional pod's VLANs are locally significant only to the Leaf pair; they are mapped to a globally unique VNI at the VTEP (VXLAN Tunnel Endpoint) before entering the fabric.

> **Why VXLAN over VLAN:** Traditional VLANs are limited to 4094 IDs and propagate across the entire switching domain via STP. VXLAN removes both constraints and eliminates STP entirely.

### 5.2 Control Plane: MP-BGP EVPN

MAC and IP reachability information is distributed via MP-BGP EVPN route types rather than by flooding. This eliminates ARP/unknown unicast flooding at scale and makes the control plane auditable — any reachability issue can be diagnosed by inspecting BGP routing tables rather than sniffing broadcast traffic.

| EVPN Route Type | Purpose | Usage in This Design |
|---|---|---|
| Type 2 | MAC/IP Advertisement | Distributes host MAC and IP bindings from each Leaf. Allows remote Leafs to answer ARP requests locally without flooding. |
| Type 3 | Inclusive Multicast | Handles unavoidable BUM (Broadcast, Unknown Unicast, Multicast) traffic via Ingress Replication. PIM is not required. |
| Type 5 | IP Prefix Route | Enables inter-subnet routing between VRFs via the Spine layer. Required for any authorized cross-zone communication. |

### 5.3 ESI Multihoming (Replaces MLAG)

Servers connect to both switches in a Leaf pair using standard LACP bonding. Each bonded group is identified by an Ethernet Segment Identifier (ESI), which is advertised into EVPN as a Type 1 route. Link state and active-forwarder election are synchronized via the BGP control plane over existing uplinks — no proprietary inter-switch peer-link is required.

> **Why ESI over MLAG:** MLAG requires a vendor-specific peer-link cable and limits redundancy to exactly two switches. ESI is standards-based (RFC 7432), uses existing BGP uplinks for synchronization, and supports N-way redundancy as the design grows.

### 5.4 DF Election & Split Horizon

ESI multihoming introduces two correctness problems that EVPN solves automatically via protocol mechanisms. Both are mandatory — without them, dual-homed servers receive duplicate frames or cause forwarding loops.

| Mechanism | Problem Solved & How |
|---|---|
| DF Election (Designated Forwarder) | **Problem:** both Leafs in a pair receive BUM traffic destined for a dual-homed server. Without coordination, the server receives every broadcast frame twice. **Solution:** EVPN elects exactly one Designated Forwarder per Ethernet Segment. Only the DF Leaf forwards BUM traffic into that segment; the non-DF Leaf discards it. Election is deterministic, based on the Leaf's loopback IP modulo the number of candidates. |
| Split Horizon | **Problem:** a Leaf receives a frame from a dual-homed server and re-floods it toward the other Leaf in the same ESI segment, causing a loop. **Solution:** a VTEP never forwards traffic back into the same Ethernet Segment from which it was received. The ESI tag on the EVPN route type identifies the segment — if the destination segment matches the source segment, the frame is dropped. |

### 5.5 Symmetric IRB & Anycast Gateway

Inter-subnet routing — traffic between two VMs in different VNIs but the same VRF — uses the Symmetric IRB (Integrated Routing and Bridging) model. Both the ingress and egress Leafs perform a routing lookup. This is in contrast to Asymmetric IRB where only the ingress Leaf routes, which requires every Leaf to hold every subnet's routing table regardless of whether it has attached servers for that subnet.

| Property | Value & Justification |
|---|---|
| IRB Model | Symmetric IRB. Each Leaf only holds the subnets of VNIs it directly serves, plus the L3VNI for each VRF. This reduces memory consumption and simplifies per-leaf configuration. |
| Anycast Gateway IP | Each Leaf hosts the default gateway IP for every VNI it serves (e.g., 192.168.10.1 for TP-SERVERS). All Leafs share the same gateway IP per subnet — a VM that migrates to a different Leaf never needs to update its default gateway. |
| Anycast Gateway MAC | A shared virtual MAC address (e.g., 00:00:00:11:11:11) is configured identically on all Leafs for a given VRF. This prevents ARP flaps when a VM migrates — the gateway MAC never changes from the VM's perspective. |
| VTEP Source | Each Leaf uses its Loopback0 address as the VXLAN tunnel source. VXLAN encapsulation uses UDP destination port 4789 (IANA-assigned, RFC 7348). The underlay ensures Loopback0 reachability fabric-wide via eBGP. |
| Spines as EVPN RR | Both Spine switches act as EVPN Route Reflectors. All Leafs peer with both Spines in the L2VPN EVPN address family. The Spines reflect EVPN NLRIs (Type 2, 3, 5 routes) between Leafs without requiring a Leaf-to-Leaf full mesh. |

### 5.6 BUM Traffic Handling: Head-End Replication

EVPN must handle BUM (Broadcast, Unknown Unicast, Multicast) traffic for scenarios that cannot yet be handled by known MAC/IP routes — primarily ARP requests during initial host discovery and genuine broadcast traffic (DHCP, etc.). The mechanism used for this is Head-End Replication (HER), not multicast.

| Aspect | Detail |
|---|---|
| Mechanism | Ingress Replication (Head-End Replication). When a VTEP receives a BUM frame, it sends one unicast VXLAN-encapsulated copy to each remote VTEP in the VNI's replication list. |
| Replication List | Built automatically from EVPN Type 3 (IMET) routes. When a Leaf joins a VNI, it advertises a Type 3 route; all other Leafs add it to their ingress replication list for that VNI. No manual configuration. |
| Why not PIM for BUM | PIM multicast for BUM transport requires multicast routing in the underlay and additional RP (Rendezvous Point) infrastructure. At ESI's scale (10 VTEPs), HER unicast copies are far simpler and the bandwidth overhead is negligible. |
| PIM scope clarification | PIM Sparse Mode is used only in the Storage pod for application-level replication (storage cluster sync to multiple targets). It is NOT used for EVPN BUM transport. These are two different multicast planes and must not be confused. |

### 5.7 VNI Segment Table

The following table defines all logical network segments in the fabric. VNI values follow the convention 100XX where XX equals the VLAN ID. All VTEPs hold the full VNI table in their configuration; a Leaf only activates the VNIs relevant to its directly attached servers. Anycast gateway IPs (e.g., 192.168.10.1) are the first address in each subnet and are configured identically on every Leaf that serves the segment.

| VNI | VLAN | Segment | VRF | Subnet | Leaf Attachment / Notes |
|---|---|---|---|---|---|
| 10010 | 10 | STUDENT-TP | VRF-PEDAGOGY | 192.168.10.0/24 | student-leaf-01/02. TP servers for lab sessions. |
| 10020 | 20 | STUDENT-PROJ | VRF-PEDAGOGY | 192.168.20.0/24 | student-leaf-01/02. Isolated student project VMs. |
| 10030 | 30 | LMS-ORIENT | VRF-STAFF | 192.168.30.0/24 | border-leaf. LMS (Moodle), BAC orientation platform. |
| 10040 | 40 | SERVICES-WEB | VRF-STAFF | 192.168.40.0/24 | border-leaf. Internal web portals, employee/admin interfaces. |
| 10050 | 50 | CORE-INFRA | VRF-STAFF | 192.168.50.0/24 | admin-leaf. AD, DNS, DHCP, NTP, Ansible Tower. |
| 10060 | 60 | HR-FINANCE | VRF-ADMINISTRATION | 192.168.60.0/24 | admin-leaf. HR system, Finance. Data-at-rest encryption mandatory. |
| 10070 | 70 | AI-GPU | VRF-STAFF | 192.168.70.0/24 | hpc-leaf. GPU servers, SLURM/K8s nodes. RoCEv2 enabled. |
| 10080 | 80 | STORAGE-SAN | VRF-STAFF | 192.168.80.0/24 | storage-leaf. SAN, NAS, FTP, Backup. PIM enabled. |
| 10090 | 90 | BAC-ORIENT | VRF-ORIENTATION | 192.168.90.0/24 | border-leaf. Activated ~2 mo/yr for orientation operation. Zero routes to other VRFs. |
| 10100 | 100 | DMZ-WEB | VRF-PUBLIC | 192.168.100.0/24 | border-leaf. Public-facing servers. No fabric routes. |
| 10110 | 110 | MGMT-OOB | OOB | 172.16.0.0/24 | All leaves (mgmt port only). Bastion: 172.16.0.50. IDS: 172.16.0.51. |

---

## 6. Zero-Trust Macro-Segmentation

Security zones are implemented as VRF (Virtual Routing and Forwarding) instances. Each VRF has a dedicated L3 VNI and an associated IP subnet. By default, all inter-VRF communication is denied. Any authorized cross-zone path must be explicitly permitted via a Firewall policy and routed through the Border Pod. There is no 'internal' trust — traffic between the Student VRF and the Admin VRF is treated with the same suspicion as traffic from the public Internet.

| Trust Zone (VRF) | Security Posture | L3VNI | Subnet | Permitted Outbound |
|---|---|---|---|---|
| VRF-ADMINISTRATION | HR, Finance, Core Databases | 50010 | 10.10.10.0/24 | No outbound routes by default. Inbound via explicit firewall policy only. |
| VRF-STAFF | Admin, Faculty, AI/HPC, Services | 50020 | 10.10.20.0/24 | Can reach VRF-ADMINISTRATION via explicit firewall policy. Full internal fabric access. |
| VRF-PEDAGOGY | Student Labs & TP Servers | 50030 | 10.10.30.0/24 | Internet access only. No routes to VRF-STAFF or VRF-ADMINISTRATION. |
| VRF-PUBLIC | Public-Facing Services | 50040 | 192.168.100.0/24 | Internet-facing services only. No routes to any internal VRF — structurally absent, not just policy-denied. |
| VRF-ORIENTATION | BAC Orientation Operation | 50050 | 192.168.90.0/24 | Zero routes. Activated ~2 months/year. Third ISP fibre is the only permitted path. |

> **DMZ structural isolation:** VRF-PUBLIC (DMZ) contains no routes to any internal VRF — not even a deny rule. A missing route is a stronger security guarantee than a firewall rule: there is nothing to accidentally misconfigure or omit. A compromised DMZ server cannot reach internal services because no routing path exists, independent of any firewall state.

> **Lateral Movement Prevention:** Within a VRF, host-to-host lateral movement is restricted by nftables policies on each server. This is the innermost containment ring and ensures a compromised host cannot pivot freely even within its own zone.

---

## 7. Security Extensions

Security is implemented in concentric rings. Each ring is independent — the failure of an outer ring does not compromise inner rings. Every measure below is justified by a specific threat vector; nothing is added for compliance theater.

| Ring | Mechanism | Threat Addressed & Justification |
|---|---|---|
| Ring 1 — Perimeter | HA Next-Gen Firewalls | Stateful L7 inspection of all North-South traffic. Active/Active pair eliminates single point of failure on the most exposed path. |
| Ring 2 — Routing | BGP Prefix-Lists + TCP MD5 + Max-Prefix | Inbound prefix-list accepts only the default route from external peers. Outbound prefix-list blocks all RFC 1918 advertisements. TCP MD5 (RFC 2385) signs every BGP TCP segment — forged UPDATE messages are discarded before the routing daemon sees them. Max-prefix guard tears down the session if the peer advertises more routes than expected. |
| Ring 3 — Control Plane | ACLs on Management CPU | BGP (TCP/179), BFD (UDP/3784), VXLAN (UDP/4789), and SSH (TCP/22) are restricted to legitimate infrastructure source addresses only. VXLAN ACL is scoped to VTEP loopbacks exclusively — a server crafting a UDP/4789 packet to a switch loopback would otherwise inject frames into arbitrary VRFs. |
| Ring 4 — Admin Access | Bastion Host + ed25519 | No direct SSH to any network device. All admin traffic must originate from a hardened Bastion. Password authentication is globally disabled. |
| Ring 5 — Micro-seg | nftables (Host-Based) | Per-host firewall policies restrict lateral movement within a VRF. A compromised VM cannot pivot to its neighbors by default. |

### 7.1 Supporting Controls

The three controls below complement the five rings. They are detection or architectural mechanisms rather than packet-filtering layers and are therefore not numbered as rings.

| Control | Enforced At | Mechanism & Justification |
|---|---|---|
| Passive IDS (Suricata) | Dedicated IDS node — border traffic mirror | A tc (traffic control) mirror copies all inbound and outbound packets on the Border Leaf external interface to a dedicated Suricata node. The IDS operates in detection-only mode and is never in the traffic path — a false positive cannot disrupt forwarding. Alerts are written to a log file with timestamp, signature name, and source/destination. The mirror is placed on the Border Leaf because it sees all external traffic in both directions. |
| Management Bastion | bastion-01 — single SSH jump host | SSH is accepted on all switches and servers exclusively from the Bastion IP. Ring 3 enforces this at the packet level. Without a Bastion, every switch requires its own allow-list of administrator workstations — these lists drift as staff change. With a Bastion, each switch has exactly one SSH rule that never changes. |
| DMZ Structural Isolation | All Leafs — VRF routing table | VRF-PUBLIC contains no routes to any internal VRF. This is enforced at the routing table level, not the firewall level. A missing route cannot be accidentally omitted from a policy — it simply does not exist. |

### 7.2 Per-Role Host Micro-Segmentation Rules

All servers share a common baseline: INPUT chain default policy DROP, ESTABLISHED/RELATED traffic accepted, SSH permitted from Bastion (172.16.0.50) only. The table below defines the additional inbound rules layered on top of the baseline for each server role. Any port not listed is blocked.

| Server Role | Zone / VRF | Additional Inbound Rules | Justification |
|---|---|---|---|
| Student lab VMs | VRF-PEDAGOGY | None (baseline only) | No inbound service is expected. Adding any permit rule expands the attack surface with no operational benefit. |
| Admin VMs (AD, DNS…) | VRF-STAFF | TCP 53 (DNS), UDP 53 (DNS), TCP 67/68 (DHCP) from 192.168.0.0/16 | Infrastructure services must be reachable from all internal zones. Source restricted to internal subnets — internet-originating DNS/DHCP is blocked. |
| HR / Finance VMs | VRF-ADMINISTRATION | TCP 443 from VRF-STAFF only, via explicit FW policy | Highest-sensitivity data. Only verified VRF-STAFF users may connect, and only via encrypted HTTPS. |
| Research / HPC VMs | VRF-STAFF | TCP 8080 from 192.168.0.0/16 | Jupyter notebooks on port 8080. Restricted to internal subnets only — internet exposure would allow arbitrary code execution. |
| Services VMs (LMS, web) | VRF-STAFF | TCP 80, TCP 443 (any internal) | Internal web apps reachable from all zones. External boundary controlled by perimeter FW and VRF-PUBLIC isolation. |
| AI/HPC bare-metal | VRF-STAFF | TCP 6006 from 192.168.0.0/16 | TensorBoard training monitor on port 6006. Internal access only — exposes training metrics and model data. |
| DMZ web servers | VRF-PUBLIC | TCP 80, TCP 443 (internet-sourced, via FW) | Perimeter FW (Ring 1) is the actual enforcement point. Server-side rule is a second layer of defence. |
| BAC Orientation servers | VRF-ORIENTATION | No inbound rules (offline by default) | Zero inbound permitted during offline periods. A single management IP range is permitted only during the active orientation window. |

The following protocol and configuration extensions are applied selectively, only where a specific workload class demands them. They are not enabled globally.

| Extension | Scope | Justification |
|---|---|---|
| Jumbo Frames (MTU 9000) | Fabric-wide | VXLAN adds a 50-byte encapsulation header. Without Jumbo Frames, the effective payload MTU drops to 1450 bytes, causing fragmentation on every packet. |
| BFD (sub-second detection) | All BGP sessions | Standard BGP keepalive timers converge in 90–180 seconds. BFD detects link failure in < 1 second and triggers BGP reconvergence immediately. |
| ECMP (Equal-Cost Multipath) | Spine-Leaf uplinks | All Leaf-to-Spine uplinks are equal-cost BGP paths. Traffic is hashed across all available Spines, using full fabric bandwidth. |
| RoCEv2 / Lossless Ethernet | AI/HPC Pod only (L5/L6) | GPU training workloads use RDMA over Converged Ethernet. PFC (Priority Flow Control) and ECN (Explicit Congestion Notification) are enabled only on the AI/HPC pod switches to prevent packet loss that would abort training runs. Enabling PFC fabric-wide would cause unnecessary head-of-line blocking. |
| PIM Sparse Mode | Storage Pod (L7/L8) | For high-bandwidth storage replication to multiple targets, PIM prevents the N-unicast problem where the source must send N identical copies. Fabric replicates only at the point of divergence. |
| NTP Stratum 1 Sync | Fabric-wide | BGP certificate validity and forensic log correlation require synchronized clocks. Unsynchronized clocks produce unauditable logs and can cause BGP session drops. |
| IPv6 Dual-Stack | Loopbacks & containers | Container orchestration (Kubernetes) natively uses IPv6 for pod addressing. Dual-stack is implemented now to avoid a costly re-addressing project in two years. |

---

## 9. Architecture Validation Matrix

The architecture is considered production-ready only when every vector in this matrix passes its success criteria. These tests are deterministic — a pass/fail answer can be obtained within one lab session.

| Validation Vector | Methodology | Success Criteria |
|---|---|---|
| Underlay Reachability | Loopback-to-loopback ping across all Leaf pairs | 100% reachability; ≤ 2 hops (traceroute confirms TTL decrement). |
| ECMP Load Distribution | Generate traffic flows; inspect ASIC counters on both Spines | Traffic distributes across all active Spine uplinks. No single uplink > 60% utilization under balanced load. |
| Overlay Control Plane | show evpn vni detail on all Leafs | All VNIs populated. MAC/IP bindings present via BGP. ARP flooding counter = 0 after initial convergence. |
| VRF Zone Isolation | Attempt cross-VRF ping without explicit firewall permit | 100% packet loss between all unauthorized VRF pairs. |
| BFD Fast Failover | Physically pull a Spine uplink; measure BGP reconvergence time | Traffic re-routes in < 1 second. No BGP session teardown on surviving links. |
| ESI Multihoming | Pull one Leaf in a pair; verify server traffic continues | Server bond fails over to surviving Leaf. Zero packet loss beyond BFD convergence window. |
| TCP MD5 Enforcement | Set wrong MD5 password on one BGP peer side; wait 30 s | BGP session drops to Active state. Restore correct password → session recovers to Established. |
| VXLAN Injection Block | Send crafted UDP/4789 packet from a server container to a switch loopback | Packet is silently dropped (timeout, not refused). Ring 3 ACL confirms VTEP-only restriction. |
| IDS Alerting | Run port scan (nmap -sS) against DMZ subnet from external test node | ET SCAN alert appears in Suricata fast.log within seconds. Confirms tc mirror is delivering traffic to IDS node. |
| OOB Access | Shut down all production BGP sessions; attempt OOB SSH to Spine | Full SSH access to all devices via OOB switch. Production fabric state is inaccessible from OOB (no cross-routing). |

---

## 10. Intentional Exclusions

The following mechanisms were considered and explicitly rejected. They are documented here to prevent well-intentioned future engineers from re-adding them without re-evaluating the trade-offs.

| Excluded Mechanism | Reason for Exclusion |
|---|---|
| MLAG / vPC | Replaced by standards-based ESI Multihoming. MLAG requires vendor-proprietary peer-links and limits redundancy to two switches. |
| STP (any variant) | Eliminated entirely. Spine-Leaf with EVPN provides loop-free topology by design. STP would reintroduce blocking ports and forwarding delays. |
| OSPF / IS-IS underlay | eBGP provides superior failure domain isolation and traffic engineering. IGPs flood topology changes globally; eBGP contains them to AS boundaries. |
| PFC fabric-wide | RoCEv2/PFC is scoped to the AI/HPC pod only. Fabric-wide PFC causes head-of-line blocking and congestion spreading that degrades all other workloads. |
| Dedicated RR appliances | Not needed at this scale. Both Spine switches serve as EVPN Route Reflectors natively — no separate appliances or RR hierarchy is required. Dedicated RR infrastructure is justified only in large multi-site fabrics with hundreds of VTEPs. |

---

## 11. Physical Component Inventory

| Quantity | Role | Target Speed | Notes |
|---|---|---|---|
| 2 | Spine Switches | 100G | High-radix, non-blocking. Must support MP-BGP EVPN and VXLAN in hardware ASICs. Act as EVPN Route Reflectors. |
| 4 | Access Leaf Switches (2 pairs) | 25G/100G | Serve compute pods (Admin, AI/HPC, Storage, Student). AI/HPC pair must be 100G non-blocking. |
| 2 | Border Leaf Switches (1 pair) | 25G/100G | Dedicated external-facing role. Terminate ISP uplinks, host EVPN VRF-PUBLIC, attach firewalls and border routers. |
| 1 | OOB Management Switch | 1G | Simple L2 switch. No routing. Never connected to production fabric. |
| 2 | Border Routers | 10G/25G | Interface with ISP. Terminate external BGP sessions and advertise aggregate prefixes only. |
| 2 | HA Next-Gen Firewalls | 10G/25G | Active/Active pair. L7 inspection. Policy gateway for all inter-VRF traffic. One per Border Leaf — independent conntrack tables. |
| 1 | Bastion Host | 1G | Hardened Linux node. ed25519 key-only SSH. Single authorized entry point for all admin SSH. PasswordAuthentication disabled globally. |
| 1 | Passive IDS Node | 1G (mirror tap) | Receives tc-mirrored copy of all Border Leaf external traffic. Runs Suricata in detection-only mode. Never in the traffic path. |

---

## 12. Compute Cluster Architecture

The ESI data center is divided into five compute clusters. Cluster assignment is determined by two orthogonal criteria: (1) virtualization posture — whether workloads benefit from hypervisor-level isolation and resource sharing, or require direct hardware access; and (2) security classification — whether the cluster operates within the production fabric or is physically air-gapped.

Clusters 1 (General) and 2 (Admin) run fully virtualized stacks built on OpenStack and Ceph. Cluster 3 (AI/HPC) and Cluster 4 (BAC Orientation) run bare-metal. Cluster 5 (Storage) is a dedicated Ceph cluster that backs the two virtualized stacks and is not a compute cluster in itself.

### 12.1 Cluster Summary

| Cluster | Name | Posture | Hardware | Stack |
|---|---|---|---|---|
| 1 | General | Virtualized | 6× 1U nodes | OpenStack (KVM) + Ceph RBD/CephFS |
| 2 | Admin / Infra | Virtualized | 3× 1U nodes | OpenStack (KVM) + Ceph RBD — air-gapped VLAN |
| 3 | AI / HPC | Bare-Metal | 2× 4U GPU | SLURM (training) + Kubernetes (inference) — RoCEv2 |
| 4 | BAC Orientation | Bare-Metal | 3× 1U nodes | Minimal OS — air-gapped, powered off ~10 mo/yr |
| 5 | Storage | Dedicated SAN + NAS nodes | — | Ceph cluster — serves Clusters 1 & 2; not a compute cluster |

### 12.2 Cluster 1 — General (Fully Virtualized)

Cluster 1 hosts all general-purpose and student-facing workloads: web servers, lab VMs, orientation platform, and any service that does not carry sensitive administrative data. The six 1U nodes form a shared resource pool under OpenStack, with Ceph providing all persistent storage.

| Layer | Technology & Justification |
|---|---|
| Hypervisor | KVM via libvirt. Kernel-native on Linux, zero licensing cost, full QEMU device emulation. No proprietary lock-in. |
| Compute Orchestration | OpenStack Nova. Schedules VM placement across the 6-node pool, enforces resource quotas per project/tenant, and exposes a self-service API for lab provisioning. |
| VM Networking | OpenStack Neutron with OVN (Open Virtual Network) backend. Neutron creates per-tenant virtual networks that are stitched into the EVPN/VXLAN fabric via the Leaf VTEP. No standalone SDN controller is required — OVN runs distributed on each compute node. |
| Block Storage | Ceph RBD (RADOS Block Device) via Cinder. VM root disks and data volumes are thin-provisioned on the Ceph cluster. Live migration is possible at any time because the disk never lives on the compute node. |
| Shared File Storage | CephFS via Manila. Provides POSIX-compliant shared filesystems for workloads that require NFS-style multi-read/write access (e.g., shared lab datasets). |
| VM Images | OpenStack Glance backed by Ceph RBD. Images are stored once in Ceph and cloned (copy-on-write) for each new VM — provisioning a new lab VM takes seconds, not minutes. |
| Oversubscription | CPU 4:1, RAM 1.5:1. Student workloads are bursty and idle most of the time. These ratios allow 6 physical nodes to host significantly more VMs than raw capacity suggests, with negligible contention during off-peak hours. |

> **Why OpenStack over Proxmox or VMware:** OpenStack is the only option that is fully open-source, API-driven, multi-tenant by design, and directly integrable with Neutron/OVN for EVPN fabric attachment. VMware introduces licensing costs and proprietary lock-in. Proxmox lacks native multi-tenancy and Ceph integration at this level.

### 12.3 Cluster 2 — Admin / Core Infra (Fully Virtualized, Air-Gapped VLAN)

Cluster 2 hosts all administrative services: Active Directory, DNS, DHCP, NTP, HR and Finance systems, Ansible Tower, and monitoring (Grafana + Prometheus). The three 1U nodes run the same OpenStack/Ceph stack as Cluster 1 but in a completely separate resource pool. This cluster maps to VRF-STAFF and has no network reachability to Cluster 1 by default.

| Layer | Technology & Justification |
|---|---|
| Hypervisor | KVM via libvirt — identical stack to Cluster 1 to minimize operational surface. |
| Compute Orchestration | Dedicated OpenStack region (separate Keystone domain). Admin and student workloads never share a scheduler, a quota namespace, or an API endpoint. |
| Storage | Ceph RBD via Cinder. Same Ceph cluster as Cluster 1 but with separate RADOS pools, enforced by Ceph RBAC. Data-at-rest encryption (LUKS) enabled on the HR and Finance pools. |
| Network Isolation | All VMs in Cluster 2 are placed in VRF-STAFF (L3VNI 50020). Neutron enforces that no VM port can be attached to a network in a different VRF without an explicit firewall policy crossing the zone boundary. |
| Oversubscription | CPU 3:1, RAM 1:1. Administrative services (AD, DNS) are latency-sensitive; memory oversubscription is disabled to prevent swap-induced latency spikes. |

### 12.4 Cluster 3 — AI / HPC (Bare-Metal, Dual Orchestration)

Cluster 3 is the performance-critical cluster. The two 4U GPU servers run entirely bare-metal — no hypervisor layer exists between the workload and the PCIe bus. This is non-negotiable: a hypervisor introduces GPU scheduling jitter of 50–200 µs per kernel launch, which compounds into minutes of wasted time over a multi-hour training run.

Two orchestration layers coexist on the same physical nodes, addressing two distinct workload profiles that have fundamentally different scheduling requirements.

| Orchestrator | Workload Type | Scheduling Model | Justification |
|---|---|---|---|
| SLURM | Batch training jobs | Queue-based, exclusive GPU allocation | Training jobs require full GPU exclusivity for hours. SLURM enforces strict job queuing, resource accounting, and time limits. Industry standard in HPC. |
| Kubernetes | Inference serving | Container-based, shared GPU (MIG/vGPU) | Inference is API-driven and short-lived. K8s auto-scales pods on demand and supports NVIDIA MIG (Multi-Instance GPU) partitioning so multiple inference endpoints share one GPU. |

| Layer | Technology & Justification |
|---|---|
| GPU Driver Stack | NVIDIA CUDA + ROCm (if AMD GPUs present). Drivers installed directly on bare-metal OS. No PCIe passthrough overhead. |
| SLURM Configuration | slurmctld (controller) runs on a dedicated management VM in Cluster 2. slurmd daemons run on each GPU node. Job accounting is logged to a MariaDB instance in Cluster 2. |
| Kubernetes Configuration | Single-node or two-node K8s cluster using k3s (lightweight distribution). NVIDIA device plugin enables GPU resource requests in pod specs. Inference images are pulled from a local Harbor registry hosted in Cluster 1. |
| High-Speed Fabric | 100G RoCEv2 via the AI/HPC Leaf pair (L5/L6). PFC and ECN enabled on these switches only. All RDMA traffic stays within the pod — it never traverses the Spine unless explicitly routed. |
| Shared Storage | Training datasets and model checkpoints are stored on the NAS (CephFS) in Cluster 5, mounted via high-speed NFS over the Storage pod uplink. Local NVMe SSDs on GPU nodes serve as a fast scratch tier for active jobs. |
| Coexistence | SLURM and K8s share the physical nodes via Linux cgroups v2 resource partitioning. SLURM jobs are assigned to a dedicated cgroup hierarchy that guarantees exclusive GPU access. K8s pods run in a separate hierarchy with shared access to unused GPUs. |

> **Why not a single orchestrator:** SLURM and Kubernetes solve different problems. SLURM's queue model is optimal for exclusive long-running jobs. Kubernetes' pod model is optimal for concurrent short-lived API workloads. Using only SLURM wastes GPU capacity during idle training periods. Using only Kubernetes makes it impossible to guarantee exclusive access for a 48-hour training run.

### 12.5 Cluster 4 — BAC Orientation (Bare-Metal, Air-Gapped)

Cluster 4 is dedicated exclusively to the national BAC orientation operation — the annual university placement process through which students select their higher-education institutions. This operation runs for approximately two months per year; for the remaining ten months the cluster is powered off and physically disconnected from the network. This is not a cost-cutting measure — it is the primary security control. A powered-off cluster has zero attack surface.

Internal school exams are not a special workload. They run as ordinary VMs on Cluster 1 (General) with no dedicated hardware required.

| Layer | Technology & Justification |
|---|---|
| Hypervisor | None. Bare-metal only. The orientation platform is a nationally mandated, integrity-critical system. A hypervisor introduces an unauditable abstraction layer that complicates certification and incident response. |
| Operating System | Minimal hardened Linux (e.g., Rocky Linux with CIS Benchmark profile). Only orientation platform binaries and their dependencies are installed. No package manager remains active during the operation window. |
| Orchestration | None beyond systemd service management. The orientation platform is a known, static application stack. Adding Kubernetes or any container runtime would introduce unnecessary complexity and attack surface for a workload that runs identically every year. |
| Network Posture | VRF-ORIENTATION (L3VNI 50050). Zero outbound routes exist in this VRF. The dedicated third ISP fibre is the only permitted path in or out. Inbound access from the production fabric is restricted to a single management IP range during the active window only. |
| Physical Security | Network cables physically disconnected when cluster is offline. Power strips locked. BIOS requires physical presence for boot-order changes. TPM-backed secure boot enabled. |
| Activation Procedure | A documented runbook governs the bring-up sequence: (1) physical inspection, (2) secure boot verification, (3) network cable re-attachment, (4) VRF-ORIENTATION route injection by infrastructure team, (5) orientation platform health check. |

> **Why bare-metal over virtualization:** The BAC orientation platform is provided or certified by a national authority and may include integrity or anti-tampering requirements that assume direct hardware access. Virtualizing it introduces a hypervisor escape risk and potential certification incompatibility that cannot be accepted.

### 12.6 Cluster 5 — Dedicated Storage (Ceph)

Cluster 5 is not a compute cluster — it is the shared storage substrate for Clusters 1 and 2. It runs a dedicated Ceph cluster with separate RADOS pools for each consumer. Block storage (RBD) is consumed by OpenStack Cinder in both virtualized clusters. Shared filesystem (CephFS) is consumed by AI/HPC training jobs for dataset access. Object storage (RGW) serves as the artifact and image registry backend.

| Ceph Service | Consumer | Notes |
|---|---|---|
| RBD (Block) | Clusters 1 & 2 (Cinder) | VM root disks and data volumes. Copy-on-write cloning for fast VM provisioning from Glance images. |
| CephFS (File) | Cluster 3 (AI/HPC) | Shared dataset and checkpoint storage for training jobs. Mounted via NFS-Ganesha or kernel CephFS client on GPU nodes. |
| RGW (Object) | Cluster 1 (Glance/Harbor) | S3-compatible endpoint for VM image storage (Glance) and container image registry (Harbor). Eliminates need for separate object storage appliances. |
| Separate RADOS Pools | All clusters | Cluster 1 and Cluster 2 data resides in separate RADOS pools with distinct Ceph RBAC credentials. A compromised Cluster 1 credential cannot read Cluster 2 data. |

### 12.7 Inter-Cluster Communication Matrix

The following matrix defines all permitted inter-cluster communication paths. Any path not listed is denied by default at the VRF boundary. Cross-cluster paths always traverse the HA Firewall pair in the Border Pod.

| Source Cluster | Destination Cluster | Permitted | Protocol / Purpose |
|---|---|---|---|
| 1 — General | 5 — Storage | Yes | iSCSI / NFS (Ceph RBD + CephFS) via Storage VRF uplink. |
| 2 — Admin | 1 — General | Yes (one-way) | Admin can push DNS/DHCP config and monitoring agents to Cluster 1 VMs. Cluster 1 cannot initiate connections to Cluster 2. |
| 2 — Admin | 5 — Storage | Yes | iSCSI / NFS for Admin VM persistent storage. |
| 3 — AI/HPC | 5 — Storage | Yes | NFS/CephFS for training dataset read and checkpoint write. |
| 3 — AI/HPC | 2 — Admin | Yes (one-way) | SLURM controller (in Cluster 2) manages Cluster 3 nodes via slurmd. Cluster 3 cannot initiate connections to Cluster 2. |
| 4 — BAC Orient. | Any | No | VRF-ORIENTATION — zero routes. No permitted paths in any direction during offline periods. Third ISP fibre only when active. |
| 1 — General | 2 — Admin | No | Explicitly blocked. Student VMs cannot reach Admin or HR systems under any circumstance. |

---

## 13. Infrastructure Services

The following services are not compute workloads — they are the operational substrate that every other cluster depends on. All services in this section run as VMs in Cluster 2 (Admin, VRF-STAFF) unless otherwise noted. They are always-on and require the same HA treatment as the fabric itself.

### 13.1 Core Network Services

| Service | Implementation | Design Notes |
|---|---|---|
| DHCP | Kea DHCP (ISC) | One Kea instance per VRF that requires dynamic addressing. DHCP relay agents are configured on each Leaf's SVI (Switched Virtual Interface) to forward client requests from the access VNI to the Kea server in Cluster 2. Static reservations are used for all infrastructure nodes; dynamic pool is for lab VMs only. |
| DNS | BIND 9 or Unbound | Authoritative for the internal domain (e.g., esi.internal). Recursive resolver for all internal hosts. Each VRF receives DNS via DHCP option 6. DNS queries from the DMZ VRF are directed to a separate resolver with no visibility into internal zones. |
| NTP | Chrony (Stratum 2) | Synchronizes to an upstream public Stratum 1 server via the border uplinks. All fabric switches and compute hosts sync to this instance. Mandatory: BGP certificate validity, Kerberos authentication (AD), and forensic log correlation all require clock skew < 30 seconds. Unsynchronized clocks produce unauditable logs. |
| FTP | vsftpd (Storage pod) | File transfer service for large internal data movement: backup distribution, configuration file transfers, dataset staging. Hosted in the Storage pod (MEDIUM VRF), not Admin cluster, because its traffic profile (large sustained transfers) matches the 1:1 non-blocking storage leaf pair. |

### 13.2 Monitoring Stack

Two complementary tools are deployed rather than one. Each addresses a distinct monitoring surface that the other cannot cover adequately.

| Tool | Primary Use | Justification & Configuration |
|---|---|---|
| Zabbix | Infrastructure monitoring, alerting | SNMP polling of all switches (interface counters, BGP peer state, CPU/memory). Threshold-based alerting for link down, BGP session drop, disk utilization. Zabbix has native network device templates and is already familiar to ESI staff (previously used Cacti for the same role). Replaces Cacti. |
| Prometheus + Grafana | Metrics collection, dashboards | Time-series metrics scraped from OpenStack, Ceph, SLURM, Kubernetes, and server-level exporters (node_exporter). Grafana provides live dashboards for fabric utilization, cluster health, and storage capacity. Operates alongside Zabbix — does not replace it. |
| Centralized Syslog | Log aggregation | All switch and server syslog streams are forwarded to a central collector (rsyslog or Loki). Forensic analysis and incident correlation require all logs in one place with synchronized timestamps. In the lab, TCP/514 is explicitly permitted to the collector while unrelated inter-zone traffic remains denied by policy. Without central syslog, reconstructing a BGP event across 12 switches requires logging into each device individually. |

> **Replacing Cacti:** ESI currently uses Cacti for bandwidth monitoring. Zabbix is a strict superset: it covers all of Cacti's SNMP graphing capability plus threshold alerting, service checks, and a maintained codebase. The migration path is low-risk — Zabbix can import Cacti-style SNMP configurations.

### 13.3 Configuration Management

| Tool | Scope | Design Notes |
|---|---|---|
| Ansible Tower (AWX) | Network + OS automation | Idempotent playbooks manage: (1) switch underlay and overlay configuration, (2) OS hardening on all VMs and bare-metal nodes, (3) service deployment. Playbooks are the single source of truth — manual changes to switch CLIs are prohibited. AWX provides a web UI for scheduled playbook runs and audit logs. |

### 13.4 WiFi & Campus Access Integration

Campus WiFi Access Points connect to the Student/Lab pod (student-leaf-01/02). Each AP supports a maximum of approximately 30 simultaneous clients. APs are managed by a WiFi Controller VM hosted in Cluster 1 (General, VRF-PEDAGOGY). The controller handles SSID-to-VLAN mapping: the student SSID maps to VLAN 10 (STUDENT-TP VNI 10010); a separate staff SSID maps to VLAN 50 (CORE-INFRA VNI 10050) for authenticated faculty access.

Newer campus buildings uplink directly via fibre to the Student Leaf switches. Older buildings (e.g., auditorium) route traffic through intermediate distribution switches (BP) before reaching the fabric. EtherChannel is configured between BP distribution switches and the Student Leaf pair to eliminate the congestion bottleneck that currently exists in the legacy topology.

> **AP placement note:** An AP is not a routable node and cannot be represented as a VTEP. It connects to a Leaf access port in the appropriate VLAN. VXLAN encapsulation is performed by the Leaf VTEP — the AP has no awareness of the overlay.
