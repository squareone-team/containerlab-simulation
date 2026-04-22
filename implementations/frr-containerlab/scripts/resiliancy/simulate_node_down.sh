#!/usr/bin/env bash
# ============================================================================
# simulate_node_down.sh — Containerlab Spine-Leaf resilience testing tool
#
# Simulates node outages by admin-toggling every topology link on the target
# node.  Containers keep running; only interfaces are toggled via FRR/vtysh
# (leaf-*/spine-*) or kernel ip-link (firewalls, servers, …).
#
# Bugs fixed vs original:
#   • collect_links: handles BOTH inline and block YAML endpoint formats
#   • list_topology_nodes: robust indent-agnostic awk (no hardcoded 4-space)
#   • get_container_name: jq-first JSON parsing with awk fallback
#   • verify_interface_state: NO-CARRIER state added; sh -lc replaced with
#     ip -o directly (works in minimal containers); timeout 15→20 s
#   • has_frr(): dynamic vtysh probe instead of name-pattern-only check
#   • LINK_ROWS: empty-entry filtering after mapfile
#   • Shared-link isolation guard (--force to override)
#   • State tracking: records which nodes are currently isolated
#   • Convergence wait with countdown (--wait / --no-wait)
#   • --status: shows currently isolated nodes
#   • --list: now shows [ISOLATED] marker
#   • Action info line was using broken $() substitution in original
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOPOLOGY_FILE="$LAB_ROOT/esi-datacenter.clab.yml"

TARGET_NODE=""
RESTORE=0
DRY_RUN=0
LIST_ONLY=0
STATUS_ONLY=0
WAIT_CONVERGENCE=1
CONVERGENCE_WAIT=0    # 0 = auto (uses WAIT_TOTAL_DEFAULT)
FORCE=0

# State dir survives reboots if XDG_RUNTIME_DIR is set, otherwise /tmp
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/clab-resilience"

# ── convergence timing constants (seconds) ──────────────────────────────────
# BFD:            3 × min-rx  (default 300 ms intervals → ~1 s)
# BGP w/ BFD:     session drop (<1 s) + EVPN withdrawal (~2-4 s)  → ~5 s
# BGP w/o BFD:    hold-timer (90 s default, 9 s with aggressive timers)
# LACP fast:      3 × 1 s PDU → 3 s  (link-down triggers immediate anyway)
# LACP slow:      3 × 30 s PDU → 90 s
# EVPN ESI:       Type-1 EAD withdrawal + re-advert + MAC/IP flush → ~8 s
# Safe default with BFD+aggressive-BGP configured: 15 s outage / 20 s restore
WAIT_DEFAULT_DOWN=15
WAIT_DEFAULT_UP=20

DOCKER_CMD=()

# ── usage ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") --node <name> [OPTIONS]
       $(basename "$0") --list   [--topology <file>]
       $(basename "$0") --status [--topology <file>]

Simulate a node outage by administratively disabling every topology-defined
link on the target node.  Containers keep running; only interfaces are toggled.
Use --restore to bring links back up.

Options:
  --node <name>        Node to isolate or restore
  --restore            Bring the node's topology links back up
  --dry-run            Print commands without executing them
  --no-wait            Skip post-toggle convergence wait
  --wait <seconds>     Override convergence wait time (default: auto)
  --force              Allow isolating a node whose peer is already isolated
  --list               List topology nodes and link counts
  --status             Show nodes currently marked as isolated
  --topology <file>    Override the default topology file
  -h, --help           Show this help

Node-type detection (controls how interfaces are toggled):
  FRR/vtysh : nodes named leaf-*/spine-*/router-*/pe-*/p-*
              OR any node where 'vtysh' is found in its container
  ip-link   : everything else (firewalls, servers, OOB, …)

Recommended convergence wait times (applied automatically):
  BFD detection                  ~1 s   (3 × 300 ms default interval)
  BGP session teardown (w/ BFD)  ~2 s
  EVPN MAC-IP withdrawal         ~3-5 s
  ESI failover (Type-1 EAD)      ~5-8 s
  LACP fast / slow               ~3 s / ~90 s
  ─────────────────────────────────────────────────────
  Outage simulation default      ${WAIT_DEFAULT_DOWN} s  (assumes BFD + fast BGP timers)
  Restore default                ${WAIT_DEFAULT_UP} s  (extra time for re-convergence)
  Without BFD                    use --wait 120 minimum

