# ESI Datacenter — Project Synthesis Document
**Version:** v2.0 | Architecture Spec Refinement Applied  
**Previous Baseline:** v1.6 (architecture_spec_draft.docx)  
**Current Baseline:** architecture_spec_refinement.pdf (supersedes v1.6 on all conflicting points)  
**Simulation Platform:** ContainerLab 0.73.0 + FRR 9.1 + Alpine Linux

---

## Table of Contents
0. Reconciliation Rules (architecture_spec_full.md)
1. Authoritative Reference Tables
2. Changes from v1.6 — What Changed and Why
3. Feature Analysis (Simulatable / Workaround / Out of Scope)
4. Phase 1 — Initial State (Reference)
5. Phase 2 — Task Split by Theme
6. Test Blocks (Phase 1 + Per-Theme)
7. GitHub Collaboration Rules

---

## 0. Reconciliation Rules (architecture_spec_full.md)

This section resolves mismatches between older implementation docs and the full architecture source document.

### 0.1 Source Priority

1. `architecture_spec_full.md` is the conceptual source of truth.
2. `context.md` is the implementation transition plan and must stay compatible with active Phase 2 branches.
3. If a conceptual statement conflicts with an implementation snippet, the conceptual statement wins, then transition is staged to minimize branch breakage.

### 0.2 Resolved Decisions

| Topic | Final Decision for This Repository | Reason |
|------|------------------------------------|--------|
| WiFi controller mgmt IP | `192.168.10.100` hosted on wifi-controller in `VRF-PEDAGOGY` | Matches architecture hosting model; keeps a single canonical controller IP across branches |
| WiFi mgmt ingress path | Campus ingress is only via border-leaf-01 in `VRF-WIFI-CTRL`, with one static `/32` to `192.168.10.100` | Matches architecture micro-VRF isolation while preserving reachability to controller hosted in `VRF-PEDAGOGY` |
| Border uplink port naming | In simulation, use the dedicated campus port already wired in YAML (currently `leaf-01:eth8`) | Keeps current lab stable while preserving single-port design intent from physical spec |
| PIM in fabric | **Excluded** from this project baseline; EVPN BUM remains HER only | `architecture_spec_full.md` states no multicast routing in the fabric |
| Firewall HA nuance | Active/Active is mandatory. Dedicated state-sync link remains mandatory. Session sync implementation may be staged by T3 without changing Ring 1 ownership boundaries | Keeps transition safe for in-flight branches while preserving architecture intent |

### 0.3 Missing Architecture Element Added Here

`architecture_spec_full.md` includes an explicit inter-cluster communication matrix with one-way constraints and VRF-boundary rules. That matrix is now represented in this transition document (Section 2, Change 10 and Section 5 ownership updates).

---

## 1. Authoritative Reference Tables

> These values supersede all previous versions. The refinement PDF is the single source of truth.  
> Every config written by every member must use these values. No exceptions.

### 1.1 Node Inventory

| Node | Role | AS | Loopback |
|------|------|----|----------|
| spine-01 | Spine + EVPN relay (not VTEP) | 65000 | 10.1.0.1/32 |
| spine-02 | Spine + EVPN relay (not VTEP) | 65000 | 10.1.0.2/32 |
| leaf-01 | Border Leaf A (L1) | 65001 | 10.1.0.11/32 |
| leaf-02 | Border Leaf B (L2) | 65001 | 10.1.0.12/32 |
| leaf-03 | Admin pod A (L3) | 65002 | 10.1.0.13/32 |
| leaf-04 | Admin pod B (L4) | 65002 | 10.1.0.14/32 |
| leaf-05 | AI/HPC pod A (L5) | 65003 | 10.1.0.15/32 |
| leaf-06 | AI/HPC pod B (L6) | 65003 | 10.1.0.16/32 |
| leaf-07 | Storage pod A (L7) | 65004 | 10.1.0.17/32 |
| leaf-08 | Storage pod B (L8) | 65004 | 10.1.0.18/32 |
| leaf-09 | Student pod A (L9) | 65005 | 10.1.0.19/32 |
| leaf-10 | Student pod B (L10) | 65005 | 10.1.0.20/32 |
| isp-router-01 | AT Fibre upstream | 64500 | 100.64.0.1/32 |
| isp-router-02 | FH Microwave upstream | 64501 | 100.64.0.2/32 |
| isp-router-03 | BAC Orientation 3rd fibre | 64502 | 100.64.0.3/32 |
| firewall-01 | HA NGFW A on border-leaf-01 | — | 192.168.1.1 |
| firewall-02 | HA NGFW B on border-leaf-02 | — | 192.168.1.2 |
| bastion-01 | SSH Jump Host | — | 172.16.0.50 |
| ids-01 | Passive IDS (Suricata) | — | 172.16.0.51 |
| ntp-server | Stratum 2 NTP (Chrony) | — | 192.168.50.20 |
| dns-server | DNS (Unbound, split-view) | — | 192.168.50.30 |
| dhcp-server | DHCP (Kea) | — | 192.168.50.40 |
| ftp-server | FTP (vsftpd, Storage pod) | — | 192.168.80.10 |
| zabbix-server | SNMP monitoring | — | 192.168.50.50 |
| prometheus | Metrics scraper | — | 192.168.50.60 |
| syslog-server | Centralized logs (rsyslog) | — | 192.168.50.70 |
| wifi-controller | AP management VM (hosted in VRF-PEDAGOGY, reached via VRF-WIFI-CTRL /32) | — | 192.168.10.100 |
| campus-bp | BP distribution switch (campus edge) | — | — |
| oob-sw | OOB L2 switch (symbolic) | — | — |

### 1.2 P2P Link Addressing

Spine-01 block: `10.0.0.x/31` — spine always gets the even address.  
Spine-02 block: `10.0.1.x/31` — mirrors spine-01 sequencing.

| Link | Spine Side | Leaf Side | Subnet |
|------|-----------|-----------|--------|
| S1 → leaf-01 (border) | 10.0.0.0 | 10.0.0.1 | 10.0.0.0/31 |
| S1 → leaf-02 (border) | 10.0.0.2 | 10.0.0.3 | 10.0.0.2/31 |
| S1 → leaf-03 (admin) | 10.0.0.4 | 10.0.0.5 | 10.0.0.4/31 |
| S1 → leaf-04 (admin) | 10.0.0.6 | 10.0.0.7 | 10.0.0.6/31 |
| S1 → leaf-05 (hpc) | 10.0.0.8 | 10.0.0.9 | 10.0.0.8/31 |
| S1 → leaf-06 (hpc) | 10.0.0.10 | 10.0.0.11 | 10.0.0.10/31 |
| S1 → leaf-07 (storage) | 10.0.0.12 | 10.0.0.13 | 10.0.0.12/31 |
| S1 → leaf-08 (storage) | 10.0.0.14 | 10.0.0.15 | 10.0.0.14/31 |
| S1 → leaf-09 (student) | 10.0.0.16 | 10.0.0.17 | 10.0.0.16/31 |
| S1 → leaf-10 (student) | 10.0.0.18 | 10.0.0.19 | 10.0.0.18/31 |
| S2 mirrors above | 10.0.1.0–.18 | 10.0.1.1–.19 | 10.0.1.x/31 |

As for campus network, the new link from campus-bp to border-leaf-01 is:
| Link | Leaf Side | Switch Side | Subnet |
|------|-----------|-----------|--------|
| leaf-01 (border) → campus-bp | 10.200.0.1 | 10.200.0.2 | 10.200.0.0/30 | Dedicated WiFi Mgmt Link |

### 1.3 VNI Segment Table

> campus-bp **BREAKING CHANGE FROM v1.6:** VNI 10030 and 10040 have moved from border-leaf to admin-leaf.  
> VNI 10120 is entirely new (added by the refinement). See Section 2 for full explanation.

| VNI | VLAN | Segment | VRF | Subnet | Leaf Pair | Notes |
|-----|------|---------|-----|--------|-----------|-------|
| 10010 | 10 | STUDENT-TP | VRF-PEDAGOGY | 192.168.10.0/24 | leaf-09/10 | TP servers for supervised lab sessions |
| 10020 | 20 | STUDENT-PROJ | VRF-PEDAGOGY | 192.168.20.0/24 | leaf-09/10 | Isolated student project VMs |
| **10030** | **30** | **LMS-STAFF** | **VRF-STAFF** | **192.168.30.0/24** | **leaf-03/04** | **Moved from border to admin-leaf. Students reach via FW policy.** |
| **10040** | **40** | **SERVICES-WEB** | **VRF-STAFF** | **192.168.40.0/24** | **leaf-03/04** | **Moved from border to admin-leaf. Internal portals only.** |
| 10050 | 50 | CORE-INFRA | VRF-STAFF | 192.168.50.0/24 | leaf-03/04 | AD, DNS, DHCP, NTP, Ansible Tower, monitoring |
| 10060 | 60 | HR-FINANCE | VRF-ADMINISTRATION | 192.168.60.0/24 | leaf-03/04 | Data-at-rest encryption mandatory |
| 10070 | 70 | AI-GPU | VRF-STAFF | 192.168.70.0/24 | leaf-05/06 | GPU servers, RoCEv2, PFC+ECN on L5/L6 only |
| 10080 | 80 | STORAGE-SAN | VRF-STAFF | 192.168.80.0/24 | leaf-07/08 | SAN, NAS, FTP, Backup |
| 10090 | 90 | BAC-ORIENT | VRF-ORIENTATION | 192.168.90.0/24 | leaf-01/02 | Powered off ~10 mo/yr; port+BGP disable when inactive |
| 10100 | 100 | DMZ-WEB | VRF-PUBLIC | 192.168.100.0/24 | leaf-01/02 | No routes to any internal VRF |
| **10120** | **120** | **WIFI-CTRL-MGMT** | **VRF-WIFI-CTRL** | **/32 host only** | **leaf-01** | **NEW. Single static /32 route to wifi-controller mgmt IP; no default; no VRF export** |
| 10110 | 110 | MGMT-OOB | OOB (not EVPN) | 172.16.0.0/24 | all (mgmt port) | Out-of-band only; never part of EVPN fabric |

