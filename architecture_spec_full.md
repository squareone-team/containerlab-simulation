# Architecture Spec Refinement

---

## 📑 Tasks

**Amine** takes the design core. The architectural model—defining what a pod is, what a cluster is, how they relate to each other, and how everything maps: pods to leaf pairs, clusters to pods, VNIs to VLANs to VRFs to segments. The full protocol stack. Service-to-pod assignment. Inter-cluster communication. Everything at the conceptual and structural level of the design.

**Sarah and Nadine** both work on the physical architecture and the naming and addressing scheme. Specify everything—rack layout, cabling, port assignments, hardware specifications, IP address assignments, and consistently name every concept and every device (switches, VRFs, segments, pods, and clusters). Leave nothing vague or implicit.

On top of that, **Nadine** refines and merges the QoS document and verifies that it integrates cleanly with what we already have—does not just append it.

And **Sarah** takes security—goes through it the same way the original security document approached things, tightens the specifications, and makes sure nothing is hand-wavy.

On the last day before the deadline, everyone does a review pass on someone else's work. Amine reviews Sarah and Nadine's physical architecture. Sarah reviews QoS. Nadine reviews security. Sarah and Nadine both review Amine's part.

---

## 1 — Principles

Before describing any component of this architecture, it is necessary to state the reasoning framework that governs every decision in this document. Three principles are applied, in order of precedence, whenever a trade-off must be made.

The **first** is **reasoning clarity**: the full topology must fit in one engineer's working memory. No protocol, no component, and no abstraction layer is introduced unless every member of the team can explain in plain language why it exists and what happens if it is removed. This is a claim about explainability, not about shallow simplicity: EVPN/VXLAN is not a simple technology in absolute terms and carries a genuine learning curve. The principle requires that its complexity be justified and documented — not eliminated. Virtually every protocol decision in this document is accompanied by a reason for its inclusion and an explicit comparison to the alternative that was rejected. This principle has direct consequences on technology choices: every time a simpler solution solves the same problem, the simpler solution wins.

The **second** is **extensibility**: adding compute capacity, a new functional zone, or a new service must require zero modification to the existing control or data plane. The architecture is a substrate, not a configuration file. Growth must be horizontal — a new Leaf pair extends the fabric without touching anything already deployed.

The **third** is **performance determinism**: latency must be bounded and bandwidth must be non-blocking where workloads demand it. This is not a goal for the entire fabric equally — it is selectively enforced where workload profiles require it, and deliberately relaxed where they do not. The AI/HPC pod operates at 1:1 non-blocking; the Student pod runs at 4:1 oversubscription. Both ratios are correct for their respective workloads.

While those three principles govern how trade-offs are managed, a final element is entirely exempt from compromise. **Security is a structural property of this design, not just an add-on.** It is achieved through routing isolation at the VRF layer — where VRF (Virtual Routing and Forwarding) denotes an independent routing table instance that, by default, shares no routes with any other VRF — rather than through perimeter firewalls alone. This distinction is fundamental: a firewall rule can be misconfigured; a missing route cannot.

---

## 2 — Network Topology

The underlay fabric is a two-tier, non-blocking Clos topology — commonly called Spine-Leaf. Every Leaf switch connects upward to every Spine switch in a full mesh. No Leaf-to-Leaf links exist. This single topological constraint produces a set of properties that no other topology can simultaneously guarantee.

Any two endpoints in the fabric are separated by exactly two hops: one from the source Leaf to a Spine, one from that Spine to the destination Leaf. This guarantee eliminates the variable and unpredictable latency that is inherent in three-tier (Access-Distribution-Core) designs, where traffic may traverse one, two, or three hops depending on whether endpoints share an access switch, a distribution switch, or only a core switch. Deterministic hop count means deterministic latency, which is a prerequisite for the AI/HPC workloads that this fabric must support.

Bandwidth scaling is horizontal. Adding a Spine switch adds an equal-cost path from every Leaf to every other Leaf, increasing aggregate fabric bandwidth without modifying any existing switch configuration. This is the operational realization of the extensibility principle: no re-architecture is ever required.

### Fabric Scale and Device Grouping

The fabric is built with two Spine switches and five Leaf pairs (ten Leaf switches total), plus one Out-of-Band (OOB) management switch that is never part of the EVPN fabric.

**Why Leaf switches are grouped in pairs.** Each pair of Leaf switches serves a single pod — a physical network zone housing a class of workloads with homogeneous traffic and security requirements. Within a pair, servers dual-home their network connections: each server connects one link to the first Leaf and one link to the second. This dual-homing provides link-level and switch-level redundancy without vendor-proprietary protocols. The mechanism that makes this work — ESI Multihoming — is detailed in the Protocol Stack section; the relevant point here is that the pairing is not an arbitrary grouping: it is the minimum unit of topology that enables standards-based server redundancy.

**Why two Spine switches, specifically.** Two Spines provide the minimum N+1 redundancy for the uplink tier. In systems architecture, N+1 redundancy ensures a system remains fully functional if a single component fails, where "N" is the absolute minimum number of components required for baseline capacity and "+1" is a single independent backup.

For fabric routing, N=1 Spine is required to connect all Leaf switches, making the second Spine the +1 backup; if one Spine is lost, every Leaf retains one active path to every other Leaf.

Note, however, that this N+1 redundancy applies strictly to reachability and the control plane, not aggregate bandwidth. A single Spine failure will reduce uplink capacity by 50%, temporarily degrading the AI/HPC pod from 1:1 non-blocking to 2:1 oversubscribed until the fault is resolved.

Both Spines also propagate EVPN routes between all Leaf pairs as a default property of eBGP; operating both simultaneously means no single Spine failure can interrupt EVPN route distribution. The mechanism by which they do so is detailed in the Protocol Stack section.

At the current fabric scale, two Spines provide sufficient aggregate bandwidth; adding a third would increase ECMP (Equal-Cost Multi-Path — the mechanism by which traffic is load-balanced simultaneously across multiple routes of identical cost) path count and aggregate bandwidth without requiring any change to existing configuration.

The OOB management switch is the single most cost-effective resilience component in the design. When a bad configuration push drops all BGP (Border Gateway Protocol — the routing protocol used in this fabric to distribute reachability information; detailed in the Protocol Stack section) sessions on a Spine or Leaf, the OOB provides the only path back in. Without it, a misconfiguration that affects the production control plane could become a physical hands-on incident.

### Why Not Three-Tier?

The legacy topology is an extended-star-with-bus that exhibits the classic pathologies of three-tier designs: oversubscription accumulates at the distribution layer, STP (Spanning Tree Protocol — a loop-prevention mechanism that works by blocking redundant links, at the cost of reducing effective bandwidth) blocks ports to prevent loops, and EtherChannel (link aggregation) is applied as a partial mitigation at aggregation points. Congestion at the BP distribution switches is a documented symptom of this fundamental structural flaw. Spine-Leaf removes all three pathologies simultaneously: oversubscription is controlled per-pod rather than accumulated, STP is eliminated by topology (there are no L2 loops in a Spine-Leaf with EVPN), and bandwidth scales linearly rather than through aggregation workarounds.

---

## 3 — Pods and Clusters

A server has two properties that matter to this architecture: its physical attachment point to the fabric, and its logical compute role. These two properties are strictly independent. They scale for different reasons, they are managed by different teams, and they impose different constraints. Collapsing them into a single concept would force architectural compromises where none are needed. Therefore, the data center organizes compute resources using exactly two structural definitions.

**A pod defines where a server sits in the network. A cluster defines the workload the server participates in.** Decoupling these two layers is the foundational concept required to understand the rest of this architecture.

### What a Pod Is

A pod is a physical network construct. It is defined as a set of servers connected to a dedicated Leaf switch pair, forming an isolated attachment domain within the Spine-Leaf fabric. That shared Leaf pair is the entire definition — everything else follows from it.

Because all servers in a pod share the same switching hardware, they share the same network policy: the same oversubscription ratio, the same link speed, the same protocol-level extensions. This is not a limitation — it is the design. Workloads with incompatible network requirements must be placed in different pods precisely so that each Leaf pair can be configured to match its workload, without compromise.

Pods exist because different workloads have fundamentally different and mutually incompatible traffic profiles. A GPU training job saturates a 100G link for hours at near-zero packet loss tolerance. A student lab VM produces bursty, irregular traffic and tolerates significant congestion. Placing these workloads on a shared Leaf pair would force a single hardware configuration — oversubscription ratio, buffer depth, QoS policy — to satisfy both profiles simultaneously, which is impossible. Pod isolation resolves this: each Leaf pair is tuned exclusively for its attached workload class.

A pod boundary is hardware-enforced. Moving a server between pods requires physical recabling.

| Pod | Leaf Pair | Oversubscription | Key Extensions |
|-----|-----------|-----------------|----------------|
| Border / DMZ | L1/L2 | 2:1 | — |
| Admin / Core Infra | L3/L4 | 3:1 | — |
| AI / HPC | L5/L6 | 1:1 | RoCEv2, PFC, ECN, 100G |
| Storage / Backup | L7/L8 | 1:1–1.5:1 | — |
| Student / Lab | L9/L10 | 4:1 | — |

### What a Cluster Is

A cluster is a logical compute construct. It is defined as a set of physical servers grouped by workload type, orchestration platform, virtualization posture, and security classification. A cluster is the unit of operational management: its servers share a hypervisor stack (or run bare-metal), a storage backend, and a scheduler. A cluster does not define network policy — that is the pod's responsibility. A cluster defines what runs and how it is managed.

A cluster does not know which Leaf pair its nodes connect to, and it does not need to. The orchestrator sees nodes — not ports, not Leaf pairs.

| Cluster | Orchestrator | Posture |
|---------|-------------|---------|
| 1 — General | OpenStack + KVM | Virtualized |
| 2 — Admin / Infra | OpenStack + KVM | Virtualized |
| 3 — AI / HPC | SLURM + Kubernetes | Bare-metal |
| 4 — BAC Orientation | None | Bare-metal |
| 5 — Storage | Ceph | Dedicated |

**Managing seasonal isolation.** Because Cluster 4 (BAC Orientation) is active for only two months of the year, dedicating isolated switching hardware to it is architecturally wasteful. Instead, it terminates on the shared L1/L2 Border Leaf pair under strict logical isolation. During its operational window, the cluster is bounded entirely within the VRF-ORIENTATION routing table, which shares no routes with production or administration VRFs (VRF isolation is explained fully in the Macro-Segmentation section). To enforce security during the ten months the cluster is dormant, network administrators must administratively disable the Leaf switch ports facing the Cluster 4 nodes, as well as the BGP session for its dedicated external ISP uplink. This operational procedure provides a physical-equivalent disconnect without requiring a separate hardware footprint.

### The Relationship Between Pods and Clusters

The relationship between pods and clusters is many-to-many. A cluster can span multiple pods. A pod can host servers from multiple clusters. This is not a complication — it is a direct consequence of the two concepts being independent.

**Why a cluster can span multiple pods.** When a cluster grows beyond the capacity of its current Leaf pair, a new Leaf pair is added to the fabric and new servers connect to it. The cluster's orchestrator sees new nodes registering — it does not know or care that they connect through a different Leaf pair. The cluster spans two pods. The fabric handles inter-pod east-west traffic transparently through the Spine. This is exactly the extensibility the Spine-Leaf topology is built for: horizontal growth with zero modification to the existing control or data plane.

**Why a pod can host servers from multiple clusters.** A server's network requirements and its compute role are independent criteria. The SLURM controller is the definitive example: it runs as a VM on the Admin Leaf pair and belongs to Cluster 2 — it needs AD, DNS, and VRF-STAFF isolation — but its operational function is to schedule all GPU training jobs in Cluster 3. Placing it on the HPC Leaf pair would give it 100G non-blocking links it does not need and expose it to the wrong security zone. The pod and cluster disagree on where this server belongs, and both are right — because they are answering different questions.

**The current mapping.** At the current scale, pods and clusters align closely. This is a property of the scale, not a limitation of the model. The Border Pod is the most visible exception to this alignment: it hosts no general-purpose compute cluster, but simultaneously serves as the network attachment point for external connectivity (border routers, firewalls, DMZ services) and for the Cluster 4 bare-metal nodes, whose network requirements mandate Border Pod attachment — the dedicated third ISP uplink for the BAC orientation operation terminates on the Border Leaf pair and nowhere else.

