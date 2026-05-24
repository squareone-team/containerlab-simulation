# Identity And Access Model

This lab models the identity plane with three layers so the behavior is visible even in ContainerLab:

1. **OpenLDAP** is the source of truth for demo people and groups.
2. **TACACS+** enforces SSH authentication and authorization on protected servers.
3. **RADIUS** backs campus NAC and the VPN gateway so edge devices can classify clients.

The goal is to show how identity drives policy at the border without pretending the Linux bridge is a real 802.1X switch.

## Directory Of Truth (LDAP)

The `aaa-server` container runs OpenLDAP on loopback only. It contains:

- People: `nora.benali@esi.dz`, `hamani.nacer@esi.dz`, `amrouche.hakim@esi.dz`, `amine.kadri@esi.dz`, `selma.bouaziz@esi.dz`, `ilyes.rahmani@esi.dz`, `tati.youcef@esi.dz`, `kherroubi.amine@esi.dz`, `badaoui.ikram@esi.dz`, `zitouni.rania@esi.dz`, `mostefai.mounir@esi.dz`, `bousdjira.nadine@esi.dz`, `hassnaoui.sarah@esi.dz`, `squareone.admin@esi.dz`
- Linux SSH aliases: `nora.benali`, `hamani.nacer`, `amrouche.hakim`, `amine.kadri`, `tati.youcef`, `kherroubi.amine`, `badaoui.ikram`, `zitouni.rania`, `mostefai.mounir`, `bousdjira.nadine`, `hassnaoui.sarah`, `squareone.admin`
- Groups: `students`, `student`, `professors`, `squareone-admins`, `admins`, `hpc-users`

Identity metadata lives in the `description` attribute:

- Student and professor identities map to campus student privileges and VPN student enrollment.
- `squareone.admin@esi.dz` maps to the SquareOne admin role for campus NAC and is deliberately rejected by VPN.

## TACACS+ For Server SSH

Protected servers (`server-student-*`, `server-admin-*`, `server-hpc-*`) run PAM with `esi-pam-auth-client.py`:

1. SSH password is handed to the PAM exec client.
2. The client opens a TACACS+ session to `aaa-server`.
3. The custom TACACS+ daemon binds to LDAP with the user DN.
4. Authorization is based on group membership and the resource label in `/etc/esi-auth-resource`.

Resource mapping is enforced inside `tacacs_server.py`:

- `students` / `student` -> `student`, `hpc`
- `squareone-admins` / `admins` -> `student`, `hpc`, `admin`, `core`
- `hpc-users` → `hpc`

TACACS+ is therefore the user authorization layer. Reaching TCP/22 is not enough: the SSH login still has to pass LDAP password validation and a TACACS+ authorization decision for that server resource.

The TACACS+ PoC uses encrypted TACACS+ packet bodies with a shared lab secret. The protected servers send authentication and authorization requests with the unencrypted flag cleared, and `aaa-server` rejects unencrypted TACACS+ by default. Recent TACACS+ logs include `encrypted_body: true` so the test suite can prove that server-side AAA is not moving as plain text on the internal fabric.

## Campus NAC (PoC)

The campus devices share one subnet (`192.168.110.0/24`). Instead of hardcoding IPs in the firewall, `distribution-switch` now behaves like a small NAC enforcement point:

1. Campus devices call the local HTTPS NAC portal/API (`distribution-switch:8443`) with ESI mail credentials.
2. `distribution-switch` authenticates to `aaa-server` over RADIUS.
3. RADIUS responses return a role (`campus-student` or `campus-admin`).
4. `distribution-switch` inserts the device IP into dynamic nftables role sets.
5. Traffic is filtered locally based on those sets.

This mirrors the control-plane intent of NAC without claiming switchport 802.1X support.

The protected servers intentionally do not encode `student-01` or `admin-01` addresses as the role boundary. They accept the campus subnet as a possible SSH source, and `distribution-switch` decides which current campus IP may reach which target:

| Device role at `distribution-switch` | Dynamic set | Allowed SSH targets |
| --- | --- | --- |
| student or professor identity | `campus_students` | student pod, HPC pod, Moodle, Google demo, Jupyter |
| SquareOne admin identity | `campus_admins` | student pod, HPC pod, admin pod, Moodle, Google demo, Jupyter |
| unauthenticated campus node | no set | no internal SSH targets |

This removes the same-subnet hardcoding while keeping the enforcement visible in ContainerLab. The remaining static addresses are service identities and test endpoints, not role membership.

Unauthenticated campus clients may reach only the NAC portal itself. `www.google.com`, `moodle.esi.dz`, DNS, Jupyter, and SSH paths are opened only after the device IP appears in a NAC role set.

