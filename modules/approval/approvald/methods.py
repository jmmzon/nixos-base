"""The approval methods. Each one is enabled and configured from Nix
(`my.approval.methods.<name>`), see core.Method for the interface."""

import json
import os
import secrets
import threading
import time

from . import verify
from .core import Method


def describe(req):
    """Text shown wherever the approver decides."""
    when = time.strftime("%H:%M:%S", time.localtime(req["expires"]))
    lines = [req["summary"], f"{req['caller']} · {req['action']} · {req['risk']} risk · until {when}"]
    lines += [f"{k}: {v}" for k, v in sorted(req["details"].items())]
    return "\n".join(lines)


class Store:
    """Enrolled credentials, one JSON file per method in the state directory."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def load(self):
        try:
            with open(self.path) as f:
                return json.load(f)
        except FileNotFoundError:
            return {}

    def save(self, data):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, self.path)

    def user(self, user):
        return self.load().get(user, [])

    def add(self, user, cred):
        with self.lock:
            data = self.load()
            data.setdefault(user, []).append(cred)
            self.save(data)

    def update(self, user, cred_id, **fields):
        with self.lock:
            data = self.load()
            for c in data.get(user, []):
                if c["id"] == cred_id:
                    c.update(fields)
            self.save(data)


class Desktop(Method):
    """Approve/Deny notification in the session. Weak: any process of the
    user can answer it, so by default it may not approve high-risk actions."""

    strength = "weak"

    def __init__(self, name, settings, hub):
        super().__init__(name, settings)
        self.hub = hub

    def available(self, req):
        return self.hub.connected()

    def run(self, ctx):
        reply = self.hub.call(
            "confirm",
            ctx.remaining(),
            ctx.cancel,
            tag=ctx.req["id"],
            title=f"Approve on {ctx.req['host']}?",
            body=describe(ctx.req),
        )
        answer = (reply or {}).get("answer")
        return {"approve": "approved", "deny": "denied"}.get(answer, "failed")


class Mac(Method):
    """A signature from the Mac's SSH agent (Touch ID), forwarded over the
    Mac approval tunnel, checked against the keys root provisioned."""

    def __init__(self, name, settings, hub):
        super().__init__(name, settings)
        self.hub = hub

    def keys(self, user):
        try:
            with open(os.path.join(self.settings["keysDir"], f"{user}.keys")) as f:
                return verify.read_authorized_keys(f.read())
        except OSError:
            return []

    def available(self, req):
        return bool(self.keys(req["user"])) and self.hub.probe().get("mac") is True

    def run(self, ctx):
        keys = self.keys(ctx.req["user"])
        data = verify.SSH_NAMESPACE + ctx.challenge
        ctx.progress(self.name, "asking")
        reply = self.hub.call(
            "mac-sign",
            ctx.remaining(),
            ctx.cancel,
            socket=self.settings.get("socket"),
            keys=[verify.b64u(k) for k in keys],
            data=verify.b64u(data),
            reason=describe(ctx.req).replace("\n", " — "),
        )
        if not reply or "signature" not in reply:
            return "denied" if (reply or {}).get("refused") else "failed"
        try:
            key = verify.unb64u(reply["key"])
            sig = verify.unb64u(reply["signature"])
        except (KeyError, ValueError, TypeError):
            return "failed"
        if key in keys and verify.ssh_verify(key, sig, data):
            return "approved"
        return "failed"


class YubiKey(Method):
    """A FIDO2 touch on an enrolled security key. The session agent passes the
    assertion through; the daemon checks it against the enrolled public key."""

    def __init__(self, name, settings, hub, state):
        super().__init__(name, settings)
        self.hub = hub
        self.rp_id = settings.get("rpId", "approvald")
        self.store = Store(os.path.join(state, "yubikey.json"))

    def available(self, req):
        return bool(self.store.user(req["user"])) and self.hub.probe().get("fido") is True

    def run(self, ctx):
        user = ctx.req["user"]
        creds = {c["id"]: c for c in self.store.user(user)}
        ctx.progress(self.name, "touch")
        reply = self.hub.call(
            "fido-assert",
            ctx.remaining(),
            ctx.cancel,
            tag=ctx.req["id"],
            rp_id=self.rp_id,
            client_data_hash=verify.b64u(ctx.challenge),
            credentials=list(creds),
            title=f"Touch the security key to approve on {ctx.req['host']}",
            body=describe(ctx.req),
        )
        if not reply or "signature" not in reply:
            return "failed"
        cred = creds.get(reply.get("credential"))
        if cred is None:
            return "failed"
        try:
            counter = verify.fido_verify(
                verify.unb64u(cred["public_key"]),
                self.rp_id,
                ctx.challenge,
                verify.unb64u(reply["auth_data"]),
                verify.unb64u(reply["signature"]),
                cred.get("counter", 0),
            )
        except (KeyError, ValueError, TypeError):
            return "failed"
        if counter is None:
            return "failed"
        self.store.update(user, cred["id"], counter=counter, last_used=int(time.time()))
        return "approved"

    def enroll(self, user, cred):
        """Store a credential the root enroll command made on the key."""
        entry = {
            "id": str(cred["id"]),
            "public_key": str(cred["public_key"]),
            "counter": 0,
            "created": int(time.time()),
        }
        verify.unb64u(entry["id"]), verify.unb64u(entry["public_key"])
        self.store.add(user, entry)


class Phone(Method):
    """A passkey on the phone, on a one-time page; the link reaches the phone
    by each configured delivery (KDE Connect, a notification, a QR code)."""

    def __init__(self, name, settings, hub, state, web):
        super().__init__(name, settings)
        self.hub = hub
        self.web = web
        self.store = Store(os.path.join(state, "phone.json"))
        self.web.store = self.store
        self.deliveries = settings.get("delivery", ["kdeconnect"])
        self.device = settings.get("kdeconnectDevice")

    def usable_deliveries(self):
        if not self.hub.connected():
            return []
        probe = self.hub.probe()
        return [d for d in self.deliveries if d != "kdeconnect" or (self.device and probe.get("kdeconnect"))]

    def available(self, req):
        return bool(self.store.user(req["user"])) and bool(self.usable_deliveries())

    def run(self, ctx):
        entry = self.web.open("approve", ctx.req["user"], ctx.challenge, ctx.req["expires"], describe(ctx.req), ctx.req["host"])
        url = entry["url"]
        try:
            sent = False
            for d in self.usable_deliveries():
                if d == "kdeconnect":
                    r = self.hub.call("share", 8, ctx.cancel, device=self.device, url=url)
                else:  # notification, qr
                    r = self.hub.call(
                        d,
                        8,
                        ctx.cancel,
                        tag=ctx.req["id"],
                        title=f"Approve on {ctx.req['host']} with the phone",
                        body=describe(ctx.req),
                        url=url,
                    )
                sent = sent or bool(r and r.get("ok"))
            if not sent:
                return "failed"
            ctx.progress(self.name, "link-sent")
            ctx.wait(entry["done"])
            return entry["result"] if entry["done"].is_set() else "failed"
        finally:
            self.web.close(entry["token"])
            self.hub.dismiss(ctx.req["id"])


class Fake(Method):
    """Test-only: answers as configured (approve, deny, fail, timeout) after
    `delay` seconds. The module refuses it unless my.approval.testing is set."""

    def __init__(self, name, settings):
        super().__init__(name, settings)
        self.strength = settings.get("strength", "strong")
        self.allow_high_risk = bool(settings.get("allowHighRisk", self.strength == "strong"))

    def run(self, ctx):
        answer = self.settings.get("answer", "approve")
        path = self.settings.get("answerFile")
        if path:
            try:
                with open(path) as f:
                    answer = f.read().strip() or answer
            except OSError:
                pass
        done = threading.Event()
        done.wait(min(float(self.settings.get("delay", 0)), ctx.remaining()))
        if answer == "timeout":
            ctx.wait(threading.Event())
            return "failed"
        return {"approve": "approved", "deny": "denied"}.get(answer, "failed")


def build(config, hub, state, web):
    """The enabled methods, by name."""
    out = {}
    for name, settings in config["methods"].items():
        if not settings.get("enable"):
            continue
        kind = settings.get("type", name)
        if kind == "phone":
            out[name] = Phone(name, settings, hub, state, web)
        elif kind == "yubikey":
            out[name] = YubiKey(name, settings, hub, state)
        elif kind == "mac":
            out[name] = Mac(name, settings, hub)
        elif kind == "desktop":
            out[name] = Desktop(name, settings, hub)
        elif kind == "fake" and config.get("testing"):
            out[name] = Fake(name, settings)
        else:
            raise SystemExit(f"approvald: unknown or disallowed method {name} ({kind})")
    return out


def new_token():
    return secrets.token_urlsafe(18)