Examples:
  $(basename "$0") --list
  $(basename "$0") --status
  $(basename "$0") --node leaf-01
  $(basename "$0") --node leaf-01 --restore
  $(basename "$0") --node spine-01 --dry-run
  $(basename "$0") --node firewall-01 --wait 10
  $(basename "$0") --node leaf-02 --no-wait          # fire-and-forget
  $(basename "$0") --node leaf-03 --wait 120          # no BFD environment
EOF
}

# ── logging ──────────────────────────────────────────────────────────────────
info()    { echo "[INFO]  $*"; }
warn()    { echo "[WARN]  $*" >&2; }
die()     { echo "[ERROR] $*" >&2; exit 1; }
section() { printf '\n=== %s ===\n' "$*"; }

# ── argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      [[ $# -ge 2 ]] || die "Missing value for --node"
      TARGET_NODE="$2"; shift 2 ;;
    --restore)
      RESTORE=1; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    --no-wait)
      WAIT_CONVERGENCE=0; shift ;;
    --wait)
      [[ $# -ge 2 ]] || die "Missing value for --wait"
      CONVERGENCE_WAIT="$2"
      [[ "$CONVERGENCE_WAIT" =~ ^[0-9]+$ ]] || die "--wait must be a positive integer"
      shift 2 ;;
    --force)
      FORCE=1; shift ;;
    --list)
      LIST_ONLY=1; shift ;;
    --status)
      STATUS_ONLY=1; shift ;;
    --topology)
      [[ $# -ge 2 ]] || die "Missing value for --topology"
      TOPOLOGY_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      if [[ "$1" == -* ]]; then
        die "Unknown argument: $1"
      fi
      if [[ -z "$TARGET_NODE" ]]; then
        TARGET_NODE="$1"; shift
      else
        die "Unknown argument: $1"
      fi ;;
  esac
done

# ── topology bootstrap ───────────────────────────────────────────────────────
[[ -f "$TOPOLOGY_FILE" ]] || die "Topology file not found: $TOPOLOGY_FILE"

LAB_NAME="$(awk '/^name:[[:space:]]*/ { print $2; exit }' "$TOPOLOGY_FILE")"
[[ -n "$LAB_NAME" ]] || die "Could not determine lab name from $TOPOLOGY_FILE"

TOPOLOGY_DATA_FILE="$(dirname "$TOPOLOGY_FILE")/clab-${LAB_NAME}/topology-data.json"
STATE_FILE="$STATE_DIR/${LAB_NAME}.json"

# ── state file helpers ───────────────────────────────────────────────────────
state_init() {
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || printf '{"isolated":[]}\n' > "$STATE_FILE"
}

# Add node to isolated list (idempotent)
state_add() {
  local node="$1"
  if command -v jq &>/dev/null; then
    local tmp; tmp="$(mktemp)"
    jq --arg n "$node" '
      if (.isolated | index($n)) == null
      then .isolated += [$n]
      else .
      end' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    # Plain-text fallback: one node per line
    local lf="${STATE_FILE%.json}.list"
    touch "$lf"
    grep -qxF -- "$node" "$lf" 2>/dev/null || echo "$node" >> "$lf"
  fi
}

# Remove node from isolated list
state_remove() {
  local node="$1"
  if command -v jq &>/dev/null; then
    local tmp; tmp="$(mktemp)"
    jq --arg n "$node" '.isolated |= map(select(. != $n))' \
      "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    local lf="${STATE_FILE%.json}.list"
    [[ -f "$lf" ]] && sed -i "/^${node}$/d" "$lf" || true
  fi
}

# Print currently isolated nodes, one per line
state_list_isolated() {
  if command -v jq &>/dev/null && [[ -f "$STATE_FILE" ]]; then
    jq -r '.isolated[]' "$STATE_FILE" 2>/dev/null || true
  elif [[ -f "${STATE_FILE%.json}.list" ]]; then
    cat "${STATE_FILE%.json}.list"
  fi
}

state_is_isolated() {
  state_list_isolated | grep -qxF -- "$1" 2>/dev/null
}

# ── topology parsing ─────────────────────────────────────────────────────────

# Robust node list: matches any indented "name:" key under the nodes: block.
# Works regardless of whether indentation is 2, 4, or 6 spaces.
list_topology_nodes() {
  awk '
    function leading_ws_len(s, t) {
      t = s
      sub(/^[[:space:]]+/, "", t)
      return length(s) - length(t)
    }

    /^[[:space:]]*nodes:[[:space:]]*$/ {
      in_nodes=1
      nodes_indent=leading_ws_len($0)
      next
    }

    in_nodes {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) {
        next
      }

      indent = leading_ws_len($0)

      # Reached the next sibling/top-level block.
      if (indent <= nodes_indent) {
        exit
      }

      if (indent == nodes_indent + 2 &&
          match($0, /^[[:space:]]*([A-Za-z0-9_-]+):[[:space:]]*$/, m)) {
        print m[1]
      }
    }
  ' "$TOPOLOGY_FILE"
}

node_exists() {
  list_topology_nodes | grep -qxF -- "$1"
}

# Collect all topology links for a node.
# Handles BOTH yaml formats:
#   Inline:  endpoints: ["a:eth1", "b:eth2"]
#   Block :  endpoints:
#              - "a:eth1"
#              - "b:eth2"
#
# Output (TSV): local_node  local_iface  peer_node  peer_iface
collect_links() {
  local node="$1"
  awk -v node="$node" '
    /^[[:space:]]*links:[[:space:]]*$/ { in_links=1; ep_count=0; delete ep; next }
    !in_links { next }

    # ── inline format ────────────────────────────────────────────────────
    match($0, /endpoints:[[:space:]]*\[[[:space:]]*"([^"]+)",[[:space:]]*"([^"]+)"[[:space:]]*\]/, m) {
      split(m[1], left,  ":")
      split(m[2], right, ":")
      if      (left[1]  == node) printf "%s\t%s\t%s\t%s\n", left[1],  left[2],  right[1], right[2]
      else if (right[1] == node) printf "%s\t%s\t%s\t%s\n", right[1], right[2], left[1],  left[2]
      ep_count = 0; delete ep
      next
    }

    # ── block format — reset accumulator on new endpoints: key ───────────
    /endpoints:[[:space:]]*$/ { ep_count = 0; delete ep; next }

    # ── block format — collect "  - \"node:iface\"" lines ───────────────
    match($0, /^[[:space:]]*-[[:space:]]+"([^"]+)"/, m) {
      ep[ep_count++] = m[1]
      if (ep_count == 2) {
        split(ep[0], left,  ":")
        split(ep[1], right, ":")
        if      (left[1]  == node) printf "%s\t%s\t%s\t%s\n", left[1],  left[2],  right[1], right[2]
        else if (right[1] == node) printf "%s\t%s\t%s\t%s\n", right[1], right[2], left[1],  left[2]
        ep_count = 0; delete ep
      }
      next
    }

    # ── block format — handle single-quoted variants ─────────────────────
    match($0, /^[[:space:]]*-[[:space:]]+"'"'"'([^'"'"']+)'"'"'"/, m) {
      ep[ep_count++] = m[1]
      if (ep_count == 2) {
        split(ep[0], left,  ":")
        split(ep[1], right, ":")
        if      (left[1]  == node) printf "%s\t%s\t%s\t%s\n", left[1],  left[2],  right[1], right[2]
        else if (right[1] == node) printf "%s\t%s\t%s\t%s\n", right[1], right[2], left[1],  left[2]
        ep_count = 0; delete ep
      }
      next
    }
  ' "$TOPOLOGY_FILE"
}

list_nodes() {
  while read -r node_name; do
    [[ -n "$node_name" ]] || continue
    local link_count marker=""
    link_count="$(collect_links "$node_name" | wc -l | tr -d ' ')"
    state_is_isolated "$node_name" && marker=" [ISOLATED]" || true
    printf "%-26s %2s links%s\n" "$node_name" "$link_count" "$marker"
  done < <(list_topology_nodes | sort)
}

# ── docker helpers ───────────────────────────────────────────────────────────
resolve_docker_cmd() {
  if docker ps >/dev/null 2>&1; then
    DOCKER_CMD=(docker); return
  fi
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n docker); return
  fi
  # In dry-run we don't need real access
  (( DRY_RUN )) && { DOCKER_CMD=(docker); return; }
  die "Docker access required. Run as docker-group user or grant passwordless sudo."
}

