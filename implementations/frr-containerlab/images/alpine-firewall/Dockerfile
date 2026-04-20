FROM alpine:3.20

RUN set -eux; \
    apk add --no-cache \
      curl \
      iproute2 \
      iputils \
      keepalived \
      nftables \
      tcpdump; \
    mkdir -p \
      /etc/keepalived \
      /usr/local/bin
