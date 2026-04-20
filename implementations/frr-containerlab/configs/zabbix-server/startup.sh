#!/bin/sh
# configs/zabbix-server/startup.sh
# NO set -e — mysqld_safe runs in background; set -e would kill the script
#             when mysqld_safe returns immediately after forking.

log() { echo "[zabbix] $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — NETWORK
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 1: network ==="

wait_for_iface() {
    local iface=$1 retries=20
    while [ $retries -gt 0 ]; do
        ip link show "$iface" > /dev/null 2>&1 && return 0
        log "waiting for $iface..."
        sleep 2
        retries=$((retries - 1))
    done
    return 1
}

if wait_for_iface eth1; then
    ip addr add 192.168.50.50/24 dev eth1 2>/dev/null || true
    ip link set eth1 up

    # Gateway = leaf-03 VRF-STAFF SVI
    ip route add default         via 192.168.50.1 dev eth1 2>/dev/null || true

    # Explicit routes so Zabbix can reach loopbacks (10.1.0.x) once leaf-03
    # leaks them into VRF-STAFF via "import vrf default" in frr.conf
    ip route add 10.0.0.0/8     via 192.168.50.1 dev eth1 2>/dev/null || true
    ip route add 172.16.0.0/12  via 192.168.50.1 dev eth1 2>/dev/null || true
    ip route add 192.168.0.0/16 via 192.168.50.1 dev eth1 2>/dev/null || true

    log "network OK — 192.168.50.50/24, GW 192.168.50.1"
else
    log "WARNING: eth1 never appeared"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 2: packages ==="
log "packages provided by prebuilt image"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — MARIADB
# KEY FIX: mysqld_safe forks into background immediately.
# We must wait for the SOCKET FILE to appear before running any mysql commands.
# set -e would exit right after mysqld_safe returns — do not use it.
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 3: MariaDB ==="

mkdir -p /var/lib/mysql /run/mysqld /var/log/mysql
chown -R mysql:mysql /var/lib/mysql /run/mysqld /var/log/mysql 2>/dev/null || true

if [ ! -d /var/lib/mysql/zabbix ]; then
    log "initializing MariaDB data directory..."
    if [ -d /var/lib/mysql/mysql ] && [ ! -d /var/lib/mysql/zabbix ]; then
        echo "[zabbix] stale MariaDB data detected — cleaning up"
        rm -rf /var/lib/mysql/*
    fi
    mysql_install_db \
    --user=mysql \
    --datadir=/var/lib/mysql \
    --skip-test-db \
    > /var/log/mysql/install.log 2>&1
    # Show last 5 lines so errors are visible in clab logs
    tail -5 /var/log/mysql/install.log

    log "starting MariaDB (bootstrap)..."
    mysqld_safe \
        --user=mysql \
        --socket=/run/mysqld/mysqld.sock \
        --skip-networking \
        > /var/log/mysql/mysqld.log 2>&1 &

    # Wait for the socket — this is the CORRECT way to detect mysqld is ready
    log "waiting for MariaDB socket..."
    RETRIES=40
    while [ $RETRIES -gt 0 ]; do
        [ -S /run/mysqld/mysqld.sock ] && break
        sleep 1
        RETRIES=$((RETRIES - 1))
    done
    if [ $RETRIES -eq 0 ]; then
        log "ERROR: MariaDB socket never appeared"
        cat /var/log/mysql/mysqld.log 2>/dev/null | tail -20
        sleep infinity
    fi
    log "MariaDB socket ready"

    log "creating database and user..."
    mysql -u root --socket=/run/mysqld/mysqld.sock << 'SQL'
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY 'zabbix-lab-pass';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL

    log "importing Zabbix schema..."
    # Alpine's zabbix-server-mysql puts SQL files in one of these locations:
    SCHEMA_DIR=""
    for d in \
        /usr/share/zabbix-server-mysql \
        /usr/share/doc/zabbix-server-mysql \
        /usr/share/zabbix/sql/mysql \
        /usr/share/zabbix-server; do
        if [ -f "$d/schema.sql" ] || [ -f "$d/schema.sql.gz" ]; then
            SCHEMA_DIR="$d"
            break
        fi
    done

    if [ -z "$SCHEMA_DIR" ]; then
        # Last resort: search everywhere
        SCHEMA_DIR=$(find /usr/share -name "schema.sql*" 2>/dev/null \
            | head -1 | xargs dirname 2>/dev/null)
    fi

    if [ -n "$SCHEMA_DIR" ]; then
        log "schema dir: $SCHEMA_DIR"
        for f in schema images data; do
            if [ -f "$SCHEMA_DIR/${f}.sql.gz" ]; then
                zcat "$SCHEMA_DIR/${f}.sql.gz" \
                    | mysql -u zabbix -pzabbix-lab-pass \
                            --socket=/run/mysqld/mysqld.sock zabbix \
                            2>/dev/null || true
                log "loaded ${f}.sql.gz"
            elif [ -f "$SCHEMA_DIR/${f}.sql" ]; then
                mysql -u zabbix -pzabbix-lab-pass \
                      --socket=/run/mysqld/mysqld.sock zabbix \
                      < "$SCHEMA_DIR/${f}.sql" 2>/dev/null || true
                log "loaded ${f}.sql"
            fi
        done
        log "schema import done"
    else
        log "WARNING: cannot find Zabbix SQL schema files — DB will be empty"
    fi

    # Shut down bootstrap instance cleanly
    mysqladmin -u root --socket=/run/mysqld/mysqld.sock shutdown 2>/dev/null || true
    sleep 3
fi

# Start MariaDB for real — TCP on 127.0.0.1:3306
log "starting MariaDB (production)..."
mysqld_safe \
    --user=mysql \
    --socket=/run/mysqld/mysqld.sock \
    --bind-address=127.0.0.1 \
    --port=3306 \
    > /var/log/mysql/mysqld.log 2>&1 &

# Wait for socket again
RETRIES=40
while [ $RETRIES -gt 0 ]; do
    [ -S /run/mysqld/mysqld.sock ] && break
    sleep 1
    RETRIES=$((RETRIES - 1))
done

# Wait for TCP to be accepting connections
RETRIES=20
while [ $RETRIES -gt 0 ]; do
    mysql -u zabbix -pzabbix-lab-pass -h 127.0.0.1 \
          -e "SELECT 1;" zabbix > /dev/null 2>&1 && break
    sleep 2
    RETRIES=$((RETRIES - 1))
done
[ $RETRIES -eq 0 ] && log "WARNING: MariaDB TCP not responding" || log "MariaDB ready"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — ZABBIX SERVER CONFIG
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 4: Zabbix config ==="

mkdir -p /var/lib/zabbix /etc/zabbix /var/log/zabbix /run/zabbix
chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix /run/zabbix 2>/dev/null || true

cat > /etc/zabbix/zabbix_server.conf << 'EOF'
DBHost=127.0.0.1
DBPort=3306
DBName=zabbix
DBUser=zabbix
DBPassword=zabbix-lab-pass
LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=10
DebugLevel=3
PidFile=/run/zabbix/zabbix_server.pid
SNMPTrapperFile=/var/log/zabbix/snmptraps.log
StartSNMPTrapper=1
Timeout=30
AlertScriptsPath=/usr/lib/zabbix/alertscripts
ExternalScripts=/usr/lib/zabbix/externalscripts
StartPollers=5
StartPingers=2
StartTrappers=2
StartDiscoverers=1
CacheSize=16M
HistoryCacheSize=8M
TrendCacheSize=4M
ValueCacheSize=8M
EOF

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — SNMP CLIENT CONFIG
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 5: SNMP client ==="
mkdir -p /etc/snmp
cat > /etc/snmp/snmp.conf << 'EOF'
defCommunity esi-read
defVersion   2c
defTimeout   3
defRetries   1
EOF

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — START ZABBIX
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 6: starting Zabbix server ==="
zabbix_server -c /etc/zabbix/zabbix_server.conf
sleep 3

if pgrep zabbix_server > /dev/null 2>&1; then
    log "zabbix_server is UP"
else
    log "ERROR: zabbix_server failed — last 30 lines of log:"
    tail -30 /var/log/zabbix/zabbix_server.log 2>/dev/null || true
fi

# Optional local agent
command -v zabbix_agentd > /dev/null 2>&1 && \
    zabbix_agentd 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — SNMP PRE-FLIGHT (informational, not fatal)
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 7: SNMP reachability check (waiting 15s for BGP convergence) ==="
sleep 15

SWITCH_LOOPBACKS="
10.1.0.1   spine-01
10.1.0.2   spine-02
10.1.0.11  leaf-01
10.1.0.12  leaf-02
10.1.0.13  leaf-03
10.1.0.14  leaf-04
10.1.0.15  leaf-05
10.1.0.16  leaf-06
10.1.0.17  leaf-07
10.1.0.18  leaf-08
10.1.0.19  leaf-09
10.1.0.20  leaf-10
"

printf '%s\n' "$SWITCH_LOOPBACKS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    IP=$(echo "$line"   | awk '{print $1}')
    NAME=$(echo "$line" | awk '{print $2}')
    if ! ping -c1 -W2 "$IP" > /dev/null 2>&1; then
        log "PING  FAIL: $NAME ($IP) — route leak may not be active yet on leaf-03"
        continue
    fi
    if snmpget -v2c -c esi-read -t3 -r1 "$IP" 1.3.6.1.2.1.1.1.0 > /dev/null 2>&1; then
        log "SNMP  OK  : $NAME ($IP)"
    else
        log "SNMP  FAIL: $NAME ($IP) — snmpd may still be starting"
    fi
done

log "=== READY ==="
log "  zabbix-server : 192.168.50.50 | VRF-STAFF | eth1 -> leaf-03:eth10"
log "  MariaDB       : 127.0.0.1:3306 / db=zabbix"
log "  SNMP community: esi-read (v2c)"
log "  Targets       : spine-01/02, leaf-01..10 via loopbacks 10.1.0.x/32"
log "  Route leak    : leaf-03 imports default VRF into VRF-STAFF"

tail -f /var/log/zabbix/zabbix_server.log 2>/dev/null || sleep infinity