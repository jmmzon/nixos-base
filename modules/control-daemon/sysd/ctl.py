"""erebor-sys: a small client for erebor-sysd.

    erebor-sys set-power-profile profile=balanced
    erebor-sys desktop.set-noctalia-preset look=glass-pbsio2
    erebor-sys list-actions
    erebor-sys subscribe
Values are JSON when they parse as JSON, strings otherwise.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

import jsonline

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


async def call(req: dict, raw: bool) -> int:
    try:
        async for line in jsonline.request(SOCKET, req, timeout=5):
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
    except (OSError, ConnectionError) as e:
        print(f"erebor-sys: erebor-sysd is not reachable at {SOCKET} ({e})", file=sys.stderr)
        return 1
    return 1


async def subscribe() -> int:
    try:
        reader, writer = await asyncio.open_unix_connection(SOCKET, limit=jsonline.MAX_LINE)
    except OSError as e:
        print(f"erebor-sys: erebor-sysd is not reachable at {SOCKET} ({e})", file=sys.stderr)
        return 1
    writer.write(b'{"command":"subscribe"}\n')
    await writer.drain()
    while raw := await reader.readline():
        sys.stdout.write(raw.decode())
        sys.stdout.flush()
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="erebor-sys", description="Talk to erebor-sysd.")
    ap.add_argument("--json", action="store_true", help="print every line as JSON")
    ap.add_argument("command")
    ap.add_argument("args", nargs="*", metavar="key=value")
    a = ap.parse_args(argv)
    if a.command == "subscribe":
        return asyncio.run(subscribe())
    return asyncio.run(call({"command": a.command, **parse(a.args)}, a.json))
