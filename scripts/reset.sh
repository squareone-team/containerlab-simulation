#!/usr/bin/env bash
# =============================================================================
#  reset.sh — ESI Datacenter Lab Config Reset (all implementations)
#
#  Usage:
#    ./scripts/reset.sh                             # reset all nodes in ALL implementations
#    ./scripts/reset.sh --impl frr-containerlab     # reset all nodes in one implementation
#    ./scripts/reset.sh --impl frr-containerlab --node spine-01  # reset single node
#    ./scripts/reset.sh --dry-run                   # preview only, no changes
#    ./scripts/reset.sh --snapshot                  # force-recreate all snapshots
#    ./scripts/reset.sh --help
#
#  Supported implementations (auto-detected from implementations/ folder):
#    frr-containerlab
#    arista-containerlab
#    arista-ansible
#
#  Snapshot location:
#    .config-backups/<implementation>/initial/
#
#  First-run behaviour:
#    If no snapshot exists for an implementation, one is created automatically.
#    Commit .config-backups/ to git once — teammates get it on clone, no setup needed.
#=====================================================================================

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMPLEMENTATIONS_DIR="${REPO_ROOT}/implementations"
BACKUPS_ROOT="${REPO_ROOT}/.config-backups"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*" >&2; }
header()  { echo -e "\n${BOLD}── $* ──${NC}"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC} $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
FORCE_SNAPSHOT=false
TARGET_IMPL=""
TARGET_NODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --snapshot)  FORCE_SNAPSHOT=true ;;
    --impl)      TARGET_IMPL="$2"; shift ;;
    --node)      TARGET_NODE="$2"; shift ;;
    --help|-h)
      echo ""
      echo "Usage: $0 [--impl <name>] [--node <name>] [--dry-run] [--snapshot]"
      echo ""
      echo "  (no args)                      Reset ALL nodes in ALL active implementations"
      echo "  --impl <name>                  Target a specific implementation only"
      echo "  --node <name>                  Target a single node (requires --impl)"
      echo "  --dry-run                      Preview changes without touching any file"
      echo "  --snapshot                     Force-recreate snapshots from current configs"
      echo "  --help                         Show this message"
      echo ""
      echo "Examples:"
      echo "  $0                                           # reset everything"
      echo "  $0 --impl frr-containerlab                  # reset FRR only"
      echo "  $0 --impl frr-containerlab --node leaf-01   # reset one node"
      echo "  $0 --dry-run                                # preview all"
      echo "  $0 --snapshot                               # re-snapshot everything"
      echo ""
      exit 0 ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
  shift
done

# ── Validate --node requires --impl ───────────────────────────────────────────
if [[ -n "$TARGET_NODE" && -z "$TARGET_IMPL" ]]; then
  error "--node requires --impl"
  echo "  Example: $0 --impl frr-containerlab --node leaf-01"
  exit 1
fi

# ── Node definitions per implementation ───────────────────────────────────────
declare -A IMPL_NODES
IMPL_NODES["frr-containerlab"]="spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 border-01 border-02"
IMPL_NODES["arista-containerlab"]="spine-01 spine-02 leaf-01 leaf-02 leaf-03 leaf-04 border-01 border-02"
IMPL_NODES["arista-ansible"]=""

# ── Check if an implementation is active (has actual configs) ─────────────────
impl_is_active() {
  local impl=$1
  local configs_dir
  configs_dir="$(impl_configs_dir "$impl")"

  # For ansible: check if inventory/ exists
  if [[ "$impl" == "arista-ansible" ]]; then
    [[ -d "${configs_dir}/inventory" ]] && return 0 || return 1
  fi

  # For containerlab: check if at least one node folder exists
  local nodes="${IMPL_NODES[$impl]:-}"
  for node in $nodes; do
    [[ -d "${configs_dir}/${node}" ]] && return 0
  done
  return 1
}

# ── Files expected per node ───────────────────────────────────────────────────
node_files() {
  local impl=$1
  local node=$2
  case "$impl" in
    frr-containerlab)
      case "$node" in
        spine-*)  echo "daemons frr.conf" ;;
        leaf-*)   echo "daemons frr.conf startup.sh" ;;
        border-*) echo "daemons frr.conf startup.sh" ;;
      esac ;;
    arista-containerlab)
      echo "startup-config" ;;
  esac
}

