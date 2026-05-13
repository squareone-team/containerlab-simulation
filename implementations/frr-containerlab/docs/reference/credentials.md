# Lab Credentials

These credentials are demo-only and intentionally documented so the topology can be validated in class.

## NAC And VPN

| Person | Username | Password | Groups | Expected role |
| --- | --- | --- | --- | --- |
| Prof. Nora Benali | `nora.benali@esi.dz` | `NoraTPs#2026` | `students`, `student`, `professors` | NAC `campus-student`, VPN `vpn-student` |
| Amine Kadri | `amine.kadri@esi.dz` | `AmineLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Selma Bouaziz | `selma.bouaziz@esi.dz` | `SelmaLms#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Ilyes Rahmani | `ilyes.rahmani@esi.dz` | `IlyesVpn#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| SquareOne admin | `squareone.admin@esi.dz` | `SquareOneRoot#2026` | `squareone-admins`, `admins` | NAC `campus-admin`; VPN rejected |

## SSH/TACACS Aliases

Linux SSH usernames avoid `@` because local account tools are stricter than LDAP/RADIUS usernames.

| Person | SSH username | Password | Authorized resources |
| --- | --- | --- | --- |
| Amine Kadri | `amine.kadri` | `AmineLab#2026` | `student`, `hpc` |
| SquareOne admin | `squareone.admin` | `SquareOneRoot#2026` | `student`, `hpc`, `admin`, `core` |

## Moodle

| Role | Username | Password | Notes |
| --- | --- | --- | --- |
| Site admin | `squareone.admin` | `SquareOneMoodle#2026` | Created by the Moodle container bootstrap; email is `squareone.admin@esi.dz`. |
| Professor | `nora.benali@esi.dz` | `NoraTPs#2026` | Enrolled as editing teacher in `TP-NAC-VPN`. |
| Student | `amine.kadri@esi.dz` | `AmineLab#2026` | Enrolled as student. |
| Student | `selma.bouaziz@esi.dz` | `SelmaLms#2026` | Enrolled as student. |
| Student | `ilyes.rahmani@esi.dz` | `IlyesVpn#2026` | Enrolled as student. |

## Infrastructure Secrets

| Component | Username or secret name | Value |
| --- | --- | --- |
| LDAP bind DN | `cn=admin,dc=esi,dc=internal` | `EsiDirectoryRoot#2026` |
| Campus RADIUS shared secret | `campus-nac` | `EsiCampusNacRadius#2026` |
| VPN RADIUS shared secret | `vpn-gateway` | `EsiVpnRadius#2026` |
| TACACS+ shared secret | `esi-tacacs` | `SquareOneTacacs#2026` |
| Grafana | `squareone.admin` | `SquareOneGrafana#2026` |
| Moodle database root | `root` | `MoodleRootDb#2026` |
| Moodle database app user | `moodle_app` | `MoodleAppDb#2026` |
