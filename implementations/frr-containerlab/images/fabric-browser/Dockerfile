FROM jlesage/firefox:latest

RUN set -eux; \
    apk update; \
    apk add -v --no-cache \
      bind-tools \
      busybox-extras \
      curl \
      freeradius-utils \
      geckodriver \
      iproute2 \
      iptables \
      nftables \
      openssh-client \
      openssl \
      python3 \
      sshpass \
      wireguard-tools; \
    mkdir -p /etc/wireguard /run/wireguard /var/log