The VRF assignments in the table below are listed for completeness; each VRF is formally defined — including its trust posture, L3VNI, and security guarantees — in the Macro-Segmentation section.

| Pod | Leaf Pair | Primary Cluster | Cluster Posture | Primary VRF |
|-----|-----------|----------------|-----------------|-------------|
| Border / DMZ | L1/L2 | Cluster 4 + network appliances | Bare-metal | VRF-ORIENTATION / VRF-PUBLIC |
| Admin / Core Infra | L3/L4 | Cluster 2 | Fully virtualized | VRF-STAFF / VRF-ADMINISTRATION |
| AI / HPC | L5/L6 | Cluster 3 | Bare-metal | VRF-STAFF |
| Storage | L7/L8 | Cluster 5 | Dedicated Ceph | VRF-STAFF |
| Student / Lab | L9/L10 | Cluster 1 | Fully virtualized | VRF-PEDAGOGY |

### Communication

Inter-pod communication is the dominant traffic pattern in this architecture. Traffic between pods travels Leaf to Spine to Leaf, and any two servers are always exactly two hops apart, regardless of which pods they belong to.

Communication constraints are a function of VRF membership and firewall policy, not pod membership. A server cannot reach another server because a route exists or does not exist in the routing table, not because of which Leaf pair it connects to. The full VRF structure and all permitted inter-cluster paths are defined in the Macro-Segmentation and Inter-Cluster Communication sections, respectively.

### Extensibility

Because pods and clusters are independent, each can be extended without affecting the other.

- When a cluster grows, but its pod does not need to change, new servers are added to the existing Leaf pair. The orchestrator sees new nodes. Nothing else changes.
- When a pod must grow because the existing Leaf pair is at capacity, a new Leaf pair is added to the fabric — two new switches, new uplinks to both Spines, new BGP sessions — and the cluster's orchestrator registers the new nodes with the existing fabric configuration untouched.
- When a Leaf pair is upgraded (e.g., from 25G to 100G), the cluster's orchestrator does not know this happened. The upgrade is transparent to every layer above the fabric.

In no case does growth in one dimension require modification to the other.

---

## 4 — Protocol Stack

The fabric is built on many protocol layers that together form a coherent and complete stack. Each layer has a precisely defined scope, and the boundaries between layers are respected throughout the design. No protocol bleeds into another's domain.

```
Application/Compute Layer
  OpenStack · SLURM · Kubernetes · Ceph

Macro-Segmentation Layer
  VRF (L3VNI per security zone)

Overlay Control Plane
  MP-BGP EVPN (RFC 7432) — MAC/IP distribution · ARP suppression · Next-Hop Preservation

Overlay Data Plane
  VXLAN (RFC 7348, UDP/4789) — L2 extension · VNI as segment identifier

Underlay Control Plane
  eBGP (RFC 7938) — Loopback reachability · AS-per-Leaf-pair

Physical Underlay
  Two-Tier Clos (Spine-Leaf) — Full-mesh uplinks · /31 P2P · BFD
```

### The Underlay Control Plane: eBGP (RFC 7938)

eBGP is the sole underlay routing protocol. Its only responsibility is to distribute loopback reachability across the fabric: every switch's Loopback0 address must be reachable from every other switch. That is the entire scope of the underlay. No host routes, no subnet advertisements, no policy routing — only twelve /32 loopback prefixes circulate in the underlay BGP RIB, regardless of how many VMs or services are deployed on top.

The AS assignment model is deliberately asymmetric. Both Spine switches share AS 65000. Each Leaf pair operates in its own unique AS, numbered 65001 through 65005. This is not an arbitrary assignment — it is an engineered failure domain model. eBGP's AS-Path loop prevention mechanism ensures that a routing update originating from a Leaf pair (e.g., AS 65003) cannot be re-advertised back to that same Leaf pair through a different path. This prevents routing loops without any additional configuration. More importantly, eBGP limits failure visibility to routing reachability rather than full topology state. When a link on a Leaf pair fails, the Leaf sends route withdrawals to its directly connected Spines. These withdrawals propagate hop-by-hop to other Leaves only as needed to maintain reachability. Unlike link-state protocols, eBGP does not require every device to recompute the entire topology, which contains the failure domain and reduces control-plane churn. This failure domain isolation is the key advantage over link-state protocols.

**Why not OSPF or IS-IS.** Link-state IGPs distribute the entire topology to every router in the routing domain. A link failure on any device causes an LSA (or LSP) flood to every device in the domain simultaneously. In a fabric with ten Leaf switches and two Spines, a single link failure would trigger twelve simultaneous topology recalculations. eBGP contains the failure to AS boundaries: the two Spines recompute; no Leaf pair other than the affected one sees any change. Additionally, traffic engineering in eBGP is accomplished through AS-Path prepending — a deterministic, well-understood mechanism. OSPF's metric-based engineering is less precise and harder to reason about when multiple equal-cost paths exist.

**Why not iBGP.** iBGP requires either a full mesh between all peers — where the number of required sessions grows as the square of the number of peers, becoming unmanageable at scale — or a Route Reflector hierarchy that must be explicitly designed and maintained. The eBGP-per-Leaf-pair model achieves the same result with a simpler session topology: each Leaf pair peers with exactly two Spines, and the Spines peer with each other. No additional RR hierarchy is required for the underlay.

BFD (Bidirectional Forwarding Detection) is enabled on all BGP sessions. Standard BGP keepalive timers detect a peer failure in 90 to 180 seconds. BFD detects the same failure in under one second by exchanging lightweight heartbeat packets at millisecond intervals. Upon BFD failure detection, BGP withdraws routes and reconverges immediately. This sub-second failover is mandatory: without BFD, a failed Spine uplink would black-hole traffic for up to three minutes before BGP reconverged.

Only loopback /32 addresses are advertised into eBGP. Point-to-point /31 link addresses are never redistributed. This constraint keeps the BGP RIB at a fixed, minimal size: twelve prefixes, regardless of fabric growth. The P2P links are reachable to directly connected peers without BGP — they do not need to be globally visible. Advertising them would add noise to the RIB and create unnecessary state that BGP must maintain and reconverge on link failures.

### The Overlay Data Plane: VXLAN (RFC 7348)

VXLAN (Virtual eXtensible LAN) is the data-plane encapsulation for the fabric overlay. It wraps an original Ethernet frame inside a UDP packet with a 24-bit Virtual Network Identifier (VNI) in the header, then forwards it across the IP underlay using standard routed forwarding. The encapsulation and decapsulation are performed by VXLAN Tunnel Endpoints (VTEPs), which in this design are the Leaf switches themselves. Servers, VMs, and bare-metal nodes have no awareness of the overlay — they transmit and receive standard Ethernet frames.

The VNI is the globally unique segment identifier. Each logical network segment (VLAN) is assigned a VNI that is unique across the entire fabric. While VLAN IDs are locally significant to a single Leaf pair (VLAN 10 on one Leaf pair and VLAN 10 on another Leaf pair are completely unrelated), the VNI is globally significant: VNI 10010 means exactly one logical segment regardless of which Leaf pair is queried. The mapping between VLAN and VNI is configured on the Leaf pair; the fabric sees only VNIs.

**Why not VLANs.** The traditional VLAN model is limited to 4094 identifiers and propagates across the entire switching domain via STP. In a multi-pod fabric with distinct VLAN namespaces per pod, VLAN leakage — a VLAN tag appearing on a Leaf pair it was not intended for — creates forwarding anomalies that are extremely difficult to diagnose. VXLAN eliminates this: VLAN IDs are local to a Leaf pair's access ports, and the VNI identifier crosses the fabric. STP is eliminated entirely from the fabric — there are no L2 loops in a Spine-Leaf topology where all inter-switch links are routed (/31 P2P), and Leaf-to-Leaf L2 reachability is provided by VXLAN tunnels rather than by L2 spanning.

Jumbo frames (MTU 9000) are configured fabric-wide. VXLAN adds 50 bytes of encapsulation overhead (outer Ethernet header (14 bytes) + outer IP header (20 bytes) + UDP header (8 bytes) + VXLAN header (8 bytes)). A standard 1500-byte Ethernet frame generated by a server becomes a 1550-byte packet on the wire. If the underlay were left at a default 1500-byte MTU, these encapsulated packets would be dropped or require CPU-intensive fragmentation. Configuring jumbo frames in the underlay eliminates this overhead and allows encapsulated payloads to transit seamlessly.

VXLAN tunnels use UDP destination port 4789 (IANA-assigned per RFC 7348). Each Leaf uses its Loopback0 address as the VTEP source address. The underlay's eBGP-distributed loopback reachability is what enables VTEP-to-VTEP tunnel establishment: once all loopbacks are reachable, all VXLAN tunnels are implicitly possible.

### The Overlay Control Plane: MP-BGP EVPN (RFC 7432)

VXLAN defines the data-plane encapsulation but says nothing about how VTEPs discover each other, how they learn which MAC addresses and IP addresses are reachable through which tunnel, or how ARP requests are handled. Without a control plane, VTEPs would flood unknown unicast and ARP traffic to every other VTEP in the fabric — a behavior that does not scale. MP-BGP EVPN is the control plane that eliminates flooding by distributing MAC and IP reachability information through BGP rather than through data-plane learning.

In this design, EVPN uses the existing eBGP sessions — the same sessions that carry underlay loopback routes — but in a separate address family (L2VPN EVPN). This is architecturally significant: no additional peering sessions, no additional protocol adjacencies. The underlay and overlay control planes share the same BGP transport, separated cleanly by address family.

EVPN carries four route types relevant to this design:

| Route Type | Name | Purpose in This Design |
|------------|------|----------------------|
| Type 1 | Ethernet Auto-Discovery | ESI multihoming: advertises Ethernet Segment membership and enables mass MAC withdrawal on link failure |
| Type 2 | MAC/IP Advertisement | Distributes host MAC and IP bindings from each Leaf; enables remote Leaves to answer ARP requests locally without flooding |
| Type 3 | Inclusive Multicast Ethernet Tag (IMET) | Builds the ingress replication list for BUM traffic per VNI; automatically populated — no manual configuration required |
| Type 5 | IP Prefix Route | Enables inter-subnet routing between VRFs; required for any authorized cross-zone communication |

**Next-Hop Preservation in eBGP.** Since these are eBGP sessions, the Spines would normally rewrite the BGP Next-Hop to their own IP addresses. To ensure VXLAN tunnels form directly between Leaf VTEPs, the Spines are configured to preserve the Next-Hop for the EVPN address family. This allows the control plane to remain unified on the existing eBGP physical peering while maintaining the end-to-end data plane required for VXLAN.

**ARP suppression.** When a VM sends an ARP request, its local Leaf VTEP — having received the target IP's binding via EVPN Type 2 — responds locally on behalf of the remote host. The ARP request never enters the fabric as a broadcast. This eliminates what is, in large VLAN-based fabrics, one of the dominant sources of broadcast traffic and control-plane load.

**Alternative design.** While this design uses a unified eBGP model for both underlay and overlay, an iBGP-based overlay is a valid alternative. The underlay continues to run eBGP to establish loopback reachability; once loopbacks are mutually reachable, a second layer of iBGP sessions is formed between them exclusively for EVPN route exchange. Each Leaf therefore maintains two distinct sets of adjacencies: eBGP sessions to directly connected Spines for underlay transport, and iBGP sessions over loopbacks for EVPN. The Spines act as Route Reflectors for the iBGP sessions, eliminating the need for a full iBGP mesh between all Leaves. Because iBGP does not rewrite the BGP next-hop by default, the receiving Leaf retains the originating VTEP address as the next-hop and establishes VXLAN tunnels directly — without the explicit next-hop-unchanged configuration that the eBGP model requires on the Spines. The cost of this simplification is additional operational complexity: two session types must be configured and maintained, and the Route Reflector role on the Spines becomes an explicit design concern separate from the underlay. The unified eBGP model was chosen here because it reduces the number of distinct protocol roles to one, at the cost of a single additional per-Spine configuration directive.

### ESI Multihoming

Servers connect to both switches in their Leaf pair using standard LACP (Link Aggregation Control Protocol — IEEE 802.3ad, the standard that negotiates the bundling of multiple physical Ethernet links into a single logical interface, providing both increased bandwidth and link-level failover) bonding, providing link-level redundancy. Each such bonded connection is identified by an Ethernet Segment Identifier (ESI) — a 10-byte value that uniquely identifies the physical link bundle. The ESI is advertised into EVPN as a Type 1 route, synchronizing link state and active-forwarder election between the two Leaf switches over the existing BGP control plane.

