#!/bin/sh
set -eu

hostname vpn-gateway

ip link set eth1 up
ip addr replace 198.51.100.20/24 dev eth1
ip route del default 2>/dev/null || true
ip route add default via 198.51.100.1 dev eth1

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

mkdir -p /etc/wireguard /var/log
mkdir -p /etc/esi-vpn/tls
WG_KEY="/etc/wireguard/server.key"
WG_PUB="/etc/wireguard/server.pub"
WG_PORT="51820"
WG_ADDR="10.250.200.1/24"
VPN_ENROLL_PORT="8448"

if [ ! -f "$WG_KEY" ]; then
  umask 077
  wg genkey | tee "$WG_KEY" | wg pubkey > "$WG_PUB"
fi

if [ ! -f /etc/esi-vpn/tls/vpn.key ] || [ ! -f /etc/esi-vpn/tls/vpn.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/esi-vpn/tls/vpn.key \
    -out /etc/esi-vpn/tls/vpn.crt \
    -days 365 \
    -subj "/C=DZ/ST=Algiers/L=Oued Smar/O=ESI/CN=198.51.100.20" \
    >/dev/null 2>&1
  chmod 600 /etc/esi-vpn/tls/vpn.key
fi

ip link add wg0 type wireguard 2>/dev/null || true
wg set wg0 listen-port "$WG_PORT" private-key "$WG_KEY"
ip addr replace "$WG_ADDR" dev wg0
ip link set wg0 up

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -p udp --dport "$WG_PORT" -j ACCEPT
iptables -A INPUT -p tcp --dport "$VPN_ENROLL_PORT" -j ACCEPT

iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i wg0 -o eth1 -p tcp -d 192.168.10.10 --dport 22 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i wg0 -o eth1 -p tcp -d 192.168.70.10 --dport 22 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i wg0 -o eth1 -p tcp -d 192.168.70.30 --dport 8080 -m conntrack --ctstate NEW -j ACCEPT

iptables -t nat -C POSTROUTING -s 10.250.200.0/24 -o eth1 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s 10.250.200.0/24 -o eth1 -j MASQUERADE

if [ -f /usr/local/bin/esi-vpn-enroll.py ]; then
  ESI_RADIUS_HOST="192.168.50.80" \
  ESI_RADIUS_SECRET="EsiVpnRadius#2026" \
  ESI_RADIUS_NAS_ID="vpn-gateway" \
  ESI_VPN_LISTEN="198.51.100.20" \
  ESI_VPN_PORT="$VPN_ENROLL_PORT" \
  ESI_VPN_TLS="1" \
  ESI_VPN_TLS_CERT="/etc/esi-vpn/tls/vpn.crt" \
  ESI_VPN_TLS_KEY="/etc/esi-vpn/tls/vpn.key" \
  ESI_WG_INTERFACE="wg0" \
  nohup python3 /usr/local/bin/esi-vpn-enroll.py >/var/log/esi-vpn-enroll.log 2>&1 &
fi
