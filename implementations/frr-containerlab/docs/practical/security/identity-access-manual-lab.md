# Identity Access Manual Lab

This playbook is the hands-on companion to the identity design. It shows how to act as a campus student, campus admin, unauthenticated campus client, and remote VPN student.

It is aligned with the `feature/authentication-fabric` branch commits:

| Commit | What it added |
| --- | --- |
| `f81e790` | OpenLDAP on `auth-server`, TACACS+ SSH authorization, PAM client on protected servers |
| `07b6698` | RADIUS role service, campus NAC role sets, WireGuard student VPN enrollment |

## Mental Model

| Layer | Node | Ports | Main job |
| --- | --- | --- | --- |
| LDAP directory | `auth-server` | loopback `389` only | stores users, device identities, groups, and descriptions |
| TACACS+ | `auth-server` | TCP `49` | protects SSH logins to student, HPC, and admin servers |
| RADIUS | `auth-server` | UDP `1812` | returns campus device roles and VPN student role |
| Campus NAC | `campus-bp` | TCP `8085` on `192.168.110.1` | turns RADIUS roles into nftables source-IP sets |
| VPN gateway | `vpn-gateway` | TCP `8088`, UDP `51820` on `198.51.100.20` | enrolls students, installs WireGuard peers, NATs tunnel clients |
| Ring 1 firewall | `firewall-01/02` | transit only | allows only approved cross-VRF flows |

The important part: reaching TCP/22 is not the same as being authorized. The packet path may allow SSH, but the target server still asks TACACS+, and TACACS+ asks LDAP.

## Topology Anchors

| Area | Exact topology anchor | Why you care during tests |
| --- | --- | --- |
| Campus bridge | `campus-bp:eth4/eth5/eth6` bridge to `student-bp-01`, `campus-student-01`, `campus-admin-01` | this is where NAC HTTP and role-based forwarding happen |
| Campus transit | `campus-bp:eth3` to `leaf-01:eth8`, `10.200.0.0/30` | campus traffic enters the fabric here, but RADIUS is sourced as `192.168.110.1` |
| VPN edge | `vpn-client-01:eth1` on Internet side, `vpn-gateway:eth1` on DMZ side | enrollment and WireGuard start outside the protected fabric |
| Auth service | `auth-server` bonded to `leaf-03` and `leaf-04`, IP `192.168.50.80` | LDAP stays local; TACACS+ and RADIUS are exposed narrowly |
| Ring 1 firewall | `firewall-01/02` VIP `192.168.1.254` between border leaves and internal VRFs | cross-VRF permits and denies are enforced here |
| Protected servers | student on `leaf-09/10`, admin on `leaf-03/04`, HPC on `leaf-05/06` | ESI/bonded servers still apply local nftables plus TACACS+ |

## Lab Identities

| Identity | Password | Used by | Expected role |
| --- | --- | --- | --- |
| `student1` | `Student@2026` | human SSH and VPN enrollment | LDAP group `students`, `hpc-users`, RADIUS role `vpn-student` |
| `admin1` | `Admin@2026` | human SSH | LDAP group `admins`, `hpc-users`, no VPN role |
| `dev-campus-student-01` | `DeviceStudent@2026` | `campus-student-01` NAC device auth | RADIUS `Filter-Id = campus-student` |
| `dev-campus-admin-01` | `DeviceAdmin@2026` | `campus-admin-01` NAC device auth | RADIUS `Filter-Id = campus-admin` |

Protected server resources:

| Target | IP | Resource label | Who should SSH successfully |
| --- | --- | --- | --- |
| `server-student-01` | `192.168.10.10` | `student` | `student1`, `admin1` |
| `server-hpc-01` | `192.168.70.10` | `hpc` | `student1`, `admin1` |
| `server-admin-01` | `192.168.50.10` | `admin` | `admin1` only |

## First Health Check

Run these before manual experiments:

```bash
docker ps --format '{{.Names}}' | grep 'clab-esi-datacenter-auth-server'
docker exec clab-esi-datacenter-auth-server tail -n 5 /var/log/esi-radius.log
docker exec clab-esi-datacenter-auth-server tail -n 5 /var/log/esi-tacacs.log
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_students
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_admins
```

Good signs:

