# Traffic And Security Model

This page explains how traffic is supposed to move so the practical runbooks make sense.

## Underlay And Overlay

- The underlay is eBGP between `spine-01/02` in AS `65000` and the leaf pairs in AS `65001` to `65005`.
- BFD is enabled on fabric sessions for faster failure detection.
- Loopbacks in `10.1.0.0/24` are the stable router identities and the EVPN next hops.
- The overlay is EVPN/VXLAN. Leafs advertise VNIs and prefixes with MP-BGP EVPN instead of flooding everything.
- Anycast gateway addresses live on the serving leaf pair, and dual-homed servers use `bond0`.

## Dual-Homed Workloads

- `server-student-*`, `server-admin-*`, `server-hpc-*`, and `server-storage-01` are attached to two leaves.
- The leaves carry ESI multihoming state in FRR.
- The hosts themselves use Linux bonding, so the easiest runtime check is `cat /proc/net/bonding/bond0`.

## North-South Traffic

- `leaf-01` and `leaf-02` are the border leaves.
- They maintain external BGP with the ISP routers and accept only the default route from those peers.
- DMZ traffic lives in `VRF-PUBLIC`.
- Campus test traffic reaches only a narrow set of service IPs plus the DMZ through policy routing on `leaf-01` and the Ring 1 firewall.
- `configs/orientation-runbook.sh` temporarily activates the orientation route in `VRF-ORIENTATION` instead of keeping it always on.

## East-West Traffic

- Student, admin, HPC, storage, and service segments stay in separate VRFs.
- Authorized cross-VRF flows are pushed toward the Ring 1 firewall VIP `192.168.1.254`.
- The border leaves install static policy routes so only the intended prefixes go through that firewall path.

## Security Rings In Practice

| Ring | Main mechanism | What that means in this lab |
| --- | --- | --- |
| Ring 1 | `firewall-01` and `firewall-02` with `keepalived` and `nftables` | one shared VIP, explicit allow rules, default deny, counter-based validation |
| Ring 3 | `iptables` on spines and leaves | BGP, BFD, VXLAN, and SSH accept only expected sources |
| Ring 4 | `bastion-01` over `oob-sw` | SSH is expected to succeed from bastion to OOB IPs only |
| Ring 5 | host `nftables` | per-node input policy blocks lateral movement even inside reachable segments |
| Ring 6 | `rsyslog` to `syslog-server` | reachable nodes forward logs over TCP/514 |

## Identity And Access Plane

- `auth-server` runs OpenLDAP on loopback only and serves TACACS+ and RADIUS.
- TACACS+ enforces SSH identity on protected servers via PAM and LDAP-backed authorization rules.
- `campus-bp` acts as a NAC enforcement point: campus devices authenticate via RADIUS, then their IPs are placed into dynamic role sets.
- `vpn-gateway` accepts only RADIUS-authenticated students, adds them to WireGuard, and NATs to Ring 1 so VRF-PUBLIC stays clean.
- The firewall still limits campus and VPN traffic to approved destinations; role separation is enforced at `campus-bp`.

## Important Isolation Rules

- `VRF-PUBLIC` should not carry internal route leaks. The only `192.168.x.x` space that belongs there is the DMZ segment.
- `VRF-WIFI-CTRL` is intentionally tiny. It should have the WiFi controller route and campus route, but no default route.
- `VRF-ORIENTATION` is expected to be empty until the orientation runbook activates it.
- DMZ to internal access is intentionally blocked by firewall policy even when the reverse direction has a valid service path.

## Why The Manual Checks Look The Way They Do

- `show bgp summary` and `show evpn vni` prove the control plane is healthy.
- `ip route show vrf ...` proves the intended traffic boundaries exist at runtime.
- `nc`, `ping`, `curl`, and `nslookup` prove the data plane follows those boundaries.
- `nft` and `iptables` checks prove a success or failure is policy-driven, not just a routing accident.