# ── Where configs live per implementation ─────────────────────────────────────
impl_configs_dir() {
  local impl=$1
  case "$impl" in
    frr-containerlab|arista-containerlab)
      echo "${IMPLEMENTATIONS_DIR}/${impl}/configs" ;;
    arista-ansible)
      echo "${IMPLEMENTATIONS_DIR}/${impl}" ;;
  esac
}

# ── Container name prefix per implementation ──────────────────────────────────
impl_container_prefix() {
  case "$1" in
    frr-containerlab)    echo "clab-esi-datacenter" ;;
    arista-containerlab) echo "clab-esi-arista" ;;
    *)                   echo "" ;;
  esac
}

# ── Discover implementations ──────────────────────────────────────────────────
get_implementations() {
  if [[ -d "$IMPLEMENTATIONS_DIR" ]]; then
    ls -1 "$IMPLEMENTATIONS_DIR"
  else
    error "implementations/ directory not found at $IMPLEMENTATIONS_DIR"
    exit 1
  fi
}

# ── Snapshot one implementation ───────────────────────────────────────────────
snapshot_implementation() {
  local impl=$1
  local auto=${2:-false}
  local snapshot_dir="${BACKUPS_ROOT}/${impl}/initial"
  local configs_dir
  configs_dir="$(impl_configs_dir "$impl")"

  # Skip if configs don't exist yet
  if ! impl_is_active "$impl"; then
    skip "[$impl] No configs found — skipping snapshot (placeholder implementation)"
    return
  fi

  if [[ -d "$snapshot_dir" && "$auto" == "false" ]]; then
    warn "[$impl] Snapshot already exists."
    read -r -p "  Overwrite? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "[$impl] Snapshot unchanged."; return; }
    rm -rf "$snapshot_dir"
  fi

  mkdir -p "$snapshot_dir"

  if [[ "$impl" == "arista-ansible" ]]; then
    for folder in inventory playbooks roles; do
      local src="${configs_dir}/${folder}"
      [[ -d "$src" ]] && cp -r "$src" "${snapshot_dir}/${folder}" && success "  [$impl] Snapshotted $folder/"
    done
  else
    local nodes="${IMPL_NODES[$impl]:-}"
    local found=0
    for node in $nodes; do
      local src="${configs_dir}/${node}"
      if [[ -d "$src" ]]; then
        cp -r "$src" "${snapshot_dir}/${node}"
        success "  [$impl] Snapshotted $node"
        ((found++)) || true
      fi
    done
    [[ $found -eq 0 ]] && warn "[$impl] No node directories found in $configs_dir"
  fi
}

# ── Reset a single node ───────────────────────────────────────────────────────
reset_node() {
  local impl=$1
  local node=$2
  local snapshot_dir="${BACKUPS_ROOT}/${impl}/initial"
  local configs_dir
  configs_dir="$(impl_configs_dir "$impl")"
  local src="${snapshot_dir}/${node}"
  local dst="${configs_dir}/${node}"

  if [[ ! -d "$src" ]]; then
    error "[$impl] No snapshot for $node"
    return 1
  fi

  info "[$impl] Resetting ${BOLD}${node}${NC} ..."
  for f in $(node_files "$impl" "$node"); do
    local from="${src}/${f}"
    local to="${dst}/${f}"
    if [[ -f "$from" ]]; then
      if $DRY_RUN; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC}  would restore: $f"
      else
        cp "$from" "$to"
        success "  Restored $f"
      fi
    else
      warn "  $f not in snapshot — skipping"
    fi
  done
}

# ── Restart container after reset ─────────────────────────────────────────────
restart_container() {
  local impl=$1
  local node=$2
  local prefix
  prefix="$(impl_container_prefix "$impl")"
  [[ -z "$prefix" ]] && return

  local cname="${prefix}-${node}"
  if docker inspect "$cname" &>/dev/null 2>&1; then
    if $DRY_RUN; then
      echo -e "  ${YELLOW}[DRY-RUN]${NC}  would restart: $cname"
    else
      info "  Restarting $cname ..."
      # Capture docker errors but don't fail the whole script
      if docker restart "$cname" >/dev/null 2>&1; then
        success "  Container restarted"
      else
        warn "  Container restart had an issue — redeploy may be needed:"
        warn "  sudo containerlab destroy -t spin-topology.clab.yml"
        warn "  sudo containerlab deploy  -t spin-topology.clab.yml"
      fi
    fi
  else
    warn "  $cname not running — config applies on next deploy"
  fi
}

