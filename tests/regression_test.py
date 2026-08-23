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


def request(port: int, source: str | Path) -> str:
    query = f"target=clash&url={quote(str(source), safe='')}"
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
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    print("PASS: AnyTLS client-fingerprint and VLESS default TCP regressions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
