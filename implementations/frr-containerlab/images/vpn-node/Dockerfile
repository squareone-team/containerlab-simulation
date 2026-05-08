FROM alpine:3.20

RUN set -eux; \
    apk add --no-cache \
      busybox-extras \
      curl \
      freeradius-utils \
      iproute2 \
      iptables \
      nftables \
      openssh-client \
      openssl \
      python3 \
      sshpass \
      wireguard-tools; \
    mkdir -p /etc/wireguard /run/wireguard /var/log

CMD ["sleep", "infinity"]
