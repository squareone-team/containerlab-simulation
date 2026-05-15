# Identity And Access

This runbook validates OpenLDAP, TACACS+, campus NAC, browser POV, and VPN enrollment.

## Automation

```bash
bash implementations/frr-containerlab/scripts/tests/auth_fabric_validation.sh
bash implementations/frr-containerlab/scripts/tests/vpn_access_validation.sh
bash implementations/frr-containerlab/scripts/tests/browser_pov_validation.sh
```

## LDAP And AAA Health

```bash
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=amine.kadri@esi.dz)' dn
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(cn=squareone-admins)' memberUid
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-radius.log
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-tacacs.log
```

Good signs:

- `amine.kadri@esi.dz` exists in LDAP.
- `squareone.admin@esi.dz` is a member of `squareone-admins`.
- TACACS+ log entries show `encrypted_body: true`.

## Campus NAC

The NAC gateway is `campus-bp` at `192.168.110.1`. It authenticates ESI mail identities over RADIUS, then inserts the client IP into one of two nftables sets:

| Identity | Password | Expected set |
| --- | --- | --- |
| `amine.kadri@esi.dz` | `AmineLab#2026` | `campus_students` |
| `tati.youcef@esi.dz` | `TatiLab#2026` | `campus_students` |
| `nora.benali@esi.dz` | `NoraTPs#2026` | `campus_students` |
| `hamani.nacer@esi.dz` | `HamaniTPs#2026` | `campus_students` |
| `squareone.admin@esi.dz` | `SquareOneRoot#2026` | `campus_admins` |

Manual role test:

```bash
docker exec clab-esi-datacenter-campus-bp sh -lc 'printf "User-Name = \"amine.kadri@esi.dz\"\nUser-Password = \"AmineLab#2026\"\nNAS-Identifier = \"campus-nac\"\n" | radclient -x 192.168.50.80:1812 auth EsiCampusNacRadius#2026'
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_students
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_admins
```

or from device terminal :

```bash
docker exec clab-esi-datacenter-campus-admin-01 -lc 'ESI_NAC_USER=squareone.admin@esi.dz ESI_NAC_PASSWORD=SquareOneRoot#2026 timeout 8 python3 /usr/local/bin/esi-nac-client.py || true'
```

The unauthenticated browser at `192.168.110.30` should not appear in either set.

## Browser POV

| Browser node | Host URL | Shares network with | Expected behavior |
| --- | --- | --- | --- |
| `campus-guest-browser` | `http://127.0.0.1:5813` | `student-bp-01` | NAC portal only. |
| `campus-student-browser` | `http://127.0.0.1:5811` | `campus-student-01` | Student access after NAC. |
| `campus-admin-browser` | `http://127.0.0.1:5812` | `campus-admin-01` | Admin access after NAC. |
| `vpn-browser-01` | `http://127.0.0.1:5814` | `vpn-client-01` | External/VPN-side view. |

Open `https://192.168.110.1:8443/` for the NAC portal. After student or professor login, these URLs should work:

- `http://www.google.com/`
- `http://moodle.esi.dz/`
- `https://hpc-jupyter.esi.internal:8080/hub/login`

The SquareOne admin can also open admin SSH transport. Student/professor roles cannot.

## VPN Enrollment

The VPN portal is `https://198.51.100.20:8448/`. The web UI can generate a lab WireGuard keypair, or you can enroll by API:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'umask 077; wg genkey | tee /tmp/vpn.key | wg pubkey > /tmp/vpn.pub'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PUB=$(cat /tmp/vpn.pub); printf "{\"username\":\"amine.kadri@esi.dz\",\"password\":\"AmineLab#2026\",\"public_key\":\"%s\"}" "$PUB" | curl -ks -X POST -H "Content-Type: application/json" -d @- https://198.51.100.20:8448/enroll'
```

Expected:

- Student identities such as `amine.kadri@esi.dz` and `tati.youcef@esi.dz` receive `vpn-student`.
- Professor identities such as `nora.benali@esi.dz` and `hamani.nacer@esi.dz` receive `vpn-student`.
- `squareone.admin@esi.dz` is rejected by VPN enrollment.
- The gateway NATs tunnel clients behind `198.51.100.20`; `10.250.200.0/24` is not advertised to ISP/Internet routers.

## SSH/TACACS

Linux SSH tests use local-safe aliases:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'sshpass -p "AmineLab#2026" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 amine.kadri@192.168.10.10 "cat /etc/esi-auth-resource"'
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'sshpass -p "SquareOneRoot#2026" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 squareone.admin@192.168.50.10 "cat /etc/esi-auth-resource"'
```

See [Credentials](../../reference/credentials.md) for the complete credential table.