get_container_name() {
  local node="$1" longname=""

  # Preferred: jq parse of topology-data.json
  if [[ -f "$TOPOLOGY_DATA_FILE" ]] && command -v jq &>/dev/null; then
    longname="$(jq -r --arg n "$node" \
      '.nodes | to_entries[] | select(.value.shortname == $n) | .value.longname' \
      "$TOPOLOGY_DATA_FILE" 2>/dev/null | head -1)"
  fi

  # Fallback: awk parse (handles both old and new clab JSON schema)
  if [[ -z "$longname" ]] && [[ -f "$TOPOLOGY_DATA_FILE" ]]; then
    longname="$(awk -v node="$node" -F'"' '
      $2 == "shortname" && $4 == node { found=1; next }
      found && $2 == "longname" { print $4; found=0; exit }
    ' "$TOPOLOGY_DATA_FILE")"
  fi

  [[ -n "$longname" ]] && { printf '%s\n' "$longname"; return; }

  # Last resort: conventional clab naming
  printf 'clab-%s-%s\n' "$LAB_NAME" "$node"
}

run_container_cmd() {
  local container="$1"; shift
  local cmd=( "${DOCKER_CMD[@]}" exec "$container" "$@" )
  if (( DRY_RUN )); then
    printf '[DRY-RUN]'; printf ' %q' "${cmd[@]}"; printf '\n'
    return 0
  fi
  "${cmd[@]}"
}

