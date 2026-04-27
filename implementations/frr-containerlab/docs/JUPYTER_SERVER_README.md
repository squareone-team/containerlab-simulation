# Jupyter Server in Pod 3 (AI/HPC)

This document explains how the Jupyter server is deployed in the lab, how
students/admin reach it, and how to configure and manage access tokens.

## 1) How It Works

- Node: `server-hpc-jupyter` in the HPC pod.
- Container image: `esi/alpine-jupyter:3.20`.
- Notebook process: started by
  [configs/server-hpc-jupyter/startup.sh](../configs/server-hpc-jupyter/startup.sh).
- Listen address: `0.0.0.0:8080` inside the container.
- Persistent notebooks path:
  [configs/server-hpc-jupyter/notebooks](../configs/server-hpc-jupyter/notebooks),
  bind-mounted to `/srv/notebooks`.
- Host exposure: [esi-datacenter.clab.yml](../esi-datacenter.clab.yml) maps host
  port `8888` to container port `8080`.

## 2) Network and Access Paths

### From student/admin nodes (inside the lab)

- Internal DNS name: `hpc-jupyter.esi.internal`.
- Internal URL:

  `http://hpc-jupyter.esi.internal:8080/tree?token=<TOKEN>`

- Allowed source prefixes for 8080 are configured in
  [configs/server-hpc-jupyter/startup.sh](../configs/server-hpc-jupyter/startup.sh).

### From the host machine (outside the lab)

- Use Docker port publishing from the topology file.
- Host URL:

  `http://127.0.0.1:8888/tree?token=<TOKEN>`

- If localhost is not desired, you can also use the host IP with port `8888`.

## 3) Default Token Behavior

The startup script currently uses:

`JUPYTER_TOKEN="${JUPYTER_TOKEN:-esi-jupyter-demo-token}"`

So if no environment variable is injected, token defaults to:

- `esi-jupyter-demo-token`

## 4) How to Set or Change the Token

### Option A: Persistent token via topology env (recommended)

In [esi-datacenter.clab.yml](../esi-datacenter.clab.yml), under
`server-hpc-jupyter`, add:

```yaml
env:
  JUPYTER_TOKEN: "your-strong-token-here"
```

Then redeploy (or recreate only that node) so startup re-reads the value.

### Option B: Persistent token via startup default

Edit
[configs/server-hpc-jupyter/startup.sh](../configs/server-hpc-jupyter/startup.sh)
and change the fallback token string.

### Option C: Runtime emergency rotation (non-persistent)

```bash
docker exec clab-esi-datacenter-server-hpc-jupyter sh -lc '
  pkill -f "jupyter notebook" || true
  JUPYTER_TOKEN="new-temporary-token"
  nohup jupyter notebook --ip=0.0.0.0 --port=8080 --no-browser --allow-root \
    --NotebookApp.token="${JUPYTER_TOKEN}" --notebook-dir=/srv/notebooks \
    </dev/null >/var/log/jupyter/notebook.log 2>&1 &
'
```

This change is temporary and will be lost on container restart unless also
applied through Option A or B.

## 5) Token Management Recommendations

- Use a strong random token for non-demo use.
- Do not hardcode production-like secrets in git history.
- Rotate token after each demo session.
- If sharing URLs, share only with trusted participants because token grants
  code execution access.
- Keep notebooks in
  [configs/server-hpc-jupyter/notebooks](../configs/server-hpc-jupyter/notebooks)
  and back them up if needed.

## 6) Verification and Troubleshooting

### End-to-end verification

Run:

```bash
bash implementations/frr-containerlab/scripts/tests/jupyter_access_verify.sh
```

Expected result: all checks pass.

### Check if Jupyter is listening

```bash
docker exec clab-esi-datacenter-server-hpc-jupyter ss -lntp | grep ':8080'
```

### Read Jupyter logs

```bash
docker exec clab-esi-datacenter-server-hpc-jupyter tail -n 100 /var/log/jupyter/notebook.log
```

### Validate host access

```bash
curl -I "http://127.0.0.1:8888/tree?token=<TOKEN>"
```

## 7) Quick Demo Flow

1. Confirm service and DNS checks pass with the verification script.
2. Open host URL `http://127.0.0.1:8888/tree?token=<TOKEN>`.
3. Create a notebook and run a simple Python cell.
4. Show that notebook files appear under
   [configs/server-hpc-jupyter/notebooks](../configs/server-hpc-jupyter/notebooks).
5. Rotate token after the demo.
