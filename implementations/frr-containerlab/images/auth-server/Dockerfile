FROM alpine:3.20

RUN set -eux; \
    apk add --no-cache \
      busybox-extras \
      freeradius \
      freeradius-ldap \
      freeradius-utils \
      iproute2 \
      nftables \
      openldap \
      openldap-back-mdb \
      openldap-clients \
      py3-ldap3 \
      python3; \
    mkdir -p /etc/esi-auth /srv/auth /var/log

COPY tacacs_server.py /usr/local/bin/esi-tacacsd
COPY radius_server.py /usr/local/bin/esi-radiusd
RUN chmod +x /usr/local/bin/esi-tacacsd /usr/local/bin/esi-radiusd

CMD ["sleep", "infinity"]
