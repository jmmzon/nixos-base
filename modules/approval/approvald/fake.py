"""approvald-fake: a stand-in daemon for callers' tests (e.g. a control daemon).

  approvald-fake --socket PATH --answer approve|deny|timeout|failed|error:CODE [--delay S]

Speaks protocol v1 (docs/approval-protocol.md) without checking the peer or
asking anyone. Each request is answered with `--answer` after `--delay`
seconds; "timeout" waits for the request's own timeout. Requests are
validated like the real daemon's, and every request line it got is printed
to stdout as JSON, so a test can check what its caller sent.
"""

import argparse
import json
import os
import secrets
import socket
import sys
import threading
import time

from . import core


def serve(path, answer, delay):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(16)

    def handle(conn):
        with conn:
            f = conn.makefile("rwb")
            line = f.readline(core.MAX_SUMMARY * 40)
            send = lambda o: (f.write((json.dumps(o) + "\n").encode()), f.flush())
            try:
                msg = json.loads(line)
            except ValueError:
                return send({"error": "bad-request"})
            print(json.dumps(msg), flush=True)
            if msg.get("op") == "ping":
                return send({"ok": True, "version": core.PROTOCOL})
            if msg.get("op") == "methods":
                return send({"methods": [{"name": "fake", "strength": "strong", "allowHighRisk": True}], "caller": "fake"})
            try:
                req = core.parse_request(msg, 300, 60)
            except core.BadRequest as e:
                return send({"error": "bad-request", "field": str(e)})
            if answer.startswith("error:"):
                return send({"error": answer[6:]})
            rid = secrets.token_urlsafe(12)
            send({"event": "pending", "request": rid, "methods": ["fake"], "expires": int(time.time() + req["timeout"])})
            time.sleep(req["timeout"] if answer == "timeout" else min(delay, req["timeout"]))
            result = {"approve": "approved", "deny": "denied"}.get(answer, answer)
            final = {"result": result, "request": rid}
            if result in ("approved", "denied"):
                final["method"] = "fake"
            send(final)

    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


def main(argv=None):
    p = argparse.ArgumentParser(prog="approvald-fake")
    p.add_argument("--socket", required=True)
    p.add_argument("--answer", default="approve")
    p.add_argument("--delay", type=float, default=0)
    a = p.parse_args(argv)
    serve(a.socket, a.answer, a.delay)


if __name__ == "__main__":
    sys.exit(main())
