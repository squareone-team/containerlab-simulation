#!/bin/sh
# ==============================================================================
# configs/admin/pam-users-init.sh
# ==============================================================================
# Initialize local Linux users and groups for JupyterHub authentication
# Runs on server-admin-01 during startup
# 
# Creates:
#  - user groups: students, researchers, gpu-users, admins
#  - test users for each group
#  - consistent uid/gid across the infrastructure
#
# Idempotent: safe to run multiple times
# ==============================================================================

set -e

log() { echo "[PAM-INIT] $*"; }
die() { echo "[PAM-INIT] ERROR: $*" >&2; exit 1; }

# ============================================================================
# 1. Create Groups (ensure consistent GIDs for UID/GID mapping)
# ============================================================================

log "Creating user groups..."

# Students group: 5001
getent group students >/dev/null || \
  groupadd -g 5001 students || die "Failed to create students group"

# Researchers group: 5002
getent group researchers >/dev/null || \
  groupadd -g 5002 researchers || die "Failed to create researchers group"

# GPU users group: 5003 (subset of researchers/admins who can access GPU)
getent group gpu-users >/dev/null || \
  groupadd -g 5003 gpu-users || die "Failed to create gpu-users group"

# Admins group: 5004
getent group admins >/dev/null || \
  groupadd -g 5004 admins || die "Failed to create admins group"

log "Groups created/verified"

# ============================================================================
# 2. Create Test Users
# ============================================================================

# Create a generic JupyterHub service account (admin)
create_user_if_missing() {
  local username=$1
  local uid=$2
  local groups=$3
  local home="/home/${username}"
  
  if ! id "$username" >/dev/null 2>&1; then
    useradd -m -u "$uid" -g "$uid" -d "$home" -s /bin/bash "$username" || \
      die "Failed to create user $username"
    log "Created user: $username (uid=$uid, home=$home)"
  else
    log "User exists: $username"
  fi
  
  # Add to supplementary groups if specified
  if [ -n "$groups" ]; then
    for grp in $groups; do
      if getent group "$grp" >/dev/null; then
        usermod -a -G "$grp" "$username" || \
          die "Failed to add $username to group $grp"
      fi
    done
  fi
}

# Admin users: UID 1000+
create_user_if_missing "admin"        1000 "admins gpu-users"
create_user_if_missing "administrator" 1001 "admins"

# Researcher users: UID 2000+
create_user_if_missing "researcher-01" 2001 "researchers"
create_user_if_missing "researcher-02" 2002 "researchers gpu-users"

# Student users: UID 3000+
create_user_if_missing "student-01" 3001 "students"
create_user_if_missing "student-02" 3002 "students"
create_user_if_missing "student-03" 3003 "students"

log "Test users created/verified"

# ============================================================================
# 3. Create /shared and /home directories with correct ownership
# ============================================================================

log "Creating shared directories..."

# Ensure /home exists with correct permissions
mkdir -p /home
chmod 755 /home

# Create shared project directories (will be NFS mounted)
mkdir -p /shared/course-001
mkdir -p /shared/course-002
mkdir -p /shared/team-research

# Set ownership to researchers for team directories
chown -R 2001:5002 /shared/team-research || true
chmod -R 770 /shared/team-research || true

chown -R root:root /shared/course-001 || true
chmod -R 755 /shared/course-001 || true

log "Shared directories created/verified"

# ============================================================================
# 4. Create sudoers entries for jupyterhub (will spawn notebooks as users)
# ============================================================================

log "Configuring sudoers for JupyterHub..."

cat > /etc/sudoers.d/jupyterhub-spawner << 'SUDOERS'
# Allow JupyterHub to spawn notebook servers as any user
Defaults:jupyterhub    !authenticate
jupyterhub ALL = (ALL) NOPASSWD: /usr/local/bin/spawn-notebook.sh
jupyterhub ALL = (ALL) NOPASSWD: /usr/bin/srun
jupyterhub ALL = (ALL) NOPASSWD: /usr/bin/sbatch
SUDOERS

chmod 440 /etc/sudoers.d/jupyterhub-spawner
log "Sudoers configured"

# ============================================================================
# 5. Verify
# ============================================================================

log "Verification:"
log "  Groups:"
getent group | grep -E "^(students|researchers|gpu-users|admins):" || true

log "  Users:"
for user in admin researcher-01 researcher-02 student-01 student-02 student-03; do
  id "$user" 2>/dev/null | sed 's/^/    /' || log "    $user: NOT FOUND"
done

log "PAM user initialization complete"
