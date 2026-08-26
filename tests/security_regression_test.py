#!/usr/bin/env python3
"""Focused integration checks for the public-service security boundary."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import socket
import subprocess
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_server(port: int, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"subconverter exited with {process.returncode}")
        try:
            with urlopen(f"http://127.0.0.1:{port}/version", timeout=1):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError("subconverter did not start")


def status(port: int, path: str) -> int:
    try:
        with urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as response:
            return response.status
    except HTTPError as error:
        return error.code


def post_status(port: int, path: str, body: bytes = b"") -> int:
    try:
        request = Request(f"http://127.0.0.1:{port}{path}", data=body, method="POST")
        with urlopen(request, timeout=5) as response:
            return response.status
    except HTTPError as error:
        return error.code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    for config_name in ("pref.example.ini", "pref.example.toml", "pref.example.yml"):
        config = (repo / "base" / config_name).read_text(encoding="utf-8")
        assert "password" not in config.splitlines()[:10], config_name
    template_root = repo / "base" / "templates"
    sibling_root = repo / "base" / "templates_backup"
    template_root.mkdir(exist_ok=True)
    sibling_root.mkdir(exist_ok=True)
    include_test = template_root / ".security-include-test.tpl"
    sibling_secret = sibling_root / ".security-leak-test.tpl"
    include_test.write_text('{% include "../templates_backup/.security-leak-test.tpl" %}', encoding="utf-8")
    sibling_secret.write_text("include-scope-leak", encoding="utf-8")
    port = free_port()
    env = os.environ.copy()
    env.update({"PORT": str(port), "API_MODE": "true", "API_TOKEN": "security-test-token"})
    process = subprocess.Popen(
        [str(args.binary.resolve()), "-f", str(repo / "base" / "pref.example.ini")],
        cwd=repo,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_for_server(port, process)
        assert post_status(port, "/updateconf?type=direct") == 403
        assert status(port, "/flushcache") == 403
        assert status(port, "/sub?target=clash&url=http%3A%2F%2F127.0.0.1%2F") == 400
        assert status(port, "/sub?target=clash&url=http%3A%2F%2F2130706433%2F") == 400
        assert status(port, "/sub?target=clash&url=http%3A%2F%2F0x7f000001%2F") == 400
        assert status(port, "/sub?target=clash&url=http%3A%2F%2F%5B%3A%3A1%5D%2F") == 400
        assert status(port, "/sub?target=clash&url=http%3A%2F%2F169.254.169.254%2F") == 400
        assert status(port, "/sub?target=clash&url=file%3A%2F%2F%2Fetc%2Fhosts") == 400
        assert status(port, "/sub?target=clash&url=http%3A%2F%2F127.0.0.1%2F&filter_script=" + quote("function filter() { return true; }")) == 403
        assert status(port, "/render?path=templates%2F..%2Fpref.example.ini") == 404
        assert status(port, "/render?path=templates%2F.security-include-test.tpl") == 400
        # API mode does not register the local-file endpoint at all.
        assert status(port, "/getlocal?path=../pref.toml") == 404
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        include_test.unlink(missing_ok=True)
        sibling_secret.unlink(missing_ok=True)
        for directory in (template_root, sibling_root):
            try:
                directory.rmdir()
            except OSError:
                pass
    print("PASS: security boundary regressions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
