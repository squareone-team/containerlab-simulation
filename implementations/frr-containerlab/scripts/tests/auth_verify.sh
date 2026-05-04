# 1. Redéployer le lab
sudo containerlab deploy -t esi-datacenter.clab.yml

# 2. Vérifier OpenLDAP
docker exec openldap-server ldapsearch \
  -x -D "cn=admin,dc=esi,dc=dz" \
  -w ESI@Admin2024 \
  -b "ou=users,dc=esi,dc=dz" \
  "(uid=admin1)"
# → doit retourner la fiche de admin1 ✅

# 3. Vérifier TACACS+
docker exec tacacs-server ps aux | grep tac_plus
# → doit être en cours d'exécution ✅

# 4. Tester SSH sur bastion-01
ssh admin1@bastion-01
# mot de passe : Admin@2024
# → cette fois vérifié dans OpenLDAP ✅

# 5. Tester un refus
ssh inconnu@bastion-01
# → doit être refusé ❌

# 6. Vérifier les logs
docker exec tacacs-server cat /var/log/tacacs_accounting.log