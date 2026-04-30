FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      chrony \
      curl \
      iproute2 \
      iptables \
      libpam0g \
      libpam-modules \
      mariadb-client \
      mariadb-server \
      munge \
      netcat-openbsd \
      nfs-common \
      nfs-kernel-server \
      nftables \
      nodejs \
      npm \
      openssh-client \
      openssh-server \
      openssl \
      python3 \
      python3-cryptography \
      python3-pip \
      python3-venv \
      rpcbind \
      rsyslog \
      slurm-client \
      slurmctld \
      slurmdbd \
      slurmd \
      slurm-wlm-basic-plugins \
      sudo; \
    pip3 install --no-cache-dir --break-system-packages \
      cryptography \
      ipykernel \
      jupyterhub \
      pamela \
      jupyterlab \
      notebook \
      pymysql \
      sqlalchemy; \
    npm install -g configurable-http-proxy; \
    mkdir -p /run/sshd /var/log/chrony /var/run/chrony; \
    rm -rf /var/lib/apt/lists/*