run_in_node() {
  local node="$1"; shift
  run_container_cmd "$(get_container_name "$node")" "$@"
}

# ── route snapshot/restore for ip-link toggles ─────────────────────────────
# Some minimal nodes (notably firewalls) lose static routes when an interface
# is brought down. Snapshot before down, and restore after up.
route_state_file() {
  local node="$1" iface="$2"
  local safe_node safe_iface
  safe_node="${node//[^A-Za-z0-9_.-]/_}"
  safe_iface="${iface//[^A-Za-z0-9_.-]/_}"
  printf '%s/%s.%s.%s.routes\n' "$STATE_DIR" "$LAB_NAME" "$safe_node" "$safe_iface"
}

snapshot_static_routes() {
  local node="$1" iface="$2" rf
  (( DRY_RUN )) && return 0

  rf="$(route_state_file "$node" "$iface")"
  run_in_node "$node" ip -4 route show table main dev "$iface" proto static \
    > "$rf" 2>/dev/null || true
}

restore_static_routes() {
  local node="$1" iface="$2" rf line
  (( DRY_RUN )) && return 0

  rf="$(route_state_file "$node" "$iface")"
  [[ -s "$rf" ]] || return 0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    # Split route tokens for docker exec argv-safe passing.
    local parts=()
    read -r -a parts <<< "$line"

    if ! run_in_node "$node" ip -4 route replace "${parts[@]}"; then
      warn "Could not restore static route on $node ($iface): $line"
    fi
  done < "$rf"

  rm -f "$rf"
}

ensure_node_post_restore_routes() {
  local node="$1" iface="$2" gw=""
  (( DRY_RUN )) && return 0

  # Ring1 firewalls rely on a static transit route that can disappear when
  # eth1 is toggled down/up. Re-assert it on restore.
  [[ "$iface" == "eth1" ]] || return 0
  case "$node" in
    firewall-01) gw="192.168.1.252" ;;
    firewall-02) gw="192.168.1.253" ;;
    *) return 0 ;;
  esac

  if ! run_in_node "$node" ip -4 route replace 192.168.0.0/16 via "$gw" dev "$iface"; then
    warn "Could not ensure static transit route on $node via $gw dev $iface"
  fi
}