> **Border-leaf VNI summary after correction:** leaf-01/02 now carry ONLY VNI 10090 (BAC-ORIENT), 10100 (DMZ-WEB), and 10120 (WIFI-CTRL-MGMT on leaf-01 only). LMS and SERVICES-WEB are gone from border-leaf.

### 1.4 VRF Table

| VRF | L3VNI | IRB Subnet | Permitted Outbound | Notes |
|-----|-------|-----------|-------------------|-|
| VRF-ADMINISTRATION | 50010 | 10.10.10.0/24 | None — inbound via explicit FW only | LUKS encryption mandatory on all volumes |
| VRF-STAFF | 50020 | 10.10.20.0/24 | Via explicit FW to VRF-ADMINISTRATION; full internal fabric | Includes LMS, SERVICES-WEB, CORE-INFRA, AI-GPU, STORAGE-SAN |
| VRF-PEDAGOGY | 50030 | 10.10.30.0/24 | Internet only | No routes to STAFF or ADMINISTRATION |
| VRF-PUBLIC | 50040 | 192.168.100.0/24 | Internet-facing only | No internal routes — structurally absent, not policy-denied |
| VRF-ORIENTATION | 50050 | 192.168.90.0/24 | Zero routes always | Third ISP fibre only when activated; port+BGP disable when offline |
| **VRF-WIFI-CTRL** | **50060** | **n/a** | **Single /32 only** | **NEW. No default route. Only static /32 to wifi-controller mgmt IP resolved via EVPN Type-5** |

> **Note on IRB subnets vs server subnets:**  
> The L3VNI subnet (10.10.x.0/24) is for IRB interfaces only — it is NOT a server-facing network.  
> Servers use the VNI-specific subnets (192.168.x.0/24). The IRB subnet is assigned only to the `vlanXXX`  
> IRB interface inside the VRF. Servers never see 10.10.x.0/24 addresses.

### 1.5 Security Rings Summary

| Ring | Mechanism | Where Enforced | Notes |
|------|----------|---------------|-------|
| Ring 1 | HA NGFW (nftables stateful + keepalived VIP + conntrackd state sync) | firewall-01/02 between border-leaf and fabric | State sync via dedicated link; both units hold full session table |
| Ring 2 | BGP prefix-lists + **two distinct MD5 secrets** + Max-Prefix | border-leaf external sessions only | Internal secret ≠ external secret |
| Ring 3 | CPU ACLs: iptables on BGP/BFD/VXLAN/SSH ports | ALL FRR containers startup.sh | VXLAN ACL restricts to VTEP loopbacks only |
| Ring 4 | Bastion + ed25519 + SSH restriction to 172.16.0.50 | bastion-01 + iptables on all nodes | AllowUsers whitelist, MaxAuthTries 3, LoginGraceTime 30 |
| Ring 5 | nftables per-host micro-segmentation | server containers per Table in Spec Section 3 | Baseline: INPUT DROP; permit ESTABLISHED, SSH from bastion only |
| Support | Passive IDS (Suricata) + tc mirror + ET rulesets | ids-01 (172.16.0.51) + leaf-01 eth mirror port | ET SCAN, ET EXPLOIT, ET POLICY, ET TROJAN rulesets minimum |
| Support | DMZ structural isolation | VRF-PUBLIC routing table | Missing route, not deny rule |
| Support | VRF-ORIENTATION always empty | VRF-ORIENTATION routing table | Empty when inactive; third ISP route injected only by runbook |
| Support | Centralized Syslog + NTP | syslog-server + ntp-server | TCP/514 preferred; < 1s skew for log correlation |

### 1.6 Anycast Gateway

- **MAC:** `00:00:00:11:11:11` — shared identically on every leaf for every VNI SVI
- **IP:** First address of each VNI subnet (e.g., 192.168.10.1 for VNI 10010)
- **Purpose:** VM mobility (MAC never changes during migration), ARP suppression

### 1.7 BGP MD5 Secrets (New — Two Distinct Values)

| Session Type | Scope | Secret |
|---|---|---|
| **Internal fabric** | All spine↔leaf, leaf↔leaf EVPN sessions | `ESI-BGP-INTERNAL` |
| **External ISP** | border-leaf ↔ isp-router-01, -02, -03 sessions | `ESI-BGP-EXTERNAL` |

A leak of the external secret cannot compromise the internal fabric control plane.

---

## 2. Changes from v1.6 — What Changed and Why

> This section replaces the old Remarks section. Old remarks that were architecture misunderstandings  
> are removed; new definitive changes are explained here with their simulation impact.

### Change 1 — VNI 10030 and 10040 MOVE to admin-leaf (HIGH PRIORITY)

**What changed:** The refinement PDF explicitly corrects the previous document. VNI 10030 (now named LMS-STAFF, was LMS-ORIENT) and VNI 10040 (SERVICES-WEB) move from border-leaf to admin-leaf.

**Why:** "Both are VRF-STAFF internal services with no operational requirement for border proximity; assigning them to border-leaf would incorrectly place general administrative services on a Leaf pair dedicated exclusively to external-facing and air-gapped functions."

**Simulation impact:** leaf-01/02 (border-leaf) startup.sh and frr.conf must REMOVE these VNIs. leaf-03/04 (admin-leaf) startup.sh and frr.conf must ADD them. **Youcef must push this correction before Ikram starts ESI work on leaf-03/04.**

**Before:** border-leaf had VNIs 10030, 10040, 10090, 10100  
**After:** border-leaf has VNIs 10090, 10100 (and 10120 on leaf-01 only)

### Change 2 — New VNI 10120 (WIFI-CTRL-MGMT) and VRF-WIFI-CTRL (NEW TOPOLOGY NODE)

**What changed:** The WiFi campus architecture section introduces an entirely new network path. The WiFi Controller VM lives on student-leaf in VRF-PEDAGOGY (no change). But management access from the campus distribution (BP) switches is NOT through student-leaf ports. Instead, a dedicated uplink from campus-bp to border-leaf-01 carries management traffic in a new micro-VRF.

**Why:** Direct BP-to-student-leaf connection would introduce campus AP traffic into the data center, violating performance determinism (4:1 student pod vs. unscheduled WiFi traffic) and structural security (physically unsecured AP endpoints gaining L2 adjacency with data center switch ports).

**Simulation impact:**
- New YAML link: `campus-bp:eth3 → leaf-01:eth8` (simulation mapping of physical design intent: border-leaf-01 campus uplink port)
- New VRF-WIFI-CTRL on leaf-01 with only a static /32 to wifi-controller's IP
- VRF-WIFI-CTRL has no default route, no export to other VRFs
- The /32 is resolved via EVPN Type-5 across the fabric to student-leaf
- Youcef adds this to border-leaf-01 frr.conf and startup.sh
- campus-bp gets an eth3 connected to border-leaf-01 with this address space

**Important:** APs do NOT connect to any DC leaf. Campus BP retains its campus edge role. Sophos URL filter is at campus edge, NOT in the Border Pod — no Sophos simulation needed.

### Change 3 — Firewall Active/Active with State Sync (TASK UPDATE)

**What changed:** The refinement explicitly states: "Connection state is continuously synchronized between both units over a dedicated state-sync link; each unit holds a full, current copy of the session table. A failover does not cause session loss — the surviving unit already has all active session state."

**Why:** The old context.md Remark 5 was wrong — it said firewalls were truly independent. They are NOT. Both hold a full synchronized copy of all session state.

**Simulation impact:**
- New YAML link: `firewall-01:eth3 ↔ firewall-02:eth3` (dedicated state-sync link)
- Mounir adds `conntrackd` for connection tracking state synchronization
- Mounir's task is updated to include conntrackd config

### Change 4 — Two Distinct BGP MD5 Secrets (TASK UPDATE)

**What changed:** The security specification requires: "two distinct TCP MD5 secrets — one for external sessions (Border Leafs ↔ ISP), one for internal fabric sessions."

**Simulation impact:**
- Internal sessions keep: `ESI-BGP-INTERNAL`
- border-leaf external sessions (toward isp-router-01/02/03) use: `ESI-BGP-EXTERNAL`
- Youcef updates leaf-01/02 frr.conf for external sessions
- Phase 1 spine/leaf configs using the single password remain valid (they are all internal sessions)

### Change 5 — Suricata Minimum Rulesets Specified

**What changed:** The security spec lists the minimum required Suricata rulesets explicitly.

**Simulation impact:** Mounir must enable exactly: ET SCAN, ET EXPLOIT, ET POLICY, ET TROJAN. Not just any default ruleset.

### Change 6 — BAC Orientation: Port Disable During Off-Season

**What changed:** "network administrators must administratively disable the Leaf switch ports facing the Cluster 4 nodes, as well as the BGP session for its dedicated external ISP uplink" during the ~10 months BAC is offline.

**Simulation impact:** Youcef's orientation runbook must include:
- Activation: `ip link set eth_BAC up` + BGP neighbor enable
- Deactivation: `ip link set eth_BAC down` + BGP neighbor disable for isp-router-03

### Change 7 — DNS Split-Horizon: NXDOMAIN from VRF-PUBLIC

**What changed:** "The DNS instance serving VRF-PUBLIC has no visibility into internal zones — a query for an internal hostname from the DMZ returns NXDOMAIN."

**Simulation impact:** Zitouni's Unbound config must define a separate view for VRF-PUBLIC that returns NXDOMAIN for internal zone (esi.internal) queries.

