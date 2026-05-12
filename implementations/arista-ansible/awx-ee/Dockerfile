FROM quay.io/ansible/awx-ee:24.6.1

USER root

COPY requirements.txt /tmp/requirements.txt
COPY requirements.yml /tmp/requirements.yml

RUN dnf -y install dnf-plugins-core && \
    dnf config-manager --set-enabled crb || true && \
    dnf -y install \
      gcc \
      python3-devel \
      libssh-devel \
      openssh-clients \
      sshpass && \
    dnf clean all

RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir -r /tmp/requirements.txt

RUN ansible-galaxy collection install \
    -r /tmp/requirements.yml \
    --collections-path /usr/share/ansible/collections

RUN python3 -m pip show ansible-pylibssh paramiko netaddr jmespath jsonschema && \
    ansible-galaxy collection list

USER 1000
