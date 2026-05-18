# Moodle LMS

The DMZ LMS is a real Moodle stack, not a static placeholder.

| Node | Image | Data-plane address | Purpose |
| --- | --- | --- | --- |
| `moodle` | `bitnamilegacy/moodle:5.0.2` | `198.51.100.30/24` | Moodle application, Apache, PHP |
| `moodle-db` | `bitnamilegacy/mariadb:11.4` | `192.168.80.31/24` | Moodle database inside the storage pod, multihomed to `leaf-07` and `leaf-08` |

Bitnami announced that existing versioned images moved from `docker.io/bitnami` to `docker.io/bitnamilegacy` in 2025: <https://github.com/bitnami/containers/issues/83267>. The current non-legacy `bitnami/moodle:5.0` manifest was not pullable during implementation, while `bitnamilegacy/moodle:5.0.2` and `bitnamilegacy/mariadb:11.4` were pullable and include the expected Moodle/MariaDB runtime. Keep this as a lab-pinned choice; review it before using the stack outside the demo.

## Names And Routing

| Name | Expected answer |
| --- | --- |
| `moodle.esi.dz` | `198.51.100.30` |
| `www.google.com` | `198.18.3.10` |

Moodle is deliberately published under `moodle.esi.dz`, not `internal.esi.dz`, and the old apex `esi.dz` web shortcut is not published. Campus users reach Moodle only after NAC places their source IP into the `campus_students` or `campus_admins` set. `distribution-switch` also clamps forwarded TCP MSS to 1360 for the campus-to-public path so full Moodle pages survive the lab's mixed-MTU routed segments.

## First Start

```bash
cd implementations/frr-containerlab
docker build -t esi/auth-server:3.20 images/auth-server
containerlab deploy -t esi-datacenter.clab.yml --reconfigure
```

Moodle first boot can take a few minutes because the container initializes the application database. Watch:

```bash
docker logs -f clab-esi-datacenter-moodle
docker exec clab-esi-datacenter-moodle sh -lc 'tail -f /tmp/esi-moodle-bootstrap.log'
```

The bootstrap script creates the ESI demo accounts, enrolls the professors as editing teachers, enrolls students, and publishes a page resource named `TP1 - Captive portal and VPN evidence` in course `TP-NAC-VPN`.

## Verification

```bash
docker exec clab-esi-datacenter-student-01 nslookup moodle.esi.dz 192.168.50.30
docker exec clab-esi-datacenter-student-01 wget -qO- -T 8 http://moodle.esi.dz/ | grep -Ei 'Moodle|TP - NAC'
docker exec clab-esi-datacenter-moodle sh -lc '/opt/bitnami/php/bin/php /opt/bitnami/moodle/admin/cli/cfg.php --name=wwwroot'
```

Run the full browser perspective check:

```bash
bash implementations/frr-containerlab/scripts/tests/browser_pov_validation.sh
```

## Demo Flow

1. Open the fabric-attached student browser at `http://127.0.0.1:5811`, or use `student-01` for headless tests.
2. Authenticate at NAC as `hamani.nacer@esi.dz` / `HamaniTPs#2026`.
3. Browse to `http://moodle.esi.dz/`.
4. Log in to Moodle as `hamani.nacer@esi.dz` / `HamaniTPs#2026`.
5. Open `TP - NAC, VPN and Moodle Access`.
6. Turn editing on and add a Page or Assignment for a new TP.
7. Log out, then log in as `tati.youcef@esi.dz` / `TatiLab#2026`.
8. Confirm the student can open the course and read the TP content without teacher editing controls.

## Seeded Accounts

See [Credentials](../../reference/credentials.md) for the full credential list.
