"""Request handling shared by every method: validation, caller policy,
challenge binding, method racing, rate limits.

Nothing here touches sockets or devices, so it is unit-tested directly.
"""

import hashlib
import json
import queue
import re
import secrets
import threading
import time

PROTOCOL = 1
ACTION_RE = re.compile(r"^[a-z0-9._-]{1,64}$")
NAME_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
MAX_SUMMARY = 200
MAX_DETAILS = 8
MAX_DETAIL = 100
RISKS = ("low", "high")


class BadRequest(Exception):
    pass


def clean_text(value, limit):
    """Printable text only: control characters would let a caller fake extra
    lines in a notification or on the phone page."""
    if not isinstance(value, str):
        raise BadRequest("text")
    text = "".join(c if c.isprintable() else " " for c in value)
    return text.strip()[:limit]


def parse_request(msg, max_timeout, default_timeout):
    """The request fields the daemon keeps, or BadRequest."""
    if not isinstance(msg, dict) or msg.get("v") != PROTOCOL or msg.get("op") != "request":
        raise BadRequest("op")
    action = msg.get("action")
    if not isinstance(action, str) or not ACTION_RE.match(action):
        raise BadRequest("action")
    summary = clean_text(msg.get("summary", action), MAX_SUMMARY) or action
    details = msg.get("details", {})
    if not isinstance(details, dict) or len(details) > MAX_DETAILS:
        raise BadRequest("details")
    details = {
        clean_text(k, 32): clean_text(v, MAX_DETAIL)
        for k, v in details.items()
        if isinstance(k, str) and isinstance(v, str)
    }
    methods = msg.get("methods")
    if methods is not None:
        if not isinstance(methods, list) or not all(isinstance(m, str) for m in methods):
            raise BadRequest("methods")
    risk = msg.get("risk", "high")
    if risk not in RISKS:
        raise BadRequest("risk")
    timeout = msg.get("timeout", default_timeout)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
        raise BadRequest("timeout")
    return {
        "action": action,
        "summary": summary,
        "details": details,
        "methods": methods,
        "risk": risk,
        "timeout": min(float(timeout), max_timeout),
    }


def statement(req):
    """The canonical bytes every method's signature is bound to."""
    fields = {
        "v": PROTOCOL,
        "host": req["host"],
        "request": req["id"],
        "nonce": req["nonce"],
        "caller": req["caller"],
        "action": req["action"],
        "summary": req["summary"],
        "details": req["details"],
        "risk": req["risk"],
        "user": req["user"],
        "expires": req["expires"],
    }
    return json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def challenge(req):
    return hashlib.sha256(statement(req)).digest()


class RateLimit:
    """Token bucket: `burst` requests at once, refilled at `per_minute`."""

    def __init__(self, burst, per_minute, clock=time.monotonic):
        self.burst, self.rate, self.clock = burst, per_minute / 60.0, clock
        self.tokens, self.last = float(burst), clock()

    def take(self):
        now = self.clock()
        self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens < 1:
            return False
        self.tokens -= 1
        return True


class Context:
    """What a method gets for one request."""

    def __init__(self, req, emit):
        self.req = req
        self.statement = statement(req)
        self.challenge = challenge(req)
        self.cancel = threading.Event()
        self._emit = emit

    def remaining(self):
        return max(0.0, self.req["expires"] - time.time())

    def expired(self):
        return self.cancel.is_set() or self.remaining() <= 0

    def wait(self, event):
        """Wait for `event` until the request ends; True if it was set."""
        while not self.expired():
            if event.wait(min(0.5, self.remaining())):
                return True
        return event.is_set()

    def progress(self, method, state):
        try:
            self._emit({"event": "progress", "method": method, "state": state})
        except OSError:
            self.cancel.set()


class Method:
    """A way to approve. Subclasses override `available` and `run`.

    `run` returns "approved", "denied" or "failed" and must return soon after
    `ctx.cancel` is set or the request expires. It returns "approved" only
    after checking a signature bound to `ctx.challenge`, except for weak
    methods (strength "weak")."""

    strength = "strong"

    def __init__(self, name, settings):
        self.name = name
        self.settings = settings
        default = self.strength == "strong"
        self.allow_high_risk = bool(settings.get("allowHighRisk", default))

    def available(self, req):
        return True

    def run(self, ctx):
        raise NotImplementedError


