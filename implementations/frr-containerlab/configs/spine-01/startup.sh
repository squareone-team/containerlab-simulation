#!/bin/bash
set -e
for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

QOS_LINK_MBIT=1000
QOS_CS6_MBIT=10
QOS_EF_MBIT=50
QOS_AF41_MBIT=200
QOS_AF31_MBIT=250
QOS_AF21_MBIT=200
QOS_AF11_MBIT=100
QOS_CS1_MBIT=50
QOS_DF_MBIT=$((QOS_LINK_MBIT - QOS_CS6_MBIT - QOS_EF_MBIT - QOS_AF41_MBIT - QOS_AF31_MBIT - QOS_AF21_MBIT - QOS_AF11_MBIT - QOS_CS1_MBIT))

apply_spine_qos() {
  local IFACE=$1

  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc add dev "$IFACE" root handle 1: htb default 80
  tc class add dev "$IFACE" parent 1: classid 1:1 htb rate "${QOS_LINK_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit"

  tc class add dev "$IFACE" parent 1:1 classid 1:10 htb rate "${QOS_CS6_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 0
  tc class add dev "$IFACE" parent 1:1 classid 1:20 htb rate "${QOS_EF_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 1
  tc class add dev "$IFACE" parent 1:1 classid 1:30 htb rate "${QOS_AF41_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 2
  tc class add dev "$IFACE" parent 1:1 classid 1:40 htb rate "${QOS_AF31_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 3
  tc class add dev "$IFACE" parent 1:1 classid 1:50 htb rate "${QOS_AF21_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 4
  tc class add dev "$IFACE" parent 1:1 classid 1:60 htb rate "${QOS_AF11_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 5
  tc class add dev "$IFACE" parent 1:1 classid 1:70 htb rate "${QOS_CS1_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 6
  tc class add dev "$IFACE" parent 1:1 classid 1:80 htb rate "${QOS_DF_MBIT}mbit" ceil "${QOS_LINK_MBIT}mbit" prio 7

  tc qdisc add dev "$IFACE" parent 1:10 handle 10: pfifo limit 64
  tc qdisc add dev "$IFACE" parent 1:20 handle 20: pfifo limit 64
  tc qdisc add dev "$IFACE" parent 1:30 handle 30: fq_codel
  tc qdisc add dev "$IFACE" parent 1:40 handle 40: fq_codel ecn
  tc qdisc add dev "$IFACE" parent 1:50 handle 50: fq_codel
  tc qdisc add dev "$IFACE" parent 1:60 handle 60: fq_codel
  tc qdisc add dev "$IFACE" parent 1:70 handle 70: fq_codel
  tc qdisc add dev "$IFACE" parent 1:80 handle 80: fq_codel

  tc filter add dev "$IFACE" parent 1: protocol ip prio 10 u32 match ip dsfield 0xc0 0xfc flowid 1:10
  tc filter add dev "$IFACE" parent 1: protocol ip prio 20 u32 match ip dsfield 0xb8 0xfc flowid 1:20
  tc filter add dev "$IFACE" parent 1: protocol ip prio 30 u32 match ip dsfield 0x88 0xfc flowid 1:30
  tc filter add dev "$IFACE" parent 1: protocol ip prio 40 u32 match ip dsfield 0x68 0xfc flowid 1:40
  tc filter add dev "$IFACE" parent 1: protocol ip prio 50 u32 match ip dsfield 0x48 0xfc flowid 1:50
  tc filter add dev "$IFACE" parent 1: protocol ip prio 60 u32 match ip dsfield 0x28 0xfc flowid 1:60
  tc filter add dev "$IFACE" parent 1: protocol ip prio 70 u32 match ip dsfield 0x20 0xfc flowid 1:70
}

for IFACE in eth1 eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9 eth10; do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    apply_spine_qos "$IFACE"
  fi
done

# RING 3: Configure iptables to allow BGP and BFD from the expected sources, and SSH from the management host, while dropping other traffic to these ports.
iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j DROP

for BFD_PORT in 3784 3785 4784; do
  iptables -A INPUT -p udp --dport "$BFD_PORT" -s 10.0.0.0/16 -j ACCEPT
  iptables -A INPUT -p udp --dport "$BFD_PORT" -j DROP
done

iptables -A INPUT -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

# Ring 4: OOB management for bastion-only SSH
OOB_IF="eth11"
ip addr replace 172.16.0.11/24 dev "$OOB_IF"
ip link set "$OOB_IF" up