For RADIUS, `distribution-switch` deliberately uses `192.168.110.1` as the client source. The `10.200.0.0/29` link is only a routing transit to the firewall campus VIP; it is not trusted as an identity. Ring 1 and `aaa-server` therefore accept campus RADIUS only from the NAC gateway address, which keeps the AAA trust boundary tied to the enforcement point instead of to a point-to-point transport IP.

## VPN Remote Access

A WireGuard-based VPN gateway lives in the DMZ (`vpn-gateway` at `198.51.100.20`). Enrollment is identity-driven:

1. The client posts credentials to the enrollment API; the browser portal can generate a lab WireGuard keypair implicitly.
2. The gateway authenticates against RADIUS on `aaa-server`.
3. Only student/professor identities returning `vpn-student` are accepted.
4. The gateway adds the peer to `wg0`; if the request came from `vpn-client-01`, it asks that same container's lab helper to bring up the client-side `wg0`.
5. The gateway NATs traffic toward the firewall.
6. Firewall and DNS rules allow the gateway to use datacenter DNS, resolve service names, reach student/HPC SSH, reach Moodle, and reach the Jupyter frontend.

Admins are intentionally rejected at the VPN enrollment step. `/logout` removes the WireGuard peer and lease state, and disconnects the browser client tunnel when it was installed by the helper, so repeated browser tests start from a clean remote-access state.

The VPN source seen by the firewall and workloads is the gateway DMZ address (`198.51.100.20`), not a tunnel-client private address. The tunnel pool (`10.250.200.0/24`) stays behind NAT on `vpn-gateway`, so private VPN client space is not advertised into the public/ISP side.

| Remote identity | RADIUS role | VPN enrollment | Internal reachability |
| --- | --- | --- | --- |
| `amine.kadri@esi.dz` | `vpn-student` | accepted | DNS to datacenter resolver, Moodle by name, SSH to student/HPC targets, and HTTPS to Jupyter by name |
| `nora.benali@esi.dz` | `vpn-student` | accepted | Same VPN privilege as a student |
| `tati.youcef@esi.dz` | `vpn-student` | accepted | Same VPN privilege as a student |
| `hamani.nacer@esi.dz` | `vpn-student` | accepted | Same VPN privilege as a student |
| `squareone.admin@esi.dz` | none for VPN | rejected | no tunnel peer is installed |

## Credential Protection By Hop

This is the honest security posture of the lab:

| Flow | Protection in this lab | Caveat |
| --- | --- | --- |
| Campus browser/device to NAC | HTTPS on `192.168.110.1:8443`; port `80` only redirects and rejects credential POSTs | self-signed lab certificate; encrypted against passive sniffing, not production PKI |
| NAC gateway to RADIUS | RADIUS shared-secret password hiding; aaa-server accepts only `192.168.110.1` and `198.51.100.20` | RADIUS is not full-packet encryption; usernames, NAS ID, and role attributes can still be visible |
| User SSH client to server | SSH transport encryption | protects the human password before the target server calls TACACS+ |
| Protected server to TACACS+ | encrypted TACACS+ packet bodies using `ESI_TACACS_SECRET` | shared-secret PoC, not TLS; keep it on an isolated management/control plane |
| TACACS+/RADIUS to LDAP | OpenLDAP bound to `127.0.0.1` inside `aaa-server` | not exposed on the fabric; also not LDAPS because it never leaves the container |
| VPN enrollment browser/API to gateway | HTTPS on `198.51.100.20:8448` | self-signed lab certificate |
| VPN data plane | WireGuard encryption on UDP `51820` | tunnel client space is NATed at the gateway and not advertised externally |

## Why This Design

- **No private IP leakage:** VRF-PUBLIC stays clean; the VPN gateway NATs tunnel clients.
- **Defense in depth:** campus NAC filters locally, firewall still enforces shared service boundaries.
- **Observable PoC:** each step is logged (LDAP, TACACS+, RADIUS, NAC) and can be tested with scripts.

## Limitations

- The NAC simulation is not real 802.1X. It is an HTTP-backed role assignment using a Linux bridge.
- WireGuard enrollment is a lab API, not a production-grade AAA portal.
- TACACS+ now encrypts packet bodies in this PoC, but it still uses a static lab shared secret rather than managed production AAA keying or TLS.
- RADIUS still provides only password hiding, not full packet encryption. Production deployments should use management-plane isolation and preferably RadSec/DTLS or equivalent protections where appropriate.
- NAC and VPN enrollment use HTTPS with lab-generated self-signed certificates. That encrypts credentials on the wire, but production should use managed certificates and non-demo secrets.
- Demo passwords and shared secrets remain in repository fixtures so the lab is reproducible. Treat them as training data, not deployable secrets.
- The model is meant to illustrate identity-driven policy in a reproducible lab environment.
