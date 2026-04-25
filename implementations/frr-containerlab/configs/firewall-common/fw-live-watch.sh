#!/bin/sh
# Live firewall packet watcher backed by temporary nft tracing.

set -eu

LOG_FILE="/var/log/fw-live-watch.log"
LOCK_DIR="/run/fw-live-watch.lock"
TRACE_TABLE_FAMILY="inet"
TRACE_TABLE_NAME="fwlivewatch"
TRACE_CHAIN_NAME="trace_prerouting"

usage() {
    cat <<'EOF'
Usage: fw-live-watch.sh [--log-file PATH]

Starts a foreground live packet watcher for the firewall.
- Every run overwrites the log file.
- Packets are traced until you stop the script with Ctrl+C.
- Only one watcher can run at a time on each firewall.
EOF
}

cleanup() {
    status=$?
    trap - EXIT INT TERM HUP
    nft delete table "${TRACE_TABLE_FAMILY}" "${TRACE_TABLE_NAME}" >/dev/null 2>&1 || true
    if [ -d "${LOCK_DIR}" ]; then
        rm -f "${LOCK_DIR}/pid" >/dev/null 2>&1 || true
        rmdir "${LOCK_DIR}" >/dev/null 2>&1 || true
    fi
    exit "${status}"
}

acquire_lock() {
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        echo "$$" > "${LOCK_DIR}/pid"
        return 0
    fi

    if [ -f "${LOCK_DIR}/pid" ]; then
        stale_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
        if [ -n "${stale_pid}" ] && kill -0 "${stale_pid}" 2>/dev/null; then
            echo "fw-live-watch.sh is already running with PID ${stale_pid}" >&2
            exit 1
        fi
    fi

    rm -f "${LOCK_DIR}/pid" >/dev/null 2>&1 || true
    rmdir "${LOCK_DIR}" >/dev/null 2>&1 || true

    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        echo "$$" > "${LOCK_DIR}/pid"
        return 0
    fi

    echo "Unable to acquire watcher lock at ${LOCK_DIR}" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -l|--log-file)
            [ "$#" -ge 2 ] || {
                echo "Missing value for $1" >&2
                exit 1
            }
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

trap cleanup EXIT INT TERM HUP

acquire_lock
mkdir -p "$(dirname "${LOG_FILE}")"
: > "${LOG_FILE}"

nft delete table "${TRACE_TABLE_FAMILY}" "${TRACE_TABLE_NAME}" >/dev/null 2>&1 || true
nft add table "${TRACE_TABLE_FAMILY}" "${TRACE_TABLE_NAME}"
nft add chain "${TRACE_TABLE_FAMILY}" "${TRACE_TABLE_NAME}" "${TRACE_CHAIN_NAME}" "{ type filter hook prerouting priority raw; policy accept; }"
nft add rule "${TRACE_TABLE_FAMILY}" "${TRACE_TABLE_NAME}" "${TRACE_CHAIN_NAME}" meta nftrace set 1

echo "Watching firewall decisions live. Press Ctrl+C to stop." >&2
echo "Log file: ${LOG_FILE}" >&2

nft monitor trace | awk '
function service_name(proto, sport, dport,    port) {
    if (proto == "icmp") {
        return "ICMP"
    }
    if (proto == "icmpv6") {
        return "ICMPV6"
    }
    if (proto == "vrrp" || proto == "112") {
        return "VRRP"
    }

    port = dport
    if (service[port] != "") {
        return service[port]
    }

    port = sport
    if (service[port] != "") {
        return service[port]
    }

    return "???"
}

function emit(id, action,    ts, src_ip, dst_ip, src_port, dst_port, proto_label, chain_name) {
    if (done[id]) {
        return
    }

    done[id] = 1
    ts = strftime("%Y-%m-%d %H:%M:%S")
    src_ip = src[id] != "" ? src[id] : "?"
    dst_ip = dst[id] != "" ? dst[id] : "?"
    src_port = sport[id] != "" ? sport[id] : "-"
    dst_port = dport[id] != "" ? dport[id] : "-"
    proto_label = service_name(proto[id], src_port, dst_port)
    chain_name = seen_chain[id] != "" ? seen_chain[id] : "UNKNOWN"

    printf("[%s] [SRC %s:%s] [DST %s:%s] [PROTO %s] [ACTION %s] [CHAIN %s]\n",
        ts, src_ip, src_port, dst_ip, dst_port, proto_label, action, chain_name)
    fflush()

    delete src[id]
    delete dst[id]
    delete sport[id]
    delete dport[id]
    delete proto[id]
    delete seen_chain[id]
    delete done[id]
}

