# QoS Ansible Playbook

This playbook redeploys the Containerlab topology and runs the QoS validation script.

## Usage

From the repo root:

```bash
ansible-playbook implementations/frr-containerlab/ansible/qos_deploy.yml
```

The playbook assumes `containerlab` and `docker` are available in the WSL distro and that your user can run `sudo containerlab`.
