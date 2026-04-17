#!/bin/sh
set -eu

for i in 1 2 3 4 5 6 7 8 9 10; do
  if apk update >/dev/null 2>&1 && apk add --no-cache openssh-server openssh-client rsyslog >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! command -v rsyslogd >/dev/null 2>&1; then
  echo "Failed to install rsyslog on syslog-server" >&2
  exit 1
fi

ip addr add 192.168.50.70/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 192.168.50.254 dev eth1

mkdir -p /run/sshd /root/.ssh /var/log
chmod 700 /root/.ssh
ssh-keygen -A

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  if [ -s /shared/bastion_ed25519.pub ]; then
    break
  fi
  sleep 1
done

if [ ! -s /shared/bastion_ed25519.pub ]; then
  echo "Bastion public key not found in /shared/bastion_ed25519.pub" >&2
  exit 1
fi

cp /shared/bastion_ed25519.pub /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

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
if grep -q '^MaxAuthTries' /etc/ssh/sshd_config; then
  sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
else
  echo 'MaxAuthTries 3' >> /etc/ssh/sshd_config
fi
if grep -q '^LoginGraceTime' /etc/ssh/sshd_config; then
  sed -i 's/^LoginGraceTime.*/LoginGraceTime 30/' /etc/ssh/sshd_config
else
  echo 'LoginGraceTime 30' >> /etc/ssh/sshd_config
fi

cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
module(load="imtcp")
module(load="imudp")
input(type="imtcp" port="514")
input(type="imudp" port="514")

*.* /var/log/messages
RSYSLOG

touch /var/log/messages
chmod 640 /var/log/messages

/usr/sbin/rsyslogd
/usr/sbin/sshd