- `campus_students` contains `192.168.110.31`.
- `campus_admins` contains `192.168.110.32`.
- `student-bp-01` at `192.168.110.30` is absent from both sets.

The full automated baseline is still useful:

```bash
bash implementations/frr-containerlab/scripts/tests/auth_fabric_validation.sh
bash implementations/frr-containerlab/scripts/tests/vpn_access_validation.sh
```

## LDAP Truth Source

Check users and groups directly on the auth server:

```bash
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=student1)' dn description
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=admin1)' dn
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(cn=admins)' memberUid
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(cn=hpc-users)' memberUid
```

What to notice:

- `student1` has `description: vpn-student`.
- `admin1` is in `admins`.
- Both `student1` and `admin1` are in `hpc-users`.
- LDAP itself listens only on loopback inside `auth-server`; fabric nodes do not talk to LDAP directly.

## Campus NAC Role Assignment

The campus subnet is `192.168.110.0/24` behind `campus-bp`. The NAC clients keep refreshing their role, but you can trigger the exchange manually.

Student device registration:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'ESI_NAC_USER=dev-campus-student-01 ESI_NAC_PASSWORD=DeviceStudent@2026 timeout 8 python3 /usr/local/bin/esi-nac-client.py || true'
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_students
docker exec clab-esi-datacenter-auth-server tail -n 5 /var/log/esi-radius.log
docker exec clab-esi-datacenter-campus-bp tail -n 5 /var/log/esi-nac.log
```

Admin device registration:

```bash
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'ESI_NAC_USER=dev-campus-admin-01 ESI_NAC_PASSWORD=DeviceAdmin@2026 timeout 8 python3 /usr/local/bin/esi-nac-client.py || true'
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_admins
docker exec clab-esi-datacenter-auth-server tail -n 5 /var/log/esi-radius.log
docker exec clab-esi-datacenter-campus-bp tail -n 5 /var/log/esi-nac.log
```

The same RADIUS decision can be tested from the NAC gateway:

```bash
docker exec clab-esi-datacenter-campus-bp sh -lc 'printf "User-Name = \"dev-campus-student-01\"\nUser-Password = \"DeviceStudent@2026\"\nNAS-Identifier = \"campus-nac\"\n" | radclient -x 192.168.50.80:1812 auth CampusRadiusSecret@2026'
```

Expected result:

- `Access-Accept`
- `Filter-Id = "campus-student"`

The trusted RADIUS source must be the campus gateway identity:

```bash
docker exec clab-esi-datacenter-campus-bp ip route get 192.168.50.80
docker exec clab-esi-datacenter-auth-server nft list ruleset | grep 'udp dport 1812'
```

Good sign: the route uses `src 192.168.110.1`, and the auth server allows RADIUS from `192.168.110.1` and `198.51.100.20`, not from the transit IP `10.200.0.2`.

## Try The Campus Student Experience

From the student campus device, student and HPC SSH should be reachable:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'nc -z -w3 192.168.10.10 22 && echo tcp-open-student'
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'nc -z -w3 192.168.70.10 22 && echo tcp-open-hpc'
```

Now login as the human student. The command prints the resource label from the target server:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'sshpass -p Student@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 student1@192.168.10.10 "hostname; cat /etc/esi-auth-resource"'

docker exec clab-esi-datacenter-campus-student-01 sh -lc 'sshpass -p Student@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 student1@192.168.70.10 "hostname; cat /etc/esi-auth-resource"'
```

Expected labels:

- `server-student-01` returns `student`.
- `server-hpc-01` returns `hpc`.

The campus student device should not even reach admin SSH:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo unexpected-open || echo blocked-before-ssh'
docker exec clab-esi-datacenter-campus-bp nft list chain inet campus_nac forward
```

This block happens at `campus-bp` because `192.168.110.31` is in `campus_students`, and that role does not include `192.168.50.10`.

## Try The Campus Admin Experience

The admin campus device should reach all three protected SSH targets:

```bash
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'nc -z -w3 192.168.10.10 22 && echo tcp-open-student'
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'nc -z -w3 192.168.70.10 22 && echo tcp-open-hpc'
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo tcp-open-admin'
```

Admin identity succeeds on the admin resource:

