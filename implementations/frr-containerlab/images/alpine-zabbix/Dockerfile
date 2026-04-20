FROM alpine:3.20

RUN set -eux; \
    printf '%s\n' \
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/community' \
      'https://dl-cdn.alpinelinux.org/alpine/edge/community' \
      >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache \
      iproute2 \
      mariadb \
      mariadb-client \
      net-snmp \
      net-snmp-tools \
      zabbix-mysql \
      zabbix-setup \
      zabbix-utils; \
    mkdir -p \
      /etc/snmp \
      /etc/zabbix \
      /run/mysqld \
      /run/zabbix \
      /var/lib/mysql \
      /var/lib/zabbix \
      /var/log/mysql \
      /var/log/zabbix
