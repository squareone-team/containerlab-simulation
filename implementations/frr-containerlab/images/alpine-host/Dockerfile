FROM alpine:3.20

RUN set -eux; \
    # Mise à jour des index pour éviter les erreurs "Package not found"
    apk update; \
    apk add --no-cache \
      busybox-extras \
      chrony \
      iproute2 \
      iptables \
      nftables \
      openssh-client \
      # Sur Alpine 3.20, le paquet avec support PAM est souvent openssh-server-pam
      # On ajoute aussi 'openssh' pour s'assurer que les binaires de base sont là
      openssh \
      openssh-server-pam \
      linux-pam \
      rsyslog \
      python3 \
      py3-pip; \
    # Installation de la librairie TACACS+
    pip3 install tacacs_plus --break-system-packages; \
    # Création des répertoires nécessaires
    mkdir -p \
      /run/sshd \
      /root/.ssh \
      /var/log \
      /var/log/chrony \
      /var/run/chrony; \
    # On force la génération des clés d'hôte SSH au build pour gagner du temps
    ssh-keygen -A

# Le binaire sshd sera dans /usr/sbin/sshd