### Change 8 — Syslog TCP/514 Preferred

**What changed:** The security spec specifies "TCP/514 (reliable delivery — preferred)" over UDP/514.

**Simulation impact:** Zitouni uses TCP/514 in rsyslog forwarding rules on all nodes.

### Change 9 — Moodle Student Access Firewall Policy

**What changed:** The refinement explicitly calls out: "Students access Moodle through an explicit firewall policy (VRF-PEDAGOGY → VRF-STAFF)."

**Simulation impact:** Mounir must add a specific nftables forward rule on firewall-01/02 permitting VRF-PEDAGOGY source to reach 192.168.30.0/24 (LMS-STAFF) on TCP/443 and TCP/80.

### Change 10 — Inter-Cluster Communication Matrix Added (from full architecture)

**What changed:** The full architecture defines explicit one-way and no-route constraints between clusters (not just per-VRF high-level statements).

**Simulation impact:**
- Youcef (T1) and Ikram (T2) must avoid introducing reverse Type-5 paths that violate one-way rules.
- Mounir (T3) must encode explicit cross-VRF permit rules only for matrix-approved paths.
- Zitouni (T4) adds matrix validation checks to theme tests.

### Informational — No Simulation Impact

| Item | Explanation |
|------|-------------|
| Sophos URL filter | At campus edge, NOT in DC. No simulation needed. |
| iBGP overlay alternative | Explicitly rejected; eBGP chosen. No change. |
| k3s for Kubernetes | Compute layer, out of scope. |
| NFS-Ganesha for CephFS | Storage layer, out of scope. |
| SLURM controller in Admin Cluster | Compute layer, out of scope. |
| PIM in this simulation baseline | Excluded from the fabric. EVPN BUM remains Head-End Replication only. |
| Spine N+1 redundancy = reachability only | Single spine failure → 50% bandwidth loss. No config change. |

---

## 3. Feature Analysis

### 3.1 Fully Simulatable (no workaround)

| # | Feature | Technology | Who | Status |
|---|---------|-----------|-----|--------|
| 1 | eBGP Multi-AS underlay | FRR bgpd | Phase 1 (Youcef) | Done |
| 2 | BFD sub-second detection | FRR bfdd | Phase 1 (Youcef) | Done |
| 3 | ECMP (maximum-paths 10) | FRR + Linux kernel | Phase 1 (Youcef) | Done |
| 4 | ECMP L4 hash policy | `sysctl net.ipv4.fib_multipath_hash_policy=1` | Phase 1 | Done |
| 5 | MTU 9000 jumbo frames (fabric-wide) | `ip link set mtu 9000` in startup.sh | Phase 1 (Youcef) | Done |
| 6 | TCP MD5 BGP hardening (internal) | FRR `neighbor X password ESI-BGP-INTERNAL` | Phase 1 (Youcef) | Done |
| 7 | TCP MD5 BGP hardening (external) | FRR `neighbor X password ESI-BGP-EXTERNAL` | Youcef T1 | Update needed |
| 8 | BGP Max-Prefix Guard | FRR `neighbor X maximum-prefix 100 80` | Youcef T1 | Pending |
| 9 | BGP Prefix-Lists (ISP in/out) | FRR `ip prefix-list` | Youcef T1 | Pending |
| 10 | VXLAN data plane (all VNIs) | Linux kernel vxlan module, `nolearning` | Phase 1 (Youcef) | Done |
| 11 | DSCP tos inherit on VXLAN | `tos inherit` flag per vxlan interface | Phase 1 (Youcef) | Done |
| 12 | BGP EVPN Type-2 (MAC/IP) | FRR `advertise-all-vni` | Phase 1 (Youcef) | Done |
| 13 | BGP EVPN Type-3 (IMET/BUM) | FRR `advertise-all-vni` | Phase 1 (Youcef) | Done |
| 14 | BGP EVPN Type-5 (IP Prefix) | FRR per-VRF `advertise ipv4 unicast` | Phase 1 (Youcef) | Done |
| 15 | Head-End Replication (BUM) | Automatic from EVPN Type-3 | Phase 1 | Done |
| 16 | ARP suppression (flooding = 0) | Automatic from EVPN Type-2 + nolearning | Phase 1 | Done |
| 17 | 5 VRFs + VRF-WIFI-CTRL (6 total) | Linux VRF kernel objects | Phase 1 (5) + Youcef T1 (VRF-WIFI-CTRL) | Pending |
| 18 | Symmetric IRB | Anycast GW + L3VNI on each leaf | Phase 1 (Youcef) | Done |
| 19 | Anycast Gateway (MAC 00:00:00:11:11:11) | Linux SVI + shared MAC | Phase 1 (Youcef) | Done |
| 20 | Spines as EVPN relay (`attribute-unchanged next-hop`) | FRR | Phase 1 (Youcef) | Done |
| 21 | VRF-PUBLIC structural isolation | No routes installed | Phase 1 (Youcef) | Done |
| 22 | VRF-ORIENTATION always empty | Empty routing table | Phase 1 (Youcef) | Done |
| 23 | VNI 10030/10040 on admin-leaf | leaf-03/04 startup.sh + frr.conf | Youcef T1 (correction) | CORRECTION |
| 24 | VNI 10120 WIFI-CTRL-MGMT on border-leaf-01 | New VRF-WIFI-CTRL, static /32 → EVPN Type-5 | Youcef T1 | Pending |
| 25 | Third ISP (BAC orientation fibre) | isp-router-03 → leaf-01 dedicated interface | Youcef T1 | Pending |
| 26 | ISP BGP sessions (2 active uplinks) | FRR eBGP to isp-router-01/02 | Youcef T1 | Pending |
| 27 | BAC activation/deactivation runbook | Shell script with port+BGP enable/disable | Youcef T1 | Pending |
| 28 | ESI Multihoming Type-1 routes | FRR evpn mh es-id + es-sys-mac | Ikram T2 | Pending |
| 29 | DF Election | FRR automatic with ESI config | Ikram T2 | Pending |
| 30 | Split Horizon | FRR automatic with ESI config | Ikram T2 | Pending |
| 31 | LACP bonding on servers | Linux bond mode 802.3ad | Ikram T2 | Pending |
| 32 | EtherChannel (campus-bp → student-leaf) | Linux bond for old campus buildings | Ikram T2 | Pending |
| 33 | WiFi Controller container (VRF-PEDAGOGY, student-leaf) | Alpine container with VLAN bridge | Ikram T2 | Pending |
| 34 | Ring 1: HA Firewall + keepalived VIP | nftables stateful + keepalived | Mounir T3 | Pending |
| 35 | Ring 1: Firewall state sync (conntrackd) | conntrackd + dedicated state-sync link | Mounir T3 | Pending NEW |
| 36 | Ring 1: Moodle student access FW rule | nftables: VRF-PEDAGOGY→VRF-STAFF TCP/80,443 | Mounir T3 | Pending NEW |
| 37 | Ring 2: BGP prefix-lists | FRR prefix-list on border external session | Youcef T1 | Pending |
| 38 | Ring 2: Two distinct MD5 secrets | FRR `neighbor password` per session type | Youcef T1 | Update |
| 39 | Ring 2: Max-Prefix Guard (threshold=100) | FRR `maximum-prefix 100 80` on border | Youcef T1 | Pending |
| 40 | Ring 3: VXLAN injection block | `iptables` DROP UDP/4789 from non-VTEP sources | Mounir T3 | Pending |
| 41 | Ring 3: BGP/BFD/SSH CPU ACL | `iptables` restrict ports to infra IPs only | Mounir T3 | Pending |
| 42 | Ring 4: Bastion ed25519 hardening | openssh: AllowUsers, MaxAuthTries 3, LoginGraceTime 30 | Mounir T3 | Pending |
| 43 | Ring 4: SSH restricted to bastion IP | `iptables` DROP TCP/22 except 172.16.0.50 | Mounir T3 | Pending |
| 44 | Ring 5: nftables per-host micro-seg | Per spec Table (Section 3) on each server container | Mounir T3 | Pending |
| 45 | IDS (Suricata) + tc mirror | `jasonish/suricata` + `tc mirred` on leaf-01 | Mounir T3 | Pending |
| 46 | Suricata specific rulesets | ET SCAN, ET EXPLOIT, ET POLICY, ET TROJAN | Mounir T3 | Pending NEW |
| 47 | DMZ structural isolation | VRF-PUBLIC routing table audit | Phase 1 (Youcef) | Done |
| 48 | Centralized Syslog TCP/514 (rsyslog) | Alpine + rsyslog, TCP/514 preferred | Mounir T3 | Pending |
| 49 | No multicast routing in fabric (PIM excluded) | Keep `pimd` disabled and validate HER behavior | Zitouni T4 | Pending |
| 50 | ECN on HPC pod | `sysctl net.ipv4.tcp_ecn=2` on hpc servers | Zitouni T4 | Pending |
| 51 | NTP Stratum 2 (Chrony, < 1s skew) | Alpine + chrony, all nodes sync | Zitouni T4 | Pending |
| 52 | QoS 8-class DiffServ on spines | `tc prio` + `tc htb` + `fq_codel ecn` | Zitouni T4 | Pending |
| 53 | QoS DSCP marking on leafs | `tc filter skbedit dscp` on server ports | Zitouni T4 | Pending |
| 54 | QoS policing + shaping on border | `tc police` inbound, `tc tbf` outbound | Zitouni T4 | Pending |
| 55 | QoS DSCP remark (strip untrusted ISP) | `tc filter skbedit dscp 0` on eth3 ingress | Zitouni T4 | Pending |
| 56 | SNMP on all FRR containers | Net-SNMP agentx + FRR `agentx` command | Zitouni T4 | Pending |
| 57 | Zabbix SNMP monitoring | `zabbix/zabbix-server-pgsql` container | Zitouni T4 | Pending |
| 58 | Prometheus + Grafana + frr-exporter | `prom/prometheus`, `grafana/grafana` | Youcef T1 | Pending |
| 59 | node_exporter on servers | Prometheus node_exporter | Zitouni T4 | Pending |
| 60 | DNS (Unbound) with split-horizon view | Internal view (esi.internal), DMZ view (NXDOMAIN) | Zitouni T4 | Pending |
| 61 | DHCP (Kea) + leaf SVI relay | Kea container + FRR `ip dhcp-relay` on SVIs | Zitouni T4 | Pending |
| 62 | FTP (vsftpd, storage pod) | Alpine + vsftpd in VRF-STAFF | Zitouni T4 | Pending |
| 63 | OOB access isolation | ContainerLab mgmt network + no cross-route | Phase 1 (documented) | Done |
| 64 | BAC port/BGP disable runbook | Shell script deactivation procedure | Youcef T1 | Pending NEW |
| 65 | ECMP flow hash verification | `iperf3` multi-flow test across both spines | Test only | — |

