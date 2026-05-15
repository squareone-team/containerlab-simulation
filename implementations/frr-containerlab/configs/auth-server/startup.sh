#!/bin/sh
set -eu

LDAP_BASE_DN="dc=esi,dc=internal"
LDAP_BIND_DN="cn=admin,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="EsiDirectoryRoot#2026"
RADIUS_SECRET_CAMPUS="EsiCampusNacRadius#2026"
RADIUS_SECRET_VPN="EsiVpnRadius#2026"
TACACS_SECRET="SquareOneTacacs#2026"

wait_for_iface() {
    iface="$1"
    retries="${2:-30}"
    while [ "$retries" -gt 0 ]; do
        ip link show "$iface" >/dev/null 2>&1 && return 0
        sleep 1
        retries=$((retries - 1))
    done
    return 1
}

hostname auth-server 2>/dev/null || true

if wait_for_iface eth1 && wait_for_iface eth2; then
    ip link add bond0 type bond mode active-backup miimon 100 primary eth1 2>/dev/null || true
    ip addr flush dev eth1 2>/dev/null || true
    ip addr flush dev eth2 2>/dev/null || true
    ip link set eth1 down 2>/dev/null || true
    ip link set eth2 down 2>/dev/null || true
    ip link set eth1 master bond0
    ip link set eth2 master bond0
    ip link set eth1 up
    ip link set eth2 up
    ip link set bond0 up
    sleep 2

    ip addr add 192.168.50.80/24 dev bond0 2>/dev/null || true
    ip route replace default via 192.168.50.1 dev bond0
    ip route replace 192.168.0.0/16 via 192.168.50.1 dev bond0
    ip route replace 10.0.0.0/8 via 192.168.50.1 dev bond0
else
    echo "[auth-server] WARNING: eth1/eth2 did not appear for bond0" >&2
fi

mkdir -p /etc/esi-auth /run/openldap /var/lib/openldap/openldap-data /var/log
chown -R ldap:ldap /run/openldap /var/lib/openldap

cat > /etc/nftables.conf << 'NFT'
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0;
        policy drop;
        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept

        # Only protected servers may query TACACS+. LDAP stays loopback-only.
        ip saddr { 192.168.10.10, 192.168.50.10, 192.168.70.10 } tcp dport 49 accept

        # RADIUS is exposed only to the campus NAC gateway and VPN gateway.
        ip saddr { 192.168.110.1, 198.51.100.20 } udp dport 1812 accept
    }
    chain forward {
        type filter hook forward priority 0;
        policy drop;
    }
    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}
NFT
nft -f /etc/nftables.conf

