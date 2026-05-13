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
memberUid: amine.kadri@esi.dz
memberUid: amine.kadri
memberUid: selma.bouaziz@esi.dz
memberUid: ilyes.rahmani@esi.dz

dn: cn=student,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: student
gidNumber: 2105
memberUid: nora.benali@esi.dz
memberUid: amine.kadri@esi.dz
memberUid: selma.bouaziz@esi.dz
memberUid: ilyes.rahmani@esi.dz

dn: cn=professors,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: professors
gidNumber: 2106
memberUid: nora.benali@esi.dz

dn: cn=hpc-users,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: hpc-users
gidNumber: 2103
memberUid: amine.kadri
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
