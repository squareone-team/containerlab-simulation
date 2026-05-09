#!/bin/sh
# Compact firewall observability summary helper.

set -eu

LOG_FILE="/var/log/fw-live-watch.log"
MODE="all"
SHOW_ALL_RULES=0
RECENT_LINES=12
TOP_FLOWS=8

usage() {
    cat <<'EOF'
Usage: fw-summary.sh [options]

Options:
  --log-only           Show capture-log analysis only
  --rules-only         Show nftables rule counters only
  --all-rules          Include zero-hit rules in rule summaries
  --log-file PATH      Read a different capture log
  --recent N           Show N most recent capture lines (default: 12)
  --top N              Show N top flows (default: 8)
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --log-only)
            MODE="log"
            shift
            ;;
        --rules-only)
            MODE="rules"
            shift
            ;;
        --all-rules)
            SHOW_ALL_RULES=1
            shift
            ;;
        --log-file)
            [ "$#" -ge 2 ] || {
                echo "Missing value for $1" >&2
                exit 1
            }
            LOG_FILE="$2"
            shift 2
            ;;
        --recent)
            [ "$#" -ge 2 ] || {
                echo "Missing value for $1" >&2
                exit 1
            }
            RECENT_LINES="$2"
            shift 2
            ;;
        --top)
            [ "$#" -ge 2 ] || {
                echo "Missing value for $1" >&2
                exit 1
            }
            TOP_FLOWS="$2"
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

section() {
    printf '\n=== %s ===\n' "$1"
}

print_snapshot() {
    role="BACKUP"
    if ip -4 addr show eth1 2>/dev/null | grep -q '192.168.1.254/24'; then
        role="MASTER"
    fi

    section "Firewall Snapshot"
    printf 'Node: %s\n' "$(hostname 2>/dev/null || echo firewall)"
    printf 'Role: %s\n' "${role}"
    printf 'Time: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Log file: %s\n' "${LOG_FILE}"
    if [ -f "${LOG_FILE}" ]; then
        printf 'Captured lines: %s\n' "$(wc -l < "${LOG_FILE}")"
    else
        printf 'Captured lines: 0\n'
    fi
}

print_log_summary() {
    if [ ! -s "${LOG_FILE}" ]; then
        section "Capture Summary"
        printf 'No capture log found at %s. Run fw-live-watch.sh first.\n' "${LOG_FILE}"
        return
    fi

    section "Capture Summary"
    printf "%8s %-8s %-14s %s\n" "COUNT" "ACTION" "PROTO" "CHAIN"
    awk -F'[][]' '
    /^\[/ {
        proto = $8
        action = $10
        chain = $12
        sub(/^PROTO /, "", proto)
        sub(/^ACTION /, "", action)
        sub(/^CHAIN /, "", chain)
        counts[action "|" proto "|" chain]++
    }
    END {
        for (key in counts) {
            split(key, parts, "|")
            printf "%8d %-8s %-14s %s\n", counts[key], parts[1], parts[2], parts[3]
        }
    }' "${LOG_FILE}" | sort -nr

    section "Top Flows"
    awk -F'[][]' '
    /^\[/ {
        src = $4
        dst = $6
        proto = $8
        action = $10
        sub(/^SRC /, "", src)
        sub(/^DST /, "", dst)
        sub(/^PROTO /, "", proto)
        sub(/^ACTION /, "", action)
        flow = src " -> " dst " [" proto "] [" action "]"
        counts[flow]++
    }
    END {
        for (flow in counts) {
            printf "%8d %s\n", counts[flow], flow
        }
    }' "${LOG_FILE}" | sort -nr | head -n "${TOP_FLOWS}"

    section "Recent Events"
    tail -n "${RECENT_LINES}" "${LOG_FILE}"
}

print_chain_summary() {
    chain_name="$1"

    section "Rule Counters: ${chain_name}"
    printf "%10s %12s %-8s %s\n" "PACKETS" "BYTES" "ACTION" "RULE"
    nft list chain inet filter "${chain_name}" 2>/dev/null | awk -v show_all="${SHOW_ALL_RULES}" '
    /counter packets/ {
        line = $0
        sub(/^[ \t]+/, "", line)

        packets = 0
        bytes = 0
        action = "OTHER"
        rule = line

        if (match(line, /counter packets [0-9]+ bytes [0-9]+/)) {
            counts = substr(line, RSTART, RLENGTH)
            split(counts, parts, " ")
            packets = parts[3] + 0
            bytes = parts[5] + 0
        }

        if (!show_all && packets == 0) {
            next
        }

        if (line ~ / accept$/) {
            action = "ACCEPT"
        } else if (line ~ / drop$/) {
            action = "DROP"
        } else if (line ~ / reject/) {
            action = "REJECT"
        } else if (line ~ / queue/) {
            action = "QUEUE"
        }

        sub(/^counter packets [0-9]+ bytes [0-9]+ /, "", rule)
        sub(/ counter packets [0-9]+ bytes [0-9]+/, "", rule)
        printf "%10d %12d %-8s %s\n", packets, bytes, action, rule
        totals[action] += packets
        shown++
    }
    END {
        if (shown == 0) {
            print "No matching rules for this view."
            exit
        }

        print ""
        print "Action totals:"
        for (name in totals) {
            printf "%-8s %d packets\n", name, totals[name]
        }
    }'
}

print_snapshot

case "${MODE}" in
    all)
        print_log_summary
        print_chain_summary input
        print_chain_summary forward
        ;;
    log)
        print_log_summary
        ;;
    rules)
        print_chain_summary input
        print_chain_summary forward
        ;;
esac