### 3.2 Requires Workaround (teachers notified it is simulated)

| Feature | Real Technology | Simulation Workaround |
|---------|---------------|----------------------|
| HA NGFW L7 DPI | Sophos/Fortinet actual DPI | nftables stateful (no L7 inspection) |
| Firewall state sync | Proprietary HA protocol | conntrackd (open-source conntrack sync) |
| RoCEv2 / RDMA lossless fabric | RDMA NICs + PFC hardware | ECN only (`sysctl tcp_ecn=2`) |
| ECMP verification | Hardware ASIC counters | `iperf3` multi-flow + `ss -s` |
| EVPN MAC mobility | Live VM migration | eth1 down on server → leaf withdraws Type-2 |
| Suricata alert verification | Real attack traffic | `nmap -sS` port scan from external test node |
| Max-prefix threshold values | ISP contract knowledge | Use 100 as default in simulation |

### 3.3 Out of Scope — Documented for Article

| Feature | Reason |
|---------|--------|
| OpenStack / Nova / Neutron / OVN | Compute infrastructure |
| Ceph RBD / CephFS / NFS-Ganesha / RGW | Storage backend |
| SLURM / k3s (Kubernetes) | Workload orchestration |
| Ansible Tower / AWX | Automation excluded per project scope |
| Sophos URL filter | Campus edge appliance, not DC |
| Access Points (APs) and campus WiFi radio | Not connected to DC fabric by design |
| IPv6 dual-stack | No K8s target in simulation |
| Hardware ASIC forwarding rates | Kernel software path only |
| PFC fabric-wide | Hardware RDMA NIC required |
| Physical OOB switch | Replaced by ContainerLab management network |
| STP, MLAG/vPC, OSPF/IS-IS | Explicitly excluded by design spec |
| TPM secure boot for BAC cluster | Physical hardware security |
| LUKS encryption on volumes | OS-level, not network |

---

## 4. Phase 1 — Initial State (Reference)

Phase 1 is complete and deployed. The items below describe what exists and what  
needs a correction push before Phase 2 branches proceed.

### 4.1 What Phase 1 Delivered

| Layer | Delivered | Correction Needed |
|-------|-----------|---------------------|
| Physical | All 12 leaf/spine nodes + 3 ISP routers + servers + placeholder nodes | None |
| Underlay | eBGP, BFD, ECMP, TCP MD5 (single secret), MTU 9000 | Split MD5 into two secrets (Youcef) |
| Overlay | VXLAN all VNIs with wrong 10030/10040 placement, EVPN Type-2/3/5, 5 VRFs, IRB, anycast GW | Move VNI 10030/10040 to admin-leaf; add VNI 10120 + VRF-WIFI-CTRL |
| Security | VRF isolation, VRF-PUBLIC/ORIENTATION empty | None to Phase 1 structure |
| Infrastructure | Placeholder containers declared | None |

### 4.2 Correction Push Required (Youcef — High Priority)

Before any Phase 2 branch is opened, a **correction push to main** must:

1. **Remove** VNI 10030 (LMS-STAFF) and VNI 10040 (SERVICES-WEB) from `configs/leaf-01/startup.sh` and `configs/leaf-02/startup.sh` and their frr.conf VRF-STAFF sections
2. **Add** VNI 10030 and 10040 to `configs/leaf-03/startup.sh` and `configs/leaf-04/startup.sh` and their frr.conf
3. **Add** VNI 10120 (WIFI-CTRL-MGMT) and VRF-WIFI-CTRL to `configs/leaf-01/startup.sh` and frr.conf
4. **Add** new YAML link: `campus-bp:eth3 → leaf-01:eth8` (fixed simulation mapping)
5. **Add** new YAML link: `firewall-01:eth3 ↔ firewall-02:eth3` (state-sync link, Mounir uses it)
6. Update phase1-verify.sh to test that leaf-03/04 have VNI 10030 and leaf-01/02 do NOT

This correction push should be reviewed by everyone before any Phase 2 branch diverges.

### 4.3 File Structure (Unchanged from v1.6)

```
esi-datacenter/
├── context.md
├── implementations/
│   └── frr-containerlab/
│       ├── esi-datacenter.clab.yml
│       ├── configs/
│       │   ├── spine-0[12]/{daemons,frr.conf,startup.sh}
│       │   ├── leaf-0[1-9]/{daemons,frr.conf,startup.sh}
│       │   ├── leaf-10/{daemons,frr.conf,startup.sh}
│       │   ├── isp-router-0[123]/{daemons,frr.conf}
│       │   └── ...placeholder dirs for infra nodes...
│       ├── tests/
│       │   ├── phase1-verify.sh
│       │   └── README-tests.md
│       └── README.md
└── README.md
```

---

## 5. Phase 2 — Task Split by Theme

> **YAML is editable by domain.** Members may modify `esi-datacenter.clab.yml` when needed.  
> Every YAML change must be documented in the PR and linked to the theme test block.

All file paths in Phase 2 sections are relative to `implementations/frr-containerlab/`.

### Theme Ownership

| Theme | Member | Branch Name | Priority Correction |
|-------|--------|------------|---------------------|
| **T1 — Border Routing & Internet** | Youcef | `feature/border-routing` | Correction push FIRST |
| **T2 — ESI Multihoming & Campus** | Ikram | `feature/esi-campus` | Waits for correction push |
| **T3 — Security Rings** | Mounir | `feature/security-rings` | Waits for correction push |
| **T4 — Protocol Extensions & Monitoring** | Zitouni | `feature/protocols-monitoring` | Merges last |

---

### Youcef — T1: Border Routing, Correction & Internet Observability

**Files touched:**
- `configs/leaf-01/frr.conf` — REMOVE VNI 10030/10040; ADD VRF-WIFI-CTRL, VNI 10120; ADD ISP BGP with external MD5
- `configs/leaf-02/frr.conf` — REMOVE VNI 10030/10040; ADD ISP BGP with external MD5
- `configs/leaf-01/startup.sh` — REMOVE VNI 10030/10040 bridge entries; ADD VRF-WIFI-CTRL setup; ADD VNI 10120; ADD orientation port control
- `configs/leaf-02/startup.sh` — REMOVE VNI 10030/10040 bridge entries
- `configs/leaf-03/frr.conf` — ADD VNI 10030, 10040 (new on this leaf)
- `configs/leaf-04/frr.conf` — ADD VNI 10030, 10040 (new on this leaf)
- `configs/leaf-03/startup.sh` — ADD VXLAN bridges for VNI 10030, 10040
- `configs/leaf-04/startup.sh` — ADD VXLAN bridges for VNI 10030, 10040
- `configs/isp-router-01/frr.conf` — complete
- `configs/isp-router-02/frr.conf` — complete
- `configs/isp-router-03/frr.conf` — complete
- `configs/orientation-runbook.sh` — new (activation + deactivation steps)
- `configs/prometheus/` — new directory
- YAML: add campus-bp link to leaf-01; add firewall state-sync link (for Mounir to use)

**What to implement:**

**0. CORRECTION — Remove VNI 10030/10040 from border-leaf (leaf-01/02):**
In leaf-01 and leaf-02 startup.sh, remove all `vxlan10030`, `vxlan10040`, `vlan30`, `vlan40`, `bridge vlan add vid 30`, `bridge vlan add vid 40` lines.
In leaf-01 and leaf-02 frr.conf, remove `interface vlan30`, `interface vlan40`, and the VRF-STAFF per-VRF BGP instance entirely (VRF-STAFF is no longer local to border-leaf).

**1. ADD VNI 10030/10040 to admin-leaf (leaf-03/leaf-04):**
```bash
# In leaf-03/startup.sh — add after existing VNI blocks:
# VNI 10030 — LMS-STAFF (moved from border-leaf)
ip link add vxlan10030 type vxlan id 10030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan10030 master br0
ip link set vxlan10030 mtu 9000
ip link set vxlan10030 up
bridge vlan add vid 30 dev vxlan10030 pvid untagged

ip link add vlan30 link br0 type vlan id 30
ip link set vlan30 master VRF-STAFF
ip link set vlan30 address $ANYCAST_MAC
ip addr add 192.168.30.1/24 dev vlan30
ip link set vlan30 up

# VNI 10040 — SERVICES-WEB (moved from border-leaf)
ip link add vxlan10040 type vxlan id 10040 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan10040 master br0
ip link set vxlan10040 mtu 9000
ip link set vxlan10040 up
bridge vlan add vid 40 dev vxlan10040 pvid untagged

ip link add vlan40 link br0 type vlan id 40
ip link set vlan40 master VRF-STAFF
ip link set vlan40 address $ANYCAST_MAC
ip addr add 192.168.40.1/24 dev vlan40
ip link set vlan40 up
```

