#!/bin/sh
set -eu

hostname dmz-server-01

ip link set eth1 up
ip addr replace 198.51.100.10/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 198.51.100.1 dev eth1

if command -v sshd >/dev/null 2>&1; then
    mkdir -p /run/sshd /root/.ssh
    chmod 700 /root/.ssh
    ssh-keygen -A

    if grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    else
        echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    fi
    if grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config; then
        sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    else
        echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    fi
    if grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    else
        echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
    fi

    /usr/sbin/sshd
fi

cat > /etc/nftables.conf << 'NFT'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;
    iif "lo" accept
    ct state established,related accept
    ip protocol icmp accept
    tcp dport 80 accept
    ip saddr 172.16.0.50 tcp dport 22 accept
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
NFT

nft -f /etc/nftables.conf

cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

if command -v rsyslogd >/dev/null 2>&1; then
    /usr/sbin/rsyslogd
fi

httpd -f -p 80 -h /www >/tmp/dmz-httpd.log 2>&1 &
