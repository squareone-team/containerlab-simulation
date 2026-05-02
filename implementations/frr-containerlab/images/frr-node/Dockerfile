FROM frrouting/frr:latest

COPY frr-bgp-peer-mib.py /usr/local/bin/frr-bgp-peer-mib.py

RUN set -eux; \
    apk add --no-cache \
      busybox-extras \
      chrony \
      dhcrelay \
      iptables \
      net-snmp \
      net-snmp-tools \
      openssh-client \
      openssh-server \
      rsyslog; \
    mkdir -p \
      /etc/snmp \
      /root/.ssh \
      /run/sshd \
      /var/agentx \
      /var/log \
      /var/log/chrony \
      /var/run/chrony \
      /var/run/net-snmp; \
    chmod +x /usr/local/bin/frr-bgp-peer-mib.py
