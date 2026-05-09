#!/bin/sh
set -eu

LDAP_BASE_DN="dc=esi,dc=internal"
LDAP_BIND_DN="cn=admin,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="DirectoryAdmin@2026"
RADIUS_SECRET_CAMPUS="CampusRadiusSecret@2026"
RADIUS_SECRET_VPN="VpnRadiusSecret@2026"

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
ADMINPW="$(slappasswd -s 'Admin@2026')"
STUDENTPW="$(slappasswd -s 'Student@2026')"
DEVICE_STUDENT_PW="$(slappasswd -s 'DeviceStudent@2026')"
DEVICE_ADMIN_PW="$(slappasswd -s 'DeviceAdmin@2026')"

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

dn: ou=Devices,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Devices

dn: uid=admin1,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Campus Admin
uid: admin1
uidNumber: 2101
gidNumber: 2101
homeDirectory: /home/admin1
loginShell: /bin/sh
userPassword: ${ADMINPW}

dn: uid=student1,ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Campus Student
uid: student1
uidNumber: 2102
gidNumber: 2102
homeDirectory: /home/student1
loginShell: /bin/sh
userPassword: ${STUDENTPW}
description: vpn-student

dn: uid=dev-campus-student-01,ou=Devices,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Campus Student Device
uid: dev-campus-student-01
uidNumber: 2201
gidNumber: 2201
homeDirectory: /dev/null
loginShell: /sbin/nologin
userPassword: ${DEVICE_STUDENT_PW}
description: campus-student-device

dn: uid=dev-campus-admin-01,ou=Devices,${LDAP_BASE_DN}
objectClass: top
objectClass: account
objectClass: posixAccount
objectClass: shadowAccount
cn: Campus Admin Device
uid: dev-campus-admin-01
uidNumber: 2202
gidNumber: 2202
homeDirectory: /dev/null
loginShell: /sbin/nologin
userPassword: ${DEVICE_ADMIN_PW}
description: campus-admin-device

dn: cn=admins,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: admins
gidNumber: 2101
memberUid: admin1

dn: cn=students,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: students
gidNumber: 2102
memberUid: student1

dn: cn=hpc-users,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: hpc-users
gidNumber: 2103
memberUid: student1
memberUid: admin1
EOF

slapadd -f /etc/openldap/slapd.conf -l /etc/esi-auth/bootstrap.ldif >/var/log/esi-ldap-bootstrap.log 2>&1
chown -R ldap:ldap /var/lib/openldap

slapd -f /etc/openldap/slapd.conf -h "ldap://127.0.0.1:389/" -u ldap -g ldap

for _ in $(seq 1 20); do
    if ldapsearch -x -H ldap://127.0.0.1:389 -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PASSWORD}" -b "${LDAP_BASE_DN}" "(uid=student1)" dn >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

LDAP_URI="ldap://127.0.0.1:389" \
LDAP_BASE_DN="${LDAP_BASE_DN}" \
LDAP_BIND_DN="${LDAP_BIND_DN}" \
LDAP_BIND_PASSWORD="${LDAP_BIND_PASSWORD}" \
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