```bash
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'sshpass -p Admin@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 admin1@192.168.50.10 "hostname; cat /etc/esi-auth-resource"'
```

Expected label: `admin`.

Now use the student human identity from the admin device. TCP reaches the server, but TACACS+ authorization denies the login:

```bash
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'sshpass -p Student@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=8 student1@192.168.50.10 "cat /etc/esi-auth-resource" && echo unexpected-login || echo tacacs-denied'
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-tacacs.log
docker exec clab-esi-datacenter-server-admin-01 tail -n 20 /var/log/esi-auth-client.log
```

Good log evidence:

- TACACS authentication for `student1` can pass.
- TACACS authorization for resource `admin` fails with `resource_not_allowed`.

## Try The Unauthenticated Campus Client

`student-bp-01` is a same-subnet campus client with no NAC enrollment. It should keep basic campus/Internet service access but not protected SSH.

```bash
docker exec clab-esi-datacenter-student-bp-01 sh -lc 'ip -4 addr show dev eth1'
docker exec clab-esi-datacenter-student-bp-01 sh -lc 'nc -z -w3 192.168.10.10 22 && echo unexpected-student-ssh || echo blocked-student-ssh'
docker exec clab-esi-datacenter-student-bp-01 sh -lc 'nc -z -w3 192.168.70.10 22 && echo unexpected-hpc-ssh || echo blocked-hpc-ssh'
docker exec clab-esi-datacenter-student-bp-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo unexpected-admin-ssh || echo blocked-admin-ssh'
docker exec clab-esi-datacenter-student-bp-01 sh -lc 'nc -z -w3 192.168.50.80 49 && echo unexpected-tacacs || echo direct-tacacs-blocked'
docker exec clab-esi-datacenter-student-bp-01 sh -lc 'nc -z -w3 192.168.50.80 389 && echo unexpected-ldap || echo direct-ldap-blocked'
```

The direct LDAP/TACACS blocks are important: clients do not get to query the identity back end themselves.

## Try Remote Student VPN

Reset the VPN client and create a WireGuard key pair:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link del wg0 2>/dev/null || true; rm -f /tmp/vpn.key /tmp/vpn.pub'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'umask 077; wg genkey | tee /tmp/vpn.key | wg pubkey > /tmp/vpn.pub'
```

Send student credentials and the public key to the enrollment API:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PUB=$(cat /tmp/vpn.pub); printf "{\"username\":\"student1\",\"password\":\"Student@2026\",\"public_key\":\"%s\"}" "$PUB" | curl -s -X POST -H "Content-Type: application/json" -d @- http://198.51.100.20:8088/enroll'
```

Expected response shape:

```json
{"ok": true, "address": "10.250.200.10/32", "endpoint": "198.51.100.20:51820", "server_pubkey": "...", "allowed_ips": ["192.168.10.10/32", "192.168.70.10/32"]}
```

Configure the tunnel using the `server_pubkey` returned by the API:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link add wg0 type wireguard 2>/dev/null || true'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip addr replace 10.250.200.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'wg set wg0 private-key /tmp/vpn.key peer <SERVER_PUBKEY> endpoint 198.51.100.20:51820 allowed-ips 192.168.10.10/32,192.168.70.10/32 persistent-keepalive 25'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link set wg0 up'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.10.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.70.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.50.10/32 dev wg0'
```

Check the tunnel and reachability:

```bash
docker exec clab-esi-datacenter-vpn-client-01 wg show
docker exec clab-esi-datacenter-vpn-gateway wg show
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.10.10 22 && echo vpn-student-ssh-open'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.70.10 22 && echo vpn-hpc-ssh-open'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo unexpected-admin-open || echo vpn-admin-blocked'
```

The normal enrollment response lists only `192.168.10.10/32` and `192.168.70.10/32` in `allowed_ips`, so the client itself has no valid WireGuard peer for the admin server. If you deliberately broaden the client peer for a deeper negative test, the VPN gateway forwarding rules, Ring 1 firewall, and `server-admin-01` host policy still do not permit VPN-to-admin SSH.

Use the human student identity over the tunnel:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'sshpass -p Student@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 student1@192.168.10.10 "hostname; cat /etc/esi-auth-resource"'
```