BEGIN {
    service["20"] = "FTP-DATA"
    service["21"] = "FTP"
    service["22"] = "SSH"
    service["23"] = "TELNET"
    service["25"] = "SMTP"
    service["53"] = "DNS"
    service["67"] = "DHCP"
    service["68"] = "DHCP"
    service["69"] = "TFTP"
    service["80"] = "HTTP"
    service["110"] = "POP3"
    service["111"] = "RPCBIND"
    service["123"] = "NTP"
    service["143"] = "IMAP"
    service["161"] = "SNMP"
    service["179"] = "BGP"
    service["389"] = "LDAP"
    service["443"] = "HTTPS"
    service["514"] = "SYSLOG"
    service["636"] = "LDAPS"
    service["2049"] = "NFS"
    service["3260"] = "ISCSI"
    service["3306"] = "MYSQL"
    service["3389"] = "RDP"
    service["5432"] = "POSTGRES"
    service["5672"] = "AMQP"
    service["6818"] = "SLURM"
    service["6819"] = "SLURM"
    service["6820"] = "SLURM"
    service["6821"] = "SLURM"
    service["6822"] = "SLURM"
    service["6823"] = "SLURM"
    service["6824"] = "SLURM"
    service["6825"] = "SLURM"
    service["6826"] = "SLURM"
    service["6827"] = "SLURM"
    service["6828"] = "SLURM"
    service["6829"] = "SLURM"
    service["6830"] = "SLURM"
    service["8080"] = "HTTP-ALT"
    service["8443"] = "HTTPS-ALT"
    service["9100"] = "NODE-EXPORTER"
}

/^trace id / {
    id = $3
    chain = toupper($6)
    if (chain != "") {
        seen_chain[id] = chain
    }
}

/^trace id / && / packet: / {
    src[id] = "?"
    dst[id] = "?"
    sport[id] = "-"
    dport[id] = "-"
    proto[id] = ""

    for (i = 1; i <= NF; i++) {
        if ($i == "ip" && $(i + 1) == "saddr") {
            src[id] = $(i + 2)
        } else if ($i == "ip" && $(i + 1) == "daddr") {
            dst[id] = $(i + 2)
        } else if ($i == "ip6" && $(i + 1) == "saddr") {
            src[id] = $(i + 2)
        } else if ($i == "ip6" && $(i + 1) == "daddr") {
            dst[id] = $(i + 2)
        } else if ($i == "tcp" && $(i + 1) == "sport") {
            sport[id] = $(i + 2)
            proto[id] = "tcp"
        } else if ($i == "tcp" && $(i + 1) == "dport") {
            dport[id] = $(i + 2)
            proto[id] = "tcp"
        } else if ($i == "udp" && $(i + 1) == "sport") {
            sport[id] = $(i + 2)
            proto[id] = "udp"
        } else if ($i == "udp" && $(i + 1) == "dport") {
            dport[id] = $(i + 2)
            proto[id] = "udp"
        } else if ($i == "icmp" && $(i + 1) == "type") {
            proto[id] = "icmp"
        } else if ($i == "icmpv6" && $(i + 1) == "type") {
            proto[id] = "icmpv6"
        } else if ($i == "ip" && $(i + 1) == "protocol" && $(i + 2) == "112") {
            proto[id] = "112"
        } else if ($i == "vrrp") {
            proto[id] = "vrrp"
        }
    }

    next
}

/^trace id / && / policy / {
    action = toupper($NF)
    if (toupper($6) == "TRACE_PREROUTING" && action == "ACCEPT") {
        next
    }

    emit(id, action)
    next
}

/^trace id / && /\(verdict / {
    verdict = $0
    sub(/^.*\(verdict /, "", verdict)
    sub(/\).*/, "", verdict)
    verdict = toupper(verdict)

    if (verdict == "CONTINUE" || verdict == "JUMP" || verdict == "GOTO" || verdict == "RETURN") {
        next
    }

    emit(id, verdict)
}
' | tee -a "${LOG_FILE}"
