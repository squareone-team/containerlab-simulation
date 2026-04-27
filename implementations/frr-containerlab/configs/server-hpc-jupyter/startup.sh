#!/bin/sh
set -eu

# Configuration for dedicated AI/HPC Jupyter server
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
ip addr add 192.168.70.30/24 dev bond0
ip route del default 2>/dev/null || true
ip route add default via 192.168.70.1 dev bond0

cat > /etc/resolv.conf << 'EOF'
search esi.internal
nameserver 192.168.50.30
EOF

mkdir -p /srv/notebooks /var/log/jupyter

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
		ip saddr 192.168.70.0/24 accept
		ip saddr { 192.168.10.0/24, 192.168.20.0/24, 192.168.50.0/24, 192.168.60.0/24 } tcp dport 8080 accept
		ip saddr 172.20.20.0/24 tcp dport 8080 accept
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
else
	echo "WARN: rsyslogd not found, skipping remote syslog forwarding" >&2
fi

JUPYTER_TOKEN="${JUPYTER_TOKEN:-esi-jupyter-demo-token}"
nohup jupyter notebook \
	--ip=0.0.0.0 \
	--port=8080 \
	--no-browser \
	--allow-root \
	--NotebookApp.token="${JUPYTER_TOKEN}" \
	--notebook-dir=/srv/notebooks \
	>/var/log/jupyter/notebook.log 2>&1 &
