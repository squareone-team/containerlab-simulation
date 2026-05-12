# ESI Data Center — Arista EVPN/VXLAN Fabric Automation

Ansible-driven fabric automation for a 10-leaf / 2-spine Arista cEOS lab running
EVPN/VXLAN with ESI multi-homing, symmetric IRB, and per-pod VRF segmentation.

### Pod Layout

| Pod     | ID | Leaves           | Role                                        | VRFs                          |
|---------|----|------------------|---------------------------------------------|-------------------------------|
| Edge    | 1  | leaf-01, leaf-02 | ISP uplinks, Firewall, DMZ, Campus          | PUBLIC, CAMPUS                |
| Core    | 2  | leaf-03, leaf-04 | Admin servers, LMS, INFRA, DNS/NTP/DHCP     | ADMIN, INFRA, LMS, SERVICES   |
| Storage | 3  | leaf-05, leaf-06 | Ceph OSD nodes, HPC storage                 | STORAGE                       |
| Compute | 4  | leaf-07, leaf-08 | Multi-tenant VM workloads                   | TENANT_A, TENANT_B            |
| Ultra   | 5  | leaf-09, leaf-10 | RoCEv2/RDMA HPC, student LACP bonds         | HPC, STUDENT                  |

### BGP AS Assignments

| Device             | AS              | Loopback0           |
|--------------------|-----------------|---------------------|
| spine-01           | 65000           | 10.0.0.1            |
| spine-02           | 65000           | 10.0.0.2            |
| leaf-01 ... leaf-10| 65101 ... 65110 | 10.0.1.1 ... 10.0.5.2 |

### Address Plan

| Block            | Purpose                                      |
|------------------|----------------------------------------------|
| 10.0.0.x/32      | Spine loopbacks                              |
| 10.0.N.x/32      | Leaf loopbacks (pod N, position x)           |
| 10.1.N.0/31      | spine-01 to leaf-N P2P (spine=.0, leaf=.1)  |
| 10.2.N.0/31      | spine-02 to leaf-N P2P (spine=.0, leaf=.1)  |
| 10.255.1.x/31    | ESI peer-links between paired leaves         |
| 192.168.x.1/24   | Anycast gateway IPs per VLAN                 |

---

## Prerequisites

### 1. Import the cEOS image

```bash
docker import cEOS64-lab-4.35.1F.tar.xz ceos:4.35.1F
```

### 2. Install Ansible on the host

```bash
sudo apt install ansible -y
ansible-galaxy collection install -r ansible/requirements.yml
```

### 3. Start the Containerlab topology

```bash
sudo containerlab deploy -t arista-ansible.clab.yml
```

### 4. Enter the Ansible container

```bash
sudo docker exec -it clab-esi-datacenter-ansible sh
```

### 5. Install build dependencies inside the container

```bash
apk add --no-cache gcc musl-dev python3-dev libffi-dev openssl-dev
apk add --no-cache libssh-dev
pip install ansible-pylibssh
pip3 install netaddr
```

### 6. Run the full site playbook

```bash
cd /ansible
ansible-playbook playbooks/site.yml
```

---

## Repository Structure

```
arista-ansible/
|
+-- arista-ansible.clab.yml            # Containerlab topology
|
+-- ansible/
|   +-- ansible.cfg                    # Ansible configuration (container paths)
|   +-- requirements.yml               # Collection dependencies
|
|   +-- group_vars/
|   |   +-- all.yml                    # Lab-wide: NTP, DNS, syslog, SNMP, credentials
|   |   +-- fabric.yml                 # Fabric-wide knobs (MTU, BGP timers, etc.)
|   |   +-- firewalls.yml              # Firewall group variables
|   |   +-- leaves.yml                 # Leaf defaults: BGP, VTEP, EVPN, MTU, LLDP
|   |   +-- pod_compute.yml            # Compute pod group vars (leaf-07/08)
|   |   +-- pod_core.yml               # Core pod group vars (leaf-03/04)
|   |   +-- pod_edge.yml               # Edge pod group vars (leaf-01/02)
|   |   +-- pod_storage.yml            # Storage pod group vars (leaf-05/06)
|   |   +-- pod_ultra.yml              # Ultra pod group vars (leaf-09/10)
|   |   +-- spines.yml                 # Spine group vars
|   |
|   +-- host_vars/
|   |   +-- leaf-01.yml                # Edge primary: ISP uplinks, Firewall, DMZ
|   |   +-- leaf-02.yml                # Edge secondary: mirrors leaf-01 role
|   |   +-- leaf-03.yml                # Core primary: Admin, LMS, INFRA services
|   |   +-- leaf-04.yml                # Core secondary: mirrors leaf-03 role
|   |   +-- leaf-05.yml                # Storage primary: Ceph OSD
|   |   +-- leaf-06.yml                # Storage secondary: mirrors leaf-05 role
|   |   +-- leaf-07.yml                # Compute primary: TENANT_A/B workloads
|   |   +-- leaf-08.yml                # Compute secondary: mirrors leaf-07 role
|   |   +-- leaf-09.yml                # Ultra primary: RoCEv2/RDMA, HPC, STUDENT
|   |   +-- leaf-10.yml                # Ultra secondary: mirrors leaf-09 role
|   |   +-- spine-01.yml               # Spine-01: P2P peers + EVPN peer list
|   |   +-- spine-02.yml               # Spine-02: P2P peers + EVPN peer list
|   |
|   +-- inventory/
|   |   +-- hosts.yml                  # Hosts grouped by role and pod
|   |
|   +-- playbooks/
|   |   +-- site.yml                   # Master playbook — runs all plays in order
|   |   +-- fabric-common.yml          # Applies arista-common role to all nodes
|   |   +-- fabric-underlay.yml        # BGP underlay: P2P links + eBGP per leaf/spine
|   |   +-- fabric-overlay.yml         # EVPN/VXLAN overlay + ESI LAGs + verification
|   |   +-- firewalls.yml              # Firewall-specific plays
|   |   +-- servers-base.yml           # Server base configuration
|   |   +-- validate-fabric.yml        # End-to-end fabric validation checks
|   |
|   +-- roles/
|       +-- arista-common/
|       |   +-- defaults/
|       |   +-- tasks/
|       |       +-- main.yml           # Hostname, NTP, syslog, LLDP, Loopback0, aliases
|       |
|       +-- arista-evpn/
|       |   +-- defaults/
|       |   +-- meta/
|       |   +-- tasks/
|       |   |   +-- main.yml           # VRFs, VLANs, Vxlan1, BGP EVPN address-family
|       |   +-- templates/             # Jinja2 templates for EVPN config blocks
|       |
|       +-- arista-underlay/
|           +-- defaults/
|           +-- tasks/
|               +-- main.yml           # Multi-agent model, P2P interfaces, BGP process
```

---

## Variable Precedence

```
group_vars/all.yml        <- lowest priority  (lab-wide defaults)
      |
group_vars/fabric.yml     <- fabric-wide knobs
      |
group_vars/leaves.yml     <- leaf-wide defaults
      |
group_vars/pod_*.yml      <- per-pod overrides
      |
host_vars/leaf-XX.yml     <- highest priority (per-node identity)
```
