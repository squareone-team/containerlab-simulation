#!/bin/sh
set -eu

# Configuration pour ADMIN-01
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
ip addr add 192.168.50.10/24 dev bond0
ip route del default 2>/dev/null || true
ip route add default via 192.168.50.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

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
		ip saddr 192.168.50.0/24 accept
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
else
	echo "WARN: nft not found, skipping nftables policy setup" >&2
fi

if command -v rsyslogd >/dev/null 2>&1; then
	cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

	/usr/sbin/rsyslogd
elif command -v syslogd >/dev/null 2>&1; then
	mkdir -p /var/log
	touch /var/log/messages
	# Fallback when rsyslog package install fails: use BusyBox syslogd remote forwarding.
	syslogd -L -O /var/log/messages -R 192.168.50.70:514
else
	echo "WARN: no syslog daemon found, skipping remote syslog forwarding" >&2
fi
