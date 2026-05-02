FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      chrony \
      curl \
      dnsutils \
      iproute2 \
      iptables \
      iputils-ping \
      libpam0g \
      libpam-modules \
      mariadb-client \
      mariadb-server \
      munge \
      netcat-openbsd \
      nfs-common \
      nfs-kernel-server \
      nftables \
      nginx \
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
      sudo \
      udhcpc \
      ifenslave; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    pip3 install --no-cache-dir --break-system-packages --timeout 600 --retries 10 --progress-bar off \
      batchspawner \
      cryptography \
      ipykernel \
      jupyterhub \
      pamela \
      jupyterlab \
      notebook \
      pymysql \
      sqlalchemy; \
    npm config set fetch-retries 5; \
    npm config set fetch-retry-mintimeout 20000; \
    npm config set fetch-retry-maxtimeout 120000; \
    npm install -g configurable-http-proxy; \
    mkdir -p /run/sshd /var/log/chrony /var/run/chrony
