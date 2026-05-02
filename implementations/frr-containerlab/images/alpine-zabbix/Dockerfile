FROM alpine:3.20

RUN set -eux; \
    printf '%s\n' \
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/community' \
      >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache \
      curl \
      fping \
      iproute2 \
      mariadb \
      mariadb-client \
      net-snmp \
      net-snmp-tools \
      nginx \
      php82-bcmath \
      php82-ctype \
      php82-fpm \
      php82-gd \
      php82-json \
      php82-mbstring \
      php82-mysqli \
      php82-pdo_mysql \
      php82-session \
      php82-xml \
      python3 \
      zabbix-mysql=6.4.19-r0 \
      zabbix-setup=6.4.19-r0 \
      zabbix-utils=6.4.19-r0 \
      zabbix-webif=6.4.19-r0; \
    mkdir -p \
      /etc/nginx/http.d \
      /etc/php82/conf.d \
      /etc/snmp \
      /etc/zabbix \
      /opt/zabbix \
      /run/nginx \
      /run/mysqld \
      /run/zabbix \
      /var/lib/mysql \
      /var/lib/zabbix \
      /var/log/nginx \
      /var/log/mysql \
      /var/log/zabbix
