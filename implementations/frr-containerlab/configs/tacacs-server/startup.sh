#!/bin/sh

# IP fixe OOB
ip link set eth1 up

# Installer PAM LDAP sur le serveur TACACS+
apk add --no-cache openldap-clients pam-ldap linux-pam

# Configurer PAM pour pointer vers OpenLDAP
cat > /etc/pam_ldap.conf << EOF
host 192.168.100.10
base dc=esi,dc=dz
binddn cn=admin,dc=esi,dc=dz
bindpw ESI@Admin2024
pam_login_attribute uid
pam_filter objectclass=posixAccount
EOF

# Configurer PAM TACACS+ pour utiliser LDAP
cat > /etc/pam.d/tac_plus << EOF
auth      required    pam_ldap.so
account   required    pam_ldap.so
EOF

# Démarrer TACACS+
/usr/sbin/tac_plus -C /etc/tacacs+/tac_plus.conf -d 8 &

echo "TACACS+ with LDAP auth started"