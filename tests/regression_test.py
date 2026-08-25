#!/usr/bin/env python3
"""Small integration checks for the parser/exporter regressions.

Usage:
    python3 tests/regression_test.py /path/to/subconverter

The script intentionally uses only the Python standard library. It expects a
normal (non-static-library) subconverter binary and the repository's
base/pref.example.ini file.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.parse import quote
from urllib.request import urlopen


ANYTLS_CONFIG = """proxies:
  - name: anytls-regression
    type: anytls
    server: example.com
    port: 443
    password: regression-password
    client-fingerprint: chrome
"""

VLESS_CONFIG = (
    "vless://11111111-1111-4111-8111-111111111111@example.com:443?security=tls"
    "#vless-default-tcp"
)

CLASH_HARDENING_CONFIG = """proxies:
  - name: tuic-default-timeout
    type: tuic
    server: example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    password: regression-password
    alpn: [h3, h2-tuic, http-tuic]
  - name: anytls-all-alpn
    type: anytls
    server: example.com
    port: 443
    password: regression-password
    alpn: [h2, http/1.1, custom-alpn]
  - name: anytls-empty-alpn
    type: anytls
    server: example.com
    port: 443
    password: regression-password
    alpn: []
"""

CLASH_SEQUENCE_CONFIG = """- name: sequence-anytls
  type: anytls
  server: example.com
  port: 443
  password: regression-password
  client-fingerprint: firefox
"""

CLASH_BAD_NODE_CONFIG = """proxies:
  - name: malformed-vless
    type: vless
    server: example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    network: ws
    ws-opts:
      path:
        invalid: true
  - name: valid-after-malformed
    type: anytls
    server: example.com
    port: 443
    password: regression-password
"""

SINGBOX_FINGERPRINT_CONFIG = """{
  "inbounds": [],
  "outbounds": [{
    "type": "vless",
    "tag": "vless-fingerprint",
    "server": "example.com",
    "server_port": 443,
    "uuid": "11111111-1111-4111-8111-111111111111",
    "tls": {
      "enabled": true,
      "server_name": "example.com",
      "utls": {"enabled": true, "fingerprint": "firefox"}
    }
  }],
  "route": {}
}
"""

SINGBOX_TUIC_TLS_CONFIG = """{
  "inbounds": [],
  "outbounds": [{
    "type": "tuic",
    "tag": "tuic-sni-without-alpn",
    "server": "example.com",
    "server_port": 443,
    "uuid": "11111111-1111-4111-8111-111111111111",
    "password": "regression-password",
    "tls": {"enabled": true, "server_name": "sni.example.com"}
  }],
  "route": {}
}
"""

SINGBOX_MINIMAL_CONFIG = """{
  "outbounds": [{
    "type": "anytls",
    "tag": "minimal-anytls",
    "server": "example.com",
    "server_port": 443,
    "password": "regression-password"
  }]
}
"""


def request(port: int, source: str | Path, target: str = "clash", options: str = "") -> str:
    query = f"target={target}"
    if options:
        query += f"&{options}"
    query += f"&url={quote(str(source), safe='')}"
    with urlopen(f"http://127.0.0.1:{port}/sub?{query}", timeout=10) as response:
        body = response.read().decode("utf-8")
        if response.status != 200:
            raise AssertionError(f"unexpected HTTP status {response.status}: {body}")
        return body


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_server(port: int, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"subconverter exited early with status {process.returncode}")
        try:
            with urlopen(f"http://127.0.0.1:{port}/version", timeout=1) as response:
                if response.status == 200:
                    return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError("subconverter did not start within 15 seconds")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path, help="path to the built subconverter executable")
    args = parser.parse_args()

    binary = args.binary.resolve()
    repo = Path(__file__).resolve().parents[1]
    pref = repo / "base" / "pref.example.ini"
    if not binary.is_file():
        raise FileNotFoundError(binary)
    if not pref.is_file():
        raise FileNotFoundError(pref)

    port = free_port()
    env = os.environ.copy()
    env["PORT"] = str(port)
    env["API_MODE"] = "false"
    process = subprocess.Popen(
        [str(binary), "-f", str(pref)],
        cwd=repo,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(port, process)
        with tempfile.TemporaryDirectory(prefix="subconverter-regression-") as temp_dir:
            temp = Path(temp_dir)
            anytls = temp / "anytls.yml"
            anytls.write_text(ANYTLS_CONFIG, encoding="utf-8")
            output = request(port, anytls)
            assert "client-fingerprint: chrome" in output, output
            assert not any(
                line.strip().startswith("fingerprint:")
                for line in output.splitlines()
            ), output

            output = request(port, VLESS_CONFIG)
            assert "name: vless-default-tcp" in output, output
            assert "network: tcp" in output, output

            hardening = temp / "clash-hardening.yml"
            hardening.write_text(CLASH_HARDENING_CONFIG, encoding="utf-8")
            output = request(port, hardening)
            assert "name: tuic-default-timeout" in output, output
            assert "request-timeout: 15000" in output, output
            assert "custom-alpn" in output, output
            assert "name: anytls-empty-alpn" in output, output

            singbox_output = json.loads(request(port, hardening, target="singbox"))
            tuic_outbound = next(
                item for item in singbox_output["outbounds"]
                if item.get("tag") == "tuic-default-timeout"
            )
            assert tuic_outbound["tls"]["alpn"] == ["h3", "h2-tuic", "http-tuic"], tuic_outbound

            sequence = temp / "clash-sequence.yml"
            sequence.write_text(CLASH_SEQUENCE_CONFIG, encoding="utf-8")
            output = request(port, sequence)
            assert "name: sequence-anytls" in output, output

            malformed = temp / "clash-bad-node.yml"
            malformed.write_text(CLASH_BAD_NODE_CONFIG, encoding="utf-8")
            output = request(port, malformed)
            assert "name: valid-after-malformed" in output, output

            singbox = temp / "singbox-fingerprint.json"
            singbox.write_text(SINGBOX_FINGERPRINT_CONFIG, encoding="utf-8")
            output = request(port, singbox, target="singbox")
            assert '"fingerprint":"firefox"' in output, output

            tuic_singbox = temp / "singbox-tuic-tls.json"
            tuic_singbox.write_text(SINGBOX_TUIC_TLS_CONFIG, encoding="utf-8")
            output = request(port, tuic_singbox, target="singbox")
            assert '"server_name":"sni.example.com"' in output, output

            minimal_singbox = temp / "singbox-minimal.json"
            minimal_singbox.write_text(SINGBOX_MINIMAL_CONFIG, encoding="utf-8")
            output = request(port, minimal_singbox)
            assert "name: minimal-anytls" in output, output

            output = request(port, VLESS_CONFIG, target="vless", options="list=true")
            assert "?&" not in output, output
            assert "?security=tls" in output, output
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    print("PASS: protocol hardening regressions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
