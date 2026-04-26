FROM esi/alpine-host:3.20

RUN set -eux; \
    apk add --no-cache \
    python3 \
    py3-pip \
    py3-ipykernel \
    jupyter-server \
    jupyter-notebook \
    jupyter-nbconvert \
    tini; \
    python3 -m ipykernel install --sys-prefix --name python3 --display-name "Python 3"; \
    mkdir -p /srv/notebooks /var/log/jupyter