Add corresponding `interface vlan30` and `interface vlan40` blocks (with `vrf VRF-STAFF`) to leaf-03 and leaf-04 frr.conf. Ensure VRF-STAFF per-VRF BGP instance on leaf-03/04 now redistributes 192.168.30.0/24 and 192.168.40.0/24 as well.

**2. ADD VRF-WIFI-CTRL + VNI 10120 to leaf-01:**
```bash
# In leaf-01/startup.sh — WiFi Controller management path
# VRF-WIFI-CTRL — micro-VRF, single /32 only
ip link add VRF-WIFI-CTRL type vrf table 60
ip link set VRF-WIFI-CTRL up

# eth for campus-bp uplink (fixed in this repo to leaf-01:eth8)
ip link set eth8 master VRF-WIFI-CTRL
ip addr add 10.200.0.1/30 dev eth8   # P2P to campus-bp on this interface
ip link set eth8 up

# Static /32 to wifi-controller mgmt IP (192.168.10.100 in VRF-PEDAGOGY on student-leaf)
# This route is injected as EVPN Type-5 toward student-leaf
ip route add 192.168.10.100/32 via 10.200.0.2 vrf VRF-WIFI-CTRL
```

In leaf-01 frr.conf:
```
vrf VRF-WIFI-CTRL
 vni 50060
!
interface eth8
 vrf VRF-WIFI-CTRL
!
router bgp 65001 vrf VRF-WIFI-CTRL
 bgp router-id 10.1.0.11
 address-family ipv4 unicast
  redistribute static
 exit-address-family
 address-family l2vpn evpn
  advertise ipv4 unicast
  rd 10.1.0.11:50060
  route-target both 65000:50060
 exit-address-family
!
```

campus-bp startup.sh:
```bash
# campus-bp — simulates the campus distribution switch WiFi MGMT uplink
ip addr add 10.200.0.2/30 dev eth3   # eth3 → leaf-01:eth8
ip route add 192.168.10.100/32 via 10.200.0.1   # route to wifi-controller mgmt IP
```

**3. ISP BGP with prefix-lists and external MD5:**
```
ip prefix-list ISP-IN  seq 5  permit 0.0.0.0/0
ip prefix-list ISP-IN  seq 10 deny   any
ip prefix-list ISP-OUT seq 5  deny   10.0.0.0/8 le 32
ip prefix-list ISP-OUT seq 10 deny   172.16.0.0/12 le 32
ip prefix-list ISP-OUT seq 15 deny   192.168.0.0/16 le 32
ip prefix-list ISP-OUT seq 20 permit any

neighbor 203.0.113.2 remote-as 64500
neighbor 203.0.113.2 password ESI-BGP-EXTERNAL   ← external secret
neighbor 203.0.113.2 prefix-list ISP-IN  in
neighbor 203.0.113.2 prefix-list ISP-OUT out
neighbor 203.0.113.2 maximum-prefix 100 80
```

**4. BAC orientation runbook (`configs/orientation-runbook.sh`):**
```bash
#!/bin/bash
# BAC Orientation Activation / Deactivation Runbook
# Usage: ./orientation-runbook.sh activate | deactivate

ACTION=$1

if [ "$ACTION" = "activate" ]; then
  echo "[runbook] Activating BAC orientation..."
  # Step 1: Physical inspection (documented, not automated)
  # Step 2: Secure boot verification (documented, not automated)
  # Step 3: Re-enable Leaf ports facing BAC cluster
  docker exec clab-esi-datacenter-leaf-01 ip link set eth_bac up
  # Step 4: Inject VRF-ORIENTATION third ISP route
  docker exec clab-esi-datacenter-leaf-01 \
    vtysh -c "conf t" -c "neighbor 203.0.114.2 activate" -c "end"
  # Step 5: Platform health check
  echo "[runbook] Verify: ip route show vrf VRF-ORIENTATION"
elif [ "$ACTION" = "deactivate" ]; then
  echo "[runbook] Deactivating BAC orientation..."
  # Disable BGP session for third ISP
  docker exec clab-esi-datacenter-leaf-01 \
    vtysh -c "conf t" -c "neighbor 203.0.114.2 shutdown" -c "end"
  # Admin-disable Leaf ports facing BAC nodes
  docker exec clab-esi-datacenter-leaf-01 ip link set eth_bac down
  echo "[runbook] VRF-ORIENTATION is now route-empty"
fi
```

**5. Prometheus + Grafana + frr-exporter** in `configs/prometheus/` (unchanged from previous spec)

---

### Ikram — T2: ESI Multihoming & Campus Connectivity

**Files touched:** Same as before. No changes from the refinement affect Ikram's scope.  
WiFi controller stays on student-leaf in VRF-PEDAGOGY.  
The WiFi MGMT path through border-leaf is entirely Youcef's concern.  
Campus-bp still connects to student-leaf via EtherChannel for OLD wired buildings (separate from WiFi MGMT path).  
APs do NOT connect to any DC leaf — if simulating AP clients, they should connect to campus-bp only.

**Merge note:** Ikram must rebase after Youcef's correction push lands on main, because leaf-03/04 frr.conf files now have new content from the correction. Ikram's ESI additions to those files must come after.

**What to implement:** Unchanged from v1.6 context — ESI config on all leaf pairs, LACP on servers, campus-bp EtherChannel to student-leaf for wired campus buildings, wifi-controller container in VRF-PEDAGOGY.

**Clarification on WiFi controller simulation:**
- wifi-controller container runs on student-leaf (eth connected to leaf-09/leaf-10)
- Its VRF-PEDAGOGY IP (192.168.10.100) is the management IP that the campus-bp reaches via VRF-WIFI-CTRL
- Ikram does NOT need to simulate the management path — Youcef handles it from the border-leaf side
- Ikram simply ensures the wifi-controller container has IP 192.168.10.100 in VRF-PEDAGOGY and is reachable via EVPN from border-leaf

---

### Mounir — T3: Security Rings (All 5 Rings + Supporting Controls)

**Files touched:** Same as before, plus:
- `configs/firewall-01/startup.sh` — add conntrackd state sync
- `configs/firewall-02/startup.sh` — add conntrackd state sync
- YAML: state-sync link `firewall-01:eth3 ↔ firewall-02:eth3` (Youcef adds this in correction push)

**New additions from refinement:**

**1. Ring 1 — Firewall state sync (conntrackd):**
```bash
# firewall-01/startup.sh (add after keepalived config):
apk add --no-cache conntrack-tools

cat > /etc/conntrackd/conntrackd.conf << 'EOF'
Sync {
  Mode FTFW {
    DisableExternalCache Off
    CommitTimeout 1800
  }
  Network {
    Interface eth3   # dedicated state-sync link to firewall-02
    IPvX {
      IPv4_address 192.168.2.1  # state-sync P2P address
    }
    Peer {
      Address 192.168.2.2   # firewall-02 state-sync address
    }
  }
}
General {
  HashSize 32768
  HashLimit 131072
  LogFile /var/log/conntrackd.log
  LockFile /var/lock/conntrack.lock
  UNIX {
    Path /var/run/conntrackd.ctl
  }
}
EOF
conntrackd -d
```

firewall-02 is symmetric: state-sync address 192.168.2.2, peer 192.168.2.1.

**2. Suricata specific rulesets (Mounir):**
```bash
# ids-01/startup.sh — enable specific rulesets after Suricata install:
# Download and enable required ET rulesets
suricata-update add-source et/open https://rules.emergingthreats.net/open/suricata-6.0/emerging.rules.tar.gz
suricata-update enable-only-conf << 'EOF'
emerging-scan.rules
emerging-exploit.rules
emerging-policy.rules
emerging-trojan.rules
EOF
suricata-update
suricata -c /etc/suricata/suricata.yaml -i eth1 --daemon
```

**3. Moodle student access firewall rule (Mounir):**
```bash
# firewall-01/startup.sh — add cross-VRF permit for Moodle access:
# Students (VRF-PEDAGOGY, 192.168.10.0/24 + 192.168.20.0/24) → Moodle (VRF-STAFF, 192.168.30.0/24)
nft add rule inet filter forward \
  ip saddr { 192.168.10.0/24, 192.168.20.0/24 } \
  ip daddr 192.168.30.0/24 \
  tcp dport { 80, 443 } ct state new,established accept
# Return traffic handled by ct state established,related rule in baseline
```

**Everything else in Mounir's task is unchanged from v1.6.**

---

### Zitouni — T4: Protocol Extensions & Monitoring

**Files touched:** Same as before, with these additions:

**0. No-PIM compliance guard (from full architecture):**
- Keep `pimd` disabled across the whole fabric (`daemons` files remain without `pimd=yes`)
- Do not add any `ip pim` or `router pim` statements in any FRR config
- Validate EVPN BUM behavior through Type-3/IMET evidence, not PIM neighbor state

**1. DNS split-horizon for VRF-PUBLIC (NXDOMAIN for internal zones):**
```bash
# dns-server/setup.sh — Unbound with views:
cat > /etc/unbound/unbound.conf << 'EOF'
server:
  interface: 0.0.0.0
  access-control: 192.168.0.0/16 allow
  access-control: 10.0.0.0/8 allow

# Internal view — full esi.internal visibility
view:
  name: "internal"
  match-client: 192.168.10.0/24  # VRF-PEDAGOGY
  match-client: 192.168.30.0/24  # VRF-STAFF
  match-client: 192.168.50.0/24  # VRF-STAFF
  local-zone: "esi.internal." static
  local-data: "spine-01.esi.internal. A 10.1.0.1"
  local-data: "spine-02.esi.internal. A 10.1.0.2"
  # ... add all nodes ...

# DMZ view — NXDOMAIN for internal zones
view:
  name: "dmz"
  match-client: 192.168.100.0/24  # VRF-PUBLIC
  local-zone: "esi.internal." refuse  # NXDOMAIN for internal queries from DMZ
  local-zone: "." transparent         # Public DNS for everything else
EOF
unbound -c /etc/unbound/unbound.conf
```

