#!/usr/bin/env python3
import json
import os
import ssl
import time
import urllib.error
import urllib.request


NAC_URL = os.environ.get("ESI_NAC_URL", "https://192.168.110.1:8443/auth")
NAC_USER = os.environ.get("ESI_NAC_USER", "")
NAC_PASSWORD = os.environ.get("ESI_NAC_PASSWORD", "")
REFRESH = int(os.environ.get("ESI_NAC_REFRESH", "600"))
RETRY = int(os.environ.get("ESI_NAC_RETRY", "10"))
LOG_FILE = os.environ.get("ESI_NAC_CLIENT_LOG", "/var/log/esi-nac-client.log")


def log_line(message):
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(LOG_FILE, "a", encoding="utf-8") as handle:
        handle.write(f"{timestamp} {message}\n")


def send_auth():
    if not NAC_USER or not NAC_PASSWORD:
        log_line("missing credentials")
        return False
    payload = json.dumps({"username": NAC_USER, "password": NAC_PASSWORD}).encode("utf-8")
    request = urllib.request.Request(
        NAC_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        context = ssl._create_unverified_context() if NAC_URL.startswith("https://") else None
        with urllib.request.urlopen(request, timeout=6, context=context) as response:
            status = response.status
            body = response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, TimeoutError, ValueError) as exc:
        log_line(f"auth error: {exc}")
        return False

    log_line(f"auth status={status} body={body}")
    return status == 200


def main():
    while True:
        time.sleep(REFRESH if send_auth() else RETRY)


if __name__ == "__main__":
    main()
