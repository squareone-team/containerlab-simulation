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

- `esi/alpine-services:3.20`
  - Extends `esi/alpine-host:3.20` with service packages used by DNS and DHCP:
    `unbound`, `kea`, `bind-tools`.

- `esi/alpine-zabbix:3.20`
  - Packages the Zabbix/MariaDB/SNMP stack used by `zabbix-server`.

- `esi/alpine-firewall:3.20`
  - Packages the firewall runtime used by Ring 1:
    `keepalived`, `nftables`, `tcpdump`, `curl`, `iputils`.

- `esi/alpine-exporter:3.20`
  - Packages the FRR exporter runtime:
    `busybox-extras`, `docker-cli`, `jq`, `iproute2`.

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
