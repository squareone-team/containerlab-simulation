# Lab Credentials

These credentials are demo-only and intentionally documented so the topology can be validated in class.

## NAC And VPN

| Person | Username | Password | Groups | Expected role |
| --- | --- | --- | --- | --- |
| Prof. Nora Benali | `nora.benali@esi.dz` | `NoraTPs#2026` | `students`, `student`, `professors` | NAC `campus-student`, VPN `vpn-student` |
| Prof. Hamani Nacer | `hamani.nacer@esi.dz` | `HamaniTPs#2026` | `students`, `student`, `professors` | NAC `campus-student`, VPN `vpn-student` |
| Prof. Amrouche Hakim | `amrouche.hakim@esi.dz` | `AmroucheTPs#2026` | `students`, `student`, `professors` | NAC `campus-student`, VPN `vpn-student` |
| Amine Kadri | `amine.kadri@esi.dz` | `AmineLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Selma Bouaziz | `selma.bouaziz@esi.dz` | `SelmaLms#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Ilyes Rahmani | `ilyes.rahmani@esi.dz` | `IlyesVpn#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Tati Youcef | `tati.youcef@esi.dz` | `TatiLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Kherroubi Amine | `kherroubi.amine@esi.dz` | `KherroubiLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Badaoui Ikram | `badaoui.ikram@esi.dz` | `BadaouiLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Zitouni Rania | `zitouni.rania@esi.dz` | `ZitouniLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Mostefai Mounir | `mostefai.mounir@esi.dz` | `MostefaiLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Bousdjira Nadine | `bousdjira.nadine@esi.dz` | `BousdjiraLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| Hassnaoui Sarah | `hassnaoui.sarah@esi.dz` | `HassnaouiLab#2026` | `students`, `student` | NAC `campus-student`, VPN `vpn-student` |
| SquareOne admin | `squareone.admin@esi.dz` | `SquareOneRoot#2026` | `squareone-admins`, `admins` | NAC `campus-admin`; VPN rejected |

## SSH/TACACS Aliases

Linux SSH usernames avoid `@` because local account tools are stricter than LDAP/RADIUS usernames.

| Person | SSH username | Password | Authorized resources |
| --- | --- | --- | --- |
| Prof. Hamani Nacer | `hamani.nacer` | `HamaniTPs#2026` | `student`, `hpc` |
| Prof. Amrouche Hakim | `amrouche.hakim` | `AmroucheTPs#2026` | `student`, `hpc` |
| Prof. Nora Benali | `nora.benali` | `NoraTPs#2026` | `student`, `hpc` |
| Amine Kadri | `amine.kadri` | `AmineLab#2026` | `student`, `hpc` |
| Tati Youcef | `tati.youcef` | `TatiLab#2026` | `student`, `hpc` |
| Kherroubi Amine | `kherroubi.amine` | `KherroubiLab#2026` | `student`, `hpc` |
| Badaoui Ikram | `badaoui.ikram` | `BadaouiLab#2026` | `student`, `hpc` |
| Zitouni Rania | `zitouni.rania` | `ZitouniLab#2026` | `student`, `hpc` |
| Mostefai Mounir | `mostefai.mounir` | `MostefaiLab#2026` | `student`, `hpc` |
| Bousdjira Nadine | `bousdjira.nadine` | `BousdjiraLab#2026` | `student`, `hpc` |
| Hassnaoui Sarah | `hassnaoui.sarah` | `HassnaouiLab#2026` | `student`, `hpc` |
| SquareOne admin | `squareone.admin` | `SquareOneRoot#2026` | `student`, `hpc`, `admin`, `core` |

## JupyterHub

JupyterHub uses local PAM usernames, not email-form usernames. These accounts replace the previous generic `student-*`, `researcher-*`, and `admin` logins.

| Role | Jupyter username | Password | Notes |
| --- | --- | --- | --- |
| Hub admin | `squareone.admin` | `SquareOneRoot#2026` | Hub admin and GPU profile access. |
| Professor | `nora.benali` | `NoraTPs#2026` | CPU notebook profile. |
| Professor | `hamani.nacer` | `HamaniTPs#2026` | CPU notebook profile. |
| Professor | `amrouche.hakim` | `AmroucheTPs#2026` | CPU notebook profile. |
| Student | `tati.youcef` | `TatiLab#2026` | CPU notebook profile; primary NaaS test user. |
| Student | `kherroubi.amine` | `KherroubiLab#2026` | CPU notebook profile. |
| Student | `badaoui.ikram` | `BadaouiLab#2026` | CPU notebook profile. |
| Student | `zitouni.rania` | `ZitouniLab#2026` | CPU notebook profile. |
| Student | `mostefai.mounir` | `MostefaiLab#2026` | CPU notebook profile. |
| Student | `bousdjira.nadine` | `BousdjiraLab#2026` | CPU notebook profile. |
| Student | `hassnaoui.sarah` | `HassnaouiLab#2026` | CPU notebook profile. |
| Student | `amine.kadri` | `AmineLab#2026` | CPU notebook profile. |
| Student | `selma.bouaziz` | `SelmaLms#2026` | CPU notebook profile. |
| Student | `ilyes.rahmani` | `IlyesVpn#2026` | CPU notebook profile. |

## Moodle

| Role | Username | Password | Notes |
| --- | --- | --- | --- |
| Site admin | `squareone.admin` | `SquareOneMoodle#2026` | Created by the Moodle container bootstrap; email is `squareone.admin@esi.dz`. |
| Professor | `nora.benali@esi.dz` | `NoraTPs#2026` | Enrolled as editing teacher in `TP-NAC-VPN`. |
| Professor | `hamani.nacer@esi.dz` | `HamaniTPs#2026` | Enrolled as editing teacher in `TP-NAC-VPN`. |
| Professor | `amrouche.hakim@esi.dz` | `AmroucheTPs#2026` | Enrolled as editing teacher in `TP-NAC-VPN`. |
| Student | `amine.kadri@esi.dz` | `AmineLab#2026` | Enrolled as student. |
| Student | `selma.bouaziz@esi.dz` | `SelmaLms#2026` | Enrolled as student. |
| Student | `ilyes.rahmani@esi.dz` | `IlyesVpn#2026` | Enrolled as student. |
| Student | `tati.youcef@esi.dz` | `TatiLab#2026` | Enrolled as student. |
| Student | `kherroubi.amine@esi.dz` | `KherroubiLab#2026` | Enrolled as student. |
| Student | `badaoui.ikram@esi.dz` | `BadaouiLab#2026` | Enrolled as student. |
| Student | `zitouni.rania@esi.dz` | `ZitouniLab#2026` | Enrolled as student. |
| Student | `mostefai.mounir@esi.dz` | `MostefaiLab#2026` | Enrolled as student. |
| Student | `bousdjira.nadine@esi.dz` | `BousdjiraLab#2026` | Enrolled as student. |
| Student | `hassnaoui.sarah@esi.dz` | `HassnaouiLab#2026` | Enrolled as student. |

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
