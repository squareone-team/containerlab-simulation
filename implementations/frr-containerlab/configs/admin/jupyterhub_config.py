"""
JupyterHub Configuration for ESI Datacenter Lab
================================================

Authentication: PAM (Linux local accounts)
Spawner: LocalProcessSpawner
Notebook profiles:
  - CPU (cpu partition)
  - GPU (gpu partition, gpu-users group only)

Users:
  - students: cpu partition only
  - researchers: cpu partition only
  - admins: all partitions
  - gpu-users: gpu partition + cpu partition

JupyterHub version: 5.x
"""

import os
import sys

# ============================================================================
# 1. Basic JupyterHub Configuration
# ============================================================================

# Hub API is only consumed by the proxy running in this same container.
# Pin the connect URL to IPv4 so Docker's IPv6 hostname entry cannot cause 503s.
c.JupyterHub.hub_ip = '127.0.0.1'
c.JupyterHub.hub_port = 8081
c.JupyterHub.hub_connect_url = 'http://127.0.0.1:8081/hub/'

# The public-facing port (what users connect to, what's proxied by nginx on hpc-jupyter)
c.JupyterHub.bind_url = 'http://0.0.0.0:8000'

# Proxy API (configurable-http-proxy control channel)
c.JupyterHub.proxy_api_ip = '127.0.0.1'
c.JupyterHub.proxy_api_port = 8001

# Session cookie lifetime (7 days in days, not seconds for JupyterHub 5.x)
c.JupyterHub.cookie_max_age_days = 7

c.JupyterHub.allow_named_servers = False
c.JupyterHub.shutdown_on_logout = True
c.JupyterHub.delete_stopped_servers = True

# ============================================================================
# 2. Security & TLS
# ============================================================================

# TLS is terminated at nginx on hpc-jupyter; admin runs plain HTTP internally
# c.JupyterHub.ssl_key = '/etc/jupyterhub/jupyterhub.key'
# c.JupyterHub.ssl_cert = '/etc/jupyterhub/jupyterhub.crt'

# ============================================================================
# 3. Authenticator: PAM (Local Linux Accounts)
# ============================================================================

# Use 'pam' (the JupyterHub built-in PAM authenticator, backed by pamela)
c.JupyterHub.authenticator_class = 'pam'

from jupyterhub.auth import PAMAuthenticator
c.PAMAuthenticator.encoding = 'utf8'
c.PAMAuthenticator.service = 'login'
c.PAMAuthenticator.open_sessions = False

# ============================================================================
# 4. Spawner: LocalProcessSpawner
# ============================================================================

c.JupyterHub.spawner_class = 'jupyterhub.spawner.LocalProcessSpawner'

# Notebook directory per-user (on NFS /home)
c.LocalProcessSpawner.notebook_dir = '/home/{username}'
c.LocalProcessSpawner.default_url = '/lab'

# ============================================================================
# 5. User Whitelist & Authorization
# ============================================================================

# Admins can manage JupyterHub
c.Authenticator.admin_users = {
    'admin',
    'root',
}

# Allow specific users (created via PAM/useradd)
c.Authenticator.allowed_users = {
    'admin',
    'student-01', 'student-02', 'student-03',
    'researcher-01', 'researcher-02',
}

# ============================================================================
# 6. Database Configuration (MariaDB)
# ============================================================================

c.JupyterHub.db_url = 'mysql+pymysql://jupyterhub:jupyterhub_pass@localhost/jupyterhub'

# ============================================================================
# 7. Logging
# ============================================================================

c.JupyterHub.log_level = 'INFO'

# ============================================================================
# 8. Activity Timeout
# ============================================================================

c.JupyterHub.inactive_server_timeout = 3600  # 1 hour
c.JupyterHub.services = []