# Ring 4: enable SSH daemon for bastion management
if ! command -v sshd >/dev/null 2>&1; then
  echo "Failed to install OpenSSH server on $(hostname)" >&2
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
if grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
fi

/usr/sbin/sshd

iptables -C INPUT -i "$OOB_IF" -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$OOB_IF" -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -C INPUT -i "$OOB_IF" -p tcp --dport 22 -j DROP 2>/dev/null || iptables -A INPUT -i "$OOB_IF" -p tcp --dport 22 -j DROP

cat > /etc/rsyslog.conf << 'RSYSLOG'
module(load="imuxsock")
*.* @@192.168.50.70:514
RSYSLOG

/usr/sbin/rsyslogd

# === NTP CLIENT ===
# Chrony is preinstalled in the lab image

# Write client config
cat > /etc/chrony.conf << 'EOF'
# Sync from lab NTP server (stratum 2)
server 192.168.50.20 iburst prefer minpoll 0 maxpoll 2
# Fallback: if NTP server unreachable, use local clock at high stratum
local stratum 10
# Accept clock step on first 3 syncs
makestep 1.0 3
# Accept the lab local source quickly; tests enforce resulting clock offset < 1s
maxdistance 16.0
logdir /var/log/chrony
log measurements statistics tracking
EOF

mkdir -p /var/log/chrony

# Start chronyd in background — use & and not exec so startup.sh continues
sleep 5
chronyd -f /etc/chrony.conf &


# SNMP 
# ── rp_filter: loose mode (not disabled) ────────────────────────────────────
sysctl -w net.ipv4.conf.all.rp_filter=2      2>/dev/null || true
sysctl -w net.ipv4.conf.eth1.rp_filter=2     2>/dev/null || true
sysctl -w net.ipv4.conf.eth2.rp_filter=2     2>/dev/null || true
# Do NOT set accept_local=1 — that was papering over the wrong binding

# ── Wait for FRR to assign the loopback IP (health check only) ───────────────
echo "[snmp] waiting for FRR loopback IP..."
RETRIES=30
MY_IP=""
while [ $RETRIES -gt 0 ]; do
    MY_IP=$(ip addr show lo 2>/dev/null \
        | grep 'inet ' \
        | awk '{print $2}' \
        | cut -d/ -f1 \
    | grep -v '^127\.' || true)
    [ -n "$MY_IP" ] && break
    sleep 2
    RETRIES=$((RETRIES - 1))
done

if [ -z "$MY_IP" ]; then
    echo "[snmp] WARNING: FRR loopback IP never appeared on lo — FRR may have failed"
    MY_IP="<unknown>"
fi
echo "[snmp] FRR loopback IP: $MY_IP"

mkdir -p /etc/snmp /var/run/net-snmp /var/agentx
chmod 770 /var/agentx           # NOT 777 — agentx refuses world-writable sockets

# ── snmpd.conf ───────────────────────────────────────────────────────────────
# agentAddress udp:161  — listen on ALL interfaces (0.0.0.0:161)
# This is the critical fix. The SNMP request arrives on eth1/eth2 from
# zabbix-server. snmpd must be listening on those interfaces, not just lo.
# The rocommunity ACL still restricts who can actually poll.
cat > /etc/snmp/snmpd.conf << 'EOF'
# Listen on all interfaces — packets arrive on eth1/eth2, not on lo
agentAddress udp:161
 
# Community — restrict by source subnet
rocommunity esi-read 10.0.0.0/8
rocommunity esi-read 192.168.0.0/16
rocommunity esi-read 172.16.0.0/12
 
# System info
sysLocation ESI-Datacenter-Lab
sysContact  noc@esi.internal
sysServices 72
 
# AgentX — FRR subagent connects here to expose BGP/routing MIBs
master agentx
agentXSocket /var/agentx/master
pass_persist .1.3.6.1.2.1.15.3 /usr/local/bin/frr-bgp-peer-mib.py
 
# MIB views — expose standard MIBs that Zabbix polls
view systemview included .1.3.6.1.2.1.1
view systemview included .1.3.6.1.2.1.2
view systemview included .1.3.6.1.2.1.4
view systemview included .1.3.6.1.4.1.2021
EOF

# ── Start snmpd ──────────────────────────────────────────────────────────────
snmpd -C -c /etc/snmp/snmpd.conf -Lf /var/log/snmpd.log &
sleep 2

if pgrep snmpd > /dev/null; then
    echo "[snmp] snmpd started — listening on 0.0.0.0:161"
else
    echo "[snmp] ERROR: snmpd failed to start — check /var/log/snmpd.log"
    cat /var/log/snmpd.log 2>/dev/null || true
fi