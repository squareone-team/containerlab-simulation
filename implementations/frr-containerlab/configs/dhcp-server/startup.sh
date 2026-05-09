#!/bin/sh
set -e

wait_for_iface() {
    local iface=$1
    local retries=15
    while [ $retries -gt 0 ]; do
        ip link show "$iface" > /dev/null 2>&1 && return 0
        echo "[dhcp-server] waiting for $iface..."
        sleep 2
        retries=$((retries - 1))
    done
    return 1
}

wait_for_iface_running() {
  local iface=$1
  local retries=${2:-90}
  while [ "$retries" -gt 0 ]; do
    if ip link show "$iface" > /dev/null 2>&1; then
      local state
      local carrier
      state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo down)"
      carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)"
      if [ "$state" = "up" ] && [ "$carrier" = "1" ]; then
        return 0
      fi
    fi
    sleep 1
    retries=$((retries - 1))
  done
  return 1
}

if wait_for_iface eth1 && wait_for_iface eth2; then
  ip link add bond0 type bond mode active-backup miimon 100 primary eth1 2>/dev/null || true
  ip addr flush dev eth1 2>/dev/null || true
  ip addr flush dev eth2 2>/dev/null || true
  ip link set eth1 down 2>/dev/null || true
  ip link set eth2 down 2>/dev/null || true
  ip link set eth1 master bond0
  ip link set eth2 master bond0
  ip link set eth1 up
  ip link set eth2 up
  ip link set bond0 up
  sleep 2

  ip addr add 192.168.50.40/24 dev bond0 2>/dev/null || true
  ip route add 192.168.0.0/16 via 192.168.50.1 dev bond0 2>/dev/null || true
  ip route add 10.0.0.0/8    via 192.168.50.1 dev bond0 2>/dev/null || true
else
  echo "[dhcp-server] WARNING: eth1/eth2 did not appear for bond0"
fi

if wait_for_iface_running bond0 120; then
  echo "[dhcp-server] bond0 is running with carrier"
else
  echo "[dhcp-server] WARNING: bond0 is not running yet; Kea may fail to bind UDP/67"
fi

mkdir -p /etc/kea /var/log/kea /var/run/kea

cat > /etc/kea/kea-dhcp4.conf << 'EOF'
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["bond0"],
      "dhcp-socket-type": "udp"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv",
      "lfc-interval": 3600
    },
    "valid-lifetime": 86400,
    "renew-timer": 43200,
    "rebind-timer": 75600,
    "option-def": [],
    "option-data": [
      { "name": "domain-name-servers", "data": "192.168.50.30" },
      { "name": "ntp-servers",         "data": "192.168.50.20" },
      { "name": "domain-name",         "data": "esi.internal"  }
    ],
    "subnet4": [
      {
        "id": 10,
        "subnet": "192.168.10.0/24",
        "pools": [{ "pool": "192.168.10.100 - 192.168.10.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.10.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:10:0a", "ip-address": "192.168.10.10",
            "hostname": "server-student-01" }
        ]
      },
      {
        "id": 20,
        "subnet": "192.168.20.0/24",
        "pools": [{ "pool": "192.168.20.100 - 192.168.20.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.20.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:20:0a", "ip-address": "192.168.20.10",
            "hostname": "server-student-02" }
        ]
      },
      {
        "id": 30,
        "subnet": "192.168.30.0/24",
        "pools": [{ "pool": "192.168.30.100 - 192.168.30.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.30.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:30:0a", "ip-address": "192.168.30.10",
            "hostname": "lms-staff" }
        ]
      },
      {
        "id": 40,
        "subnet": "192.168.40.0/24",
        "pools": [{ "pool": "192.168.40.100 - 192.168.40.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.40.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:40:0a", "ip-address": "192.168.40.10",
            "hostname": "services-web" }
        ]
      },
      {
        "id": 50,
        "subnet": "192.168.50.0/24",
        "pools": [{ "pool": "192.168.50.100 - 192.168.50.150" }],
        "option-data": [
          { "name": "routers", "data": "192.168.50.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:50:14", "ip-address": "192.168.50.20",
            "hostname": "ntp-server" },
          { "hw-address": "00:00:00:00:50:1e", "ip-address": "192.168.50.30",
            "hostname": "dns-server" },
          { "hw-address": "00:00:00:00:50:28", "ip-address": "192.168.50.40",
            "hostname": "dhcp-server" },
          { "hw-address": "00:00:00:00:50:32", "ip-address": "192.168.50.50",
            "hostname": "zabbix-server" },
          { "hw-address": "00:00:00:00:50:3c", "ip-address": "192.168.50.60",
            "hostname": "prometheus" },
          { "hw-address": "00:00:00:00:50:46", "ip-address": "192.168.50.70",
            "hostname": "syslog-server" },
          { "hw-address": "00:00:00:00:50:0a", "ip-address": "192.168.50.10",
            "hostname": "server-admin-01" }
        ]
      },
      {
        "id": 60,
        "subnet": "192.168.60.0/24",
        "pools": [{ "pool": "192.168.60.100 - 192.168.60.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.60.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:60:0a", "ip-address": "192.168.60.10",
            "hostname": "server-admin-02" }
        ]
      },
      {
        "id": 70,
        "subnet": "192.168.70.0/24",
        "relay": { "ip-addresses": [ "10.1.0.15", "10.1.0.16" ] },
        "pools": [{ "pool": "192.168.70.100 - 192.168.70.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.70.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:70:0a", "ip-address": "192.168.70.10",
            "hostname": "server-hpc-01" },
          { "hw-address": "00:00:00:00:70:14", "ip-address": "192.168.70.20",
            "hostname": "server-hpc-02" }
        ]
      },
      {
        "id": 80,
        "subnet": "192.168.80.0/24",
        "pools": [{ "pool": "192.168.80.100 - 192.168.80.200" }],
        "option-data": [
          { "name": "routers", "data": "192.168.80.1" }
        ],
        "reservations": [
          { "hw-address": "00:00:00:00:80:0a", "ip-address": "192.168.80.10",
            "hostname": "server-storage-01" }
        ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output_options": [{ "output": "/var/log/kea/kea-dhcp4.log" }],
        "severity": "INFO",
        "debuglevel": 0
      }
    ]
  }
}
EOF

mkdir -p /var/lib/kea

echo "[dhcp-server] validating Kea config..."
kea-dhcp4 -t /etc/kea/kea-dhcp4.conf

echo "[dhcp-server] starting kea-dhcp4..."
kea-dhcp4 -c /etc/kea/kea-dhcp4.conf