The protected server sees the NAT source as `198.51.100.20`, the VPN gateway. That is why `server-student-01` and `server-hpc-01` allow SSH from `198.51.100.20`, while `server-admin-01` does not:

```bash
docker exec clab-esi-datacenter-server-student-01 nft list ruleset | grep '198.51.100.20'
docker exec clab-esi-datacenter-server-hpc-01 nft list ruleset | grep '198.51.100.20'
docker exec clab-esi-datacenter-server-admin-01 nft list ruleset | grep '198.51.100.20' || echo admin-does-not-trust-vpn-source
```

## Try Admin From The Internet

Admin VPN enrollment is intentionally rejected:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PUB=$(cat /tmp/vpn.pub); printf "{\"username\":\"admin1\",\"password\":\"Admin@2026\",\"public_key\":\"%s\"}" "$PUB" | curl -s -X POST -H "Content-Type: application/json" -d @- http://198.51.100.20:8088/enroll'
docker exec clab-esi-datacenter-vpn-gateway tail -n 20 /var/log/esi-vpn-auth.log
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-radius.log
```

Expected result:

- API response has `"ok": false`.
- RADIUS does not return `vpn-student` for `admin1`.
- No new authorized admin tunnel path exists.

There is also no routed Internet path to internal admin space:

```bash
docker exec clab-esi-datacenter-internet-client-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo unexpected-admin-route || echo internet-admin-private-route-blocked'
docker exec clab-esi-datacenter-internet-router-01 vtysh -c 'show ip bgp' | grep -E '192\.168\.|10\.250\.200\.' && echo unexpected-private-leak || echo no-private-leak
```

## Firewall And Policy Evidence

The Ring 1 firewall is still the shared cross-VRF policy point. Inspect the policy objects that relate to identity and VPN:

```bash
docker exec clab-esi-datacenter-firewall-01 nft list ruleset | grep -E 'campus|vpn|tacacs|1812| dport 22'
docker exec clab-esi-datacenter-firewall-01 nft list set inet filter vpn_student_ssh_targets
docker exec clab-esi-datacenter-firewall-01 nft list set inet filter tacacs_auth_clients
docker exec clab-esi-datacenter-firewall-01 nft list set inet filter campus_ssh_targets
```

Expected policy:

- Campus access may reach selected shared services and SSH targets.
- Campus direct LDAP/TACACS probing is dropped.
- VPN gateway may query RADIUS and reach only student/HPC SSH.
- DMZ to internal clusters is otherwise dropped.

## Logs To Correlate

Use this set when you want to explain a single authentication attempt end to end:

```bash
docker exec clab-esi-datacenter-campus-bp tail -n 20 /var/log/esi-nac.log
docker exec clab-esi-datacenter-vpn-gateway tail -n 20 /var/log/esi-vpn-auth.log
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-radius.log
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-tacacs.log
docker exec clab-esi-datacenter-server-student-01 tail -n 20 /var/log/esi-auth-client.log
docker exec clab-esi-datacenter-server-admin-01 tail -n 20 /var/log/esi-auth-client.log
```

Read them in this order:

1. NAC or VPN control plane received credentials.
2. RADIUS returned a role or rejected the identity.
3. Packet policy allowed or blocked the target path.
4. SSH target asked TACACS+.
5. TACACS+ authenticated via LDAP and authorized against the resource label.

## Security Notes

The lab is intentionally observable. That is great for learning and risky for production.

| Flow | Lab protection | What to remember |
| --- | --- | --- |
| WireGuard data plane | encrypted tunnel on UDP `51820` | inner SSH traffic is hidden on the Internet-facing link |
| SSH login session | SSH transport encryption | password and commands are not readable after SSH key exchange |
| RADIUS | shared-secret password hiding only | user name, NAS ID, and role attributes may still be visible |
| TACACS+ | custom PoC uses unencrypted TACACS+ packets | isolate it in the management plane or replace with encrypted production AAA |
| NAC API and VPN enrollment API | HTTP in this lab | credentials are visible if you capture those links; use HTTPS in production |
| LDAP | loopback only inside `auth-server` | not exposed on the fabric, but also not LDAPS |

For packet-level proof, use [Packet capture and Wireshark](./packet-capture-and-wireshark.md).