**2. Syslog TCP/514 (update from UDP):**
In all FRR container startup.sh forwarding rule:
```bash
# Use TCP instead of UDP for reliable delivery
echo "*.* @@192.168.50.70:514" >> /etc/rsyslog.conf   # @@ = TCP, @ = UDP
```

**3. NTP constraint documentation:**
The chrony server allows < 1 second skew for log correlation and < 30 seconds for AD/Kerberos. The chrony config itself enforces this via `maxdistance` and `makestep` directives.

**4. Inter-cluster matrix checks (new):**
- Add test assertions for one-way rules (Admin -> General allowed, General -> Admin denied)
- Keep BAC orientation matrix behavior strict (`VRF-ORIENTATION` no production paths when inactive)

**Everything else in Zitouni's task is unchanged from v1.6, except any PIM-related configuration which is now excluded.**

---

## 6. Test Blocks

### 6.1 Phase 1 Verification Script (Updated)

```bash
#!/bin/bash
# tests/phase1-verify.sh
# Updated to include VNI placement correction validation.
set +e
PASS=0; FAIL=0
C="docker exec clab-esi-datacenter"

ok()  { echo "  [PASS] $1"; ((PASS++)); return 0; }
fail(){ echo "  [FAIL] $1"; ((FAIL++)); return 0; }
chk() {
  eval "$2" 2>/dev/null | grep -Eq "$3" && ok "$1" || fail "$1"
}

echo "=== ESI Phase 1 + Correction Verification ==="

chk "spine-01: 10 neighbors present" "$C-spine-01 vtysh -c 'show bgp summary'" "Total number of neighbors 10"
chk "spine-02: 10 neighbors present" "$C-spine-02 vtysh -c 'show bgp summary'" "Total number of neighbors 10"

for IP in 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20; do
  chk "spine-01 has route to $IP/32" "$C-spine-01 vtysh -c 'show ip route $IP/32'" "(bgp|B>)"
done

chk "leaf-09: multipath" "$C-leaf-09 vtysh -c 'show ip bgp 10.1.0.13/32'" "Multipath|2"
chk "spine-01 internal MD5 present" "$C-spine-01 grep -c 'password ESI-BGP-INTERNAL' /etc/frr/frr.conf" "1"
chk "leaf-09 BFD Up" "$C-leaf-09 vtysh -c 'show bfd peers'" "Up"
chk "spine-01 eth1 mtu 9000" "$C-spine-01 ip link show eth1" "mtu 9000"
chk "leaf-03 br0 mtu 9000" "$C-leaf-03 ip link show br0" "mtu 9000"
chk "leaf-09 vxlan10010 tos inherit" "$C-leaf-09 ip -d link show vxlan10010" "tos inherit"

for LEAF in leaf-01 leaf-03 leaf-05 leaf-07 leaf-09; do
  chk "$LEAF EVPN sessions" "$C-$LEAF vtysh -c 'show bgp l2vpn evpn summary'" "Total number of neighbors 2"
done

# VNI placement validation (CORRECTION)
chk "leaf-03 has VNI 10030 (LMS-STAFF moved from border)" "$C-leaf-03 vtysh -c 'show evpn vni 10030'" "10030"
chk "leaf-03 has VNI 10040 (SERVICES-WEB moved from border)" "$C-leaf-03 vtysh -c 'show evpn vni 10040'" "10040"

r=$($C-leaf-01 vtysh -c 'show evpn vni' 2>/dev/null)
echo "$r" | grep -q "10030" && fail "leaf-01 still has VNI 10030 (must be removed)" || ok "leaf-01 does NOT have VNI 10030 (correct)"
echo "$r" | grep -q "10040" && fail "leaf-01 still has VNI 10040 (must be removed)" || ok "leaf-01 does NOT have VNI 10040 (correct)"

chk "leaf-01 has VNI 10120 (WIFI-CTRL-MGMT)" "$C-leaf-01 vtysh -c 'show evpn vni 10120'" "10120"
chk "VRF-WIFI-CTRL exists on leaf-01" "$C-leaf-01 ip vrf show" "VRF-WIFI-CTRL"

chk "leaf-09 VNI 10010 has remote VTEPs" "$C-leaf-09 vtysh -c 'show evpn vni 10010'" "Remote VTEPs for this VNI"
chk "EVPN Type-5 present" "$C-spine-01 vtysh -c 'show bgp l2vpn evpn route type prefix'" "Route Distinguisher"
chk "student inter-subnet ping" "$C-server-student-01 ping -c3 -W2 192.168.20.10" "3 (packets )?received"

r=$($C-server-student-01 ping -c2 -W1 192.168.50.10 2>/dev/null)
echo "$r" | grep -Eq "0 (packets )?received|100% packet loss|unreachable" && ok "VRF isolation student->staff" || fail "VRF isolation broken"

r=$($C-leaf-01 ip route show vrf VRF-PUBLIC 2>/dev/null)
[ -z "$r" ] && ok "VRF-PUBLIC route table empty" || fail "VRF-PUBLIC has routes: $r"

r=$($C-leaf-01 ip route show vrf VRF-ORIENTATION 2>/dev/null)
[ -z "$r" ] && ok "VRF-ORIENTATION empty pre-activation" || fail "VRF-ORIENTATION has routes: $r"

chk "leaf-01 ping isp-router-01" "$C-leaf-01 ping -c2 -W1 203.0.113.2" "2 (packets )?received"
chk "leaf-02 ping isp-router-02" "$C-leaf-02 ping -c2 -W1 203.0.113.6" "2 (packets )?received"
chk "student default in VRF-PEDAGOGY" "$C-leaf-09 ip route show vrf VRF-PEDAGOGY" "^default"
chk "spine-01 ecmp hash policy=1" "$C-spine-01 sysctl net.ipv4.fib_multipath_hash_policy" "= 1"

$C-leaf-09 vtysh -c "clear bgp *" 2>/dev/null
sleep 2
MGMT_IP=$(docker inspect clab-esi-datacenter-spine-01 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
ping -c2 -W2 "$MGMT_IP" >/dev/null 2>&1 && ok "OOB reachable during BGP disruption" || fail "OOB not reachable"

echo "Results: $PASS passed / $FAIL failed"
[ $FAIL -eq 0 ] && echo "Phase 1 + Correction STABLE" || echo "NOT ready — fix failures above"
```

### 6.2 Per-Theme Test Blocks

#### T1 — Border Routing (Youcef)
```bash
#!/bin/bash
C="docker exec clab-esi-datacenter"
echo "=== T1: Border Routing & Internet ==="

# Two distinct MD5 passwords used
chk_inline() { eval "$1" 2>/dev/null | grep -q "$2" && echo "[PASS] $3" || echo "[FAIL] $3"; }
chk_inline "$C-leaf-01 grep -c 'ESI-BGP-EXTERNAL' /etc/frr/frr.conf" "1" "leaf-01 uses external MD5 secret"
chk_inline "$C-leaf-01 grep -c 'ESI-BGP-INTERNAL' /etc/frr/frr.conf" "1" "leaf-01 still uses internal MD5 for fabric sessions"

# VNI correction: LMS-STAFF on admin-leaf, not border-leaf
$C-leaf-03 vtysh -c "show evpn vni 10030" 2>/dev/null | grep -q "10030" && echo "[PASS] LMS-STAFF VNI on leaf-03" || echo "[FAIL] LMS-STAFF missing on leaf-03"
$C-leaf-01 vtysh -c "show evpn vni" 2>/dev/null | grep -q "10030" && echo "[FAIL] LMS-STAFF still on leaf-01" || echo "[PASS] LMS-STAFF NOT on leaf-01 (correct)"

# ISP prefix-list rejects non-default inbound
$C-leaf-01 vtysh -c "show ip bgp neighbors 203.0.113.2 routes" 2>/dev/null | \
  grep -v "0.0.0.0/0" | grep -c ">" | grep -q "^0$" \
  && echo "[PASS] Only default route accepted from ISP" || echo "[FAIL] Non-default routes accepted"

# Max-prefix guard
$C-leaf-01 vtysh -c "show bgp neighbors 203.0.113.2" 2>/dev/null | grep -q "maximum-prefix" \
  && echo "[PASS] Max-prefix guard configured" || echo "[FAIL] Max-prefix not configured"

# RFC1918 not advertised outbound
$C-isp-router-01 vtysh -c "show bgp neighbors 203.0.113.1 received-routes" 2>/dev/null | \
  grep -Eq "10\.|172\.16\.|192\.168\." && echo "[FAIL] RFC1918 leaking to ISP" || echo "[PASS] RFC1918 blocked outbound"

# VRF-WIFI-CTRL: route to wifi-controller mgmt IP exists
$C-leaf-01 ip route show vrf VRF-WIFI-CTRL 2>/dev/null | grep -q "192.168.10.100" \
  && echo "[PASS] VRF-WIFI-CTRL has /32 route to wifi-controller" || echo "[FAIL] WiFi MGMT route missing"

# WiFi MGMT reachability from campus-bp
$C-campus-bp ping -c2 -W2 192.168.10.100 2>/dev/null | grep -q "2 received" \
  && echo "[PASS] campus-bp reaches wifi-controller via VRF-WIFI-CTRL" || echo "[FAIL] WiFi MGMT path broken"

# Default route in all VRFs
for VRF in VRF-PEDAGOGY VRF-STAFF VRF-ADMINISTRATION; do
  $C-leaf-01 ip route show vrf $VRF 2>/dev/null | grep -q "default" \
    && echo "[PASS] Default route in $VRF" || echo "[FAIL] No default in $VRF"
done

# BAC orientation runbook
./configs/orientation-runbook.sh activate >/dev/null 2>&1
$C-leaf-01 ip route show vrf VRF-ORIENTATION 2>/dev/null | grep -q "203.0.114" \
  && echo "[PASS] VRF-ORIENTATION has ISP route after activation" || echo "[FAIL] Activation runbook failed"
./configs/orientation-runbook.sh deactivate >/dev/null 2>&1
r=$($C-leaf-01 ip route show vrf VRF-ORIENTATION 2>/dev/null)
[ -z "$r" ] && echo "[PASS] VRF-ORIENTATION empty after deactivation" || echo "[FAIL] Deactivation runbook failed"

# Prometheus scraping FRR metrics
curl -s http://$(docker inspect clab-esi-datacenter-prometheus \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'):9090/api/v1/targets \
  2>/dev/null | grep -q "frr_exporter" && echo "[PASS] frr-exporter target in Prometheus" || echo "[FAIL] frr-exporter not scraped"
```

