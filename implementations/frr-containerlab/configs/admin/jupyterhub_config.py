"""
JupyterHub Configuration for ESI Datacenter Lab
================================================

Authentication: PAM (Linux local accounts)
Spawner: BatchSpawner SlurmSpawner
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

import grp
import os
import pwd

from tornado import web

import batchspawner

# ============================================================================
# 1. Basic JupyterHub Configuration
# ============================================================================

# Remote SLURM jobs call back to the Hub API from the worker nodes, so the Hub
# API must be reachable on the Admin pod's routed address.
c.JupyterHub.hub_ip = '192.168.50.10'
c.JupyterHub.hub_port = 8081
c.JupyterHub.hub_connect_url = 'http://192.168.50.10:8081/hub/'

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
# 4. Spawner: SLURM via BatchSpawner
# ============================================================================

c.JupyterHub.spawner_class = 'batchspawner.SlurmSpawner'

# Batch jobs can sit briefly in the queue while SLURM places them.
c.Spawner.http_timeout = 300
c.Spawner.start_timeout = 300

# Notebook directory per-user (NFS-mounted from server-storage-01 everywhere).
c.Spawner.cmd = ['/usr/local/bin/jupyterhub-singleuser']
c.Spawner.notebook_dir = '/home/{username}'
c.Spawner.default_url = '/lab'

# Conservative default profile: one CPU notebook on the cpu partition.
c.BatchSpawnerBase.exec_prefix = 'sudo -E -u {username}'
c.BatchSpawnerBase.batchspawner_singleuser_cmd = '/usr/local/bin/batchspawner-singleuser'
c.BatchSpawnerBase.req_nprocs = '1'
c.BatchSpawnerBase.req_runtime = '02:00:00'
c.BatchSpawnerBase.req_memory = '2G'
c.BatchSpawnerBase.req_options = '--nodes=1'
c.BatchSpawnerBase.req_prologue = '''
export PATH=/usr/local/bin:/usr/bin:/bin:${PATH:-}
cd "$HOME"
'''

c.SlurmSpawner.req_partition = 'cpu'
c.SlurmSpawner.req_srun = 'srun'

NAAS_PROFILES = {
    'cpu': {
        'label': 'CPU',
        'partition': 'cpu',
        'nprocs': '1',
        'memory': '2G',
        'runtime': '02:00:00',
    },
    'gpu': {
        'label': 'GPU',
        'partition': 'gpu',
        'nprocs': '2',
        'memory': '4G',
        'runtime': '04:00:00',
    },
}

GPU_GROUPS = {'gpu-users', 'admins'}


def user_in_any_group(username, group_names):
    try:
        user = pwd.getpwnam(username)
    except KeyError:
        return False

    user_gids = {user.pw_gid}
    for group in grp.getgrall():
        if username in group.gr_mem:
            user_gids.add(group.gr_gid)

    allowed_gids = set()
    for group_name in group_names:
        try:
            allowed_gids.add(grp.getgrnam(group_name).gr_gid)
        except KeyError:
            continue

    return bool(user_gids & allowed_gids)


def profile_options_form(spawner):
    choices = [('cpu', NAAS_PROFILES['cpu']['label'])]
    if user_in_any_group(spawner.user.name, GPU_GROUPS):
        choices.append(('gpu', NAAS_PROFILES['gpu']['label']))

    options = '\n'.join(
        f'<option value="{key}">{label}</option>'
        for key, label in choices
    )

    return f'''
<label for="profile">Notebook profile</label>
<select name="profile" id="profile">
{options}
</select>
'''


def profile_options_from_form(formdata, spawner=None):
    profile = formdata.get('profile', ['cpu'])[0]
    if profile not in NAAS_PROFILES:
        profile = 'cpu'
    return {'profile': profile}


def apply_slurm_profile(spawner):
    username = spawner.user.name
    profile = spawner.user_options.get('profile', 'cpu')
    if profile not in NAAS_PROFILES:
        profile = 'cpu'

    if profile == 'gpu' and not user_in_any_group(username, GPU_GROUPS):
        raise web.HTTPError(403, 'GPU notebooks are limited to gpu-users and admins')

    profile_config = NAAS_PROFILES[profile]
    spawner.req_partition = profile_config['partition']
    spawner.req_nprocs = profile_config['nprocs']
    spawner.req_memory = profile_config['memory']
    spawner.req_runtime = profile_config['runtime']
    spawner.environment.update({
        'NAAS_SLURM_PROFILE': profile,
        'NAAS_SLURM_PARTITION': profile_config['partition'],
    })


c.Spawner.options_form = profile_options_form
c.Spawner.options_from_form = profile_options_from_form
c.Spawner.pre_spawn_hook = apply_slurm_profile

# ============================================================================
# 5. User Whitelist & Authorization
# ============================================================================

# Admins can manage JupyterHub
c.Authenticator.admin_users = {
    'admin',
    'administrator',
    'root',
}

# Allow specific users (created via PAM/useradd)
c.Authenticator.allowed_users = {
    'admin', 'administrator',
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
# 8. Verifier Service
# ============================================================================

NAAS_VERIFIER_TOKEN = os.environ.get('NAAS_VERIFIER_TOKEN', 'naas-verifier-token')

c.JupyterHub.services = [
    {
        'name': 'naas-verifier',
        'api_token': NAAS_VERIFIER_TOKEN,
    },
]

c.JupyterHub.load_roles = [
    {
        'name': 'naas-verifier-role',
        'services': ['naas-verifier'],
        'scopes': [
            'admin:servers',
            'read:users',
            'read:servers',
        ],
    },
]

# ============================================================================
# 9. Activity Timeout
# ============================================================================

c.JupyterHub.inactive_server_timeout = 3600  # 1 hour
