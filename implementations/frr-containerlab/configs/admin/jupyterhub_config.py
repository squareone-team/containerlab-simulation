"""
JupyterHub Configuration for ESI Datacenter Lab
================================================

Authentication: PAM (Linux local accounts)
Spawner: SLURM via sudospawner
Notebook profiles:
  - CPU (cpu partition)
  - GPU (gpu partition, gpu-users group only)

Users:
  - students: cpu partition only
  - researchers: cpu partition only
  - admins: all partitions
  - gpu-users: gpu partition + cpu partition
"""

import os
import sys

# ============================================================================
# 1. Basic JupyterHub Configuration
# ============================================================================

c.JupyterHub.hub_ip = '192.168.50.10'
c.JupyterHub.hub_port = 8000
c.JupyterHub.proxy_api_ip = '192.168.50.10'
c.JupyterHub.proxy_api_port = 8001
c.JupyterHub.ip = '0.0.0.0'
c.JupyterHub.port = 8080
c.JupyterHub.cookie_max_age = 604800  # 7 days
c.JupyterHub.delete_stopped_servers = False
c.JupyterHub.allow_named_servers = False
c.JupyterHub.default_server_name = 'default'

# ============================================================================
# 2. Security & TLS
# ============================================================================

c.JupyterHub.ssl_key = '/etc/jupyterhub/jupyterhub.key'
c.JupyterHub.ssl_cert = '/etc/jupyterhub/jupyterhub.crt'
c.JupyterHub.ssl_version = 'TLSv1_2'

# ============================================================================
# 3. Authenticator: PAM (Local Linux Accounts)
# ============================================================================

c.JupyterHub.authenticator_class = 'pamela'

# pamela requires 'jupyterhub_pamela' extra
from jupyterhub.auth import PAMAuthenticator
c.PAMAuthenticator.encoding = 'utf8'
c.PAMAuthenticator.service_name = 'login'
c.PAMAuthenticator.open_sessions = False

# ============================================================================
# 4. Spawner: LocalProcessSpawner (SLURM jobs spawned as subprocesses)
# ============================================================================

c.JupyterHub.spawner_class = 'jupyterhub.spawner.LocalProcessSpawner'

# Spawner settings
c.LocalProcessSpawner.notebook_dir = '/home/{username}'
c.LocalProcessSpawner.default_url = '/lab'  # Use JupyterLab
c.LocalProcessSpawner.args = [
    '--SingleUserNotebookApp.ip=127.0.0.1',
    '--SingleUserNotebookApp.port={port}',
    '--NotebookApp.disable_check_xsrftoken=False',
]

# ============================================================================
# 5. Kernel Specifications & Profiles
# ============================================================================

# Users may select CPU or GPU kernel profile
# These trigger different SLURM submissions
c.JupyterHub.kernel_specs = {
    'python3-cpu': {
        'display_name': 'Python 3 (CPU)',
        'language': 'python',
        'argv': ['python', '-m', 'ipykernel_launcher', '-f', '{connection_file}'],
    },
    'python3-gpu': {
        'display_name': 'Python 3 (GPU)',
        'language': 'python',
        'argv': ['python', '-m', 'ipykernel_launcher', '-f', '{connection_file}'],
    },
}

# ============================================================================
# 6. User Whitelist & Authorization
# ============================================================================

# Admins can manage JupyterHub
c.Authenticator.admin_users = {
    'admin',
    'root',
}

# Allow specific user groups (created via PAM/useradd)
c.Authenticator.allowed_users = [
    'admin',
    'student-01', 'student-02', 'student-03',
    'researcher-01', 'researcher-02',
]

# ============================================================================
# 7. Database Configuration (MariaDB)
# ============================================================================

c.JupyterHub.db_url = 'mysql://jupyterhub:jupyterhub_pass@192.168.50.10/jupyterhub'

# ============================================================================
# 8. Logging
# ============================================================================

c.JupyterHub.log_level = 'INFO'
c.JupyterHub.log_format = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'

# ============================================================================
# 9. Activity Timeout
# ============================================================================

c.JupyterHub.inactive_server_timeout = 3600  # 1 hour
c.JupyterHub.services = []

# ============================================================================
# 10. Explicit Shutdown Behavior
# ============================================================================

c.JupyterHub.shutdown_on_logout = True
