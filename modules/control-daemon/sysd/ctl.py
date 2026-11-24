"""erebor-sys: a small client for erebor-sysd.

    erebor-sys set-power-profile profile=balanced
    erebor-sys desktop.set-noctalia-preset look=glass-pbsio2
    erebor-sys list-actions
    erebor-sys subscribe
Values are JSON when they parse as JSON, strings otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

SOCKET = os.environ.get("EREBOR_SYSD_SOCKET", "/run/erebor/sysd.sock")


def parse(pairs: list[str]) -> dict:
    out = {}
    for p in pairs:
        key, sep, value = p.partition("=")
        if not sep:
            raise SystemExit(f"erebor-sys: {p!r}: give key=value")
        try:
            out[key] = json.loads(value)
        except json.JSONDecodeError:
            out[key] = value
    return out


def connect(req: dict):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCKET)
    except OSError as e:
        print(f"erebor-sys: erebor-sysd is not reachable at {SOCKET} ({e})", file=sys.stderr)
        return None
    f = s.makefile("rwb")
    f.write((json.dumps(req) + "\n").encode())
    f.flush()
    return f


def call(req: dict, raw: bool) -> int:
    f = connect(req)
    if f is None:
        return 1
    for line in f:
        line = json.loads(line)
        if raw:
            print(json.dumps(line), flush=True)
        elif line.get("event") == "approval-pending":
            print(f"waiting for approval ({', '.join(line.get('methods') or [])})…", file=sys.stderr, flush=True)
        if "ok" not in line:
            continue
        if not line["ok"]:
            if not raw:
                print(f"erebor-sys: {line.get('error')}", file=sys.stderr)
            return 1
        rest = {k: v for k, v in line.items() if k != "ok"}
        if rest and not raw:
            print(json.dumps(rest, indent=2))
        return 0
    print("erebor-sys: erebor-sysd closed the connection without a reply", file=sys.stderr)
    return 1


def subscribe() -> int:
    f = connect({"command": "subscribe"})
    if f is None:
        return 1
    for line in f:
        sys.stdout.write(line.decode())
        sys.stdout.flush()
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="erebor-sys", description="Talk to erebor-sysd.")
    ap.add_argument("--json", action="store_true", help="print every line as JSON")
    ap.add_argument("command")
    ap.add_argument("args", nargs="*", metavar="key=value")
    a = ap.parse_args(argv)
    if a.command == "subscribe":
        return subscribe()
    return call({"command": a.command, **parse(a.args)}, a.json)
