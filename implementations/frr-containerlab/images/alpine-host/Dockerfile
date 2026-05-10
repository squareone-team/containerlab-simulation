FROM alpine:3.20

RUN set -eux; \
    apk add --no-cache \
      busybox-extras \
      chrony \
      freeradius-utils \
      iproute2 \
      iptables \
      nftables \
      openssl \
      openssh-client \
      openssh-server \
      openssh-server-pam \
      linux-pam \
      python3 \
      sshpass \
      rsyslog; \
    mkdir -p \
      /run/sshd \
      /root/.ssh \
      /var/log \
      /var/log/chrony \
      /var/run/chrony
