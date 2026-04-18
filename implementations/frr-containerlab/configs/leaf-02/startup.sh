#!/bin/bash
set -e
VTEP_IP="10.1.0.12"
ANYCAST_MAC="00:00:00:11:11:11"

for IFACE in eth1 eth2; do
  ip link set dev $IFACE mtu 9000 || true
done
sysctl -w net.ipv4.fib_multipath_hash_policy=1

# RING 3: Allow BGP and BFD from known peer subnets, SSH from management subnet, and VTEP control traffic from all leafs. Drop all other attempts to connect to these services on the leaf itself.
iptables -A INPUT -p tcp --dport 179 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -s 203.0.113.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -s 203.0.114.0/30 -j ACCEPT
iptables -A INPUT -p tcp --dport 179 -j DROP

for BFD_PORT in 3784 3785 4784; do
  iptables -A INPUT -p udp --dport "$BFD_PORT" -s 10.0.0.0/16 -j ACCEPT
  iptables -A INPUT -p udp --dport "$BFD_PORT" -j DROP
done

iptables -A INPUT -p tcp --dport 22 -s 172.16.0.50 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

for AUTH_VTEP in 10.1.0.1 10.1.0.2 10.1.0.11 10.1.0.12 10.1.0.13 10.1.0.14 10.1.0.15 10.1.0.16 10.1.0.17 10.1.0.18 10.1.0.19 10.1.0.20; do
  iptables -A INPUT -p udp --dport 4789 -s "$AUTH_VTEP" -j ACCEPT
done
iptables -A INPUT -p udp --dport 4789 -j DROP

ip link add VRF-PEDAGOGY type vrf table 30
ip link set VRF-PEDAGOGY up
ip link add VRF-STAFF type vrf table 20
ip link set VRF-STAFF up
ip link add VRF-PUBLIC type vrf table 40
ip link set VRF-PUBLIC up
ip link add VRF-ORIENTATION type vrf table 50
ip link set VRF-ORIENTATION up
for IFACE in eth3 eth4 eth5 eth6 eth9; do
  ip link set dev $IFACE mtu 9000 || true
done

ip link add br-fw-ha type bridge vlan_filtering 1 vlan_default_pvid 1
ip link set br-fw-ha mtu 9000
ip link set br-fw-ha up
ip link set eth5 master br-fw-ha
ip link set eth9 master br-fw-ha
ip link set eth5 up
ip link set eth9 up
ip addr add 192.168.1.253/24 dev br-fw-ha

# Policy routing for packets returning from the firewall transit segment.
ip rule add iif br-fw-ha to 192.168.10.0/24 lookup 30 prio 10000 || true
ip rule add iif br-fw-ha to 192.168.20.0/24 lookup 30 prio 10001 || true
ip rule add iif br-fw-ha to 192.168.50.0/24 lookup 20 prio 10002 || true
ip rule add iif br-fw-ha to 192.168.60.0/24 lookup 20 prio 10003 || true
ip rule add iif br-fw-ha from 192.168.50.0/24 lookup 30 prio 10010 || true
ip rule add iif br-fw-ha from 192.168.60.0/24 lookup 30 prio 10011 || true
ip rule add iif br-fw-ha from 192.168.10.0/24 lookup 20 prio 10012 || true
ip rule add iif br-fw-ha from 192.168.20.0/24 lookup 20 prio 10013 || true
ip rule add iif br-fw-ha from 192.168.70.0/24 lookup 20 prio 10014 || true
ip rule add iif br-fw-ha from 192.168.80.0/24 lookup 20 prio 10015 || true

ip link add br0 type bridge vlan_filtering 1 vlan_default_pvid 0
ip link set br0 mtu 9000
ip link set br0 up

for V in 10090 10100; do
  ip link add vxlan$V type vxlan id $V local $VTEP_IP dstport 4789 nolearning tos inherit
  ip link set vxlan$V mtu 9000
  ip link set vxlan$V master br0
  ip link set vxlan$V up
done
bridge vlan add vid 90 dev vxlan10090 pvid untagged
bridge vlan add vid 100 dev vxlan10100 pvid untagged
bridge vlan add vid 90 dev br0 self
bridge vlan add vid 100 dev br0 self
bridge vlan add vid 4020 dev br0 self
bridge vlan add vid 4030 dev br0 self

ip link add vxlan50020 type vxlan id 50020 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50020 mtu 9000
ip link set vxlan50020 master br0
ip link set vxlan50020 up
bridge vlan add vid 4020 dev vxlan50020 pvid untagged

ip link add vxlan50030 type vxlan id 50030 local $VTEP_IP dstport 4789 nolearning tos inherit
ip link set vxlan50030 mtu 9000
ip link set vxlan50030 master br0
ip link set vxlan50030 up
bridge vlan add vid 4030 dev vxlan50030 pvid untagged

ip link add vlan4020 link br0 type vlan id 4020
ip link set vlan4020 master VRF-STAFF
ip link set vlan4020 up

ip link add vlan4030 link br0 type vlan id 4030
ip link set vlan4030 master VRF-PEDAGOGY
ip link set vlan4030 up

# === END PHASE 1 — Phase 2 appends below ===

# Ring 4: OOB management for bastion-only SSH
OOB_IF="eth10"
ip addr replace 172.16.0.22/24 dev "$OOB_IF"
ip link set "$OOB_IF" up

# Ring 4: enable SSH daemon for bastion management
for i in 1 2 3 4 5 6 7 8 9 10; do
  if apk update >/dev/null 2>&1 && apk add --no-cache openssh-server openssh-client rsyslog >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

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
# Install chrony
apk add --no-cache chrony

# Write client config
cat > /etc/chrony.conf << 'EOF'
# Sync from lab NTP server (stratum 2)
server 192.168.50.20 iburst prefer
# Fallback: if NTP server unreachable, use local clock at high stratum
local stratum 10
# Accept clock step on first 3 syncs
makestep 1.0 3
# Maximum skew allowed before chrony refuses to sync (forensic requirement: < 1s)
maxdistance 1.0
logdir /var/log/chrony
log measurements statistics tracking
EOF

mkdir -p /var/log/chrony

# Start chronyd in background — use & and not exec so startup.sh continues
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
        | grep -v '^127\.')
    [ -n "$MY_IP" ] && break
    sleep 2
    RETRIES=$((RETRIES - 1))
done

if [ -z "$MY_IP" ]; then
    echo "[snmp] WARNING: FRR loopback IP never appeared on lo — FRR may have failed"
    MY_IP="<unknown>"
fi
echo "[snmp] FRR loopback IP: $MY_IP"

# ── Install net-snmp ─────────────────────────────────────────────────────────
echo "[snmp] installing net-snmp..."
echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories
apk update
apk add --no-cache \
    --repository https://dl-cdn.alpinelinux.org/alpine/v3.20/community \
    net-snmp net-snmp-tools

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