# ── Process one full implementation ───────────────────────────────────────────
process_implementation() {
  local impl=$1
  local snapshot_dir="${BACKUPS_ROOT}/${impl}/initial"

  header "$impl"

  # Skip placeholder implementations that have no configs yet
  if ! impl_is_active "$impl"; then
    skip "[$impl] No configs yet — skipping (add configs to activate)"
    return 0
  fi

  # Auto-snapshot if none exists
  if [[ ! -d "$snapshot_dir" ]]; then
    info "[$impl] No snapshot found — creating automatically ..."
    snapshot_implementation "$impl" true
    echo ""
  fi

  # Ansible: restore folders instead of per-node files
  if [[ "$impl" == "arista-ansible" ]]; then
    local configs_dir
    configs_dir="$(impl_configs_dir "$impl")"
    for folder in inventory playbooks roles; do
      local src="${snapshot_dir}/${folder}"
      local dst="${configs_dir}/${folder}"
      if [[ -d "$src" ]]; then
        if $DRY_RUN; then
          echo -e "  ${YELLOW}[DRY-RUN]${NC}  would restore: $folder/"
        else
          rm -rf "$dst" && cp -r "$src" "$dst"
          success "  [$impl] Restored $folder/"
        fi
      fi
    done
    return 0
  fi

  # ContainerLab: reset per node
  local nodes_str="${IMPL_NODES[$impl]:-}"
  local nodes_to_reset=()

  if [[ -n "$TARGET_NODE" ]]; then
    if [[ " $nodes_str " == *" $TARGET_NODE "* ]]; then
      nodes_to_reset=("$TARGET_NODE")
    else
      error "[$impl] Unknown node: '$TARGET_NODE'"
      echo "  Valid nodes: $nodes_str"
      return 1
    fi
  else
    read -r -a nodes_to_reset <<< "$nodes_str"
  fi

  local errors=0
  for node in "${nodes_to_reset[@]}"; do
    if reset_node "$impl" "$node"; then
      restart_container "$impl" "$node"
    else
      ((errors++)) || true
    fi
    echo ""
  done
  return $errors
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════

# Handle --snapshot flag
if $FORCE_SNAPSHOT; then
  impls="${TARGET_IMPL:-$(get_implementations)}"
  for impl in $impls; do
    snapshot_implementation "$impl" false
  done
  echo ""
  info "Commit snapshots to git so teammates don't need to run --snapshot:"
  echo -e "  ${CYAN}git add .config-backups/${NC}"
  echo -e "  ${CYAN}git commit -m 'chore: update config snapshots'${NC}"
  exit 0
fi

# ── Print header ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}   ESI Datacenter — Config Reset            ${NC}"
$DRY_RUN && \
echo -e "${YELLOW}   DRY-RUN mode — no files changed          ${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"

# ── Determine which implementations to process ────────────────────────────────
if [[ -n "$TARGET_IMPL" ]]; then
  IMPLS_TO_PROCESS=("$TARGET_IMPL")
else
  mapfile -t IMPLS_TO_PROCESS < <(get_implementations)
fi

# ── Run ───────────────────────────────────────────────────────────────────────
TOTAL_ERRORS=0
for impl in "${IMPLS_TO_PROCESS[@]}"; do
  if [[ ! -d "${IMPLEMENTATIONS_DIR}/${impl}" ]]; then
    warn "Implementation folder not found: $impl — skipping"
    continue
  fi
  process_implementation "$impl" || ((TOTAL_ERRORS++)) || true
done

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════${NC}"
if [[ $TOTAL_ERRORS -eq 0 ]]; then
  if $DRY_RUN; then
    warn "Dry-run complete — no files were changed."
  else
    success "All active configs restored to clean baseline ✔"
    echo ""
    info "If BGP sessions don't recover, clear them:"
    echo -e "  ${CYAN}docker exec -it clab-esi-datacenter-spine-01 vtysh -c 'clear bgp *'${NC}"
  fi
else
  error "$TOTAL_ERRORS implementation(s) had errors. Check output above."
  exit 1
fi
echo -e "${BOLD}════════════════════════════════════════════${NC}"