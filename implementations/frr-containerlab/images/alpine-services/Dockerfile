FROM esi/alpine-host:3.20

RUN set -eux; \
    apk add --no-cache \
      bind-tools \
      kea \
      unbound; \
    mkdir -p \
      /etc/kea \
      /etc/unbound \
      /var/lib/kea \
      /var/log/kea \
      /var/run/kea