#### T2 — ESI Multihoming (Ikram) — Unchanged from v1.6 (except naming consistency of campus-bp and wifi-controller)
```bash
#!/bin/bash
C="docker exec clab-esi-datacenter"
echo "=== T2: ESI Multihoming & Campus ==="

$C-spine-01 vtysh -c "show bgp l2vpn evpn route type es" 2>/dev/null | grep -q "ESI" \
  && echo "[PASS] Type-1 ES routes advertised" || echo "[FAIL] No Type-1 ES routes"

for LEAF in leaf-09 leaf-03 leaf-05 leaf-07 leaf-01; do
  $C-$LEAF vtysh -c "show evpn es detail" 2>/dev/null | grep -q "DF" \
    && echo "[PASS] $LEAF DF election done" || echo "[FAIL] $LEAF DF election missing"
done

$C-server-student-01 ip link show bond0 2>/dev/null | grep -q "UP" \
  && echo "[PASS] server-student-01 LACP bond up" || echo "[FAIL] LACP bond not established"

$C-leaf-09 ip link set eth3 down 2>/dev/null; sleep 2
$C-server-student-01 ping -c3 -W2 192.168.10.1 2>/dev/null | grep -q "3 received" \
  && echo "[PASS] ESI failover — server reachable via leaf-10" || echo "[FAIL] ESI failover failed"
$C-leaf-09 ip link set eth3 up 2>/dev/null

$C-campus-bp ip link show bond0 2>/dev/null | grep -q "UP" \
  && echo "[PASS] campus-bp EtherChannel bond active" || echo "[FAIL] campus-bp EtherChannel not established"

$C-wifi-controller ip link show br-student 2>/dev/null | grep -q "master\|UP" \
  && echo "[PASS] WiFi controller student VLAN bridge active" || echo "[FAIL] WiFi controller bridge not configured"

# WiFi controller has expected mgmt IP
$C-wifi-controller ip addr show 2>/dev/null | grep -q "192.168.10.100" \
  && echo "[PASS] WiFi controller mgmt IP 192.168.10.100 set" || echo "[FAIL] WiFi controller mgmt IP missing"
```

#### T3 — Security Rings (Mounir) — Updated
```bash
#!/bin/bash
C="docker exec clab-esi-datacenter"
echo "=== T3: Security Rings ==="

# Ring 1: Firewall VIP active
$C-firewall-01 ip addr show 2>/dev/null | grep -q "192.168.1.254" \
  && echo "[PASS] Ring 1 firewall VIP active on fw-01" || echo "[FAIL] Firewall VIP not active"

# Ring 1: State sync — conntrackd running on both firewalls
$C-firewall-01 pgrep conntrackd >/dev/null 2>&1 && echo "[PASS] conntrackd running on fw-01" || echo "[FAIL] conntrackd not running on fw-01"
$C-firewall-02 pgrep conntrackd >/dev/null 2>&1 && echo "[PASS] conntrackd running on fw-02" || echo "[FAIL] conntrackd not running on fw-02"

# Ring 1: Moodle student access policy
$C-firewall-01 nft list ruleset 2>/dev/null | grep -q "192.168.30.0/24" \
  && echo "[PASS] Moodle student access FW rule present" || echo "[FAIL] Moodle FW rule missing"

# Ring 3: VXLAN injection blocked from server
$C-spine-01 iptables -L INPUT -n 2>/dev/null | grep -q "DROP.*4789" \
  && echo "[PASS] Ring 3 VXLAN injection blocked" || echo "[FAIL] Ring 3 VXLAN ACL not configured"

# Ring 3: BGP restricted to fabric peers
$C-leaf-01 iptables -L INPUT -n 2>/dev/null | grep -q "DROP.*dpt:179" \
  && echo "[PASS] Ring 3 BGP CPU ACL active" || echo "[FAIL] Ring 3 BGP ACL missing"

# Ring 4: Direct SSH to spine blocked
ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
  root@$(docker inspect clab-esi-datacenter-spine-01 \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1) \
  echo ok 2>&1 | grep -q "Timeout\|refused\|Permission" \
  && echo "[PASS] Ring 4 direct SSH to spine blocked" || echo "[FAIL] Ring 4 SSH not blocked"

# Ring 5: nftables default drop on servers
$C-server-student-01 nft list chain inet filter input 2>/dev/null | grep -q "policy drop" \
  && echo "[PASS] Ring 5 nftables default drop on student server" || echo "[FAIL] Ring 5 nftables not configured"

# IDS: Suricata running with required rulesets
$C-ids-01 suricata --list-runmodes 2>/dev/null | grep -q "ids" \
  && echo "[PASS] Suricata running" || echo "[FAIL] Suricata not running"
$C-ids-01 cat /etc/suricata/rules/emerging-scan.rules 2>/dev/null | wc -l | grep -vq "^0$" \
  && echo "[PASS] ET SCAN ruleset loaded" || echo "[FAIL] ET SCAN missing"
$C-ids-01 cat /etc/suricata/rules/emerging-exploit.rules 2>/dev/null | wc -l | grep -vq "^0$" \
  && echo "[PASS] ET EXPLOIT ruleset loaded" || echo "[FAIL] ET EXPLOIT missing"

# IDS: tc mirror delivering traffic
$C-ids-01 timeout 5 tcpdump -i eth1 -c5 2>/dev/null | grep -qc "IP" \
  && echo "[PASS] IDS receiving mirrored traffic" || echo "[FAIL] No traffic reaching IDS"

# IDS: Port scan generates ET SCAN alert
$C-server-dmz-01 nmap -sS --host-timeout 5 192.168.100.1 2>/dev/null; sleep 3
$C-ids-01 cat /var/log/suricata/fast.log 2>/dev/null | grep -q "ET SCAN\|SCAN" \
  && echo "[PASS] IDS ET SCAN alert generated" || echo "[FAIL] No Suricata alert"

# Syslog: receiving via TCP/514 from FRR nodes
$C-syslog-server ss -tnlp 2>/dev/null | grep -q "514" \
  && echo "[PASS] Syslog server listening on TCP/514" || echo "[FAIL] Syslog TCP/514 not listening"
$C-syslog-server grep -c "BGP\|frr" /var/log/syslog 2>/dev/null | grep -vq "^0$" \
  && echo "[PASS] FRR logs arriving at syslog server" || echo "[FAIL] No FRR logs at syslog server"
```

#### T4 — Protocol Extensions & Monitoring (Zitouni) — Updated
```bash
#!/bin/bash
C="docker exec clab-esi-datacenter"
echo "=== T4: Protocol Extensions & Monitoring ==="

# No-PIM policy: multicast routing must remain excluded in this fabric
$C-leaf-07 vtysh -c "show running-config" 2>/dev/null | grep -q "ip pim\|router pim" \
  && echo "[FAIL] PIM config found on leaf-07 (must be absent)" || echo "[PASS] No PIM config on leaf-07"

# ECN: enabled on HPC servers
$C-server-hpc-01 sysctl net.ipv4.tcp_ecn 2>/dev/null | grep -q "= 2" \
  && echo "[PASS] ECN enabled on HPC server" || echo "[FAIL] ECN not enabled"

# NTP: synced with skew check
$C-spine-01 chronyc tracking 2>/dev/null | grep -q "Stratum : 2" \
  && echo "[PASS] spine-01 synced to Stratum 2 NTP" || echo "[FAIL] spine-01 NTP not synced"
SKEW=$($C-spine-01 chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}')
echo "[INFO] spine-01 NTP skew: ${SKEW}s (must be < 1s for log correlation)"

# QoS: HTB qdisc on spine
$C-spine-01 tc qdisc show dev eth1 2>/dev/null | grep -q "htb" \
  && echo "[PASS] HTB qdisc on spine-01 eth1" || echo "[FAIL] HTB not configured on spine"

# QoS: DSCP marking on leaf server ports
$C-leaf-09 tc filter show dev eth3 parent 1: 2>/dev/null | grep -q "skbedit" \
  && echo "[PASS] DSCP marking on leaf-09 server port" || echo "[FAIL] DSCP marking not configured"

# QoS: tos inherit in VXLAN outer header
$C-leaf-09 timeout 5 tcpdump -i eth1 -c10 -vv udp port 4789 2>/dev/null | grep -q "tos 0x" \
  && echo "[PASS] Non-zero DSCP in VXLAN outer header" || echo "[FAIL] DSCP not propagating"

# SNMP: FRR responding
snmpwalk -v2c -c public \
  $(docker inspect clab-esi-datacenter-spine-01 \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1) \
  1.3.6.1.2.1.1.1 2>/dev/null | grep -q "FRR\|Linux" \
  && echo "[PASS] SNMP responding on spine-01" || echo "[FAIL] SNMP not responding"

# Zabbix API
curl -s -X POST http://$(docker inspect clab-esi-datacenter-zabbix-server \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' | head -1)/api_jsonrpc.php \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"host.get","params":{},"id":1}' 2>/dev/null | grep -q "result" \
  && echo "[PASS] Zabbix API responding" || echo "[FAIL] Zabbix not accessible"

# DNS: internal zone resolves
$C-server-admin-01 nslookup spine-01.esi.internal 192.168.50.30 2>/dev/null | grep -q "Address" \
  && echo "[PASS] DNS resolving internal domain" || echo "[FAIL] DNS resolution failed"

# DNS: DMZ gets NXDOMAIN for internal zone
$C-server-dmz-01 nslookup spine-01.esi.internal 192.168.50.30 2>/dev/null | grep -qiE "NXDOMAIN|server can" \
  && echo "[PASS] DNS returns NXDOMAIN to VRF-PUBLIC for internal zone" || echo "[FAIL] DNS split-horizon not working"

# Inter-cluster matrix: General -> Admin denied (one-way policy)
$C-server-student-01 ping -c2 -W1 192.168.50.10 2>/dev/null | grep -Eq "0 (packets )?received|100% packet loss|unreachable" \
  && echo "[PASS] Matrix enforced: General cannot initiate to Admin" || echo "[FAIL] Matrix broken: General reaches Admin"

# DHCP: Kea config valid
$C-dhcp-server kea-dhcp4 -t /etc/kea/kea-dhcp4.conf 2>/dev/null \
  && echo "[PASS] Kea DHCP config valid" || echo "[FAIL] Kea config invalid"
```