**Why ESI over MLAG.** MLAG requires a vendor-proprietary inter-switch peer-link cable. This peer-link is a single point of physical failure (if it fails, both switches independently believe they are the primary forwarder, causing a split-brain condition), adds proprietary state that must be synchronized out-of-band, and limits redundancy to exactly two switches by design. ESI Multihoming (RFC 7432) requires no peer-link: the BGP control plane already carries the necessary synchronization information. If a third Leaf switch were added to the pair in the future, ESI would extend to N-way redundancy with zero additional infrastructure. MLAG would require a complete redesign.

ESI introduces two correctness problems that EVPN solves automatically through protocol mechanisms:

**Designated Forwarder (DF) Election.** When BUM traffic arrives at a VNI that is served by both Leaves in a pair (because both connect to the same Ethernet Segment), both Leaves would forward the frame to the server if no coordination existed — the server would receive every broadcast twice. EVPN elects exactly one Designated Forwarder per Ethernet Segment: only the DF Leaf forwards BUM traffic into that segment; the non-DF Leaf discards it. The election is deterministic, based on the Leaf's loopback IP modulo the number of candidate forwarders, and is reconverged automatically upon any link state change.

**Split Horizon.** When a Leaf receives a frame from a server on an Ethernet Segment and replicates it as BUM traffic, it must not send a copy back toward the other Leaf in the same ESI — that would create a forwarding loop. The ESI tag on the EVPN Type 1 route identifies the segment: a VTEP never forwards traffic back into the same Ethernet Segment from which it was received.

### Symmetric IRB and Anycast Gateway

Bridging (Layer 2) forwards frames based on MAC address within a single segment — a VNI. Routing (Layer 3) forwards packets based on IP address between segments. IRB — Integrated Routing and Bridging — means a single device does both: it bridges within a VNI and routes between VNIs. In this fabric, every Leaf is an IRB device.

Inter-subnet routing — traffic between two hosts in different VNIs but within the same VRF — therefore begins the moment a VM sends a packet whose destination IP is outside its own subnet. Its local Leaf sees that the destination belongs to a different VNI and must route, not bridge. The question is: which Leaf performs the routing lookup, and what does the packet look like while it transits the fabric?

Under **Asymmetric IRB**, the ingress Leaf performs all routing. It looks up the destination IP, identifies the destination VNI, rewrites the destination MAC to the target VM's MAC, and forwards the packet already encapsulated in the destination VNI. The egress Leaf simply bridges the frame to the destination VM — no routing occurs there. This works, but carries a significant state cost: for the ingress Leaf to route into a remote VNI, it must hold that VNI's subnet and all its MAC/IP bindings locally. Every Leaf must therefore maintain routing state for every VNI in the entire fabric, including VNIs it has no servers in. State grows with the size of the fabric, not with what each Leaf actually hosts.

**Symmetric IRB** eliminates this by having both the ingress and egress Leaf perform a routing lookup. The packet crosses the fabric in a neutral transit identifier — the L3VNI, one per VRF — rather than in either the source or destination VNI. The ingress Leaf routes the packet out of the source VNI into the L3VNI. The egress Leaf receives it in the L3VNI, routes it into the destination VNI, and bridges it to the target VM. Each Leaf only needs routing state for the VNIs it directly serves, plus one L3VNI per VRF as the transit identifier. The word "symmetric" refers to the fact that both the ingress and egress Leaf perform a routing lookup — unlike the asymmetric model, where only the ingress Leaf does. Symmetric IRB confines per-Leaf routing state to the minimum possible: the subnets it directly hosts, plus one L3VNI entry per VRF.

For Symmetric IRB to function, every Leaf must be capable of acting as the first-hop router — the default gateway — for any VM it hosts. This is where **Anycast Gateway** becomes necessary. Normally, a default gateway is a unique IP on a specific device. If a VM migrates from one Leaf to another, its cached gateway IP and MAC no longer resolve on its new Leaf; it must re-ARP, discover the new gateway, and update its cache, causing a brief forwarding interruption. Anycast Gateway solves this by assigning the same gateway IP and the same gateway MAC address to every Leaf that serves a given VNI. From the VM's perspective there is one gateway, and that gateway answers from wherever the VM currently is. Migration is instantaneous and transparent — the VM's ARP cache remains valid because the MAC and IP it already knows are present on the new Leaf.

The two mechanisms are interdependent. Symmetric IRB defines the routing path between subnets and requires every Leaf to be a capable first-hop router for its hosted VNIs. Anycast Gateway ensures that every Leaf satisfies that requirement, and that VM mobility does not disrupt it. Together they allow the fabric to route between subnets without centralizing routing at a single device, without bloating every Leaf with global state, and without making VM migration visible to the VM itself.

### BUM Traffic: Head-End Replication

Despite EVPN's ability to suppress most ARP flooding through control-plane learning, BUM (Broadcast, Unknown Unicast, Multicast) traffic cannot be entirely eliminated. DHCP Discover broadcasts, ARP requests for hosts not yet known to the control plane, and genuine multicast traffic must still be handled. The mechanism used is Head-End Replication (HER), also called Ingress Replication — the ingress VTEP produces one unicast VXLAN-encapsulated copy of the frame per remote VTEP and forwards each copy independently, rather than relying on network-layer multicast to distribute the frame.

The set of remote VTEPs to replicate to is maintained per VNI as a replication list, built automatically from EVPN Type 3 (IMET) routes: when a Leaf joins a VNI by advertising a Type 3 route, all other Leaves add it to their replication list for that VNI. No manual configuration is required.

**Why not PIM?** IP multicast with PIM as the BUM transport mechanism requires a multicast routing infrastructure in the underlay, including Rendezvous Points and multicast group management. At this fabric's scale — ten VTEPs — HER sends at most nine unicast copies per BUM frame; the bandwidth overhead is negligible, and the operational simplicity is substantial. PIM is an appropriate choice for fabrics with hundreds of VTEPs where HER's per-VTEP replication cost becomes meaningful, but that threshold is not approached here, and the horizontal extensibility model of this fabric does not assume unbounded growth. Should the VTEP count grow significantly, replacing HER with PIM is a contained underlay change that requires no modification to the EVPN overlay or any other fabric component. Therefore, PIM is strictly excluded from this design; no multicast routing is configured anywhere in the fabric.

---

## 5 — Macro-Segmentation

### VRFs as Hardware-Enforced Security Zones

Security zones are implemented as VRF (Virtual Routing and Forwarding) instances, not as VLAN ACLs or firewall rules alone. Each VRF maintains a completely independent routing table. By default, no inter-VRF routes exist — a host in VRF-PEDAGOGY has no routing path to VRF-STAFF, not because a firewall blocks the path, but because the path does not exist in either routing table. A missing route is a stronger security guarantee than a firewall rule: there is nothing to accidentally misconfigure, no rule to inadvertently omit, and no policy to bypass through a crafted packet.

Each VRF is assigned a unique L3VNI. The L3VNI is the overlay identifier used in Symmetric IRB: when traffic crosses subnets within the same VRF, the transit VXLAN header carries the L3VNI rather than the L2VNI. This allows the egress Leaf to identify the VRF context of the packet and perform the correct routing lookup. In Symmetric IRB, the ingress Leaf rewrites the inner destination MAC to the fabric-wide unique Router MAC of the egress Leaf. The egress Leaf then uses this MAC to trigger a second routing lookup toward the destination host in the final L2VNI. The Router MAC is purely internal to the fabric and carries no external security significance.

Any cross-VRF communication that is permitted by architecture (and listed in the inter-cluster communication matrix that will be presented later) must traverse the HA (High Availability — a deployment configuration in which two or more devices operate together so that the failure of one does not interrupt service) Firewall pair in the Border Pod. The firewall performs stateful L7 inspection and enforces explicit permit policies. The VRF routing model and the firewall are complementary: the VRF ensures that no unauthorized path exists at the routing level; the firewall ensures that authorized paths are inspected and logged.

### VRF Trust Zone Table

Five VRFs define the macro-segmentation boundaries of the fabric. The table below defines each zone's trust posture and L3VNI. The subnets listed in the VNI Segment Table (Section 5.3) are host subnets belonging to L2VNIs that are members of these VRFs; they are distinct from the L3VNI itself, which has no host addresses.

| VRF | Trust Zone | L3VNI | Security Posture |
|-----|-----------|-------|-----------------|
| VRF-ADMINISTRATION | HR, Finance, Core Databases | 50010 | Highest sensitivity. No outbound routes by default. Inbound only via explicit firewall policy from VRF-STAFF. Data-at-rest encryption mandatory on all volumes. |
| VRF-STAFF | Admin, Faculty, AI/HPC, Core Services | 50020 | Full internal fabric access. Can reach VRF-ADMINISTRATION via explicit firewall policy. Cannot be reached from VRF-PEDAGOGY without explicit policy. |
| VRF-PEDAGOGY | Student Labs, TP Servers | 50030 | Internet access only. No routes to VRF-STAFF or VRF-ADMINISTRATION. Students are treated as untrusted principals even inside the campus perimeter. |
| VRF-PUBLIC | Public-Facing DMZ | 50040 | Internet-facing services only. Contains no routes to any internal VRF — structurally absent. A compromised DMZ server has no routing path to any internal zone, independent of firewall state. |
| VRF-ORIENTATION | BAC Orientation Operation | 50050 | Zero routes. Activated approximately two months per year. The dedicated third ISP fibre is the only permitted path in or out. Has zero routing adjacency with the production fabric at all times. |

VRF-PUBLIC deserves specific emphasis. The absence of internal routes in VRF-PUBLIC is not a firewall policy — it is a routing table property. The route table for VRF-PUBLIC is populated at provisioning with only the routes needed to reach the public internet via the ISP uplinks. No internal RFC 1918 prefixes (RFC 1918 defines the IPv4 address ranges reserved for private networks — 10.0.0.0/8, 172.16.0.0/12, and 192.168.0.0/16 — which are not routable on the public internet) are imported into VRF-PUBLIC. This creates a structural isolation guarantee: even if the perimeter firewall were bypassed, a process running in the DMZ would find no route to internal networks. It cannot reach what it cannot route to.

### VNI Segment Table

The following table defines all logical network segments in the fabric. This is the authoritative mapping between VNI, VLAN, segment name, VRF, host subnet, and Leaf pair attachment. VNI values follow the convention 10 000 + VLAN ID (for example, VLAN 100 maps to VNI 10100).

> **Note:** VNI 10030 (LMS-STAFF) and VNI 10040 (SERVICES-WEB) are assigned to admin-leaf, not border-leaf. Both are VRF-STAFF internal services with no operational requirement for border proximity; assigning them to border-leaf would incorrectly place general administrative services on a Leaf pair dedicated exclusively to external-facing and air-gapped functions.

| VNI | VLAN | Segment Name | VRF | Host Subnet | Leaf Attachment | Notes |
|-----|------|-------------|-----|-------------|----------------|-------|
| 10010 | 10 | STUDENT-TP | VRF-PEDAGOGY | 192.168.10.0/24 | studentleaf-01/02 | TP servers for supervised lab sessions |
| 10020 | 20 | STUDENT-PROJ | VRF-PEDAGOGY | 192.168.20.0/24 | studentleaf-01/02 | Isolated student project VMs |
| 10030 | 30 | LMS-STAFF | VRF-STAFF | 192.168.30.0/24 | admin-leaf-01/02 | Moodle LMS — managed service, VRF-STAFF; students access via explicit firewall policy |
| 10040 | 40 | SERVICES-WEB | VRF-STAFF | 192.168.40.0/24 | admin-leaf-01/02 | Internal web portals, employee and admin interfaces |
| 10050 | 50 | CORE-INFRA | VRF-STAFF | 192.168.50.0/24 | admin-leaf-01/02 | AD, DNS, DHCP, NTP, Ansible Tower, monitoring |
| 10060 | 60 | HR-FINANCE | VRF-ADMINISTRATION | 192.168.60.0/24 | admin-leaf-01/02 | HR and Finance systems; data-at-rest encryption mandatory |
| 10070 | 70 | AI-GPU | VRF-STAFF | 192.168.70.0/24 | hpc-leaf-01/02 | GPU servers, SLURM/K8s nodes; RoCEv2 enabled; lossless underlay required: PFC and ECN configured on L5/L6 to maintain RDMA performance under congestion. |
| 10080 | 80 | STORAGE-SAN | VRF-STAFF | 192.168.80.0/24 | storageleaf-01/02 | SAN, NAS, FTP, Backup |
| 10090 | 90 | BAC-ORIENT | VRF-ORIENTATION | 192.168.90.0/24 | border-leaf-01/02 | Activated ~2 months/year; zero routes to other VRFs; third ISP fibre only |
| 10100 | 100 | DMZ-WEB | VRF-PUBLIC | 192.168.100.0/24 | border-leaf-01/02 | Public-facing servers; no routes to any internal VRF |
| 10110 | 110 | MGMT-OOB | OOB (not EVPN) | 172.16.0.0/24 | All devices (mgmt port only) | Out-of-band management; native VLAN 110. Not EVPN, never connected to production fabric; listed for completeness only. |

