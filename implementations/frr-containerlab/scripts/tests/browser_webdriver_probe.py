#!/usr/bin/env python3
import html
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"


class WebDriver:
    def __init__(self):
        self.port = self._free_port()
        self.log = tempfile.NamedTemporaryFile(prefix="geckodriver-", suffix=".log", delete=False)
        self.proc = subprocess.Popen(
            ["geckodriver", "--host", "127.0.0.1", "--port", str(self.port)],
            stdout=self.log,
            stderr=subprocess.STDOUT,
        )
        self.session_id = ""
        self._wait_ready()
        self._create_session()

    def _free_port(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    def _wait_ready(self):
        deadline = time.time() + 15
        while time.time() < deadline:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.settimeout(0.5)
                if sock.connect_ex(("127.0.0.1", self.port)) == 0:
                    return
            time.sleep(0.2)
        raise RuntimeError("geckodriver did not start")

    def _request(self, method, path, payload=None):
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                body = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            raise RuntimeError(f"webdriver {method} {path} failed: {body}") from exc
        return json.loads(body).get("value")

    def _create_session(self):
        value = self._request("POST", "/session", {
            "capabilities": {
                "alwaysMatch": {
                    "browserName": "firefox",
                    "acceptInsecureCerts": True,
                    "pageLoadStrategy": "none",
                    "moz:firefoxOptions": {
                        "args": ["-headless"],
                        "prefs": {
                            "browser.shell.checkDefaultBrowser": False,
                            "network.proxy.type": 0,
                        },
                    },
                }
            }
        })
        self.session_id = value["sessionId"]
        self._request("POST", f"/session/{self.session_id}/timeouts", {
            "implicit": 0,
            "pageLoad": 15000,
            "script": 10000,
        })

    def close(self):
        if self.session_id:
            try:
                self._request("DELETE", f"/session/{self.session_id}")
            except Exception:
                pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()
        try:
            os.unlink(self.log.name)
        except OSError:
            pass

    def open(self, url):
        self._request("POST", f"/session/{self.session_id}/url", {"url": url})

    def source(self):
        return html.unescape(self._request("GET", f"/session/{self.session_id}/source"))

    def find(self, selector):
        value = self._request("POST", f"/session/{self.session_id}/element", {
            "using": "css selector",
            "value": selector,
        })
        return value.get(ELEMENT_KEY) or next(iter(value.values()))

    def type(self, selector, text):
        element = self.find(selector)
        self._request("POST", f"/session/{self.session_id}/element/{element}/value", {
            "text": text,
            "value": list(text),
        })

    def click(self, selector):
        element = self.find(selector)
        self._request("POST", f"/session/{self.session_id}/element/{element}/click", {})

    def wait_source(self, pattern, timeout=25):
        regex = re.compile(pattern, re.I | re.S)
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            last = self.source()
            if regex.search(last):
                return last
            time.sleep(0.5)
        raise RuntimeError(f"pattern not found: {pattern}\n{last[:1200]}")


def page(url, pattern):
    driver = WebDriver()
    try:
        driver.open(url)
        driver.wait_source(pattern)
        print("OK")
    finally:
        driver.close()


def nac_login(url, username, password, expected_role):
    driver = WebDriver()
    try:
        driver.open(url)
        driver.wait_source("Sign in to access this network|Bienvenus au portail ESI")
        driver.type("#username", username)
        driver.type("#password", password)
        driver.click("button[type='submit']")
        driver.wait_source(f"Access granted.*{re.escape(expected_role)}|{re.escape(expected_role)}.*Access granted")
        print("OK")
    finally:
        driver.close()


def vpn_login(url, username, password):
    driver = WebDriver()
    try:
        driver.open(url)
        driver.wait_source("Create a VPN lease|Enrollment portal")
        driver.type("#username", username)
        driver.type("#password", password)
        driver.click("button[type='submit']")
        source = driver.wait_source("Enrollment accepted.*PrivateKey|PrivateKey.*Enrollment accepted", timeout=35)
        private_match = re.search(r"PrivateKey\s*=\s*([A-Za-z0-9+/=]+)", source)
        address_match = re.search(r"Address\s*=\s*([0-9./]+)", source)
        peer_public_match = re.search(r"\[Peer\].*?PublicKey\s*=\s*([A-Za-z0-9+/=]+)", source, re.S)
        client_public_match = re.search(r'name="public_key"\s+value="([^"]+)"', source)
        result = {
            "private_key": private_match.group(1) if private_match else "",
            "address": address_match.group(1) if address_match else "",
            "server_pubkey": peer_public_match.group(1) if peer_public_match else "",
            "client_public_key": client_public_match.group(1) if client_public_match else "",
            "client_installed": "Client tunnel installed" in source,
        }
        if not all([result["private_key"], result["address"], result["server_pubkey"], result["client_public_key"]]):
            raise RuntimeError(f"incomplete VPN config from browser page: {result}")
        print(json.dumps(result, sort_keys=True))
    finally:
        driver.close()


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: browser_webdriver_probe.py MODE ...")
    mode = sys.argv[1]
    if mode == "page":
        page(sys.argv[2], sys.argv[3])
    elif mode == "nac-login":
        nac_login(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif mode == "vpn-login":
        vpn_login(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
