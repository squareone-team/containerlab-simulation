#!/bin/sh
set -eu

hostname bac-server 2>/dev/null || true

# BAC server is only enabled during the BAC period.
ip link add bond0 type bond mode active-backup miimon 100 primary eth1 2>/dev/null || true
ip link set eth1 down || true
ip link set eth2 down || true
ip link set eth1 master bond0 || true
ip link set eth2 master bond0 || true
ip link set eth1 up || true
ip link set eth2 up || true
ip link set bond0 up || true
echo 1 > /sys/class/net/bond0/bonding/all_slaves_active || true
sleep 2
ip addr add 192.168.90.10/24 dev bond0
ip route del default 2>/dev/null || true
ip route add default via 192.168.90.1 dev bond0

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
		ip saddr 192.168.90.0/24 accept
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
*.* @@172.20.20.70:514
RSYSLOG

	/usr/sbin/rsyslogd
else
	echo "WARN: rsyslogd not found, skipping remote syslog forwarding" >&2
fi
