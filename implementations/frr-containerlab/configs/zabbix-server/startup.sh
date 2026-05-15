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

find_schema_dir() {
    for d in \
        /usr/share/zabbix/database/mysql \
        /usr/share/zabbix-server-mysql \
        /usr/share/doc/zabbix-server-mysql \
        /usr/share/zabbix/sql/mysql \
        /usr/share/zabbix-server; do
        if [ -f "$d/schema.sql" ] || [ -f "$d/schema.sql.gz" ]; then
            echo "$d"
            return 0
        fi
    done

    find /usr/share -name "schema.sql*" 2>/dev/null \
        | grep '/mysql/' \
        | head -1 \
        | xargs dirname 2>/dev/null
}

zabbix_table_count() {
    mysql -u zabbix -pzabbix-lab-pass \
          --socket=/run/mysqld/mysqld.sock \
          -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix';" \
          zabbix 2>/dev/null || echo 0
}

import_zabbix_schema() {
    log "importing Zabbix schema..."
    SCHEMA_DIR="$(find_schema_dir)"

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
}

find_zabbix_web_dir() {
    for d in \
        /usr/share/webapps/zabbix \
        /usr/share/zabbix; do
        if [ -f "$d/index.php" ]; then
            echo "$d"
            return 0
        fi
    done

    find /usr/share -name "index.php" 2>/dev/null \
        | grep '/zabbix' \
        | head -1 \
        | xargs dirname 2>/dev/null
}

