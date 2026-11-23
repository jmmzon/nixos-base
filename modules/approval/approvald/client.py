"""Clients of the request socket.

  approval-pam                      sudo's PAM step (pam_exec, root)
  approval methods                  what this caller may use
  approval test [--methods a,b] [--risk low|high] [--timeout S] [SUMMARY]
  approval enroll phone|yubikey     (root; through sudo)
"""

import argparse
import json
import os
import socket
import sys
import time

SOCKET = os.environ.get("APPROVALD_SOCKET", "/run/approvald/request.sock")
REASON_DIR = "/run/auth-reason"


def connect(timeout=5):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCKET)
    return s


def exchange(msg, wait, on_line=None):
    """Send `msg`, return the final reply (the first line without "event")."""
    s = connect()
    try:
        s.sendall((json.dumps(msg) + "\n").encode())
        s.settimeout(wait + 10)
        f = s.makefile("r")
        for line in f:
            reply = json.loads(line)
            if "event" in reply or "url" in reply:
                if on_line:
                    on_line(reply)
                continue
            return reply
        return {"error": "eof"}
    finally:
        s.close()


def request(action, summary, methods=None, risk="high", timeout=60, details=None, on_line=None):
    msg = {"v": 1, "op": "request", "action": action, "summary": summary, "risk": risk, "timeout": timeout}
    if methods:
        msg["methods"] = methods
    if details:
        msg["details"] = details
    try:
        return exchange(msg, timeout, on_line)
    except (OSError, ValueError) as e:
        return {"error": type(e).__name__}


def pam_reason(user):
    try:
        with open(f"{REASON_DIR}/{user}") as f:
            stamp, what = f.readline().rstrip("\n").split("\t", 1)
        if time.time() - int(stamp) < 30:
            return what
    except (OSError, ValueError):
        pass
    return "sudo"


def pam_main():
    """Exit 0 only when the daemon approved this sudo for the approver."""
    if os.environ.get("PAM_TYPE") != "auth":
        return 1
    user = os.environ.get("PAM_USER", "")
    if user != os.environ.get("APPROVAL_USER"):
        return 1  # the daemon approves as its configured user only
    methods = [m for m in os.environ.get("APPROVAL_PAM_METHODS", "").split(",") if m]
    timeout = float(os.environ.get("APPROVAL_PAM_TIMEOUT", "30"))
    service = os.environ.get("PAM_SERVICE", "pam")
    reply = request(
        service,
        pam_reason(user),
        methods=methods or None,
        risk="high",
        timeout=timeout,
        details={"user": user, "service": service},
    )
    print(f"approval: {service} {user}: {reply.get('result') or reply.get('error')}", file=sys.stderr, flush=True)
    return 0 if reply.get("result") == "approved" else 1


def cli_main(argv):
    p = argparse.ArgumentParser(prog="approval")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("methods")
    t = sub.add_parser("test", help="ask for an approval and print the result")
    t.add_argument("--methods", default="")
    t.add_argument("--risk", choices=["low", "high"], default="low")
    t.add_argument("--timeout", type=float, default=60)
    t.add_argument("--action", default="test")
    t.add_argument("summary", nargs="?", default="Test approval")
    e = sub.add_parser("enroll")
    e.add_argument("method", choices=["phone", "yubikey"])
    a = p.parse_args(argv)

    if a.cmd == "methods":
        print(json.dumps(exchange({"v": 1, "op": "methods"}, 5), indent=2))
        return 0
    if a.cmd == "test":
        methods = [m for m in a.methods.split(",") if m] or None
        r = request(a.action, a.summary, methods, a.risk, a.timeout, on_line=lambda l: print(json.dumps(l), flush=True))
        print(json.dumps(r))
        return 0 if r.get("result") == "approved" else 1
    if os.geteuid() != 0:
        os.execv("/run/wrappers/bin/sudo", ["sudo", sys.argv[0], *argv])
    if a.method == "phone":
        r = exchange(
            {"v": 1, "op": "enroll", "method": "phone"},
            600,
            on_line=lambda l: print(f"Open this on the phone (also sent by KDE Connect if set up):\n  {l['url']}", flush=True),
        )
    else:
        r = enroll_yubikey()
    print(json.dumps(r))
    return 0 if r.get("result") == "enrolled" else 1


def enroll_yubikey():
    """Make a credential on the plugged-in key (touch it) and hand the public
    key to the daemon. Runs as root, talking to the key directly."""
    import base64
    import secrets

    from fido2 import cbor
    from fido2.ctap2 import Ctap2
    from fido2.hid import CtapHidDevice

    rp_id = os.environ.get("APPROVAL_YUBIKEY_RP_ID", "approvald")
    devs = list(CtapHidDevice.list_devices())
    if not devs:
        return {"error": "no security key plugged in"}
    print("Touch the security key…", flush=True)
    att = Ctap2(devs[0]).make_credential(
        secrets.token_bytes(32),
        {"id": rp_id, "name": "approval"},
        {"id": secrets.token_bytes(16), "name": "approval"},
        [{"type": "public-key", "alg": -7}, {"type": "public-key", "alg": -8}],
        options={"rk": False},
    )
    cd = att.auth_data.credential_data

    def enc(b):
        return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

    cred = {"id": enc(cd.credential_id), "public_key": enc(cbor.encode(dict(cd.public_key)))}
    return exchange({"v": 1, "op": "enroll", "method": "yubikey", "credential": cred}, 10)


if __name__ == "__main__":
    sys.exit(cli_main(sys.argv[1:]))