# ── node type detection ──────────────────────────────────────────────────────
# Returns 0 if the node runs FRR (vtysh available); 1 otherwise.
# Name-based fast path covers the common case without a docker exec probe.
_frr_cache=()   # associative array emulated via parallel indexed arrays
_frr_keys=()
_frr_vals=()

has_frr() {
  local node="$1" i

  # Check name-pattern fast path first
  case "$node" in
    leaf-*|spine-*|router-*|pe-*|p-*|rr-*)
      return 0 ;;
  esac

  # Check in-process cache
  for (( i=0; i<${#_frr_keys[@]}; i++ )); do
    if [[ "${_frr_keys[$i]}" == "$node" ]]; then
      return "${_frr_vals[$i]}"
    fi
  done

  # Dynamic probe (one exec per uncached node)
  local result=1
  if (( ! DRY_RUN )); then
    run_in_node "$node" sh -c 'command -v vtysh >/dev/null 2>&1' && result=0 || true
  fi
  _frr_keys+=("$node")
  _frr_vals+=("$result")
  return "$result"
}

# ── FRR / kernel interface toggle ────────────────────────────────────────────
run_vtysh_interface_cmd() {
  local node="$1" iface="$2" action="$3"
  local output="" filtered="" status=0

  if (( DRY_RUN )); then
    run_in_node "$node" vtysh \
      -c "configure terminal" -c "interface $iface" -c "$action" -c "end"
    return 0
  fi

  output="$(run_in_node "$node" vtysh \
    -c "configure terminal" \
    -c "interface $iface" \
    -c "$action" \
    -c "end" 2>&1)" || status=$?

  # Strip known harmless vtysh noise
  filtered="$(printf '%s\n' "$output" | sed \
    -e "/^% Can't open configuration file \/etc\/frr\/vtysh.conf due to 'No such file or directory'\.$/d" \
    -e '/^[[:space:]]*$/d')"

  if (( status != 0 )); then
    [[ -n "$filtered" ]] && printf '%s\n' "$filtered" >&2
    return "$status"
  fi
  [[ -n "$filtered" ]] && printf '%s\n' "$filtered" >&2
  return 0
}

# BUG FIX: original used "sh -lc" which is absent in many minimal containers.
# We now call "ip -o link show dev" directly without a shell wrapper.
# Added NO-CARRIER to the set of accepted "down" states.
verify_interface_state() {
  local node="$1" iface="$2" expected="$3"
  local state="" flags="" line="" tries=20   # 20 × 1 s = 20 s max

  (( DRY_RUN )) && return 0

  while (( tries > 0 )); do
    line="$(run_in_node "$node" ip -o link show dev "$iface" 2>/dev/null || true)"

    state="$(printf '%s\n' "$line" | awk '{
      for (i=1; i<=NF; i++)
        if ($i == "state") { print $(i+1); exit }
    }' || true)"

    flags="$(printf '%s\n' "$line" | sed -n 's/.*<\([^>]*\)>.*/\1/p' | tr '[:lower:]' '[:upper:]')"

    case "$expected:${state^^}" in
      down:DOWN|down:LOWERLAYERDOWN|down:NO-CARRIER) return 0 ;;
      up:UP|up:UNKNOWN)                               return 0 ;;
    esac

    # For restore, admin-UP with no carrier is still expected if peer side
    # remains down (shared-link isolation restored in stages).
    if [[ "$expected" == "up" && ",${flags}," == *,UP,* ]]; then
      return 0
    fi

    sleep 1
    tries=$(( tries - 1 ))
  done

  warn "Interface $node:$iface did not reach expected state '$expected' (last state: '$state', flags: '${flags:-n/a}')"
  return 1
}

