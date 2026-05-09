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
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'ESI_NAC_USER=dev-campus-student-01 ESI_NAC_PASSWORD=DeviceStudent@2026 timeout 8 python3 /usr/local/bin/esi-nac-client.py || true'
```

To test the RADIUS role directly from the NAC edge:

```bash
docker exec clab-esi-datacenter-campus-bp sh -lc 'printf "User-Name = \"dev-campus-student-01\"\nUser-Password = \"DeviceStudent@2026\"\nNAS-Identifier = \"campus-nac\"\n" | radclient -x 192.168.50.80:1812 auth CampusRadiusSecret@2026'
```

Good sign: `Access-Accept` with `Filter-Id = "campus-student"`.

## VPN Enrollment + Access

```bash
# From the VPN client, request enrollment
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'umask 077; wg genkey | tee /tmp/vpn.key | wg pubkey > /tmp/vpn.pub'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PUB=$(cat /tmp/vpn.pub); printf "{\"username\":\"student1\",\"password\":\"Student@2026\",\"public_key\":\"%s\"}" "$PUB" | curl -s -X POST -H "Content-Type: application/json" -d @- http://198.51.100.20:8088/enroll'
```

Use the response payload (`address`, `server_pubkey`) to configure the tunnel:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link add wg0 type wireguard 2>/dev/null || true'
# Replace values with the enrollment response
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip addr replace 10.250.200.10/32 dev wg0'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'wg set wg0 private-key /tmp/vpn.key \
  peer <SERVER_PUBKEY> endpoint 198.51.100.20:51820 \
  allowed-ips 192.168.10.10/32,192.168.70.10/32 persistent-keepalive 25'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip link set wg0 up'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.10.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.70.10/32 dev wg0'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'ip route replace 192.168.50.10/32 dev wg0'
```

Validation:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.10.10 22 && echo student-ssh-ok'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.70.10 22 && echo hpc-ssh-ok'

docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo admin-ssh-unexpected || echo admin-ssh-blocked'
```

Admins are expected to be rejected during enrollment.

Security checks that should stay true:

- `server-student-01` and `server-hpc-01` may accept SSH from `198.51.100.20`, the VPN gateway NAT address.
- `server-admin-01` should not accept SSH from `198.51.100.20`.
- The ISP and internet routers should not learn `10.250.200.0/24` or any RFC1918 campus/internal prefixes.