> **Note about Phase 2 tests:** Not yet executed against deployed code. Adjustments may be needed based on actual implementation. Every member must run and show passing output before submitting their PR.

---

## 7. GitHub Collaboration Rules

### 7.1 Branch Strategy

```
main                        ← Protected. Requires PR + 1 review.
  └── correction/vni-fix       (Youcef — push FIRST, before any Phase 2 branch)
  └── feature/border-routing   (Youcef)
  └── feature/esi-campus       (Ikram)
  └── feature/security-rings   (Mounir)
  └── feature/protocols-monitoring (Zitouni)
```

**No member ever pushes directly to `main`.**

### 7.2 Mandatory Merge Order

```
CORRECTION (Youcef) → MERGE FIRST — VNI relocation + new links in YAML
    ↓ (everyone rebases before starting)
Ikram (ESI)   → MERGE SECOND  (touches all leaf frr.conf files)
    ↓
Mounir (Security) → MERGE THIRD  (appends to leaf-01/startup.sh for IDS mirror)
    ↓
Youcef (Border T1)  → MERGE FOURTH (appends to border-leaf frr.conf)
    ↓
Zitouni (Protocols) → MERGE LAST  (appends to all startup.sh, all daemons)
```

### 7.3 Conflict Prevention Rules

| File | Owner | Rule |
|------|-------|------|
| `esi-datacenter.clab.yml` | Theme owner | Editable by domain; document node/link changes in PR |
| `configs/spine-*/frr.conf` | Youcef | No Phase 2 member modifies spine frr.conf |
| `configs/*/daemons` | Youcef + Zitouni | Keep `pimd` disabled in all nodes; Zitouni changes only SNMP/NTP related daemon flags |
| `configs/leaf-0[12]/frr.conf` | Youcef only | Other members never touch leaf-01/02 frr.conf |
| `configs/leaf-0[34]/frr.conf` | Youcef (correction + Phase 1 base), then Ikram appends | VNI 10030/10040 added by Youcef correction; Ikram ESI on top |
| `configs/*/frr.conf` (all other leafs) | Youcef Phase 1, Ikram appends | Only Ikram appends to leaf frr.conf in Phase 2 |
| `configs/*/startup.sh` | Youcef (Phase 1 base), then Mounir + Zitouni append | Comment anchors mandatory |
| `configs/leaf-01/startup.sh` | Youcef (base + correction + T1) → Mounir → Zitouni | Strictest ordering; one open PR at a time |

### 7.4 Comment Anchor Convention

```bash
# ======================================================
# THEME T2 — ESI MULTIHOMING — Ikram
# Branch: feature/esi-campus
# ======================================================
```

### 7.4.1 Conflict Minimizers (Mandatory)

1. One-file one-theme at a time for shared files.
2. Append-only discipline below previous anchor.
3. File lock ordering for startup.sh: Youcef (base) → Mounir (IDS/Ring 3) → Zitouni (QoS).
4. Rebase gate: rebase on latest origin/main before reviewer starts.
5. No force-push after review starts unless reviewer requests.

### 7.5 PR Template

```markdown
## What this PR does
[One sentence]

## Theme
[ ] Correction — VNI relocation (Youcef, do first)
[ ] T1 — Border Routing & Internet (Youcef)
[ ] T2 — ESI Multihoming & Campus (Ikram)
[ ] T3 — Security Rings (Mounir)
[ ] T4 — Protocol Extensions & Monitoring (Zitouni)

## Files modified
- configs/xxx/frr.conf — appended VNI 10030 section
- ...

## Architecture change addressed (if applicable)
- [ ] VNI 10030/10040 correction (Change 1)
- [ ] VNI 10120 + VRF-WIFI-CTRL (Change 2)
- [ ] Firewall state sync (Change 3)
- [ ] Two MD5 secrets (Change 4)
- [ ] Suricata rulesets (Change 5)
- [ ] BAC port disable runbook (Change 6)
- [ ] DNS split-horizon NXDOMAIN (Change 7)
- [ ] Syslog TCP/514 (Change 8)
- [ ] Moodle FW rule (Change 9)

## Test block passed
Paste output of the relevant test block here. All lines must show [PASS].

## Rebase confirmation
- [ ] Rebased on latest main before this PR
- [ ] YAML changes are scoped to my theme and documented
- [ ] No file modified outside my theme's scope
```

### 7.6 WSL2 Setup

```ini
# C:\Users\<username>\.wslconfig
[wsl2]
memory=6GB
processors=4
```

```bash
# Verify modules
zcat /proc/config.gz | grep -E "CONFIG_VXLAN|CONFIG_NET_SCH_HTB|CONFIG_VETH|CONFIG_BRIDGE_NETFILTER|CONFIG_NET_CLS_U32"
```

### 7.7 Daily Workflow

```bash
git fetch origin
git checkout feature/your-theme
git rebase origin/main
# ... work ...
bash tests/phase1-verify.sh          # must still pass
bash tests/theme-TX-verify.sh        # your theme tests
git add configs/your-files/
git commit -m "feat(T2): add ESI multihoming to admin-leaf pair"
git fetch origin && git rebase origin/main
git push origin feature/your-theme --force-with-lease
```

### 7.8 README Structure

```markdown
## Architecture Overview (Youcef)
## Phase 1 — Getting Started (Youcef)
## Theme T1 — Border Routing (Youcef)
## Theme T2 — ESI Multihoming & Campus (Ikram)
## Theme T3 — Security Rings (Mounir)
## Theme T4 — Protocol Extensions & Monitoring (Zitouni)
## Out of Scope — Documented Exclusions (all)
## Running Tests (all)
```

### 7.9 RAM Budget

| Component | Count | RAM each | Total |
|-----------|-------|----------|-------|
| FRR containers | 15 | ~80MB | ~1.2GB |
| Alpine servers + infra | 17 | ~12MB | ~204MB |
| Suricata IDS | 1 | ~300MB | ~300MB |
| Zabbix server | 1 | ~500MB | ~500MB |
| Prometheus + Grafana | 2 | ~150MB | ~300MB |
| Docker/ContainerLab overhead | — | — | ~400MB |
| **Total** | | | **~2.9GB** |

Minimum: 4GB WSL2. Recommended: 6GB. Exclude Zabbix (`docker stop clab-esi-datacenter-zabbix-server`) when not testing monitoring.

### 7.10 Safe Transition for In-Flight Old Phase 2 Branches

This workflow is the safest migration path for members who started from old Phase 2 assumptions.

1. Save current work before rebase:

```bash
git status
git add -A
git commit -m "wip: checkpoint before architecture alignment rebase"
```

2. Rebase onto latest main correction baseline:

```bash
git fetch origin
git rebase origin/main
```

3. Resolve conflicts in this strict order to minimize cascades:

```text
a) esi-datacenter.clab.yml
b) configs/leaf-01/startup.sh
c) configs/leaf-01/frr.conf
d) configs/leaf-03/frr.conf and configs/leaf-04/frr.conf
e) tests/phase1-verify.sh and theme test block
```
make sure that the rebase results doesn't remove any of your intended changes, but only adjusts them to fit the new baseline (e.g. VNI 10030/10040 moved from leaf-01 to leaf-03/04, new links added in YAML, bp-sw renamed to campus-sw, etc.)

4. Re-run baseline then theme checks before push:

```bash
bash implementations/frr-containerlab/tests/phase1-verify.sh
bash implementations/frr-containerlab/tests/theme-TX-verify.sh
```

### 7.11 Compatibility Guardrails During Transition

- Keep campus WiFi management as a single dedicated path (`campus-bp` -> border-leaf-01).
- Do not re-introduce VNI 10030/10040 on border-leaf files.
- Do not add PIM to any node.
- Keep one-way matrix behavior explicit in tests (General -> Admin denied).

---

*End of Synthesis Document — ESI Datacenter Project*  
*Values derive from architecture_spec_refinement.pdf (supersedes architecture_spec_draft.docx v1.6)*  
*Refinement applied: 10 changes identified, all reflected in tasks and test blocks above*
