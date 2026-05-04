#!/bin/sh

# IP fixe sur le réseau data
ip addr add 192.168.100.10/24 dev eth1
ip link set eth1 up

# Attendre que OpenLDAP démarre complètement
sleep 5

# Créer la structure de base (OUs)
ldapadd -x -D "cn=admin,dc=esi,dc=dz" \
  -w ESI@Admin2024 << EOF

# Unité organisationnelle Users
dn: ou=users,dc=esi,dc=dz
objectClass: organizationalUnit
ou: users

# Unité organisationnelle Groups
dn: ou=groups,dc=esi,dc=dz
objectClass: organizationalUnit
ou: groups

# ─── GROUPES ───

dn: cn=super-admins,ou=groups,dc=esi,dc=dz
objectClass: groupOfNames
cn: super-admins
member: uid=admin1,ou=users,dc=esi,dc=dz

dn: cn=net-admins,ou=groups,dc=esi,dc=dz
objectClass: groupOfNames
cn: net-admins
member: uid=netadmin1,ou=users,dc=esi,dc=dz

dn: cn=etudiants,ou=groups,dc=esi,dc=dz
objectClass: groupOfNames
cn: etudiants
member: uid=etudiant1,ou=users,dc=esi,dc=dz

# ─── UTILISATEURS ───

dn: uid=admin1,ou=users,dc=esi,dc=dz
objectClass: inetOrgPerson
objectClass: posixAccount
uid: admin1
cn: Admin One
sn: One
uidNumber: 1001
gidNumber: 1001
homeDirectory: /home/admin1
loginShell: /bin/sh
userPassword: Admin@2024

dn: uid=netadmin1,ou=users,dc=esi,dc=dz
objectClass: inetOrgPerson
objectClass: posixAccount
uid: netadmin1
cn: NetAdmin One
sn: One
uidNumber: 1002
gidNumber: 1002
homeDirectory: /home/netadmin1
loginShell: /bin/sh
userPassword: Net@2024

dn: uid=etudiant1,ou=users,dc=esi,dc=dz
objectClass: inetOrgPerson
objectClass: posixAccount
uid: etudiant1
cn: Etudiant One
sn: One
uidNumber: 1003
gidNumber: 1003
homeDirectory: /home/etudiant1
loginShell: /bin/sh
userPassword: Etu@2024

EOF

echo "OpenLDAP structure created successfully"