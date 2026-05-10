# Packet Capture And Wireshark

This guide shows where to capture identity, VPN, firewall, and overlay traffic, plus what Wireshark should and should not reveal.

The honest encryption story for this lab:

| Flow | Capture filter | What Wireshark should show | Encrypted? |
| --- | --- | --- | --- |
| WireGuard tunnel | `udp port 51820` | outer IPs, UDP lengths, handshake/data packets | yes for tunnel payload |
| SSH to protected servers | `tcp port 22` | SSH banner and key exchange, then encrypted application data | yes after SSH setup |
| RADIUS | `udp port 1812` | user name, NAS ID, Filter-Id role, hidden password field | partial, not full packet encryption |
| TACACS+ PoC | `tcp port 49` | header metadata; body is encrypted by the TACACS+ shared-secret method | yes for packet body |
| NAC registration API | `tcp port 8443` | TLS handshake and encrypted HTTPS payload | yes, self-signed lab certificate |
| VPN enrollment API | `tcp port 8448` | TLS handshake and encrypted HTTPS payload | yes, self-signed lab certificate |
| LDAP | `tcp port 389` on loopback | LDAP binds/searches only inside `auth-server` | not exposed on fabric, not LDAPS |
| VXLAN overlay | `udp port 4789` | outer VTEP IPs and VNI | encapsulated, not encrypted |

Use these captures to prove which data is protected and which PoC control-plane paths would still need production-grade certificates, managed secrets, or RadSec/DTLS-style hardening.

## Capture Workflow

Most lab images are intentionally small and do not all bundle `tcpdump`. The commands below use host `tcpdump` through `nsenter`, which captures inside the container network namespace and writes the `.pcap` directly to the host `/tmp`. If the host says `tcpdump: command not found`, install `tcpdump` on the host or use the older container-side workflow on a node that already has it.

The cleanest workflow is:

1. Get the container PID with `docker inspect`.
2. Start `tcpdump` through `nsenter` in one terminal.
3. Trigger exactly one login, enrollment, or ping in another terminal.
4. Stop the capture with `Ctrl-C`.
5. Open the host-side `.pcap` in Wireshark.

Pattern:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-vpn-client-01)
sudo nsenter -t "$PID" -n tcpdump -i eth1 -U -w /tmp/example.pcap 'udp port 51820'
wireshark /tmp/example.pcap
```

If a node does have `tcpdump` installed, the equivalent `docker exec ... tcpdump ...` form is fine too.

Older container-side workflow:

1. Start `tcpdump` in one terminal and write a `.pcap` inside the container.
2. Trigger exactly one login, enrollment, or ping in another terminal.
3. Stop the capture with `Ctrl-C`.
4. Copy the `.pcap` to `/tmp`.
5. Open it in Wireshark.

Copy example:

```bash
docker cp clab-esi-datacenter-vpn-client-01:/tmp/wg-outer.pcap /tmp/wg-outer.pcap
wireshark /tmp/wg-outer.pcap
```

If Wireshark is not installed on the host, the `.pcap` files are still standard capture files and can be opened elsewhere.

## WireGuard Internet-Side Encryption

Terminal A, capture on the remote VPN client Internet link:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-vpn-client-01)
sudo nsenter -t "$PID" -n tcpdump -i eth1 -U -w /tmp/wg-outer.pcap 'host 198.51.100.20 and udp port 51820'
```

Terminal B, generate protected traffic over the tunnel:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.10.10 22'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'sshpass -p Student@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 student1@192.168.10.10 "cat /etc/esi-auth-resource"'
```

Wireshark display filters:

```text
udp.port == 51820
ip.src == 198.18.4.20 && ip.dst == 198.51.100.20
ip.addr == 192.168.10.10
tcp.port == 22
```

Expected observation:

- `udp.port == 51820` shows WireGuard packets.
- `ip.addr == 192.168.10.10` shows nothing in the outer capture.
- `tcp.port == 22` shows nothing in the outer capture.
- You cannot read the SSH password or command on the Internet-facing link.

## WireGuard Inner And NAT Views

Capture the decrypted tunnel side on `vpn-gateway`:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-vpn-gateway)
sudo nsenter -t "$PID" -n tcpdump -i wg0 -U -w /tmp/wg-inner.pcap 'tcp port 22'
```

