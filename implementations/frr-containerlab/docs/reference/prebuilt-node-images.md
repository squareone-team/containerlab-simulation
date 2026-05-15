# Prebuilt Node Images

This lab now expects a small set of locally built images so node startup does
not spend time running `apk update` and `apk add` during every deploy.

## Why

- Deploy time becomes mostly container creation plus node config.
- Startup is less dependent on external package mirrors.
- Rebuild cost is paid once when the image changes, not on every lab deploy.

## Image Set

- `esi/frr-node:latest`
  - Base for FRR spines, leaves, and routers.
  - Bundles the packages previously installed in FRR startup scripts:
    `openssh`, `rsyslog`, `chrony`, `dhcrelay`, `net-snmp`.

- `esi/alpine-host:3.20`
  - Base for generic Alpine hosts such as bastion, syslog, FTP, servers, and
    simple app nodes that need `chrony`, `nftables`, `rsyslog`, `openssh`, or
    `iptables`.

- `esi/fabric-browser:3.23`
  - Base for fabric-attached GUI client nodes: `guest-01`, `student-01`, `admin-01`, and `vpn-client-01`.
  - Extends the Firefox/noVNC image with CLI validation tools, WireGuard, and the VPN client helper used for same-container browser tunnel install.

- `esi/alpine-services:3.20`
  - Extends `esi/alpine-host:3.20` with service packages used by DNS and DHCP:
    `unbound`, `kea`, `bind-tools`.

- `esi/alpine-zabbix:3.20`
  - Packages the Zabbix server, MariaDB, official Zabbix web frontend, nginx/PHP-FPM, and SNMP tooling used by `zabbix-server`.
  - The topology publishes the frontend on `http://localhost:4000` and provisions the `ESI Fabric NOC` dashboard during startup.

- `esi/alpine-firewall:3.20`
  - Packages the firewall runtime used by Ring 1:
    `keepalived`, `nftables`, `tcpdump`, `curl`, `iputils`.

- `esi/alpine-exporter:3.20`
  - Packages the fabric telemetry scraper runtime:
    `busybox-extras`, `docker-cli`, `jq`, `iproute2`.

- `esi/auth-server:3.20`
  - Packages OpenLDAP clients, the custom RADIUS daemon, and the custom TACACS+ daemon.
  - Rebuild this image whenever `images/auth-server/radius_server.py` or `images/auth-server/tacacs_server.py` changes.

- `esi/vpn-node:3.20`
  - Packages WireGuard tools and the VPN enrollment runtime.

- `bitnamilegacy/moodle:5.0.2` and `bitnamilegacy/mariadb:11.4`
  - Upstream lab-pinned Moodle/MariaDB stack for `moodle.esi.dz`.
  - These are pulled, not locally built. The topology installs `iproute2` at first boot so the containers can receive DMZ data-plane addresses.

## Build

From the repo root:

```bash
chmod +x implementations/frr-containerlab/images/build.sh
./implementations/frr-containerlab/images/build.sh
```

## When To Rebuild

Rebuild the images whenever one of these changes:

- a Dockerfile under `implementations/frr-containerlab/images/`
- a startup script starts requiring a new Alpine package
- the team decides to pin a different upstream base image

## Important Team Note

The startup scripts were trimmed so they no longer install packages at boot.
That means deployments now assume these local images already exist. If someone
pulls the repo on a fresh machine, they should build the images first and only
then run `containerlab deploy`.

## Validation Workflow

After rebuilding images or changing topology images, run a deploy and then at
least the focused service tests that exercise the preinstalled stacks, for
example:

```bash
bash implementations/frr-containerlab/scripts/tests/firewall_inpath_validation.sh
bash implementations/frr-containerlab/scripts/tests/dns_verify.sh
bash implementations/frr-containerlab/scripts/tests/dhcp_verify.sh
bash implementations/frr-containerlab/scripts/tests/ntp_verify.sh
bash implementations/frr-containerlab/scripts/tests/snmp_verify.sh
```
