FROM alpine:3.20

RUN set -eux; \
    apk add --no-cache \
      busybox-extras \
      chrony \
      iproute2 \
      iptables \
      nftables \
      openssh-client \
      openssh-server \
      rsyslog; \
    mkdir -p \
      /run/sshd \
      /root/.ssh \
      /var/log \
      /var/log/chrony \
      /var/run/chrony
