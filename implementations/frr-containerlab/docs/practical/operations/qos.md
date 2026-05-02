# Quality of Service

Quality of Service is the operational consequence of the pod model, not an optional add-on. The design protects the control plane, preserves BAC traffic during its active window, guarantees AI/HPC throughput, and demotes bulk transfer so it cannot preempt critical services. New services must map to existing classes, and the policy must remain automatable and observable.

## Objectives

- Protect control-plane traffic from congestion.
- Preserve BAC Orientation traffic when active.
- Guarantee AI/HPC throughput and low loss in the dedicated pod.
- Deprioritize bulk and backup flows.
- Keep class model stable and extensible.
- Make enforcement and telemetry repeatable via automation.

## DiffServ Class Model

The fabric uses a fixed 8-class DiffServ model.

| Priority | Class | DSCP | Queue Behavior | Min Bandwidth | ESI Examples |
| --- | --- | --- | --- | --- | --- |
| 1 | Network Control | CS6 (48) | Strict priority | n/a | eBGP, EVPN transport, BFD, LACP, switch control traffic |
| 2 | Real-Time | EF (46) | Strict priority (rate-limited) | n/a | Reserved for future voice/video |
| 3 | Critical Applications | AF41 (34) | WFQ high | 20% | BAC Orientation (VNI 10090), critical admin transactions |
| 4 | Research / HPC | AF31 (26) | WFQ high | 25% | AI/HPC (VNI 10070), latency-sensitive storage I/O |
| 5 | Interactive / Academic | AF21 (18) | WFQ medium | 20% | VNI 10030/10040/10050, VNI 10010 |
| 6 | General Student | AF11 (10) | WFQ low | 10% | VNI 10020 |
| 7 | Bulk / Backup | CS1 (8) | Scavenger | 5% | Backup/replication, image sync, updates |
| 8 | Best Effort | DF (0) | Best effort | Remainder | Unclassified traffic |

## Classification and Marking (Leaf Ingress)

Classification is applied at leaf ingress to ensure DSCP is set before traffic enters the spine. VXLAN uses `tos inherit`, so DSCP is preserved in the outer header.

Authoritative rules:

- CS6: BGP and BFD control-plane traffic (leaf and spine output).
- AF41: BAC Orientation on VNI 10090 (192.168.90.0/24).
- AF31: AI/HPC on VNI 10070 (192.168.70.0/24).
- AF31: Storage on VNI 10080 (192.168.80.0/24), except bulk ports.
- AF21: VNIs 10030, 10040, 10050, and 10010.
- AF11: VNI 10020.
- CS1: Bulk/backup on VNI 10080 when port matches TCP/UDP 873, 21, 2049, or 445.
- DF: All other traffic.

## Queueing and Scheduling (Spine)

Spines schedule on DSCP and preserve class separation during transit. The lab uses HTB classes with per-class fq_codel queues:

- CS6 and EF are strict-priority classes (EF rate-limited).
- AF41/AF31/AF21/AF11 are weighted with minimum guarantees.
- CS1 is scavenger.
- DF consumes remaining bandwidth.

## Enforcement Points

- Leaf: classification and DSCP marking.
- Spine: DSCP-based scheduling.
- Border leaf: egress shaping + ingress policing for north-south traffic.

## VXLAN DSCP Preservation

All VXLAN interfaces use `tos inherit` to preserve the marked DSCP into the VXLAN outer header.

## Congestion Management: ECN and PFC

ECN is enabled only on the AI/HPC leaf pair (leaf-05/leaf-06) using `net.ipv4.tcp_ecn=2` and `fq_codel ecn` on spine-facing uplinks. PFC is not available in the containerlab simulation and is represented by ECN-only behavior.

## Border Shaping and Policing

Inbound DSCP is untrusted and reset to DF before internal policy applies. Egress is shaped; ingress is policed.

Lab mapping:

- Primary (Fiber) 950 Mbps: leaf-01 `eth3`.
- Secondary (Microwave) 180 Mbps: leaf-01 `eth4`, leaf-02 `eth3`.

If the physical mapping differs, update the interface list and rates in the leaf startup scripts.

## Automation and Observability

The lab includes an Ansible playbook to redeploy and validate QoS, plus a verification script that checks classification rules, queue setup, and ECN status.

## Implementation Map

Leaf QoS rules are implemented in leaf startup scripts using `iptables -t mangle` with an `ESI_QOS` chain and control-plane marking in `ESI_QOS_OUT`.

Spine scheduling is implemented with `tc htb` and DSCP filters on spine-facing interfaces.

Border shaping/policing uses `tc tbf` on egress and `tc police` on ingress with DSCP reset to DF.

Files:

- Leaf classification: `configs/leaf-01/startup.sh` through `configs/leaf-10/startup.sh`.
- Spine scheduling: `configs/spine-01/startup.sh`, `configs/spine-02/startup.sh`.
- QoS verification: `scripts/tests/qos_verify.sh`.
- Ansible deploy: `ansible/qos_deploy.yml`.
