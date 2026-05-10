# Identity And Access

This runbook validates TACACS+/LDAP server access, campus NAC behavior, and the VPN entry path.

For a step-by-step lab where you manually act as the student, admin, unauthenticated campus client, and VPN student, use [Identity access manual lab](./identity-access-manual-lab.md). For packet captures and Wireshark filters, use [Packet capture and Wireshark](./packet-capture-and-wireshark.md).

## Quick Automation

```bash
bash implementations/frr-containerlab/scripts/tests/auth_fabric_validation.sh
bash implementations/frr-containerlab/scripts/tests/vpn_access_validation.sh
```

## LDAP And TACACS+ Health

```bash
docker exec clab-esi-datacenter-auth-server ldapsearch -x -H ldap://127.0.0.1:389 -b dc=esi,dc=internal '(uid=student1)' dn

docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-tacacs.log
docker exec clab-esi-datacenter-auth-server tail -n 20 /var/log/esi-radius.log
```

- `ldapsearch` should return the DN for `student1`.
- The TACACS log should show authentication and authorization decisions.

## Campus NAC Checks

`campus-bp` should source RADIUS from the campus gateway address, not from the transit `/30`:

```bash
docker exec clab-esi-datacenter-campus-bp ip route get 192.168.50.80
```

Good sign:

- route output contains `src 192.168.110.1`
- `auth-server` RADIUS policy allows `192.168.110.1` and `198.51.100.20`, not `10.200.0.2`

```bash
docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_students

docker exec clab-esi-datacenter-campus-bp nft list set inet campus_nac campus_admins
```

Expected entries:

- `192.168.110.31` in `campus_students`
- `192.168.110.32` in `campus_admins`

The unauthenticated test client (`student-bp-01`, `192.168.110.30`) should not appear in either set.

The target servers should not hardcode the enrolled endpoint addresses. They should accept the campus subnet and rely on `campus-bp` for role separation:

```bash
docker exec clab-esi-datacenter-server-student-01 nft list ruleset | grep '192.168.110.0/24'
docker exec clab-esi-datacenter-server-admin-01 nft list ruleset | grep '192.168.110.0/24'
docker exec clab-esi-datacenter-server-hpc-01 nft list ruleset | grep '192.168.110.0/24'
```

To re-trigger one NAC registration manually without leaving a foreground loop running:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'ESI_NAC_USER=dev-campus-student-01 ESI_NAC_PASSWORD=DeviceStudent@2026 ESI_NAC_URL=https://192.168.110.1:8443/auth timeout 8 python3 /usr/local/bin/esi-nac-client.py || true'
```

To test the RADIUS role directly from the NAC edge:

```bash
docker exec clab-esi-datacenter-campus-bp sh -lc 'printf "User-Name = \"dev-campus-student-01\"\nUser-Password = \"DeviceStudent@2026\"\nNAS-Identifier = \"campus-nac\"\n" | radclient -x 192.168.50.80:1812 auth CampusRadiusSecret@2026'
```

Good sign: `Access-Accept` with `Filter-Id = "campus-student"`.

NAC and VPN enrollment are served over HTTPS with lab-generated self-signed certificates. The campus NAC port 80 listener is only a redirect helper for browsers and rejects credential POSTs; passwords are accepted only on `https://192.168.110.1:8443/auth`. The demo still uses known fixture passwords so tests are reproducible, but those passwords are no longer sent in cleartext over the campus/VPN web APIs and the NAC/VPN logs record only accept/reject metadata.

## VPN Enrollment + Access

```bash
# From the VPN client, request enrollment
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'umask 077; wg genkey | tee /tmp/vpn.key | wg pubkey > /tmp/vpn.pub'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PUB=$(cat /tmp/vpn.pub); printf "{\"username\":\"student1\",\"password\":\"Student@2026\",\"public_key\":\"%s\"}" "$PUB" | curl -ks -X POST -H "Content-Type: application/json" -d @- https://198.51.100.20:8448/enroll'
```

