#!/bin/sh
set -eu

# Configuration pour STUDENT-01
ip link add bond0 type bond mode active-backup miimon 100 primary eth1
ip link set eth1 down
ip link set eth2 down
ip link set eth1 master bond0
ip link set eth2 master bond0
ip link set eth1 up
ip link set eth2 up
ip link set bond0 up
echo 1 > /sys/class/net/bond0/bonding/all_slaves_active
sleep 2
ip addr add 192.168.10.10/24 dev bond0
ip route del default 2>/dev/null || true
ip route add default via 192.168.10.1 dev bond0

if command -v nft >/dev/null 2>&1; then
    cat > /etc/nftables.conf << 'NFT'
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0;
        policy drop;
        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        ip saddr { 192.168.50.0/24, 192.168.60.0/24 } tcp dport 9100 accept
        ip saddr 192.168.10.0/24 accept
        ip saddr 172.20.20.0/24 tcp dport 22 accept
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
else
    echo "WARN: nft not found, skipping nftables policy setup" >&2
fi

if command -v rsyslogd >/dev/null 2>&1; then
    cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG
    /usr/sbin/rsyslogd
else
    echo "WARN: rsyslogd not found, skipping remote syslog forwarding" >&2
fi

# ── SSH ──
mkdir -p /run/sshd /root/.ssh /etc/pam.d
ssh-keygen -A

# On s'assure que UsePAM est activé (CRUCIAL)
if grep -q '^UsePAM' /etc/ssh/sshd_config; then
    sed -i 's/^UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
else
    echo 'UsePAM yes' >> /etc/ssh/sshd_config
fi


if grep -q '^PasswordAuthentication' /etc/ssh/sshd_config; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
else
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
fi
if grep -q '^KbdInteractiveAuthentication' /etc/ssh/sshd_config; then
    sed -i 's/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
else
    echo 'KbdInteractiveAuthentication yes' >> /etc/ssh/sshd_config
fi
#if grep -q '^AuthenticationMethods' /etc/ssh/sshd_config; then
  #  sed -i 's/^AuthenticationMethods.*/AuthenticationMethods password/' /etc/ssh/sshd_config
#else
  #  echo 'AuthenticationMethods password' >> /etc/ssh/sshd_config
#fi

# ── SCRIPT TACACS+ ──
mkdir -p /usr/local/bin

cat > /usr/local/bin/tacacs-auth.py << 'PYEOF'
#!/usr/bin/env python3
import sys, os
from tacacs_plus.client import TACACSClient

TACACS_HOST = "172.20.20.50"
TACACS_PORT = 49
TACACS_SECRET = "ESI@Secret2024"

username = os.environ.get("PAM_USER", "")

# Lire SEULEMENT depuis stdin
raw = sys.stdin.buffer.read()

# Garder seulement ASCII imprimable
password = ''.join(chr(b) for b in raw if 32 <= b <= 126)

with open('/tmp/debug.log', 'a') as f:
    f.write(f"user={username}\n")
    f.write(f"raw_hex={raw.hex()}\n")
    f.write(f"pass_clean={password}\n")
    f.write(f"pass_len={len(password)}\n")
try:
    client = TACACSClient(TACACS_HOST, TACACS_PORT, TACACS_SECRET, timeout=5)
    auth = client.authenticate(username, password)
    with open('/tmp/debug.log', 'a') as f:
        f.write(f"valid={auth.valid} status={auth.status}\n")
    sys.exit(0 if auth.valid else 1)
except Exception as e:
    with open('/tmp/debug.log', 'a') as f:
        f.write(f"error={e}\n")
    sys.exit(1)
PYEOF
chmod +x /usr/local/bin/tacacs-auth.py

# ── CONFIG PAM ──
cat > /etc/pam.d/sshd << 'EOF'
auth      required    pam_exec.so expose_authtok /usr/bin/python3 /usr/local/bin/tacacs-auth.py
account   required    pam_permit.so
session   required    pam_permit.so
EOF

# ── DÉMARRER SSH ──
pkill sshd || true
/usr/sbin/sshd.pam

echo "server-student-01 ready with TACACS+ auth (via sshd.pam)"