Capture the post-NAT DMZ side on `vpn-gateway`:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-vpn-gateway)
sudo nsenter -t "$PID" -n tcpdump -i eth1 -U -w /tmp/wg-nat.pcap 'host 192.168.10.10 and tcp port 22'
```

Useful display filters:

```text
tcp.port == 22
ip.addr == 10.250.200.10
ip.addr == 198.51.100.20
ip.addr == 192.168.10.10
```

Expected observation:

- On `wg0`, the source is the tunnel client address, such as `10.250.200.10`.
- On `eth1`, the source is NATed to `198.51.100.20`.
- The SSH payload remains encrypted at both points after SSH setup.

## VPN Enrollment Visibility

This capture proves the enrollment API is now HTTPS. You should see TLS records, not JSON credentials.

Terminal A:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-vpn-gateway)
sudo nsenter -t "$PID" -n tcpdump -i eth1 -U -w /tmp/vpn-enroll-https.pcap 'tcp port 8448'
```

Terminal B:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PUB=$(cat /tmp/vpn.pub); printf "{\"username\":\"student1\",\"password\":\"Student@2026\",\"public_key\":\"%s\"}" "$PUB" | curl -ks -X POST -H "Content-Type: application/json" -d @- https://198.51.100.20:8448/enroll'
```

Wireshark display filters:

```text
tcp.port == 8448
tls
```

Expected observation:

- You can see the TLS handshake and encrypted application records.
- You should not see the username, password, or public key in cleartext.

## Campus NAC And RADIUS

Capture campus-side NAC HTTPS on `campus-bp`:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-campus-bp)
sudo nsenter -t "$PID" -n tcpdump -i br-student -U -w /tmp/campus-nac-https.pcap 'tcp port 8443'
```

Trigger a registration:

```bash
docker exec clab-esi-datacenter-campus-student-01 sh -lc 'ESI_NAC_USER=dev-campus-student-01 ESI_NAC_PASSWORD=DeviceStudent@2026 timeout 8 python3 /usr/local/bin/esi-nac-client.py || true'
```

Capture RADIUS between `campus-bp` and `auth-server`:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-campus-bp)
sudo nsenter -t "$PID" -n tcpdump -i eth3 -U -w /tmp/campus-radius.pcap 'host 192.168.50.80 and udp port 1812'
```

Display filters:

```text
tcp.port == 8443
tls
udp.port == 1812
radius
radius.User_Name
radius.Filter_Id
```

Expected observation:

- NAC HTTPS on `br-student` exposes only TLS metadata; the device credentials are encrypted.
- RADIUS shows user and role attributes, such as `Filter-Id = campus-student`.
- RADIUS does not provide full packet encryption; only the password field is hidden by the shared-secret method.

## TACACS+ And SSH Authorization

Capture TACACS+ on the auth server:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-auth-server)
sudo nsenter -t "$PID" -n tcpdump -i bond0 -U -w /tmp/tacacs-authz.pcap 'tcp port 49'
```

Trigger SSH:

```bash
docker exec clab-esi-datacenter-campus-admin-01 sh -lc 'sshpass -p Student@2026 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=keyboard-interactive -o KbdInteractiveAuthentication=yes -o PasswordAuthentication=no -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=8 student1@192.168.50.10 "cat /etc/esi-auth-resource" || true'
docker exec clab-esi-datacenter-auth-server tail -n 10 /var/log/esi-tacacs.log
```

Display filters:

```text
tcp.port == 49
tacacs
frame contains "student1"
frame contains "resource=admin"
```

Expected observation:

- The TACACS+ header is visible, but the body should not expose `student1`, the password, or `resource=admin` in clear text.
- The display filters that search the frame for `student1` or `resource=admin` should not match the TCP/49 capture.
- The auth-server log should show `encrypted_body: true` plus `resource_not_allowed` for `student1` on resource `admin`.