Use the response payload (`address`, `server_pubkey`) to configure the tunnel:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link add wg0 type wireguard 2>/dev/null || true'
# Replace values with the enrollment response
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip addr replace 10.250.200.10/32 dev wg0'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'wg set wg0 private-key /tmp/vpn.key \
  peer <SERVER_PUBKEY> endpoint 198.51.100.20:51820 \
  allowed-ips 192.168.10.10/32,192.168.70.10/32,192.168.70.30/32 persistent-keepalive 25'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link set wg0 up'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.10.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.70.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.70.30/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.50.10/32 dev wg0'
```

Validation:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.10.10 22 && echo student-ssh-ok'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.70.10 22 && echo hpc-ssh-ok'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.70.30 8080 && echo jupyter-web-ok'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo admin-ssh-unexpected || echo admin-ssh-blocked'
```

Admins are expected to be rejected during enrollment.

Security checks that should stay true:

- `server-student-01` and `server-hpc-01` may accept SSH from `198.51.100.20`, the VPN gateway NAT address.
- `server-admin-01` should not accept SSH from `198.51.100.20`.
- The ISP and internet routers should not learn `10.250.200.0/24` or any RFC1918 campus/internal prefixes.

## Browser POV Checks

The browser containers expose noVNC-style Firefox sessions on localhost. They run as sidecars in the network namespace of the real POV device, so the browser does not create a second campus/vpn identity:

| Browser node | Host URL | Shares network with | Lab IP | Expected role |
| --- | --- | --- | --- | --- |
| `campus-guest-browser` | `http://127.0.0.1:5813` | `student-bp-01` | `192.168.110.30` | unauthenticated |
| `campus-student-browser` | `http://127.0.0.1:5811` | `campus-student-01` | `192.168.110.31` | student after NAC login |
| `campus-admin-browser` | `http://127.0.0.1:5812` | `campus-admin-01` | `192.168.110.32` | admin after NAC login |
| `vpn-browser-01` | `http://127.0.0.1:5814` | `vpn-client-01` | `198.18.4.20` | external/VPN-side POV |

From a campus browser, open `http://192.168.110.1/` or `https://192.168.110.1:8443/`, accept the lab certificate, and authenticate the device. Plain HTTP is only a redirect to the HTTPS portal, and the NAC server rejects credential POSTs on port `80`.

Manual scenarios:

| Scenario | Open on the host | In Firefox | Expected result |
| --- | --- | --- | --- |
| Unauthenticated campus | `http://127.0.0.1:5813` | visit `http://192.168.110.1/` | NAC portal loads; `internet.esi.dz`, `esi.dz`, and Jupyter do not load |
| Campus student | `http://127.0.0.1:5811` | log in at NAC as `dev-campus-student-01` / `DeviceStudent@2026` | `internet.esi.dz`, `esi.dz`, and `https://hpc-jupyter.esi.internal:8080/hub/login` load; admin SSH stays blocked by policy |
| Campus admin | `http://127.0.0.1:5812` | log in at NAC as `dev-campus-admin-01` / `DeviceAdmin@2026` | Jupyter and datacenter access load; admin SSH transport is allowed |
| VPN-side browser | `http://127.0.0.1:5814` | visit `https://198.51.100.20:8448/` or enroll with the API first | the external browser reaches the HTTPS VPN enrollment endpoint; after WireGuard enrollment, use `https://192.168.70.30:8080/hub/login` for Jupyter |

The VPN browser shares `vpn-client-01`, so the full remote workflow has two parts: enroll WireGuard with the API to install the tunnel, then use the browser over that same network namespace. DNS for private internal names is intentionally not advertised to the Internet-side browser; use internal service IPs over the tunnel unless you add a VPN DNS policy.

Automated browser-path proof:

```bash
bash implementations/frr-containerlab/scripts/tests/browser_pov_validation.sh
```