---

## 6 — Pod Service Assignment

### Overarching Assignment Principle

Service-to-pod assignment is determined by two independent criteria applied jointly: traffic profile and security classification. A service's traffic profile determines the required oversubscription ratio and hardware characteristics of its Leaf pair. A service's security classification determines which VRF it belongs to, which in turn determines which inter-zone policies apply. When both criteria agree on a Leaf pair, the assignment is unambiguous. When they conflict, the more restrictive criterion governs.

Grouping services by traffic profile ensures that a single link's hardware configuration — buffer depth, oversubscription, QoS policy — matches the actual workload class. Grouping services by security classification ensures that hardware-enforced isolation exists at the Leaf pair boundary: a compromised server in Pod 5 (Student) cannot directly reach a server in Pod 2 (Admin) at the L2 layer, because no L2 adjacency between student-leaf and admin-leaf exists. Inter-pod communication is always L3, always routed through the fabric, always subject to VRF routing policy, and for cross-VRF paths, always subject to firewall inspection.

### Pod 1 — Border / DMZ Pod (Leaf Pair L1/L2)

**Oversubscription: 2:1**

The Border Pod is the fabric's single point of external contact. Its Leaf pair (L1/L2) connects upward to both Spines and outward to the border routers, HA (High Availability) firewalls, and the external ISP interfaces. The separation of the Border Leaf pair from all compute-facing Leaf pairs is a critical architectural decision: it isolates all external routing churn — BGP reconvergence with ISPs, DDoS absorption, prefix fluctuations — from the internal fabric. A BGP oscillation with an upstream ISP affects only the Border Leaf pair; no compute Leaf pair sees any route change.

The 2:1 oversubscription ratio is appropriate because North-South bandwidth is inherently capped by the ISP uplink capacities. No workload in this pod can ever generate more traffic than the ISPs can deliver, so a higher oversubscription ratio would provide no benefit and would only reduce burst tolerance.

The Border Pod hosts the following services:

- **Border Routers** — Terminate external BGP sessions with ISPs; advertise only the school's aggregate prefix outbound; accept only the default route inbound. Inbound prefix-lists reject anything beyond the default route, preventing a misconfigured or malicious upstream from injecting internal-network prefixes into the fabric's routing table.

- **HA Next-Generation Firewalls** — Active/Active pair. The single policy enforcement point for all North-South traffic and all authorized cross-VRF traffic. L7 stateful inspection. Connection state is continuously synchronized between both units over a dedicated state-sync link; each unit holds a full, current copy of the session table. A failover or split-brain condition therefore does not cause session loss — the surviving unit already has all active session state and can continue forwarding without interruption.

- **DMZ Web Servers (VNI 10100, VRF-PUBLIC)** — Public-facing servers with no internal routing path. Placed in the Border Pod because their traffic is externally originated and must enter the fabric at the border. Placing them on an internal Leaf pair would force all their traffic to traverse the fabric twice — once to the internal Leaf, once back to the border — adding latency and consuming internal fabric bandwidth unnecessarily.

- **BAC Orientation Nodes (VNI 10090, VRF-ORIENTATION)** — Three bare-metal 1U nodes that serve the national BAC orientation operation. These nodes are powered off for approximately ten months per year. Their Border Pod attachment is mandatory: the dedicated third ISP fibre that is activated during the orientation period terminates on a dedicated Border Leaf interface. No other Leaf pair has physical access to this uplink. The VRF-ORIENTATION routing table contains zero routes to the production fabric.

BAC Orientation nodes are deployed as bare-metal rather than VMs. The BAC orientation platform is a nationally mandated system that may include integrity or anti-tampering requirements assuming direct hardware access; a hypervisor introduces an unauditable abstraction layer and potential certification incompatibility. More critically, a powered-off bare-metal node has zero attack surface — it cannot be remotely compromised, scanned, or exfiltrated regardless of any software vulnerability. No virtualization layer can offer an equivalent guarantee.

The capital expenditure inefficiency of this choice is real: three 1U servers and their associated rack space, power provisioning, and cabling are reserved for approximately two months of active use per year. This cost is accepted as the price of the security posture and the national mandate. Alternatives such as re-purposing the nodes as general compute during the off-season were considered and rejected: re-purposing requires attaching the nodes to the production fabric, which reintroduces the attack surface that powered-off isolation eliminates, and creates an operational dependency that must be unwound before each orientation window. The CapEx inefficiency is a known and accepted trade-off, not an oversight.

### Pod 2 — Admin / Core Infra Pod (Leaf Pair L3/L4)

**Oversubscription: 3:1 compute; 1:1 RAM**

The Admin Pod hosts Cluster 2 — the set of services that every other cluster depends on for operation. These are always-on, latency-sensitive services; their failure is equivalent to a fabric outage for all dependent workloads.

The 3:1 compute oversubscription ratio is appropriate because admin services (Active Directory, DNS, NTP) are chatty but low-volume. Their peak bandwidth is limited by the number of client queries, not by data transfer throughput. Memory oversubscription, however, is disabled (1:1 RAM). AD authentication lookups and DNS resolution are highly latency-sensitive: a 50ms DNS response delay caused by a swap event would affect every host in the fabric that needs name resolution. Memory oversubscription introduces unpredictable latency spikes from swap-induced page reclaim; disabling it eliminates this risk entirely.

The Admin Pod contains two logical sub-groups: core network services (CORE-INFRA, VNI 10050) and sensitive administrative data (HR-FINANCE, VNI 10060). These sub-groups are co-located in the same pod but belong to different VRFs (VRF-STAFF and VRF-ADMINISTRATION respectively), maintaining their isolation while sharing the same physical Leaf pair. This co-location is justified because both groups share the same traffic profile (low-volume, latency-sensitive) and the same hardware requirements, and co-location reduces operational complexity by limiting the number of physical locations that require HA treatment.

- **Active Directory (AD)** — The authentication authority for the entire fabric. Every LDAP bind, every Kerberos ticket, every VPN authentication traverses this service. It must be the most available non-network service in the design.

- **DNS** — BIND 9 serves as the authoritative nameserver for esi.internal; Unbound serves as the recursive resolver for all internal hosts. Each VRF receives its DNS server IP via DHCP option 6. The DNS instance serving VRF-PUBLIC has no visibility into internal zones — a query for an internal hostname from the DMZ returns NXDOMAIN.

- **DHCP (Kea ISC)** — One Kea instance per VRF requiring dynamic addressing. DHCP relay agents are configured on each Leaf's SVI (Switched Virtual Interface — the Layer 3 IP interface instantiated on a Leaf switch for each VNI it serves; it holds the subnet's default gateway address and is the point at which the Leaf performs inter-subnet routing and DHCP relay), forwarding client requests from access VNIs to the Kea server in this cluster. Static reservations are used for all infrastructure nodes; the dynamic pool serves only lab VMs.

- **NTP (Chrony, Stratum 2)** — Synchronized to an upstream public Stratum 1 server via the Border uplinks. (In the NTP reference hierarchy: Stratum 0 is an atomic or GPS reference clock; Stratum 1 servers synchronize directly to Stratum 0; Stratum 2 servers synchronize to Stratum 1 — this instance is therefore one hop from a primary reference clock.) All fabric switches and compute hosts sync to this instance. Clock synchronization is not optional: Kerberos ticket validity and forensic log correlation both require clock skew not to exceed 5 minutes (the maximum tolerance specified in RFC 4120). Unsynchronized clocks produce logs that cannot be correlated across devices — a BGP event reconstructed from twelve switches with 5-minute clock drift is forensically worthless.

- **Ansible Tower (AWX)** — The single source of truth for all switch and server configuration. Idempotent playbooks manage switch underlay/overlay configuration, OS hardening, and service deployment. Manual changes to switch CLIs are prohibited in production; all changes are made through playbooks and logged automatically by AWX. This control makes the entire fabric reproducible from source.

- **Prometheus + Grafana** — Time-series metrics scraped from OpenStack, Ceph, SLURM, Kubernetes, and server-level exporters. Provides live dashboards for fabric utilization, cluster health, and storage capacity.

- **Zabbix** — Infrastructure monitoring and threshold alerting. SNMP polling of all switches (interface counters, BGP peer state, CPU/memory). Replaces Cacti: Zabbix is a strict superset covering all SNMP graphing capability plus threshold alerting and a maintained codebase. The two tools (Zabbix and Prometheus) are complementary, not redundant: Zabbix monitors the network layer and infrastructure state; Prometheus monitors application-layer metrics. Neither covers the other's domain adequately.

- **Centralized Syslog (rsyslog / Loki)** — All switch and server syslog streams are forwarded to a central log collector. Forensic analysis and incident correlation require all logs in one place with synchronized timestamps. Without central syslog, reconstructing a BGP event across twelve switches requires logging into each device individually. The collector depends on the NTP instance above to guarantee timestamp consistency across all log sources.

- **Moodle LMS (Learning Management System) (VNI 10030, LMS-STAFF)** — The Learning Management System is a managed administrative service operated by faculty, even though it is student-facing. It is placed in VRF-STAFF rather than VRF-PEDAGOGY because its configuration, content management, and grade data are administrative assets. Students access Moodle through an explicit firewall policy (VRF-PEDAGOGY → VRF-STAFF), which is consistent with the zero-trust model requiring explicit permits for all cross-zone paths. Placing Moodle in VRF-PEDAGOGY would expose it to lateral movement from compromised student VMs.

- **Internal Web Portals (VNI 10040, SERVICES-WEB)** — Employee-facing interfaces (HR self-service, administrative portals). VRF-STAFF placement is correct: these services have no external exposure and are accessed exclusively by authenticated staff. They share the Admin Leaf pair because their traffic profile is identical to other admin services.

- **HR and Finance Systems (VNI 10060, VRF-ADMINISTRATION)** — The highest-sensitivity data in the fabric. Isolated in VRF-ADMINISTRATION with no outbound routes; accessible only via explicit firewall policy from VRF-STAFF. Data-at-rest encryption (LUKS) is mandatory on these volumes. Co-location with CORE-INFRA is justified on hardware grounds; VRF isolation ensures that a compromise of any VRF-STAFF service cannot pivot to VRF-ADMINISTRATION without traversing the firewall.

FTP (vsftpd) is explicitly not in this pod. File transfer for backup distribution and dataset staging is hosted in the Storage Pod (Cluster 5). This is a deliberate placement decision: FTP's traffic profile — large, sustained transfers — matches the 1:1 non-blocking storage Leaf pair. Hosting it in the Admin Pod would consume admin bandwidth and introduce unnecessary contention with latency-sensitive services.

### Pod 3 — AI / HPC Pod (Leaf Pair L5/L6)

**Oversubscription: 1:1 (non-blocking)**

The AI/HPC Pod is the performance-critical cluster. Non-blocking bandwidth is non-negotiable: a GPU training job over RDMA can saturate a 100G link for hours. Any oversubscription on this Leaf pair would cause packet drops, triggering RDMA retransmissions or — worse — aborting a multi-hour training run entirely. The 1:1 ratio is the only correct choice, and it is implemented with 100G uplinks to the Spines rather than 25G.

RoCEv2 (RDMA over Converged Ethernet, version 2) is enabled exclusively on L5/L6. GPU-to-GPU communication during distributed training uses RDMA, which requires a lossless Ethernet environment. Two mechanisms enforce losslessness: PFC (Priority Flow Control) pauses upstream senders when a switch buffer approaches exhaustion, preventing drops; ECN (Explicit Congestion Notification) signals congestion to endpoints before drops occur, allowing rate adaptation. Both mechanisms are scoped to the AI/HPC Pod switches only. Enabling PFC fabric-wide would introduce head-of-line blocking in all other pods, degrading student, admin, and storage traffic. The scoping to L5/L6 is precise and intentional.

