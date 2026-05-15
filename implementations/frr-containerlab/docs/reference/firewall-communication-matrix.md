# Firewall Communication Matrix (Ring 1)

This document describes what traffic is intentionally allowed and blocked
through `firewall-01` / `firewall-02` based on the current policy and updated
topology context.

## Scope

- Applies to traffic crossing Ring 1 firewalls between internal clusters.
- Policy source: `configs/firewall-01/nftables.conf` and
  `configs/firewall-02/nftables.conf`.
- HA behavior source: `configs/firewall-01/keepalived.conf`,
  `configs/firewall-02/keepalived.conf`.
- Runtime startup logic source: `configs/firewall-common/startup-common.sh` via
  per-node wrappers.

## Address Groups Used By Firewall Policy

- `cluster_1_pedagogy`: `192.168.10.0/24`, `192.168.20.0/24`
- `cluster_2_admin`: `192.168.50.0/24`, `192.168.60.0/24`
- `cluster_3_hpc`: `192.168.70.0/24`
- `cluster_5_storage`: `192.168.80.0/24`
- `cluster_4_orientation`: `192.168.90.0/24`
- `cluster_public_dmz`: `198.51.100.0/24`
- `cluster_lms_staff`: `192.168.30.0/24`
- `core_infra_syslog`: `192.168.50.70`
- `moodle_frontend`: `198.51.100.30`
- `moodle_db_storage`: `192.168.80.31`

## Allowed New Flows (Stateful)

- Pedagogy to Storage
  - TCP: `111, 2049, 3260`
  - UDP: `111, 2049`
- Admin to Pedagogy
  - TCP: `53, 9100`
  - UDP: `53, 67, 68`
- Admin to Storage
  - TCP: `111, 2049, 3260`
  - UDP: `111, 2049`
- Admin to HPC
  - TCP/UDP: `6818-6830`
- Pedagogy to LMS (Moodle policy)
  - TCP: `80, 443`
- Pedagogy and campus access to centralized syslog
  - TCP: `514`
- Pedagogy and campus access to shared DHCP
  - UDP: `67, 68`
- DMZ to centralized syslog
  - TCP: `514` only, for one-way log export
- Moodle frontend to Moodle database
  - Source: `198.51.100.30`
  - Destination: `192.168.80.31`
  - TCP: `3306` only

## Explicitly Blocked / Isolated Flows

- Pedagogy to Admin: dropped (`cluster_1_pedagogy` -> `cluster_2_admin`)
- Orientation isolation: all traffic to/from `192.168.90.0/24` dropped
- DMZ isolation: explicit drops between `198.51.100.0/24` and all internal
  clusters except the narrow syslog and Moodle database exceptions above
  - DMZ to Pedagogy/Admin/HPC/Storage dropped
  - Pedagogy/Admin/HPC/Storage to DMZ dropped

## Stateful Behavior

- `ct state established,related accept` is enabled in forward chain.
- Return traffic for allowed sessions is accepted automatically.
- Any unmatched traffic is denied by default (`policy drop`).

## HA / VIP Behavior

- VRRP VIP: `192.168.1.254/24` on `eth1`.
- `firewall-01` is configured as preferred MASTER (priority 101).
- `firewall-02` is configured as BACKUP (priority 100).
- Health script checks:
  - `eth1` link state
  - nftables table loaded
  - basic route presence

## Notes

- Orientation subnet in policy is `192.168.90.0/24`.
- DMZ subnet is `198.51.100.0/24` and treated separately with structural
  isolation.
- HPC<->Storage direct rule is intentionally absent in firewall policy
  (hairpin/overlay design assumption).