toggle_local_interface() {
  local node="$1" iface="$2" peer="$3" peer_iface="$4" state="$5"
  local action_label action_cmd ip_state

  if [[ "$state" == "up" ]]; then
    action_label="Restoring"
    action_cmd="no shutdown"
    ip_state="up"
  else
    action_label="Disabling"
    action_cmd="shutdown"
    ip_state="down"
  fi

  info "$action_label  $node:$iface  ↔  $peer:$peer_iface"

  if has_frr "$node"; then
    if ! run_vtysh_interface_cmd "$node" "$iface" "$action_cmd"; then
      warn "vtysh failed for $node:$iface — applying kernel ip-link fallback"

      [[ "$state" == "down" ]] && snapshot_static_routes "$node" "$iface"
      run_in_node "$node" ip link set dev "$iface" "$ip_state"
      if [[ "$state" == "up" ]]; then
        restore_static_routes "$node" "$iface"
        ensure_node_post_restore_routes "$node" "$iface"
      fi
    fi
  else
    [[ "$state" == "down" ]] && snapshot_static_routes "$node" "$iface"
    run_in_node "$node" ip link set dev "$iface" "$ip_state"
    if [[ "$state" == "up" ]]; then
      restore_static_routes "$node" "$iface"
      ensure_node_post_restore_routes "$node" "$iface"
    fi
  fi

  if ! verify_interface_state "$node" "$iface" "$ip_state"; then
    if has_frr "$node"; then
      warn "FRR state did not converge for $node:$iface — kernel fallback"
      run_in_node "$node" ip link set dev "$iface" "$ip_state"
      verify_interface_state "$node" "$iface" "$ip_state" \
        || die "Interface $node:$iface refused to reach state '$ip_state'"
    else
      die "Interface $node:$iface refused to reach state '$ip_state'"
    fi
  fi
}

# ── convergence countdown ────────────────────────────────────────────────────
do_convergence_wait() {
  local default_secs="$1"   # caller passes WAIT_DEFAULT_DOWN or _UP

  (( DRY_RUN )) && return 0
  (( WAIT_CONVERGENCE == 0 )) && return 0

  local secs="${CONVERGENCE_WAIT:-0}"
  (( secs == 0 )) && secs="$default_secs"

  info "Waiting ${secs}s for protocol convergence (BFD → BGP → EVPN/ESI) …"
  local remaining="$secs"
  while (( remaining > 0 )); do
    printf "\r  %3ds remaining …" "$remaining"
    sleep 1
    remaining=$(( remaining - 1 ))
  done
  printf "\r  Convergence wait complete.          \n"
}