Cluster 3 hosts two co-located orchestrators on the same physical nodes:

- **SLURM** — Dedicated to batch training jobs requiring full, exclusive GPU allocation for hours at a time. SLURM's queue-based scheduling model is the industry standard for HPC: jobs are admitted when the required resources are available, guaranteed exclusive access for the duration, and evicted at time limit expiry. No other orchestrator provides these guarantees.

- **Kubernetes (k3s — a CNCF-certified, lightweight Kubernetes distribution with a reduced binary footprint, well-suited to nodes that run both compute workloads and an orchestration agent concurrently)** — Dedicated to inference serving endpoints that are short-lived, API-driven, and can share GPU capacity via NVIDIA MIG (Multi-Instance GPU) partitioning. K8s auto-scales pods on demand and integrates natively with the NVIDIA device plugin.

These two orchestrators coexist on the same physical nodes through Linux cgroups v2 (Control Groups version 2 — a Linux kernel subsystem that organizes processes into hierarchical groups and enforces hard limits on their CPU, memory, and device access) resource partitioning. SLURM jobs are assigned to a dedicated cgroup hierarchy with exclusive GPU access; K8s pods run in a separate hierarchy with access to unallocated GPU capacity. This coexistence is architecturally sound because the two workload types are temporally complementary: when no training job is queued, GPUs that would otherwise sit idle are available for inference serving.