ensure_zabbix_db_grants() {
    mysql -u root --socket=/run/mysqld/mysqld.sock << 'SQL' >/dev/null 2>&1
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY 'zabbix-lab-pass';
CREATE USER IF NOT EXISTS 'zabbix'@'127.0.0.1' IDENTIFIED BY 'zabbix-lab-pass';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

configure_zabbix_frontend() {
    ZABBIX_WEB_DIR="$(find_zabbix_web_dir)"
    if [ -z "$ZABBIX_WEB_DIR" ]; then
        log "WARNING: zabbix-webif files not found; web UI will not start"
        return 1
    fi

    ZABBIX_CONF_DIR="$ZABBIX_WEB_DIR/conf"
    if [ -d /etc/zabbix/web ]; then
        ZABBIX_CONF_DIR="/etc/zabbix/web"
    fi

    mkdir -p \
        "$ZABBIX_WEB_DIR/conf" \
        "$ZABBIX_CONF_DIR" \
        /etc/nginx/http.d \
        /etc/php82/conf.d \
        /run/nginx \
        /run/php-fpm82 \
        /var/log/nginx

    cat > "$ZABBIX_CONF_DIR/zabbix.conf.php" << 'EOF'
<?php
global $DB, $HISTORY, $SSO;

$DB['TYPE'] = 'MYSQL';
$DB['SERVER'] = '127.0.0.1';
$DB['PORT'] = '3306';
$DB['DATABASE'] = 'zabbix';
$DB['USER'] = 'zabbix';
$DB['PASSWORD'] = 'zabbix-lab-pass';
$DB['SCHEMA'] = '';
$DB['ENCRYPTION'] = false;
$DB['KEY_FILE'] = '';
$DB['CERT_FILE'] = '';
$DB['CA_FILE'] = '';
$DB['VERIFY_HOST'] = false;
$DB['CIPHER_LIST'] = '';
$DB['VAULT'] = '';

$HISTORY['url'] = '';
$HISTORY['types'] = [
    'uint' => 0,
    'text' => 0,
    'log' => 0,
    'str' => 0,
    'dbl' => 0
];

$SSO['SP_KEY'] = '';
$SSO['SP_CERT'] = '';
$SSO['IDP_CERT'] = '';
$SSO['SETTINGS'] = [];

$ZBX_SERVER = '127.0.0.1';
$ZBX_SERVER_PORT = '10051';
$ZBX_SERVER_NAME = 'ESI Datacenter Lab';
$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF

    if [ "$ZABBIX_CONF_DIR" != "$ZABBIX_WEB_DIR/conf" ]; then
        ln -sf "$ZABBIX_CONF_DIR/zabbix.conf.php" \
            "$ZABBIX_WEB_DIR/conf/zabbix.conf.php"
    fi

    cat > /etc/php82/conf.d/99-zabbix.ini << 'EOF'
date.timezone = Africa/Algiers
max_execution_time = 300
max_input_time = 300
memory_limit = 256M
post_max_size = 32M
upload_max_filesize = 16M
session.cookie_httponly = 1
EOF

    if [ -f /etc/php82/php-fpm.d/www.conf ]; then
        sed -i \
            -e 's|^listen = .*|listen = 127.0.0.1:9000|' \
            -e 's|^;clear_env = no|clear_env = no|' \
            /etc/php82/php-fpm.d/www.conf
    fi

    cat > /etc/nginx/http.d/default.conf << EOF
server {
    listen 0.0.0.0:8080 default_server;
    server_name _;
    root $ZABBIX_WEB_DIR;
    index index.php index.html;
    client_max_body_size 16m;

    access_log /var/log/nginx/zabbix-access.log;
    error_log /var/log/nginx/zabbix-error.log warn;

    location = /favicon.ico {
        log_not_found off;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ [^/]\.php(/|\$) {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
EOF

    log "Zabbix frontend configured at $ZABBIX_WEB_DIR"
    return 0
}

start_zabbix_frontend() {
    configure_zabbix_frontend || return 1

    if command -v php-fpm82 >/dev/null 2>&1; then
        php-fpm82 -F > /var/log/zabbix/php-fpm.log 2>&1 &
    else
        log "WARNING: php-fpm82 missing; web UI cannot start"
        return 1
    fi

    sleep 1
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/var/log/nginx/nginx-test.log 2>&1
        if [ $? -eq 0 ]; then
            nginx -g 'daemon off;' > /var/log/nginx/zabbix-frontend.log 2>&1 &
        else
            log "WARNING: nginx config test failed"
            cat /var/log/nginx/nginx-test.log 2>/dev/null | tail -20
            return 1
        fi
    else
        log "WARNING: nginx missing; web UI cannot start"
        return 1
    fi

    RETRIES=30
    while [ $RETRIES -gt 0 ]; do
        curl -fsS http://127.0.0.1:8080/index.php >/dev/null 2>&1 && break
        sleep 2
        RETRIES=$((RETRIES - 1))
    done

    if [ $RETRIES -eq 0 ]; then
        log "WARNING: Zabbix frontend did not answer on 127.0.0.1:8080"
        tail -20 /var/log/nginx/zabbix-error.log 2>/dev/null || true
        return 1
    fi

    log "Zabbix web UI is UP on container port 8080"
    return 0
}

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
CREATE USER IF NOT EXISTS 'zabbix'@'127.0.0.1' IDENTIFIED BY 'zabbix-lab-pass';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

    import_zabbix_schema

    # Shut down bootstrap instance cleanly
    mysqladmin -u root --socket=/run/mysqld/mysqld.sock shutdown 2>/dev/null || true
    sleep 3
fi

# Start MariaDB for real — TCP on 127.0.0.1:3306
log "starting MariaDB (production)..."
mysqld_safe \
    --user=mysql \
    --socket=/run/mysqld/mysqld.sock \
    --skip-networking=0 \
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

ensure_zabbix_db_grants

TABLE_COUNT="$(zabbix_table_count)"
if [ "$TABLE_COUNT" = "0" ]; then
    log "Zabbix database has no tables; importing schema again"
    import_zabbix_schema
fi

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
FpingLocation=/usr/sbin/fping
Fping6Location=/usr/sbin/fping6
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
timeout      3
retries      1
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
# PHASE 7 — ZABBIX WEB FRONTEND
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 7: Zabbix web frontend ==="
if start_zabbix_frontend; then
    log "Web URL       : http://localhost:4000"
    log "Web login     : Admin / zabbix"
else
    log "WARNING: web frontend is not ready; server daemon continues"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — TOPOLOGY PROVISIONING
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 8: Zabbix topology provisioning ==="
if [ -f /opt/zabbix/provision_topology.py ] && command -v python3 >/dev/null 2>&1; then
    python3 /opt/zabbix/provision_topology.py \
        > /var/log/zabbix/provision_topology.log 2>&1
    if [ $? -eq 0 ]; then
        tail -20 /var/log/zabbix/provision_topology.log
    else
        log "WARNING: topology provisioning failed"
        tail -30 /var/log/zabbix/provision_topology.log 2>/dev/null || true
    fi
else
    log "WARNING: topology provisioning script or python3 missing"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 9 — SNMP PRE-FLIGHT (informational, not fatal)
# ─────────────────────────────────────────────────────────────────────────────
log "=== PHASE 9: SNMP reachability check ==="

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
log "  zabbix-server : 192.168.50.50 | VRF-STAFF | eth1 -> leaf-03:eth11"
log "  Zabbix UI     : http://localhost:4000 | login Admin / zabbix"
log "  MariaDB       : 127.0.0.1:3306 / db=zabbix"
log "  SNMP community: esi-read (v2c)"
log "  Targets       : spine-01/02, leaf-01..10 via loopbacks 10.1.0.x/32"
log "  Route leak    : leaf-03 imports default VRF into VRF-STAFF"

tail -f /var/log/zabbix/zabbix_server.log 2>/dev/null || sleep infinity
