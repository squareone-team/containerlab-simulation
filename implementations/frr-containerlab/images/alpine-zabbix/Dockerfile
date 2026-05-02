FROM alpine:3.20

RUN set -eux; \
    printf '%s\n' \
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/community' \
      >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache \
      iproute2 \
      mariadb \
      mariadb-client \
      net-snmp \
      net-snmp-tools \
      zabbix-mysql=6.4.19-r0 \
      zabbix-setup=6.4.19-r0 \
      zabbix-utils=6.4.19-r0; \
    mkdir -p \
      /etc/snmp \
      /etc/zabbix \
      /run/mysqld \
      /run/zabbix \
      /var/lib/mysql \
      /var/lib/zabbix \
      /var/log/mysql \
      /var/log/zabbix