pkill -f esi-tacacsd 2>/dev/null || true
pkill radiusd 2>/dev/null || true
pkill slapd 2>/dev/null || true
rm -rf /var/lib/openldap/openldap-data/*

ROOTPW="$(slappasswd -s "${LDAP_BIND_PASSWORD}")"
SQUAREONE_ADMIN_PW="$(slappasswd -s 'SquareOneRoot#2026')"
PROFESSOR_NORA_PW="$(slappasswd -s 'NoraTPs#2026')"
STUDENT_AMINE_PW="$(slappasswd -s 'AmineLab#2026')"
STUDENT_SELMA_PW="$(slappasswd -s 'SelmaLms#2026')"
STUDENT_ILYES_PW="$(slappasswd -s 'IlyesVpn#2026')"
STUDENT_TATI_YOUCEF_PW="$(slappasswd -s 'TatiLab#2026')"
STUDENT_KHERROUBI_AMINE_PW="$(slappasswd -s 'KherroubiLab#2026')"
STUDENT_BADAOUI_IKRAM_PW="$(slappasswd -s 'BadaouiLab#2026')"
STUDENT_ZITOUNI_RANIA_PW="$(slappasswd -s 'ZitouniLab#2026')"
STUDENT_MOSTEFAI_MOUNIR_PW="$(slappasswd -s 'MostefaiLab#2026')"
STUDENT_BOUSDJIRA_NADINE_PW="$(slappasswd -s 'BousdjiraLab#2026')"
STUDENT_HASSNAOUI_SARAH_PW="$(slappasswd -s 'HassnaouiLab#2026')"
PROFESSOR_HAMANI_NACER_PW="$(slappasswd -s 'HamaniTPs#2026')"
PROFESSOR_AMROUCHE_HAKIM_PW="$(slappasswd -s 'AmroucheTPs#2026')"

cat > /etc/openldap/slapd.conf << EOF
include         /etc/openldap/schema/core.schema
include         /etc/openldap/schema/cosine.schema
include         /etc/openldap/schema/nis.schema
include         /etc/openldap/schema/inetorgperson.schema

pidfile         /run/openldap/slapd.pid
argsfile        /run/openldap/slapd.args
modulepath      /usr/lib/openldap
moduleload      back_mdb.so

database        mdb
maxsize         1073741824
suffix          "${LDAP_BASE_DN}"
rootdn          "${LDAP_BIND_DN}"
rootpw          ${ROOTPW}
directory       /var/lib/openldap/openldap-data

index           objectClass eq
index           uid eq
index           memberUid eq

access to attrs=userPassword
    by self write
    by anonymous auth
    by dn.base="${LDAP_BIND_DN}" write
    by * none
access to *
    by dn.base="${LDAP_BIND_DN}" write
    by * read
EOF

cat > /etc/esi-auth/bootstrap.ldif << EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ESI Internal Directory
dc: esi

dn: ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: People

dn: ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Groups

dn: uid=squareone.admin@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: SquareOne Network Admin
uid: squareone.admin@esi.dz
uidNumber: 2101
gidNumber: 2101
homeDirectory: /home/squareone.admin
loginShell: /bin/sh
userPassword: ${SQUAREONE_ADMIN_PW}
description: squareone-admin

dn: uid=squareone.admin,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: SquareOne Network Admin
uid: squareone.admin
uidNumber: 2111
gidNumber: 2101
homeDirectory: /home/squareone.admin
loginShell: /bin/sh
userPassword: ${SQUAREONE_ADMIN_PW}
description: squareone-admin-linux

dn: uid=nora.benali@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Nora Benali
uid: nora.benali@esi.dz
uidNumber: 2102
gidNumber: 2102
homeDirectory: /home/nora.benali
loginShell: /bin/sh
userPassword: ${PROFESSOR_NORA_PW}
description: professor-student-privilege

dn: uid=nora.benali,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Nora Benali
uid: nora.benali
uidNumber: 2322
gidNumber: 2102
homeDirectory: /home/nora.benali
loginShell: /bin/sh
userPassword: ${PROFESSOR_NORA_PW}
description: professor-linux

dn: uid=amine.kadri@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Amine Kadri
uid: amine.kadri@esi.dz
uidNumber: 2201
gidNumber: 2102
homeDirectory: /home/amine.kadri
loginShell: /bin/sh
userPassword: ${STUDENT_AMINE_PW}
description: student-vpn

dn: uid=amine.kadri,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Amine Kadri
uid: amine.kadri
uidNumber: 2202
gidNumber: 2102
homeDirectory: /home/amine.kadri
loginShell: /bin/sh
userPassword: ${STUDENT_AMINE_PW}
description: student-linux

dn: uid=selma.bouaziz@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Selma Bouaziz
uid: selma.bouaziz@esi.dz
uidNumber: 2203
gidNumber: 2102
homeDirectory: /home/selma.bouaziz
loginShell: /bin/sh
userPassword: ${STUDENT_SELMA_PW}
description: student-lms

dn: uid=ilyes.rahmani@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Ilyes Rahmani
uid: ilyes.rahmani@esi.dz
uidNumber: 2204
gidNumber: 2102
homeDirectory: /home/ilyes.rahmani
loginShell: /bin/sh
userPassword: ${STUDENT_ILYES_PW}
description: student-vpn

dn: uid=tati.youcef@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Tati Youcef
uid: tati.youcef@esi.dz
uidNumber: 2210
gidNumber: 2102
homeDirectory: /home/tati.youcef
loginShell: /bin/sh
userPassword: ${STUDENT_TATI_YOUCEF_PW}
description: student-vpn

dn: uid=tati.youcef,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Tati Youcef
uid: tati.youcef
uidNumber: 2310
gidNumber: 2102
homeDirectory: /home/tati.youcef
loginShell: /bin/sh
userPassword: ${STUDENT_TATI_YOUCEF_PW}
description: student-linux

dn: uid=kherroubi.amine@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Kherroubi Amine
uid: kherroubi.amine@esi.dz
uidNumber: 2211
gidNumber: 2102
homeDirectory: /home/kherroubi.amine
loginShell: /bin/sh
userPassword: ${STUDENT_KHERROUBI_AMINE_PW}
description: student-vpn

dn: uid=kherroubi.amine,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Kherroubi Amine
uid: kherroubi.amine
uidNumber: 2311
gidNumber: 2102
homeDirectory: /home/kherroubi.amine
loginShell: /bin/sh
userPassword: ${STUDENT_KHERROUBI_AMINE_PW}
description: student-linux

dn: uid=badaoui.ikram@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Badaoui Ikram
uid: badaoui.ikram@esi.dz
uidNumber: 2212
gidNumber: 2102
homeDirectory: /home/badaoui.ikram
loginShell: /bin/sh
userPassword: ${STUDENT_BADAOUI_IKRAM_PW}
description: student-vpn

dn: uid=badaoui.ikram,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Badaoui Ikram
uid: badaoui.ikram
uidNumber: 2312
gidNumber: 2102
homeDirectory: /home/badaoui.ikram
loginShell: /bin/sh
userPassword: ${STUDENT_BADAOUI_IKRAM_PW}
description: student-linux

dn: uid=zitouni.rania@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Zitouni Rania
uid: zitouni.rania@esi.dz
uidNumber: 2213
gidNumber: 2102
homeDirectory: /home/zitouni.rania
loginShell: /bin/sh
userPassword: ${STUDENT_ZITOUNI_RANIA_PW}
description: student-vpn

dn: uid=zitouni.rania,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Zitouni Rania
uid: zitouni.rania
uidNumber: 2313
gidNumber: 2102
homeDirectory: /home/zitouni.rania
loginShell: /bin/sh
userPassword: ${STUDENT_ZITOUNI_RANIA_PW}
description: student-linux

dn: uid=mostefai.mounir@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Mostefai Mounir
uid: mostefai.mounir@esi.dz
uidNumber: 2214
gidNumber: 2102
homeDirectory: /home/mostefai.mounir
loginShell: /bin/sh
userPassword: ${STUDENT_MOSTEFAI_MOUNIR_PW}
description: student-vpn

dn: uid=mostefai.mounir,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Mostefai Mounir
uid: mostefai.mounir
uidNumber: 2314
gidNumber: 2102
homeDirectory: /home/mostefai.mounir
loginShell: /bin/sh
userPassword: ${STUDENT_MOSTEFAI_MOUNIR_PW}
description: student-linux

dn: uid=bousdjira.nadine@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Bousdjira Nadine
uid: bousdjira.nadine@esi.dz
uidNumber: 2215
gidNumber: 2102
homeDirectory: /home/bousdjira.nadine
loginShell: /bin/sh
userPassword: ${STUDENT_BOUSDJIRA_NADINE_PW}
description: student-vpn

dn: uid=bousdjira.nadine,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Bousdjira Nadine
uid: bousdjira.nadine
uidNumber: 2315
gidNumber: 2102
homeDirectory: /home/bousdjira.nadine
loginShell: /bin/sh
userPassword: ${STUDENT_BOUSDJIRA_NADINE_PW}
description: student-linux

dn: uid=hassnaoui.sarah@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Hassnaoui Sarah
uid: hassnaoui.sarah@esi.dz
uidNumber: 2216
gidNumber: 2102
homeDirectory: /home/hassnaoui.sarah
loginShell: /bin/sh
userPassword: ${STUDENT_HASSNAOUI_SARAH_PW}
description: student-vpn

dn: uid=hassnaoui.sarah,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Hassnaoui Sarah
uid: hassnaoui.sarah
uidNumber: 2316
gidNumber: 2102
homeDirectory: /home/hassnaoui.sarah
loginShell: /bin/sh
userPassword: ${STUDENT_HASSNAOUI_SARAH_PW}
description: student-linux

dn: uid=hamani.nacer@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Hamani Nacer
uid: hamani.nacer@esi.dz
uidNumber: 2120
gidNumber: 2102
homeDirectory: /home/hamani.nacer
loginShell: /bin/sh
userPassword: ${PROFESSOR_HAMANI_NACER_PW}
description: professor-student-privilege

dn: uid=hamani.nacer,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Hamani Nacer
uid: hamani.nacer
uidNumber: 2320
gidNumber: 2102
homeDirectory: /home/hamani.nacer
loginShell: /bin/sh
userPassword: ${PROFESSOR_HAMANI_NACER_PW}
description: professor-linux

dn: uid=amrouche.hakim@esi.dz,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Amrouche Hakim
uid: amrouche.hakim@esi.dz
uidNumber: 2121
gidNumber: 2102
homeDirectory: /home/amrouche.hakim
loginShell: /bin/sh
userPassword: ${PROFESSOR_AMROUCHE_HAKIM_PW}
description: professor-student-privilege

dn: uid=amrouche.hakim,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Amrouche Hakim
uid: amrouche.hakim
uidNumber: 2321
gidNumber: 2102
homeDirectory: /home/amrouche.hakim
loginShell: /bin/sh
userPassword: ${PROFESSOR_AMROUCHE_HAKIM_PW}
description: professor-linux

dn: cn=admins,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: admins
gidNumber: 2101
memberUid: squareone.admin
memberUid: squareone.admin@esi.dz

dn: cn=squareone-admins,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: squareone-admins
gidNumber: 2110
memberUid: squareone.admin
memberUid: squareone.admin@esi.dz

dn: cn=students,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: students
gidNumber: 2102
memberUid: nora.benali@esi.dz
memberUid: nora.benali
memberUid: hamani.nacer@esi.dz
memberUid: hamani.nacer
memberUid: amrouche.hakim@esi.dz
memberUid: amrouche.hakim
memberUid: amine.kadri@esi.dz
memberUid: amine.kadri
memberUid: selma.bouaziz@esi.dz
memberUid: ilyes.rahmani@esi.dz
memberUid: tati.youcef@esi.dz
memberUid: tati.youcef
memberUid: kherroubi.amine@esi.dz
memberUid: kherroubi.amine
memberUid: badaoui.ikram@esi.dz
memberUid: badaoui.ikram
memberUid: zitouni.rania@esi.dz
memberUid: zitouni.rania
memberUid: mostefai.mounir@esi.dz
memberUid: mostefai.mounir
memberUid: bousdjira.nadine@esi.dz
memberUid: bousdjira.nadine
memberUid: hassnaoui.sarah@esi.dz
memberUid: hassnaoui.sarah

dn: cn=student,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: student
gidNumber: 2105
memberUid: nora.benali@esi.dz
memberUid: hamani.nacer@esi.dz
memberUid: amrouche.hakim@esi.dz
memberUid: amine.kadri@esi.dz
memberUid: selma.bouaziz@esi.dz
memberUid: ilyes.rahmani@esi.dz
memberUid: tati.youcef@esi.dz
memberUid: kherroubi.amine@esi.dz
memberUid: badaoui.ikram@esi.dz
memberUid: zitouni.rania@esi.dz
memberUid: mostefai.mounir@esi.dz
memberUid: bousdjira.nadine@esi.dz
memberUid: hassnaoui.sarah@esi.dz

dn: cn=professors,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: professors
gidNumber: 2106
memberUid: nora.benali@esi.dz
memberUid: nora.benali
memberUid: hamani.nacer@esi.dz
memberUid: hamani.nacer
memberUid: amrouche.hakim@esi.dz
memberUid: amrouche.hakim

dn: cn=hpc-users,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: hpc-users
gidNumber: 2103
memberUid: amine.kadri
memberUid: tati.youcef
memberUid: kherroubi.amine
memberUid: badaoui.ikram
memberUid: zitouni.rania
memberUid: mostefai.mounir
memberUid: bousdjira.nadine
memberUid: hassnaoui.sarah
memberUid: nora.benali
memberUid: hamani.nacer
memberUid: amrouche.hakim
memberUid: squareone.admin
EOF

slapadd -f /etc/openldap/slapd.conf -l /etc/esi-auth/bootstrap.ldif >/var/log/esi-ldap-bootstrap.log 2>&1
chown -R ldap:ldap /var/lib/openldap

nohup slapd -d 0 -f /etc/openldap/slapd.conf -h "ldap://127.0.0.1:389/" -u ldap -g ldap \
    >/var/log/slapd.stdout 2>&1 &

for _ in $(seq 1 20); do
    if ldapsearch -x -H ldap://127.0.0.1:389 -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" -b "${LDAP_BASE_DN}" "(uid=amine.kadri@esi.dz)" dn >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

LDAP_URI="ldap://127.0.0.1:389" \
LDAP_BASE_DN="${LDAP_BASE_DN}" \
LDAP_BIND_DN="${LDAP_BIND_DN}" \
LDAP_BIND_PASSWORD="${LDAP_BIND_PASSWORD}" \
ESI_TACACS_SECRET="${TACACS_SECRET}" \
ESI_TACACS_LOG="/var/log/esi-tacacs.log" \
nohup /usr/local/bin/esi-tacacsd >/var/log/esi-tacacs.stdout 2>&1 &

for _ in $(seq 1 20); do
    nc -z -w1 127.0.0.1 49 >/dev/null 2>&1 && break
    sleep 1
done

if [ -x /usr/local/bin/esi-radiusd ]; then
    ESI_RADIUS_CLIENTS="192.168.110.1:${RADIUS_SECRET_CAMPUS}:campus-nac,198.51.100.20:${RADIUS_SECRET_VPN}:vpn-gateway" \
    LDAP_URI="ldap://127.0.0.1:389" \
    LDAP_BASE_DN="${LDAP_BASE_DN}" \
    LDAP_BIND_DN="${LDAP_BIND_DN}" \
    LDAP_BIND_PASSWORD="${LDAP_BIND_PASSWORD}" \
    ESI_RADIUS_LOG="/var/log/esi-radius.log" \
    nohup /usr/local/bin/esi-radiusd >/var/log/esi-radius.stdout 2>&1 &

    for _ in $(seq 1 20); do
        nc -z -u -w1 127.0.0.1 1812 >/dev/null 2>&1 && break
        sleep 1
    done
else
    echo "[auth-server] WARNING: esi-radiusd missing; rebuild the auth-server image" >&2
fi

echo "[auth-server] ready: OpenLDAP on loopback, TACACS+ on 192.168.50.80:49, RADIUS on 192.168.50.80:1812"