class Broker:
    def __init__(self, config, methods, host, log=print):
        self.config = config
        self.methods = methods  # name -> Method, enabled ones only
        self.host = host
        self.log = log
        self.lock = threading.Lock()
        self.pending = set()  # caller names with a request in flight
        self.limits = {
            name: RateLimit(c["rateLimit"]["burst"], c["rateLimit"]["perMinute"])
            for name, c in config["callers"].items()
        }

    def caller_for(self, uid, gids):
        """The configured caller a peer is, by uid first, then by group."""
        callers = self.config["callers"]
        for name in sorted(callers):
            if uid in callers[name]["uids"]:
                return name
        for name in sorted(callers):
            if set(gids) & set(callers[name]["gids"]):
                return name
        return None

    def choose(self, caller, req):
        allowed = self.config["callers"][caller]["methods"]
        wanted = req["methods"] if req["methods"] is not None else allowed
        chosen = []
        for name in wanted:
            m = self.methods.get(name)
            if m is None or name not in allowed or name in chosen:
                continue
            if req["risk"] == "high" and not m.allow_high_risk:
                continue
            chosen.append(name)
        return chosen

    def methods_info(self):
        return [
            {"name": n, "strength": m.strength, "allowHighRisk": m.allow_high_risk}
            for n, m in sorted(self.methods.items())
        ]

    def handle(self, caller, msg, emit, cancel=None):
        """Run one request for `caller`; returns the final message.

        `emit` sends an intermediate line; `cancel` is set when the caller hangs up."""
        cfg = self.config
        try:
            fields = parse_request(msg, cfg["maxTimeout"], cfg["defaultTimeout"])
        except BadRequest as e:
            return {"error": "bad-request", "field": str(e)}
        with self.lock:
            if caller in self.pending:
                return {"error": "busy"}
            if not self.limits[caller].take():
                return {"error": "rate-limited"}
            self.pending.add(caller)
        try:
            return self._run(caller, fields, emit, cancel)
        finally:
            with self.lock:
                self.pending.discard(caller)

    def _run(self, caller, fields, emit, cancel):
        req = {
            **fields,
            "id": secrets.token_urlsafe(12),
            "nonce": secrets.token_urlsafe(24),
            "caller": caller,
            "user": self.config["user"],
            "host": self.host,
            "expires": int(time.time() + fields["timeout"]),
        }
        names = [n for n in self.choose(caller, req) if self._available(n, req)]
        if not names:
            self.log(f"{req['id']} {caller} {req['action']}: no method")
            return {"error": "no-method"}
        ctx = Context(req, emit)
        emit({"event": "pending", "request": req["id"], "methods": names, "expires": req["expires"]})
        self.log(f"{req['id']} {caller} {req['action']} ({req['risk']}): asking {','.join(names)}: {req['summary']}")

        results = queue.Queue()

        def runner(name):
            try:
                outcome = self.methods[name].run(ctx)
            except Exception as e:  # a broken method never approves
                self.log(f"{req['id']} {name}: error {e!r}")
                outcome = "failed"
            results.put((name, outcome if outcome in ("approved", "denied") else "failed"))

        for n in names:
            threading.Thread(target=runner, args=(n,), daemon=True).start()

        final = {"result": "timeout", "request": req["id"]}
        open_methods, denied = set(names), None
        try:
            while open_methods and not ctx.expired():
                if cancel is not None and cancel.is_set():
                    final = {"result": "cancelled", "request": req["id"]}
                    break
                try:
                    name, outcome = results.get(timeout=min(0.5, ctx.remaining()) or 0.01)
                except queue.Empty:
                    continue
                open_methods.discard(name)
                if outcome == "approved" and time.time() <= req["expires"]:
                    final = {"result": "approved", "request": req["id"], "method": name}
                    break
                if outcome == "denied":
                    denied = name
                    if self.config["onDeny"] == "deny":
                        break
            else:
                if not open_methods and denied is None:
                    final = {"result": "failed", "request": req["id"]}
            if final["result"] != "approved" and denied is not None:
                final = {"result": "denied", "request": req["id"], "method": denied}
        finally:
            ctx.cancel.set()
        self.log(f"{req['id']} {caller} {req['action']}: {final['result']} {final.get('method', '')}".rstrip())
        return final

    def _available(self, name, req):
        try:
            return bool(self.methods[name].available(req))
        except Exception as e:
            self.log(f"{name}: available() failed: {e!r}")
            return False
