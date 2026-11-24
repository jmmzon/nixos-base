"""erebor-sysd: the system control daemon.

One entry point for machine-level actions (power profile, sleep, power off,
reboot into Windows) and for desktop commands, which it forwards to the
user's erebor-desktopd over that daemon's uplink. Every request passes the
policy (none / approve / deny per action, caller and origin); "approve"
asks approvald and streams its progress before the reply.

Requests (JSON per line, jsonline):
    {"command": "set-power-profile", "profile": "balanced",
     "origin": "dashboard", "origin_user": "alice"}
    {"command": "desktop.set-noctalia-preset", "look": "glass"}
    {"command": "list-actions"}    each action's approval for this caller
    {"command": "subscribe"}       sysd's events and the desktop's (source: desktop)
"""

from __future__ import annotations

import asyncio
import json
import os
import pwd
import sys

from jsonline import Command, Error, Server, listen_fds, notify

from .actions import ACTIONS, VALIDATE, Context, Runner, desktop_read_only
from .approval import approved, ask
from .policy import ORIGIN_RE, ORIGIN_USER_RE, Policy
from .uplink import Uplinks

DESKTOP = "desktop."


def log(msg: str) -> None:
    print(f"erebor-sysd: {msg}", file=sys.stderr, flush=True)


class Sysd:
    def __init__(self, config: dict, runner=None):
        self.config = config
        self.policy = Policy(config)
        self.server = Server()
        session_user = (config.get("session") or {}).get("user")
        uid = None
        if session_user:
            try:
                uid = pwd.getpwnam(session_user).pw_uid
            except KeyError:
                log(f"config: session user {session_user} does not exist; no uplink")
        self.uplinks = Uplinks(uid, self.server.emit)
        self.ctx = Context(runner or Runner(), config, self.server.emit)

        self.server.accept = self._accept
        self.server.hello = lambda conn: {
            "session": "up" if self.uplinks.up else "down",
            "desktop": self.uplinks.state,
        }
        for name, action in ACTIONS.items():
            self.server.add({name: Command(self._guarded(name, action), hangup_cancels=True)})
        self.server.add({"list-actions": self._list_actions})
        self.server.fallback = Command(self._forward, hangup_cancels=True)

    # ── Connections ──────────────────────────────────────────────────────────
    def _accept(self, conn) -> bool:
        if conn.peer is None:
            return False
        caller = self.policy.caller(conn.peer.uid, conn.peer.gids)
        if caller is None:
            log(f"refused uid {conn.peer.uid} (pid {conn.peer.pid}): not a caller")
            return False
        conn.data["caller"] = caller
        return True

    @staticmethod
    def _origin(req: dict) -> tuple[str | None, str | None]:
        origin, user = req.get("origin"), req.get("origin_user")
        if origin is not None and not (isinstance(origin, str) and ORIGIN_RE.fullmatch(origin)):
            raise Error("bad origin", code="bad-request", field="origin")
        if user is not None and not (isinstance(user, str) and ORIGIN_USER_RE.fullmatch(user)):
            raise Error("bad origin_user", code="bad-request", field="origin_user")
        return origin, user

    # ── Policy and approval ─────────────────────────────────────────────────
    async def _gate(self, name: str, summary: str, read_only: bool, req: dict, conn, before_approval=None):
        """Yield approval progress; raise Error when the request may not run."""
        caller = conn.data["caller"]
        origin, ouser = self._origin(req)
        level = self.policy.decide(name, caller, origin, read_only)
        who = f"caller={caller} uid={conn.peer.uid} origin={origin or '-'} user={ouser or '-'}"
        if level == "deny":
            log(f"{name}: {who}: refused by policy")
            raise Error("refused by policy", code="forbidden")
        if before_approval is not None:
            before_approval()
        if level == "approve":
            opts = self.policy.approval_options(name)
            approval = self.config.get("approval") or {}
            final = {"result": "failed"}
            async for line in ask(
                approval.get("socket", "/run/approvald/request.sock"),
                action=name,
                summary=summary,
                details={"caller": caller, "origin": origin, "user": ouser},
                methods=opts.get("methods") or approval.get("methods"),
                risk=opts["risk"],
                timeout=int(approval.get("timeout", 60)),
            ):
                if "event" in line:
                    yield {**{k: v for k, v in line.items() if k != "event"}, "event": f"approval-{line['event']}"}
                else:
                    final = line
            outcome = final.get("result") or final.get("error") or "failed"
            if not approved(final):
                log(f"{name}: {who}: not approved ({outcome})")
                raise Error(f"not approved ({outcome})", code="not-approved", result=outcome)
            log(f"{name}: {who}: approved by {final.get('method')}")
        elif not read_only:
            log(f"{name}: {who}: allowed")

    def _guarded(self, name, action):
        async def handler(req, conn):
            if name in VALIDATE:
                VALIDATE[name](req)
            async for line in self._gate(name, action.summary(req), action.read_only, req, conn):
                yield line
            # Once approved, a hang-up does not stop the action halfway.
            result = await asyncio.shield(action.run(self.ctx, req))
            yield {"ok": True, **result}

        return handler

    async def _forward(self, req, conn):
        name = req.get("command", "")
        sub = name[len(DESKTOP) :] if name.startswith(DESKTOP) else ""
        if not sub or sub == "subscribe":
            raise Error(f"unknown command {name!r}")

        def need_session():
            if not self.uplinks.up:
                raise Error("no desktop session", code="no-session")

        async for line in self._gate(
            name, f"Desktop: {sub}", desktop_read_only(sub), req, conn, before_approval=need_session
        ):
            yield line
        fwd = {k: v for k, v in req.items() if k not in ("command", "id", "origin", "origin_user")}
        reply = await asyncio.shield(self.uplinks.call({**fwd, "command": sub}))
        reply.setdefault("ok", False)
        yield reply

    async def _list_actions(self, req, conn):
        caller = conn.data["caller"]
        origin, _ = self._origin(req)
        names = list(ACTIONS) + [n for n in self.policy.actions if n.startswith(DESKTOP)]
        out = {}
        for n in names:
            ro = ACTIONS[n].read_only if n in ACTIONS else desktop_read_only(n[len(DESKTOP) :])
            out[n] = self.policy.decide(n, caller, origin, ro)
        return {"caller": caller, "actions": out, "session": "up" if self.uplinks.up else "down"}

    # ── Serving ─────────────────────────────────────────────────────────────
    async def start(self, control=None, session=None, fds=None):
        fds = fds or {}
        if "control" in fds:
            await self.server.serve_socket(fds["control"])
        else:
            await self.server.serve_unix(control, 0o660)
        if "session" in fds:
            await asyncio.start_unix_server(self.uplinks.accept, sock=fds["session"], limit=64 * 1024)
        elif session:
            try:
                os.unlink(session)
            except FileNotFoundError:
                pass
            await asyncio.start_unix_server(self.uplinks.accept, session, limit=64 * 1024)
            os.chmod(session, 0o666)


def main(argv=None) -> int:
    path = os.environ.get("SYSD_CONFIG")
    if not path:
        sys.exit("erebor-sysd: set SYSD_CONFIG")
    with open(path) as f:
        config = json.load(f)
    sockets = config.get("sockets") or {}

    async def run():
        d = Sysd(config)
        await d.start(sockets.get("control"), sockets.get("session"), listen_fds())
        notify()
        log(f"ready: {len(ACTIONS)} actions, {len(d.policy.actions)} policy entries")
        await asyncio.Event().wait()

    asyncio.run(run())
    return 0