# ── safety guard: shared-link isolation check ────────────────────────────────
# If node A and node B share a link and BOTH are isolated, restoring A first
# will attempt "no shutdown" into a still-down peer — that is safe (the
# interface state will be UP on A's side once restored).  However, toggling
# BOTH sides of the same link to DOWN is technically harmless but can confuse
# operators.  We warn and require --force.
check_shared_isolation() {
  local node="$1"
  local -a already_isolated=()

  while read -r iso; do
    [[ -n "$iso" ]] && already_isolated+=("$iso")
  done < <(state_list_isolated)

  (( ${#already_isolated[@]} == 0 )) && return 0

  local -a shared=()
  while IFS=$'\t' read -r _ _ peer _; do
    for iso in "${already_isolated[@]}"; do
      [[ "$peer" == "$iso" ]] && shared+=("$iso")
    done
  done < <(collect_links "$node")

  if (( ${#shared[@]} > 0 )); then
    warn "Node '$node' shares topology links with already-isolated node(s): ${shared[*]}"
    warn "This means BOTH ends of at least one link will be admin-down."
    warn "Restoration order matters: restore peers before '$node' (or vice-versa)."
    if (( ! FORCE )); then
      die "Use --force to proceed, or restore ${shared[*]} first."
    fi
    warn "--force specified — proceeding despite shared isolation."
  fi
}

# ── --status display ─────────────────────────────────────────────────────────
show_status() {
  local -a nodes=()
  while read -r n; do [[ -n "$n" ]] && nodes+=("$n"); done < <(state_list_isolated)

  if (( ${#nodes[@]} == 0 )); then
    echo "No nodes are currently marked as isolated (state: $STATE_FILE)."
    return
  fi

  echo "Currently isolated nodes (state: $STATE_FILE)"
  echo "─────────────────────────────────────────────────"
  for n in "${nodes[@]}"; do
    local lc; lc="$(collect_links "$n" 2>/dev/null | wc -l | tr -d ' ')"
    printf "  %-26s %s topology link(s) disabled\n" "$n" "$lc"
  done
  echo
  echo "Restore with:  $(basename "$0") --node <name> --restore"
  echo
  echo "Suggested restore order (innermost/peer first):"
  local i=${#nodes[@]}
  while (( i-- > 0 )); do
    printf "  %d. $(basename "$0") --node %s --restore\n" \
           "$(( ${#nodes[@]} - i ))" "${nodes[$i]}"
  done
}

# ── link-row sanitiser ───────────────────────────────────────────────────────
# mapfile can capture trailing empty strings; strip them.
sanitise_rows() {
  local -a out=()
  local row
  for row in "${LINK_ROWS[@]}"; do
    [[ -n "$row" ]] && out+=("$row")
  done
  LINK_ROWS=("${out[@]}")
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
state_init

if (( LIST_ONLY )); then
  list_nodes
  exit 0
fi

if (( STATUS_ONLY )); then
  show_status
  exit 0
fi

[[ -n "$TARGET_NODE" ]] || die "Provide --node <name>, --list, or --status"
node_exists "$TARGET_NODE"  || die "Node '$TARGET_NODE' not found in $TOPOLOGY_FILE"

mapfile -t LINK_ROWS < <(collect_links "$TARGET_NODE")
sanitise_rows
(( ${#LINK_ROWS[@]} > 0 )) || die "No topology links found for node '$TARGET_NODE'"

# ── pre-flight checks ────────────────────────────────────────────────────────
if (( ! RESTORE )); then
  check_shared_isolation "$TARGET_NODE"
fi

if (( RESTORE )) && ! state_is_isolated "$TARGET_NODE"; then
  warn "Node '$TARGET_NODE' is not in the isolated-node state file."
  warn "Proceeding anyway (interfaces may already be up)."
fi

resolve_docker_cmd

# ── summary ──────────────────────────────────────────────────────────────────
section "Resilience test — $(date '+%Y-%m-%d %H:%M:%S')"
info "Topology   : $TOPOLOGY_FILE"
info "Lab name   : $LAB_NAME"
info "Target node: $TARGET_NODE"
info "Links found: ${#LINK_ROWS[@]}"
if (( RESTORE )); then
  info "Action     : RESTORE — bringing topology links back UP"
else
  info "Action     : ISOLATE — admin-disabling all topology links"
fi
if has_frr "$TARGET_NODE" 2>/dev/null; then
  info "Node type  : FRR/vtysh (graceful interface shutdown)"
else
  info "Node type  : kernel ip-link"
fi
echo

# ── toggle all links ─────────────────────────────────────────────────────────
STATE="down"
(( RESTORE )) && STATE="up"

for row in "${LINK_ROWS[@]}"; do
  IFS=$'\t' read -r node node_iface peer peer_iface <<<"$row"
  toggle_local_interface "$node" "$node_iface" "$peer" "$peer_iface" "$STATE"
done

echo

# ── update state & wait ──────────────────────────────────────────────────────
if (( RESTORE )); then
  (( DRY_RUN )) || state_remove "$TARGET_NODE"
  do_convergence_wait "$WAIT_DEFAULT_UP"
  if (( DRY_RUN )); then
    info "✓ Dry-run complete — no interface or state changes were applied"
  else
    info "✓ Restore complete — $TARGET_NODE is back in topology"
  fi
else
  (( DRY_RUN )) || state_add "$TARGET_NODE"
  do_convergence_wait "$WAIT_DEFAULT_DOWN"
  if (( DRY_RUN )); then
    info "✓ Dry-run complete — no interface or state changes were applied"
    info "  Execute without --dry-run to isolate $TARGET_NODE"
  else
    info "✓ Outage simulation active — $TARGET_NODE is isolated"
    info "  Restore with: $(basename "$0") --node $TARGET_NODE --restore"
    info "  Check state : $(basename "$0") --status"
  fi
fi