No hypervisor exists in Cluster 3. A hypervisor introduces GPU scheduling jitter of 50 to 200 microseconds per kernel launch, which compounds into minutes of wasted time over a multi-hour training run. PCIe passthrough (VFIO — Virtual Function I/O, a Linux kernel framework that assigns a physical PCIe device, such as a GPU, directly and exclusively to a virtual machine, bypassing the hypervisor's device emulation layer) in a hypervisor also adds non-deterministic DMA latency. Bare-metal eliminates both.

The SLURM controller (slurmctld) runs as a VM in Cluster 2 (Admin), not on the bare-metal nodes. This is correct: the controller is a management-plane process with low resource requirements and high availability requirements. Running it on the same hardware as the GPU workers would make the controller vulnerable to the same hardware failures that affect the compute nodes. The slurmd daemons run on each GPU node and communicate with the controller over VRF-STAFF.

### Pod 4 — Storage Pod (Leaf Pair L7/L8)

**Oversubscription: 1:1 to 1.5:1**

The Storage Pod is the shared storage substrate for Clusters 1 and 2 (OpenStack Cinder and Glance), Cluster 3 (CephFS for training datasets), and all backup workloads. A single backup job can saturate a link for hours; a Ceph rebalancing event (triggered by an OSD — Object Storage Daemon, the Ceph process that manages one physical disk and serves its data to the cluster — failure) can push sustained high bandwidth for extended periods. The near-non-blocking ratio (maximum 1.5:1) preserves throughput determinism for these sustained transfer patterns without requiring the full 1:1 budget of the AI/HPC pod.

Cluster 5 is not a compute cluster — it is a dedicated Ceph cluster. It exposes three storage services:

- **Ceph RBD (Block Storage)** — Consumed by OpenStack Cinder in Clusters 1 and 2. VM root disks and data volumes are thin-provisioned on Ceph. Live VM migration between compute nodes is possible at any time because the disk never resides on the compute node itself — the compute node is entirely stateless with respect to storage.

- **CephFS (Shared Filesystem)** — Consumed by Cluster 3 for training dataset reads and checkpoint writes. Mounted via NFS-Ganesha (a user-space NFS server that exports CephFS over the standard NFS v4 protocol, allowing clients that lack a native CephFS kernel module to access the filesystem transparently) or the native kernel CephFS client on GPU nodes. Local NVMe SSDs on GPU nodes serve as a fast scratch tier for active jobs; CephFS is the persistent backend.

- **Ceph RGW (RADOS Gateway)** — An HTTP object storage interface built on RADOS that exposes an S3-compatible API, consumed by OpenStack Glance (VM image registry) and Harbor (container image registry). Images are stored once in Ceph and cloned copy-on-write for each new VM — provisioning a new lab VM takes seconds, not minutes.

Separate RADOS (Reliable Autonomic Distributed Object Store — the underlying distributed object store on which all Ceph services, including RBD, CephFS, and RGW, are built) pools exist for each consumer cluster. A Cluster 1 Ceph credential cannot read Cluster 2 data, and vice versa. Ceph RBAC (Role-Based Access Control — a mechanism that grants or denies storage operations based on the identity of the credential presented to the Ceph cluster) enforces this at the storage protocol level, independently of network-layer VRF isolation.

### Pod 5 — Student / Lab Pod (Leaf Pair L9/L10)

**Oversubscription: 4:1**

The Student Pod hosts Cluster 1 — the general-purpose, student-facing compute cluster. The 4:1 oversubscription ratio is a deliberate and correct choice, not a cost-cutting measure. Student and lab workloads are inherently bursty and temporally concentrated: peak demand occurs during scheduled lab sessions, followed by near-zero utilization during lectures, weekends, and off-hours. A 1:1 oversubscription ratio would waste hardware capacity that is statistically idle for the majority of the time.

**Cluster 1 — Fully Virtualized (OpenStack + KVM)**

OpenStack with KVM is the correct hypervisor stack for this cluster. It is fully open-source, API-driven, multi-tenant by design, and directly integrable with Neutron/OVN for EVPN fabric attachment. VMware would introduce per-socket licensing costs and proprietary lock-in to a specific vendor's EVPN implementation. Proxmox lacks native multi-tenancy and cannot integrate with Neutron's VRF-per-tenant model at this level. No alternative satisfies all three requirements simultaneously.

OpenStack Nova manages VM placement across the six-node pool with 4:1 CPU oversubscription and 1.5:1 RAM oversubscription. Student workloads are bursty and idle most of the time; these ratios allow the six physical nodes to host significantly more VMs than raw capacity suggests, with negligible contention during off-peak hours. The RAM ratio of 1.5:1 (not higher) is chosen to limit swap-induced latency spikes during peak lab sessions.

VM networking uses Neutron with OVN (Open Virtual Network). OVN runs distributed on each compute node and handles the stitching of tenant virtual networks into the EVPN/VXLAN fabric via the Leaf VTEP. No standalone SDN controller is required — the control plane is distributed.

Campus wireless infrastructure — Access Points, SSIDs, and the Sophos URL filter — is excluded from this pod. No AP is cabled to L9/L10 under any SSID or VLAN assignment. Wired lab infrastructure in newer campus buildings uplinks via fibre to student-leaf-01/02; older buildings route through the legacy BP distribution switches over an EtherChannel uplink to student-leaf-01/02, eliminating the congestion bottleneck of the prior topology. The rationale for wireless exclusion and the WiFi Controller integration mechanism are specified in the Campus Internet Access section.

---

## 7 — Campus Internet Access & Wireless Infrastructure

Campus internet access and campus wireless infrastructure (WiFi) are excluded from the data center fabric. This is not an operational constraint — it is a deliberate architectural decision, each leg of which is independently justified by performance determinism, reasoning clarity, and the structural security principle.

### Design Decision

The rejected alternative proposed connecting campus Access Points (APs) directly to student-leaf-01/02 access ports mapped to VRF-PEDAGOGY, and placing the Sophos URL filter inline within the Border Pod as the campus internet gateway. This fails on all three governing principles simultaneously, and each failure is independent of the others.

**Performance determinism.** Pod 5 is dimensioned at a 4:1 oversubscription ratio calibrated specifically for student lab VM traffic. As established in the Pods and Clusters section, that traffic profile is bursty but temporally bounded by the lab schedule — peak demand is predictable, and the 4:1 ratio is correct precisely because of that predictability. Campus WiFi traffic is neither bounded nor schedulable: it peaks during lunch breaks, personal device activity, and common-area usage, with no relationship to the lab timetable. Placing both traffic classes on a single Leaf pair would require L9/L10's hardware configuration — buffer depth, oversubscription ratio, QoS policy — to satisfy two mutually incompatible profiles simultaneously. The Pods and Clusters section states explicitly that this is impossible, and that pod isolation exists precisely to prevent it.

**Reasoning clarity.** The Border Pod's defined role is unambiguous: BGP termination with upstream ISPs, HA firewall enforcement for all North-South and cross-VRF traffic, and DMZ services. Every service placed there satisfies that definition. A campus URL content filter (Sophos) does not — it is a campus IT operations appliance, not a data center perimeter security component. Placing it in the Border Pod conflates two distinct operational domains. The Border Pod is the fabric's external routing and enforcement boundary; it is not a shared rack for appliances whose function belongs at the campus edge.

**Structural security.** Security in this design is a structural property, achieved through the physical absence of unintended paths rather than through policies applied on top of them. APs are deployed in physically unsecured public hallways and common areas. A direct physical cable from those endpoints into the data center switching fabric introduces a Layer 1 and Layer 2 threat vector that VRF isolation alone cannot neutralise: a physically compromised AP patched into a Leaf access port has L2 adjacency with every other device on that port's VNI before any routing policy is consulted. The BAC Orientation design establishes the governing precedent — a powered-off bare-metal node offers a stronger security guarantee than any logical isolation policy applied to a live device on the same hardware. Physical absence is architecturally superior to logical isolation, and that principle is not selectively applied.

### Adopted Physical Topology

Under the adopted design, APs uplink exclusively into the existing campus distribution switches — the legacy BP tier. The Sophos appliance sits inline between the campus distribution layer and the external internet connection, at the campus edge where campus user traffic originates and terminates. Neither component is cabled to any Leaf switch in the data center fabric. Campus buildings reach the internet through the campus distribution path; the data center fabric carries only data center workloads.

The campus distribution layer therefore retains its existing role as the aggregation and internet-access point for all wireless and wired campus clients. No modification to the BP tier is required by this architecture.

### WiFi Controller Management Integration

The centralised WiFi Controller is deployed as a virtual machine within Cluster 1 (VRF-PEDAGOGY), on student-leaf-01/02. This placement is correct: the controller is a data center workload whose managed APs happen to be physically located outside the data center. Management reachability from the campus distribution layer must be maintained without merging the campus and data center traffic planes.

This is accomplished through a single, dedicated physical uplink from the campus distribution switch to a designated access port on border-leaf-01. That port is placed in a new, purpose-built segment: WIFI-CTRL-MGMT (VNI 10120, VLAN 120), instantiated within a dedicated micro-VRF — VRF-WIFI-CTRL — that exists solely for this path. VRF-WIFI-CTRL contains exactly one forwarding entry: a static /32 host route to the WiFi Controller's management IP, resolved via EVPN Type 5 through the fabric toward student-leaf-01/02. No default route exists in VRF-WIFI-CTRL. No other prefixes are present. No EVPN route export from VRF-WIFI-CTRL to any other VRF is configured. Traffic arriving on the WIFI-CTRL-MGMT access port and addressed to any destination other than that single /32 is dropped at the Border Leaf by the absence of a matching route — consistent with the design's general security model, in which a missing route is the enforcement mechanism rather than an explicit deny rule.

The WIFI-CTRL-MGMT segment must be added to the VNI segment table in the Physical Architecture section as follows:

| VNI | VLAN | Segment | VRF | Subnet | Leaf Attachment | Notes |
|-----|------|---------|-----|--------|----------------|-------|
| 10120 | 120 | WIFI-CTRL-MGMT | VRF-WIFI-CTRL | /32 host route only | border-leaf-01 | Single static /32 to WiFi Controller mgmt IP; no default route; no VRF export; all other traffic dropped |

This arrangement mirrors the logic applied to the BAC Orientation cluster: a controlled, physically bounded ingress path is provisioned for exactly one operational purpose, with no route adjacency to any production VRF. The fabric does not transit campus management traffic in the general sense — it exposes exactly one address, over exactly one restricted path, terminating at exactly one endpoint.

---

## 8 — Inter-Cluster Communication

### Governing Principle

Inter-cluster communication — any path between two distinct clusters — crosses a VRF boundary if and only if the source and destination clusters belong to different VRFs. When two clusters share a VRF (for example, Cluster 3 — AI/HPC and Cluster 5 — Storage, both in VRF-STAFF), traffic is routed within that single VRF and no boundary is crossed; security is enforced at the application layer (Ceph RBAC) rather than at the network layer. When clusters belong to different VRFs, the boundary is traversed exclusively via EVPN Type 5 (IP Prefix) routes, which are imported and exported between VRFs only at the Border Pod firewall. Every permitted cross-cluster path is listed explicitly below. Any path not listed is denied by default at the routing table level: the route does not exist.

### Communication Matrix

| Source | Destination | Permitted | Protocol / Purpose | Notes |
|--------|------------|-----------|-------------------|-------|
| Cluster 1 — General | Cluster 5 — Storage | Yes | iSCSI (Internet Small Computer Systems Interface — a protocol that transports block-level SCSI storage commands over a standard IP network) / NFS (Network File System — a protocol for shared filesystem access over IP) (Ceph RBD, CephFS, RGW) | Via STORAGE-SAN VNI uplink; Ceph RBAC enforces pool isolation per cluster |
| Cluster 2 — Admin | Cluster 1 — General | Yes (one-way) | Management push — DNS/DHCP config, monitoring agents | Admin initiates; Cluster 1 cannot initiate connections to Cluster 2 |
| Cluster 2 — Admin | Cluster 5 — Storage | Yes | iSCSI / NFS for Admin VM persistent storage | Separate RADOS pool from Cluster 1 |
| Cluster 3 — AI/HPC | Cluster 5 — Storage | Yes | NFS/CephFS — training dataset reads, checkpoint writes | High-bandwidth path; storage-leaf handles sustained throughput |
| Cluster 3 — AI/HPC | Cluster 2 — Admin | Yes (one-way) | SLURM: slurmctld, deployed in Cluster 2 (Admin), schedules and manages slurmd daemons running in Cluster 3 | Cluster 3 cannot initiate connections to Cluster 2 |
| Cluster 4 — BAC Orient. | Any | No | VRF-ORIENTATION — zero routes | Third ISP fibre only when active; no production fabric adjacency |
| Cluster 1 — General | Cluster 2 — Admin | No | Explicitly blocked | Student VMs cannot reach Admin or HR systems under any circumstance |
| Any | Cluster 4 — BAC Orient. | No | VRF-ORIENTATION — zero routes inbound | A single management IP range permitted only during the active operation window |

Hairpinning — when traffic has to travel away from its destination first, then come back — is a recognized cost of centralizing cross-VRF enforcement at the Border Pod firewall. The design's answer to this cost is not to optimize the hairpin path but to minimize how often it is taken. The communication matrix above is sparse by design: the overwhelming majority of traffic in this fabric is intra-VRF and never approaches the firewall. Student VM traffic stays within VRF-PEDAGOGY; AI/HPC and storage traffic stays within VRF-STAFF; administrative traffic stays within VRF-STAFF or VRF-ADMINISTRATION. The firewall handles a structurally narrow set of permitted cross-VRF paths, not general-purpose inter-cluster routing. The latency penalty of hairpinning is therefore paid only on paths where stateful L7 inspection is a deliberate requirement, not on the dominant traffic patterns of the fabric.

### How Cross-Cluster Paths Work

Understanding the data path for permitted cross-cluster communication is essential to verifying that the matrix above is enforced correctly.

When a Cluster 1 VM (VRF-PEDAGOGY) needs to access the LMS (Moodle, VRF-STAFF), the following sequence occurs: the VM sends a packet to its default gateway (Anycast Gateway on student-leaf-01/02). The Leaf performs a routing lookup in VRF-PEDAGOGY and finds no route to 192.168.30.0/24 — the LMS subnet is in a different VRF. The packet is forwarded toward the Border Pod via the EVPN Type 5 route for the inter-VRF transit. At the Border Pod firewall, the cross-VRF policy is evaluated: if an explicit permit exists (from VRF-PEDAGOGY to VRF-STAFF, destination LMS), the packet is permitted and forwarded into VRF-STAFF toward admin-leaf. The firewall logs the session. If no permit exists, the packet is dropped and logged.

For same-VRF, cross-cluster paths (e.g., Cluster 3 AI/HPC accessing Cluster 5 Storage — both in VRF-STAFF), the path is simpler: the packet is routed within VRF-STAFF using the EVPN Type 5 prefix for 192.168.80.0/24 (STORAGE-SAN). No firewall traversal is required because the path does not cross a VRF boundary. The security boundary here is enforced by Ceph RBAC at the application layer, not by the network layer.

The one-way restriction between Admin (Cluster 2) and General (Cluster 1) is enforced by the absence of a reverse route: VRF-STAFF has no EVPN Type 5 route that permits Cluster 1 to initiate connections toward Cluster 2. Admin can push DNS configuration and monitoring agents to Cluster 1 VMs; Cluster 1 VMs cannot initiate any connection toward the Admin cluster. This prevents a compromised student VM from being used as a pivot to attack administrative services.

---

## Physical Architecture — Tables

The tables in this section are the authoritative operational mapping of the physical fabric. They translate the conceptual model into concrete identifiers: autonomous system numbers, loopback allocation, underlay point-to-point addressing, and fixed port roles. Four invariants govern all entries below. First, both Spines share AS 65000, while each Leaf pair operates in its own AS. Second, only Loopback0 /32 addresses are advertised into the underlay BGP domain. Third, every production server using Bond0 is dual-homed across its Leaf pair, with Bond0 port A connected to the first Leaf and Bond0 port B connected to the second. Fourth, all exceptions are explicit: ids-01 uses one passive mirror NIC and one bonded management NIC; BAC nodes terminate on the Border Leaf pair during the active window only; and the WiFi Controller management path uses a single dedicated access port on border-leaf-01.

### ASN and Loopback Summary

| Device | Role | AS Number | Loopback Range | Notes |
|--------|------|-----------|---------------|-------|
| spine-01, spine-02 | — | 65000 | 10.1.0.1/32 – 10.1.0.2/32 | Shared Spine AS |
| border-leaf-01, border-leaf-02 | — | 65001 | 10.1.0.11/32 – 10.1.0.12/32 | Border / DMZ pod |
| admin-leaf-01, admin-leaf-02 | — | 65002 | 10.1.0.13/32 – 10.1.0.14/32 | Admin / Core Infra pod |
| hpc-leaf-01, hpc-leaf-02 | — | 65003 | 10.1.0.15/32 – 10.1.0.16/32 | AI / HPC pod, 100G |
| storage-leaf-01, storage-leaf-02 | — | 65004 | 10.1.0.17/32 – 10.1.0.18/32 | Storage pod |
| student-leaf-01, student-leaf-02 | — | 65005 | 10.1.0.19/32 – 10.1.0.20/32 | Student / Lab pod |

### Addressing Pools and Allocation Rules

| Address Space | Scope | Allocation Rule |
|--------------|-------|----------------|
| 10.1.0.0/24 | Loopback0 space | /32 per fabric device |
| 10.0.0.0/24 | Underlay P2P from spine-01 | /31 per Spine-to-Leaf link |
| 10.0.1.0/24 | Underlay P2P from spine-02 | /31 per Spine-to-Leaf link |
| 172.16.0.0/24 | OOB management | Flat L2 segment on oob-sw-01; never routed into production |
| 10000 + VLAN | EVPN L2VNI convention | Example: VLAN 100 → VNI 10100 |
| 50010–50050 | VRF L3VNI space | One L3VNI per security zone |

The reserved loopback assignments for the non-Leaf infrastructure are as follows: border-router-01 = 10.1.0.3/32, border-router-02 = 10.1.0.4/32, firewall-01 = 10.1.0.5/32, firewall-02 = 10.1.0.6/32, bastion-01 = 10.1.0.7/32, ids-01 = 10.1.0.8/32, oob-sw-01 = 10.1.0.9/32, and 10.1.0.10/32 remains reserved for future border infrastructure.

### Port Assignment Rules

| Rule | Operational Meaning |
|------|-------------------|
| Ethernet1 on every Leaf | Uplink to spine-01 |
| Ethernet2 on every Leaf | Uplink to spine-02 |
| Bond0 port A | Always terminates on leaf-01 of the pair |
| Bond0 port B | Always terminates on leaf-02 of the pair |
| Standard server downlink speed | 25G on Admin, Storage, and Student pods |
| GPU server downlink speed | 100G on AI/HPC pod |
| OOB connection | Management1 on switches, IPMI on servers, always to oob-sw-01 |

This convention is mandatory because the fabric relies on standards-based ESI multihoming. A bonded server that lands twice on the same Leaf is not dual-homed and therefore does not satisfy the resilience model defined by the architecture.

### Explicit Exceptions and Reserved Ports

| Switch | Port(s) | Endpoint | Speed | Role |
|--------|---------|----------|-------|------|
| border-leaf-01 | Ethernet3 | firewall-01 | 25G | Border downlink |
| border-leaf-01 | Ethernet4 | border-router-01 | 10G | ISP-facing router |
| border-leaf-01 | Ethernet5 | ids-01 NIC1 | 10G | Passive mirror tap, receive-only |
| border-leaf-01 | Ethernet6 | bac-node-01 Bond0 A | 25G | BAC activation window only |
| border-leaf-01 | Ethernet7 | bac-node-02 Bond0 A | 25G | BAC activation window only |
| border-leaf-01 | Ethernet8 | bac-node-03 Bond0 A | 25G | BAC activation window only |
| border-leaf-01 | Ethernet9 | Campus distribution uplink | 25G | WIFI-CTRL-MGMT, VRF-WIFI-CTRL only |
| border-leaf-02 | Ethernet3 | firewall-02 | 25G | Border downlink |
| border-leaf-02 | Ethernet4 | border-router-02 | 10G | ISP-facing router |
| border-leaf-02 | Ethernet5 | bac-node-01 Bond0 B | 25G | BAC activation window only |
| border-leaf-02 | Ethernet6 | bac-node-02 Bond0 B | 25G | BAC activation window only |
| border-leaf-02 | Ethernet7 | bac-node-03 Bond0 B | 25G | BAC activation window only |
| admin-leaf-01 | Ethernet3 | admin-node-01 Bond0 A | 25G | Downlink |
| admin-leaf-01 | Ethernet4 | admin-node-02 Bond0 A | 25G | Downlink |
| admin-leaf-01 | Ethernet5 | admin-node-03 Bond0 A | 25G | Downlink |
| admin-leaf-01 | Ethernet6 | bastion-01 Bond0 A | 25G | Downlink |
| admin-leaf-01 | Ethernet7 | ids-01 NIC2 Bond0 A | 25G | Management and alert forwarding |
| admin-leaf-02 | Ethernet3 | admin-node-01 Bond0 B | 25G | Downlink |
| admin-leaf-02 | Ethernet4 | admin-node-02 Bond0 B | 25G | Downlink |
| admin-leaf-02 | Ethernet5 | admin-node-03 Bond0 B | 25G | Downlink |
| admin-leaf-02 | Ethernet6 | bastion-01 Bond0 B | 25G | Downlink |
| admin-leaf-02 | Ethernet7 | ids-01 NIC2 Bond0 B | 25G | Management and alert forwarding |

ids-01 is therefore intentionally split across two roles. NIC1 is a passive monitoring interface connected to border-leaf-01 and never injects traffic into the fabric. NIC2 is a bonded production-facing interface connected to the Admin Leaf pair and is used exclusively for management access and alert forwarding.

### OOB Management

All switches connect to the OOB network through Management1; all servers connect through their IPMI interface. The OOB segment is 172.16.0.0/24, terminated exclusively on oob-sw-01, and has zero routing adjacency with the EVPN production fabric. bastion-01 and ids-01 are also present on this segment. This network exists solely to preserve administrative reachability when the production control plane is impaired.

---

## Security

### ESI Data Center — Security Specification

#### 1. Threat Model

Before any controls, here's what we're actually defending against. Every mechanism later in this doc maps back to one of these.

| Threat ID | Threat | Target | Example Scenario |
|-----------|--------|--------|-----------------|
| T1 | External intrusion | Border / DMZ | Attacker exploits a public-facing web server and pivots inward |
| T2 | BGP route injection / hijack | Routing fabric | Forged BGP UPDATE redirects traffic or blackholes a zone |
| T3 | BGP table exhaustion | Border Leafs | Upstream peer floods full internet routing table → memory crash |
| T4 | VXLAN frame injection | Overlay fabric | Server crafts UDP/4789 packets → injects frames into arbitrary VRFs |
| T5 | Lateral movement (East-West) | Within a VRF | Compromised VM scans and pivots to neighbors in same zone |
| T6 | Cross-zone lateral movement | Between VRFs | Compromised student VM attempts to reach HR/Finance systems |
| T7 | Unauthorized admin access | Switches / servers | Attacker SSH-es directly into a switch without going through Bastion |
| T8 | BAC orientation data tampering | Cluster 4 | Integrity-critical national platform is modified or exfiltrated |
| T9 | Insider / rogue admin | Config plane | Admin pushes a malicious config that opens a backdoor |
| T10 | Undetected intrusion | All zones | Attacker moves slowly; no alerting catches it |
| T11 | Physical access | Hardware | Unauthorized person boots a device or pulls cables |
| T12 | Clock desync / log tampering | Forensics plane | Unsynchronized timestamps make incident reconstruction impossible |

#### 2. Security Architecture — The Concentric Rings

The design uses defense in depth: 5 rings + 3 supporting controls. The failure of any outer ring does not compromise inner rings — they are independent enforcement points.

```
Internet
│
[Ring 1] ── HA Next-Gen Firewalls (North-South, L7 stateful)
│
[Ring 2] ── BGP Hardening (prefix-lists, TCP MD5, max-prefix)
│
[Ring 3] ── Control Plane ACLs (management CPU protection)
│
[Ring 4] ── Bastion Host (single SSH entry point)
│
[Ring 5] ── nftables micro-segmentation (per-host, East-West)
```

Supporting controls sitting alongside all rings:
- Passive IDS (Suricata) — detection layer on Border traffic
- DMZ Structural Isolation — routing-table level, not firewall level
- Centralized Syslog + NTP — forensics and auditability plane

#### 3. Ring-by-Ring Specification

##### Ring 1 — Perimeter Firewall

| Property | Value |
|----------|-------|
| Deployment | Active/Active HA pair |
| Placement | Border Pod, one unit per Border Leaf |
| Inspection mode | Stateful L7 (Next-Generation Firewall) |
| Failure mode | No single point of failure — independent conntrack tables per unit |
| Scope | All North-South traffic (Internet ↔ any internal zone) |
| Cross-zone traffic | ALL inter-VRF traffic also routes through this pair |
| Threats addressed | T1 (external intrusion), T6 (cross-zone lateral movement) |

What this means in practice: No traffic enters from the internet, and no traffic crosses between internal zones, without passing through stateful L7 inspection. The Active/Active setup means losing one firewall unit does not drop traffic or degrade inspection.

##### Ring 2 — BGP Session Hardening

Three independent mechanisms are applied to all BGP sessions. All three are mandatory — removing any one of them leaves a specific attack vector open.

| Mechanism | Scope | Threat | How it works |
|-----------|-------|--------|-------------|
| TCP MD5 Authentication (RFC 2385) | All BGP sessions (internal + external) | T2 — forged BGP UPDATE injection | HMAC signature on every TCP segment. Any UPDATE without a valid signature is silently dropped before the routing daemon processes it |
| Inbound Prefix-List | Border Leafs (external sessions only) | T2 — route hijack via illegitimate prefix | Only the default route (0.0.0.0/0) is accepted from external peers. All other prefixes are dropped |
| Outbound Prefix-List | Border Leafs (external sessions only) | RFC 1918 leakage | All RFC 1918 space is explicitly blocked from being advertised externally |
| Max-Prefix Guard | Border Leafs (external sessions only) | T3 — table exhaustion / memory crash | Hard ceiling on accepted prefixes per peer. Session is torn down immediately if threshold is exceeded |

**Secret separation:** Two distinct TCP MD5 secrets are used — one for external sessions (Border Leafs ↔ ISP), one for internal fabric sessions. A leak of the external secret does not compromise the internal fabric.

**Threshold values (to be defined before go-live):**
- Max-prefix threshold for Algérie Télécom session: ______ prefixes
- Max-prefix threshold for FH microwave session: ______ prefixes
- Alert-only warning at 80% of threshold before hard teardown (normally ykono kifkif since its the same ISP)

##### Ring 3 — Control Plane ACLs (Management CPU Protection)

The switch CPU processes BGP, BFD, VXLAN control, and SSH. Without ACLs, any host on the network can send packets to these ports and attempt to crash or manipulate the control plane.

| Protocol | Port | Permitted Sources | Threat Addressed |
|----------|------|-----------------|-----------------|
| BGP | TCP/179 | Legitimate BGP peer loopbacks only | T2 — rogue BGP session |
| BFD | UDP/3784 | Legitimate BGP peer loopbacks only | Control plane DoS |
| VXLAN | UDP/4789 | VTEP loopback addresses only | T4 — VXLAN frame injection |
| SSH | TCP/22 | Bastion IP (172.16.0.50) only | T7 — unauthorized admin access |

VXLAN ACL is the critical one: Without it, a server that crafts a UDP/4789 packet addressed to a switch loopback can inject Ethernet frames into arbitrary VRFs, bypassing all zone isolation. The ACL restricts VXLAN to VTEP-to-VTEP traffic only. All other sources are silently dropped.

##### Ring 4 — Admin Access via Bastion

| Property | Value |
|----------|-------|
| Bastion IP | 172.16.0.50 (OOB segment, 172.16.0.0/24) |
| Auth method | ed25519 keys only — PasswordAuthentication disabled globally on all devices |
| Access model | All SSH to any switch or server must originate from Bastion. No direct SSH allowed from admin workstations |
| Enforcement | Ring 3 ACL enforces this at packet level — SSH from any non-Bastion IP is dropped before the daemon responds |
| Bastion hardening | Minimal installed packages, no unnecessary services, SSH config: AllowUsers whitelist, MaxAuthTries 3, LoginGraceTime 30 |
| Threats addressed | T7 (unauthorized admin access), T9 (insider/rogue admin) |

Why a Bastion instead of per-device allow-lists: Without a Bastion, every switch needs its own allow-list of admin workstation IPs. These lists drift as staff change. With a Bastion, every switch has exactly one SSH rule (permit from 172.16.0.50) that never changes.

##### Ring 5 — Host-Level Micro-Segmentation (nftables)

The innermost ring. Enforced on every server independently of the network. A compromised VM cannot pivot to neighbors even within the same VRF.

**Universal baseline applied to ALL servers:**
- INPUT chain default policy: DROP
- ESTABLISHED/RELATED traffic: accepted
- SSH: permitted from Bastion (172.16.0.50) only
- Everything else: dropped unless explicitly listed below

**Per-role additional inbound rules:**

| Server Role | VRF | Additional Permitted Inbound | Justification |
|-------------|-----|------------------------------|--------------|
| Student lab VMs | VRF-PEDAGOGY | None (baseline only) | No inbound service expected. Any open port expands attack surface with no benefit |
| Admin VMs (AD, DNS, DHCP) | VRF-STAFF | TCP/53, UDP/53 (DNS), UDP/67-68 (DHCP) — source: 192.168.0.0/16 only | Infrastructure services must be reachable internally. Internet-originating DNS/DHCP blocked |
| NTP server | VRF-STAFF | UDP/123 — source: 192.168.0.0/16 only | Internal NTP clients only |
| HR / Finance VMs | VRF-ADMINISTRATION | TCP/443 — source: VRF-STAFF only, via explicit FW policy | Highest-sensitivity data. HTTPS only, no plaintext |
| Research / HPC VMs | VRF-STAFF | TCP/8080 — source: 192.168.0.0/16 only | Jupyter notebooks. Internet exposure = arbitrary code execution |
| AI/HPC bare-metal | VRF-STAFF | TCP/6006 — source: 192.168.0.0/16 only | TensorBoard. Exposes training metrics and model data — internal only |
| Services VMs (LMS, web portals) | VRF-STAFF | TCP/80, TCP/443 — source: any internal | Internal web apps. External boundary controlled by perimeter FW |
| DMZ web servers | VRF-PUBLIC | TCP/80, TCP/443 — internet-sourced, via FW | Ring 1 FW is primary enforcement. nftables rule is second layer of defence |
| BAC Orientation servers | VRF-ORIENTATION | No inbound (offline by default) | Zero inbound when offline. Single management IP range permitted during active window only |
| Syslog collector | VRF-STAFF | UDP/514, TCP/514 — source: 192.168.0.0/16 | Receives logs from all zones. No outbound log forwarding permitted |

#### 4. Zone Isolation — VRF Macro-Segmentation

This is the structural backbone of cross-zone security. VRFs are not firewall rules — they are separate routing tables. A missing route is a stronger guarantee than a deny rule because there is nothing to misconfigure.

| VRF | Security Posture | L3VNI | Subnet | Default Outbound | Notes |
|-----|-----------------|-------|--------|-----------------|-------|
| VRF-ADMINISTRATION | HR, Finance, Core Databases | 50010 | 10.10.10.0/24 | No outbound routes by default | Inbound via explicit FW policy only. Data-at-rest encryption (LUKS) mandatory on all storage pools |
| VRF-STAFF | Admin, Faculty, AI/HPC, Services | 50020 | 10.10.20.0/24 | Can reach VRF-ADMINISTRATION via explicit FW policy only | Full internal fabric access otherwise |
| VRF-PEDAGOGY | Student Labs & TP Servers | 50030 | 10.10.30.0/24 | Internet access only | Zero routes to VRF-STAFF or VRF-ADMINISTRATION |
| VRF-PUBLIC | Public-Facing / DMZ | 50040 | 192.168.100.0/24 | Internet-facing only | No routes to any internal VRF — structurally absent, not policy-denied |
| VRF-ORIENTATION | BAC Orientation | 50050 | 192.168.90.0/24 | Zero routes | Active ~2 months/year. Third ISP fibre only permitted path |

**DMZ structural isolation — why this matters:** VRF-PUBLIC contains no routes to any internal VRF. Not a deny rule — the route literally does not exist. A compromised DMZ server cannot reach internal services regardless of firewall state, misconfig, or rule omission.

#### Inter-Cluster Communication Matrix

All paths not listed below are denied by default at the VRF boundary. Cross-cluster paths always traverse the HA Firewall pair.

| Source | Destination | Permitted | Protocol / Purpose |
|--------|------------|-----------|-------------------|
| Cluster 1 — General | Cluster 5 — Storage | yes | iSCSI / NFS (Ceph RBD + CephFS) |
| Cluster 2 — Admin | Cluster 1 — General | Yes one-way | Admin pushes DNS/DHCP config and monitoring agents. Cluster 1 cannot initiate to Cluster 2 |
| Cluster 2 — Admin | Cluster 5 — Storage | yes | iSCSI / NFS for Admin VM persistent storage |
| Cluster 3 — AI/HPC | Cluster 5 — Storage | yes | NFS/CephFS for training datasets and checkpoints |
| Cluster 3 — AI/HPC | Cluster 2 — Admin | Yes one-way | SLURM controller (in Cluster 2) manages Cluster 3 nodes. Cluster 3 cannot initiate to Cluster 2 |
| Cluster 4 — BAC Orient. | Any | no | VRF-ORIENTATION — zero routes in all directions when offline |
| Cluster 1 — General | Cluster 2 — Admin | no | Explicitly blocked. Student VMs cannot reach Admin or HR systems under any circumstance |

#### 5. Supporting Controls

##### 5.1 Passive IDS — Suricata

| Property | Value |
|----------|-------|
| Deployment | Dedicated node, 172.16.0.51 (OOB segment) |
| Mode | Detection-only. Never in the traffic path |
| Traffic feed | tc (traffic control) mirror on Border Leaf external interface — copies all inbound and outbound packets |
| Mirror placement | Border Leaf — sees 100% of external traffic in both directions |
| Alert output | fast.log — timestamp, signature name, source/destination for every alert |
| False positive impact | Zero. A false positive cannot disrupt forwarding because IDS is not inline |
| Threats addressed | T1, T10 (undetected intrusion) |

Why tc mirror instead of a TAP: A physical TAP requires additional hardware. tc mirroring is done in software on the Border Leaf and produces an identical copy of all packets at no additional cost. The IDS node receives a mirrored stream — not the actual traffic.

**Suricata ruleset to enable at minimum:**
- ET SCAN — port scans and reconnaissance
- ET EXPLOIT — known CVE exploit signatures
- ET POLICY — policy violations (e.g., cleartext credentials)
- ET TROJAN — known C2 beaconing patterns

##### 5.2 Centralized Syslog

| Property | Value |
|----------|-------|
| Collector | rsyslog or Loki instance in Cluster 2 (VRF-STAFF) |
| Sources | All 12 switches + all servers + firewall pair + Bastion |
| Protocol | UDP/514 (standard) or TCP/514 (reliable delivery — preferred) |
| Retention | Minimum 90 days on-disk; archive to object storage (Ceph RGW) for 1 year |
| Clock dependency | All sources must sync to NTP (Chrony) before logging. Skew > 1 second invalidates forensic correlation |
| Access control | Syslog collector accepts only from 192.168.0.0/16. No external forwarding |

Without central syslog: Reconstructing a BGP event across 12 switches requires SSH-ing into each device individually. With desynchronized clocks, the timeline is unauditable.

##### 5.3 NTP — Clock Synchronization

| Property | Value |
|----------|-------|
| Implementation | Chrony (Stratum 2) |
| Upstream | Public Stratum 1 via border uplinks |
| Consumers | All switches, all servers, firewall pair, Bastion, IDS node |
| Maximum permitted skew | < 1 second for log correlation; < 30 seconds for Kerberos/AD authentication |
| Dependency chain | BGP certificate validity, Kerberos (AD), forensic log correlation all depend on this |

#### 6. BAC Orientation — Dedicated Security Controls

This cluster gets its own section because its threat model is different: integrity and tamper-resistance of a nationally mandated platform, not just confidentiality.

| Control | Detail |
|---------|--------|
| Physical isolation (primary control) | Powered off and physically disconnected ~10 months/year. Zero attack surface when offline |
| Network isolation | VRF-ORIENTATION — zero routes to production fabric. Third ISP fibre is the only permitted path |
| No hypervisor | Bare-metal only. Hypervisor layer introduces unauditable abstraction + hypervisor escape risk |
| OS hardening | Minimal Rocky Linux with CIS Benchmark profile. No package manager active during operation window |
| Physical security | Network cables physically disconnected when offline. Power strips locked. BIOS requires physical presence for boot-order changes |
| Secure boot | TPM-backed secure boot enabled on all Cluster 4 nodes |
| Activation runbook | Documented sequence: (1) physical inspection → (2) secure boot verification → (3) cable re-attachment → (4) VRF-ORIENTATION route injection by infra team → (5) platform health check |
| Active window access | Single management IP range permitted inbound only during active operation window |

#### 7. OOB Management Network

| Property | Value |
|----------|-------|
| Switch | L11 — dedicated, never part of EVPN fabric |
| Segment | 172.16.0.0/24 — isolated Layer-2, no production routes |
| Connected devices | Every switch and server management port |
| Bastion | 172.16.0.50 |
| IDS node | 172.16.0.51 |
| Cross-routing | Zero. OOB has no route into the production network |
| Purpose | Emergency access when fabric is unreachable (bad config push, BGP storm) |

Why this is critical: When a Spine or Leaf drops all BGP sessions due to a bad config, OOB is the only path back in to fix it. Without OOB, a config error can make a device permanently unreachable without physical console access.

#### 8. Validation & Testing Matrix

Every row is a pass/fail test executable in a lab session. Nothing is "assumed working."

| Test | Method | Pass Criteria | Threat Validated |
|------|--------|--------------|-----------------|
| VRF zone isolation | Attempt cross-VRF ping without explicit FW permit | 100% packet loss between all unauthorized VRF pairs | T5, T6 |
| VXLAN injection block | Send crafted UDP/4789 packet from a server to a switch loopback | Packet silently dropped (timeout, not refused). Ring 3 ACL confirmed | T4 |
| TCP MD5 enforcement | Set wrong MD5 password on one BGP peer side; wait 30s | BGP session drops to Active state. Restore correct password → recovers to Established | T2 |
| BGP max-prefix guard | Have a test peer advertise more routes than threshold | Session torn down immediately. Does not recover until peer is reconfigured | T3 |
| IDS alerting | Run nmap -sS port scan against DMZ subnet from external test node | ET SCAN alert appears in suricata/fast.log within seconds. Confirms tc mirror is delivering traffic | T10 |
| Bastion enforcement | Attempt direct SSH to a switch from a non-Bastion IP | Connection dropped/timed out at packet level (Ring 3 ACL). No SSH banner returned | T7 |
| nftables lateral movement | From a compromised VM, attempt to reach a neighbor on a blocked port | Connection refused or timed out. No response from blocked port | T5 |
| Cross-VRF from DMZ | Attempt to reach any internal IP from VRF-PUBLIC host | 100% packet loss. No route exists, not just denied | T1, T6 |
| OOB isolation | Attempt to reach a production IP from OOB segment | 100% packet loss. OOB has zero production routes | T9 |
| Secure boot (BAC cluster) | Power cycle a Cluster 4 node, attempt to boot from USB | Boot fails or requires physical BIOS presence override | T8, T11 |
| Syslog correlation | Generate a BGP session drop; verify event appears in central syslog with correct timestamp | Event present within 60s, timestamp within 1s of switch local time | T12 |
| BFD fast failover | Pull a Spine uplink; measure reconvergence | Traffic re-routes in < 1 second. No BGP session teardown on surviving links | Availability (not security, but operational) |
| ESI multihoming failover | Pull one Leaf in a pair | Server bond fails over to surviving Leaf. Zero packet loss beyond BFD window | Availability |

---

## Quality of Service

Quality of Service in this design is not an add-on applied after the topology is finished; it is the operational expression of the per-pod performance model already defined by the architecture. The fabric deliberately gives different workload classes different bandwidth and congestion properties: AI/HPC is 1:1 non-blocking and lossless where required, Storage is near-non-blocking, Admin is latency-sensitive but low-volume, Border traffic is bounded by ISP capacity, and Student traffic is intentionally oversubscribed. The QoS policy therefore does not attempt to make all traffic equal. It preserves the critical traffic classes first, guarantees deterministic behaviour for the workloads that require it, and pushes bulk and scavenger traffic to whatever capacity remains.

The objectives are sixfold. First, the control plane must be protected absolutely: eBGP, EVPN transport, BFD, and LACP must never fail because a data-plane queue is congested. Second, BAC Orientation traffic must remain protected during its activation window even though the cluster shares the Border Leaf pair. Third, AI/HPC traffic must preserve throughput and low-loss behaviour on L5/L6. Fourth, bulk transfers such as backup replication, image distribution, and software updates must be explicitly deprioritized. Fifth, the model must remain stable as the fabric grows: a new service is mapped into an existing class rather than introducing a new queue. Sixth, the policy must be automatable and observable through Ansible deployment and per-class queue telemetry.

### DiffServ Class Model

The fabric uses an 8-class DiffServ model. The class definitions below are authoritative.

| Priority | Class Name | DSCP Value | Queue Behaviour | Minimum Bandwidth | ESI Examples |
|----------|-----------|-----------|----------------|------------------|-------------|
| 1 | Network Control | CS6 (48) | Strict Priority | — | eBGP, EVPN transport, BFD, LACP, switch-generated control traffic |
| 2 | Real-Time | EF (46) | Strict Priority, rate-limited | — | Voice/video traffic if introduced later |
| 3 | Critical Applications | AF41 (34) | WFQ High | 20% | BAC-ORIENT (VNI 10090), AD/Kerberos, DNS, DHCP, examination-period LMS access |
| 4 | Research / HPC | AF31 (26) | WFQ High | 25% | AI-GPU (VNI 10070), SLURM/Kubernetes east-west traffic, dataset reads/writes to CephFS |
| 5 | Interactive / Academic | AF21 (18) | WFQ Medium | 20% | LMS-STAFF (VNI 10030), SERVICES-WEB (VNI 10040), STUDENT-TP (VNI 10010), internal portals, monitoring dashboards |
| 6 | General Student | AF11 (10) | WFQ Low | 10% | STUDENT-PROJ (VNI 10020), general student browsing, non-critical tenant traffic |
| 7 | Bulk / Backup | CS1 (8) | Scavenger | 5% | Backup replication, RGW/image synchronization, OS images, software updates |
| 8 | Best Effort | DF (0) | Best Effort | Remainder | Unclassified traffic |

The Real-Time class is retained even though the current architecture does not depend heavily on voice. It is kept as a reserved class so that future real-time services can be introduced without redesigning the queue model.

### Classification and Marking

QoS is enforced at ingress, not retroactively in the middle of congestion. Leaf switches classify traffic as close to the source as possible, using access VLAN, VNI membership, and server role. The class mapping is therefore deterministic:

- traffic from VNI 10090 is marked AF41;
- traffic from VNI 10070 is marked AF31;
- traffic from VNI 10030, 10040, and 10010 is marked AF21;
- traffic from VNI 10020 is marked AF11;
- backup, image transfer, and software distribution flows are marked CS1;
- all unclassified traffic remains DF.

Control-plane protocols generated by the switches themselves are always marked CS6. This includes eBGP, BFD, LACP, and other switch-originated keepalive traffic required to keep the fabric converged.

### Queueing and Scheduling

The scheduling model is hybrid. CS6 uses strict priority because fabric reachability is not negotiable. EF also uses strict priority, but is rate-limited so that it cannot starve the weighted classes under sustained load. AF41, AF31, AF21, and AF11 are scheduled by weighted fair queueing according to the percentages defined above. CS1 is a scavenger queue and is served only after the higher classes have been satisfied. DF uses whatever bandwidth remains.

This model matches the workload assumptions already established elsewhere in the architecture. AI/HPC traffic receives more guaranteed bandwidth than student traffic because the architecture already states that GPU jobs and training flows must not be degraded by general-purpose workloads. Backup traffic is intentionally pushed to the bottom because the Storage pod is designed for sustained throughput, not for preempting control or latency-sensitive traffic.

### VXLAN and DSCP Preservation

Classification occurs before VXLAN encapsulation. The DSCP value written on the inner packet is preserved across the VXLAN fabric by copying it into the outer IP header, allowing Spine switches to make queueing decisions without decapsulating the packet. This is important operationally: the Spines remain simple transit devices, yet still enforce class-aware scheduling on encapsulated east-west traffic. The overlay therefore carries class semantics end-to-end rather than treating the core as opaque transport.

### Congestion Management: ECN and PFC

Congestion signalling is deliberately scoped, not global. ECN and PFC are enabled only for the Research / HPC class on the AI/HPC Leaf pair (L5/L6) and their Spine-facing uplinks. This is the only place in the fabric where lossless behaviour is architecturally justified. Distributed GPU training and RDMA-based flows are uniquely sensitive to packet loss and retransmission. Everywhere else in the fabric, standard weighted queueing is preferred.

PFC is never enabled fabric-wide. Doing so would spread pause behaviour into pods that do not require lossless Ethernet, creating unnecessary head-of-line blocking for Admin, Storage, and Student traffic. The same scoping principle applies to ECN: it is used as a rate adaptation signal for the AI/HPC queue, not as a blanket policy across all classes.

### Border Shaping and Policing

The Border pod is the only place where the fabric meets a slower and externally controlled domain: the ISP uplinks. QoS therefore applies a distinct edge policy there.

Inbound traffic from the public internet is treated as untrusted from a marking perspective. Any DSCP values arriving from upstream are stripped or re-marked according to local policy before traffic enters the fabric. Internet traffic is not allowed to self-classify into privileged queues.

Outbound traffic toward the ISPs is shaped, not policed, to the committed rate of each uplink. Shaping is preferred on egress because it smooths bursts and preserves TCP behaviour instead of causing avoidable loss. Inbound traffic is policed to physical link capacity to prevent an external burst from overrunning the edge queues. This separation is important: inside the fabric bandwidth is abundant and deterministic; at the internet edge it is finite and asymmetric.

### OOB and Monitoring Considerations

The OOB management network is physically separate from the EVPN fabric and therefore does not participate in production QoS scheduling. This is intentional. Administrative recovery traffic must not share congestion fate with the data plane it exists to repair.

All class maps, queue policies, and re-marking rules must be implemented through Ansible playbooks and exported to monitoring. At minimum, the platform must expose per-class queue occupancy, drops, ECN marks, and interface-level class counters to Zabbix, Prometheus, or an equivalent telemetry stack. A QoS policy that cannot be measured cannot be trusted in production.

### Final Policy Statement

The QoS strategy follows the same design philosophy as the rest of the architecture: selective determinism, not universal over-engineering. The network control plane is always protected first. AI/HPC receives lossless treatment only where its workload requires it. BAC traffic is protected during its operational window. Student and bulk traffic consume the residual bandwidth that remains after critical services have been satisfied. This is not merely a queueing policy; it is the operational enforcement of the pod model.