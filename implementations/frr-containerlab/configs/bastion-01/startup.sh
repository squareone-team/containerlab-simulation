#!/bin/sh
set -eu

OOB_IF="eth1"

# Keep Docker management on eth0; assign OOB address on dedicated interface.
ip addr replace 172.16.0.50/24 dev "$OOB_IF"
ip link set "$OOB_IF" up

# Install OpenSSH with retries (network can be briefly unavailable at boot).
for i in 1 2 3 4 5 6 7 8 9 10; do
  if apk update >/dev/null 2>&1 && apk add --no-cache openssh-server openssh-client rsyslog >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! command -v ssh >/dev/null 2>&1; then
  echo "Failed to install OpenSSH on bastion" >&2
  exit 1
fi

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

mkdir -p /shared
if [ -s /shared/bastion_ed25519 ] && [ -s /shared/bastion_ed25519.pub ]; then
  cp /shared/bastion_ed25519 /root/.ssh/id_ed25519
  cp /shared/bastion_ed25519.pub /root/.ssh/id_ed25519.pub
else
  ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
  cp /root/.ssh/id_ed25519 /shared/bastion_ed25519
  cp /root/.ssh/id_ed25519.pub /shared/bastion_ed25519.pub
fi
chmod 600 /root/.ssh/id_ed25519 /shared/bastion_ed25519
chmod 644 /root/.ssh/id_ed25519.pub /shared/bastion_ed25519.pub

/usr/sbin/sshd

cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

/usr/sbin/rsyslogd
