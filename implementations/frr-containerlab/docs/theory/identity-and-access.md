# Identity And Access Model

This lab models the identity plane with three layers so the behavior is visible even in ContainerLab:

1. **OpenLDAP** is the source of truth for users and device identities.
2. **TACACS+** enforces SSH authentication and authorization on protected servers.
3. **RADIUS** backs campus NAC and the VPN gateway so edge devices can classify clients.

The goal is to show how identity drives policy at the border without pretending the Linux bridge is a real 802.1X switch.

## Directory Of Truth (LDAP)

The `auth-server` container runs OpenLDAP on loopback only. It contains:

- People: `student1`, `admin1`
- Device identities: `dev-campus-student-01`, `dev-campus-admin-01`
- Groups: `students`, `admins`, `hpc-users`

Identity metadata lives in the `description` attribute:

- `student1` has `description: vpn-student`
- `dev-campus-student-01` has `description: campus-student-device`
- `dev-campus-admin-01` has `description: campus-admin-device`

## TACACS+ For Server SSH

Protected servers (`server-student-*`, `server-admin-*`, `server-hpc-*`) run PAM with `esi-pam-auth-client.py`:

1. SSH password is handed to the PAM exec client.
2. The client opens a TACACS+ session to `auth-server`.
3. The custom TACACS+ daemon binds to LDAP with the user DN.
4. Authorization is based on group membership and the resource label in `/etc/esi-auth-resource`.

Resource mapping is enforced inside `tacacs_server.py`:

- `students` → `student`, `hpc`
- `admins` → `student`, `hpc`, `admin`, `core`
- `hpc-users` → `hpc`

TACACS+ is therefore the user authorization layer. Reaching TCP/22 is not enough: the SSH login still has to pass LDAP password validation and a TACACS+ authorization decision for that server resource.

The TACACS+ PoC uses encrypted TACACS+ packet bodies with a shared lab secret. The protected servers send authentication and authorization requests with the unencrypted flag cleared, and `auth-server` rejects unencrypted TACACS+ by default. Recent TACACS+ logs include `encrypted_body: true` so the test suite can prove that server-side AAA is not moving as plain text on the internal fabric.

## Campus NAC (PoC)

The campus devices share one subnet (`192.168.110.0/24`). Instead of hardcoding IPs in the firewall, `campus-bp` now behaves like a small NAC enforcement point:

1. Campus devices call the local HTTPS NAC portal/API (`campus-bp:8443`) with their device credentials.
2. `campus-bp` authenticates to `auth-server` over RADIUS.
3. RADIUS responses return a role (`campus-student` or `campus-admin`).
4. `campus-bp` inserts the device IP into dynamic nftables role sets.
5. Traffic is filtered locally based on those sets.

This mirrors the control-plane intent of NAC without claiming switchport 802.1X support.

The protected servers intentionally do not encode `campus-student-01` or `campus-admin-01` addresses as the role boundary. They accept the campus subnet as a possible SSH source, and `campus-bp` decides which current campus IP may reach which target:

| Device role at `campus-bp` | Dynamic set | Allowed SSH targets |
| --- | --- | --- |
| student device | `campus_students` | student pod and HPC pod |
| admin device | `campus_admins` | student pod, HPC pod, and admin pod |
| unauthenticated campus node | no set | no internal SSH targets |

This removes the same-subnet hardcoding while keeping the enforcement visible in ContainerLab. The remaining static addresses are service identities and test endpoints, not role membership.

Unauthenticated campus clients may reach only the NAC portal itself. Internet web, DMZ web, DNS, Jupyter, and SSH paths are opened only after the device IP appears in a NAC role set.

For RADIUS, `campus-bp` deliberately uses `192.168.110.1` as the client source. The `10.200.0.0/30` link is only a routing transit to `leaf-01`; it is not trusted as an identity. Ring 1 and `auth-server` therefore accept campus RADIUS only from the NAC gateway address, which keeps the AAA trust boundary tied to the enforcement point instead of to a point-to-point transport IP.

## VPN Remote Access

A WireGuard-based VPN gateway lives in the DMZ (`vpn-gateway` at `198.51.100.20`). Enrollment is identity-driven:

1. The client posts credentials + its WireGuard public key to the enrollment API.
2. The gateway authenticates against RADIUS on `auth-server`.
3. Only `vpn-student` identities are accepted.
4. The gateway adds the peer to `wg0` and NATs traffic toward the firewall.
5. Firewall rules allow the gateway to reach student/HPC SSH and the Jupyter frontend only.

Admins are intentionally rejected at the VPN enrollment step.

The VPN source seen by the firewall and workloads is the gateway DMZ address (`198.51.100.20`), not a tunnel-client private address. The tunnel pool (`10.250.200.0/24`) stays behind NAT on `vpn-gateway`, so private VPN client space is not advertised into the public/ISP side.

| Remote identity | RADIUS role | VPN enrollment | Internal reachability |
| --- | --- | --- | --- |
| `student1` | `vpn-student` | accepted | SSH to student/HPC targets and HTTPS to Jupyter |
| `admin1` | none for VPN | rejected | no tunnel peer is installed |

## Credential Protection By Hop

This is the honest security posture of the lab:

| Flow | Protection in this lab | Caveat |
| --- | --- | --- |
| Campus browser/device to NAC | HTTPS on `192.168.110.1:8443`; port `80` only redirects and rejects credential POSTs | self-signed lab certificate; encrypted against passive sniffing, not production PKI |
| NAC gateway to RADIUS | RADIUS shared-secret password hiding; auth-server accepts only `192.168.110.1` and `198.51.100.20` | RADIUS is not full-packet encryption; usernames, NAS ID, and role attributes can still be visible |
| User SSH client to server | SSH transport encryption | protects the human password before the target server calls TACACS+ |
| Protected server to TACACS+ | encrypted TACACS+ packet bodies using `ESI_TACACS_SECRET` | shared-secret PoC, not TLS; keep it on an isolated management/control plane |
| TACACS+/RADIUS to LDAP | OpenLDAP bound to `127.0.0.1` inside `auth-server` | not exposed on the fabric; also not LDAPS because it never leaves the container |
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