Now capture SSH itself:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-server-admin-01)
sudo nsenter -t "$PID" -n tcpdump -i bond0 -U -w /tmp/ssh-admin.pcap 'tcp port 22'
```

Display filters:

```text
tcp.port == 22
ssh
frame contains "SSH-"
```

Expected observation:

- The SSH banner and key exchange are visible.
- The password and command are not visible after the encrypted SSH session is established.

## LDAP Loopback Check

LDAP is not exposed to the fabric. To see it, capture inside `auth-server` on loopback:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-auth-server)
sudo nsenter -t "$PID" -n tcpdump -i lo -U -w /tmp/ldap-loopback.pcap 'tcp port 389'
```

Trigger RADIUS or TACACS+ while the capture runs:

```bash
docker exec clab-esi-datacenter-campus-bp sh -lc 'printf "User-Name = \"dev-campus-student-01\"\nUser-Password = \"DeviceStudent@2026\"\nNAS-Identifier = \"campus-nac\"\n" | radclient -x 192.168.50.80:1812 auth CampusRadiusSecret@2026'
```

Display filters:

```text
tcp.port == 389
ldap
```

Expected observation:

- LDAP traffic appears only on `lo` in the auth server.
- The fabric should not show LDAP packets from clients.

## VXLAN Encapsulation

Capture overlay traffic on a leaf uplink:

```bash
PID=$(docker inspect -f '{{.State.Pid}}' clab-esi-datacenter-leaf-09)
sudo nsenter -t "$PID" -n tcpdump -i eth1 -U -w /tmp/vxlan-student.pcap 'udp port 4789'
```

Trigger same-VRF student traffic:

```bash
docker exec clab-esi-datacenter-server-student-01 ping -c3 -W2 192.168.10.20
```

Display filters:

```text
udp.port == 4789
vxlan
vxlan.vni == 10010
ip.addr == 10.1.0.19 || ip.addr == 10.1.0.20
```

Expected observation:

- Outer IPs are VTEP loopbacks, not workload IPs.
- VXLAN VNI `10010` identifies the student segment.
- VXLAN is encapsulation, not encryption; it hides locality in the underlay view but does not cryptographically protect payloads.

## Firewall Counter Correlation

Use packet capture together with nftables counters to prove policy decisions.

Before a test:

```bash
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward
```

Trigger a blocked VPN-to-admin attempt:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo unexpected || echo blocked'
```

By default this may be blocked on the client because the enrolled WireGuard peer only allows student and HPC destinations. To force the packet far enough to watch downstream drops, temporarily widen the client peer and then restore it after the test:

```bash
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PEER=$(wg show wg0 peers | head -n 1); wg set wg0 peer "$PEER" allowed-ips 192.168.10.10/32,192.168.70.10/32,192.168.50.10/32'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'nc -z -w3 192.168.50.10 22 && echo unexpected || echo blocked'
docker exec clab-esi-datacenter-vpn-client-01 sh -lc 'PEER=$(wg show wg0 peers | head -n 1); wg set wg0 peer "$PEER" allowed-ips 192.168.10.10/32,192.168.70.10/32,192.168.70.30/32'
```

After the test:

```bash
docker exec clab-esi-datacenter-firewall-01 nft list chain inet filter forward | grep -E 'vpn|drop|dport 22'
docker exec clab-esi-datacenter-vpn-gateway iptables -L FORWARD -v -n
docker exec clab-esi-datacenter-server-admin-01 nft list ruleset | grep '198.51.100.20' || echo admin-host-has-no-vpn-source-allow
```

Interpretation:

- If the client peer was not widened, the packet is stopped before it leaves `vpn-client-01`.
- If the gateway FORWARD rule for admin is absent, the packet is stopped at `vpn-gateway`.
- If the packet reaches Ring 1, the firewall has no VPN-to-admin allow rule.
- If it somehow reaches the host, `server-admin-01` still has no local allow rule for `198.51.100.20`.

## Recommended PCAP Names

Keep captures short and named by viewpoint:

```text
/tmp/wg-outer.pcap
/tmp/wg-inner.pcap
/tmp/wg-nat.pcap
/tmp/vpn-enroll-http.pcap
/tmp/campus-nac-http.pcap
/tmp/campus-radius.pcap
/tmp/tacacs-authz.pcap
/tmp/ssh-admin.pcap
/tmp/ldap-loopback.pcap
/tmp/vxlan-student.pcap
```

Short captures are easier to explain in a report than one giant trace.
