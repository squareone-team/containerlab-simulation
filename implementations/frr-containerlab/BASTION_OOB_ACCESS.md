# Bastion and OOB SSH Access Guide

This guide documents the persistent Ring 4 management workflow for this lab.

## Topology and OOB addresses

Bastion and fabric OOB interfaces are connected through `oob-sw`.

- `bastion-01` OOB IP: `172.16.0.50/24` on `eth1`
- `spine-01` OOB IP: `172.16.0.11/24` on `eth11`
- `spine-02` OOB IP: `172.16.0.12/24` on `eth11`
- `leaf-01` OOB IP: `172.16.0.21/24` on `eth10`
- `leaf-02` OOB IP: `172.16.0.22/24` on `eth10`
- `leaf-03` OOB IP: `172.16.0.23/24` on `eth10`
- `leaf-04` OOB IP: `172.16.0.24/24` on `eth10`
- `leaf-05` OOB IP: `172.16.0.25/24` on `eth10`
- `leaf-06` OOB IP: `172.16.0.26/24` on `eth10`
- `leaf-07` OOB IP: `172.16.0.27/24` on `eth10`
- `leaf-08` OOB IP: `172.16.0.28/24` on `eth10`
- `leaf-09` OOB IP: `172.16.0.29/24` on `eth10`
- `leaf-10` OOB IP: `172.16.0.30/24` on `eth10`

## Deploy and test

From the repo root:

```bash
cd implementations/frr-containerlab
containerlab destroy -t esi-datacenter.clab.yml --cleanup
containerlab deploy -t esi-datacenter.clab.yml

cd ../../
./implementations/frr-containerlab/tests/ring4_test.sh
```

## Manual bastion access

Open a shell in bastion:

```bash
docker exec -it clab-esi-datacenter-bastion-01 sh
```

SSH examples from bastion to fabric nodes:

```bash
ssh root@172.16.0.11   # spine-01
ssh root@172.16.0.12   # spine-02
ssh root@172.16.0.21   # leaf-01
ssh root@172.16.0.30   # leaf-10
```

## Security behavior

- Leaf and spine SSH servers are configured for public key auth.
- Password login is disabled.
- SSH on OOB interfaces is limited to source `172.16.0.50`.
