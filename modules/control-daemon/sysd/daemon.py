"""erebor-sysd: the system control daemon.

One entry point for machine-level actions (power profile, sleep, power off,
reboot into Windows) and for desktop commands, which it forwards to the
user's erebor-desktopd over that daemon's uplink. Every request passes the
policy (none / approve / deny per action, caller and origin); "approve"
asks approvald and streams its progress before the reply.

Built on erebor_desktop.server (features, one JSON object per line):
    {"command": "set-power-profile", "profile": "balanced",
     "origin": "dashboard", "origin_user": "alice"}
    {"command": "desktop.set-noctalia-preset", "look": "glass"}
    {"command": "list-actions"}    each action's approval for this caller
    {"command": "subscribe"}       sysd's events and the desktop's (source: desktop)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import pwd
import signal
import sys

from erebor_desktop.server import Daemon, Feature, listen_fds, sd_notify

from .actions import ACTIONS, VALIDATE, Context, Runner, desktop_read_only
from .approval import approved, ask
from .errors import Refused
from .policy import ORIGIN_RE, ORIGIN_USER_RE, Policy
from .uplink import Uplinks

DESKTOP = "desktop."
log = logging.getLogger("erebor-sysd")


class Sysd:
    def __init__(self, config: dict, runner=None):
        self.config = config
        self.policy = Policy(config)
        self.daemon: Daemon | None = None
        session_user = (config.get("session") or {}).get("user")
        uid = None
        if session_user:
            try:
                uid = pwd.getpwnam(session_user).pw_uid
            except KeyError:
                log.warning("config: session user %s does not exist; no uplink", session_user)
        self.uplinks = Uplinks(uid, self._emit)
        self.actx = Context(runner or Runner(), config, self._emit)
        self._session_server: asyncio.Server | None = None

    def _emit(self, event: dict) -> None:
        if self.daemon is not None:
            self.daemon.emit(event)

    # ── Features ─────────────────────────────────────────────────────────────
    def features(self) -> list[Feature]:
        actions = Feature("actions", events=["power-profile-changed"])
        for name, action in ACTIONS.items():
            actions.command(name, cancel_on_hangup=True)(self._guarded(name, action))

        @actions.command("list-actions")
        async def list_actions(ctx, req):
            try:
                return self._list_actions(req, ctx.connection)
            except Refused as e:
                return e.reply

        desktop = Feature("desktop", events=["session-up", "session-down"], flat_snapshot=True)
        desktop.prefix(DESKTOP, cancel_on_hangup=True)(self._forward)
        desktop.snapshot = lambda ctx: {
            "session": "up" if self.uplinks.up else "down",
            "desktop": self.uplinks.state,
        }
        return [actions, desktop]

    def _accept(self, conn) -> bool:
        if conn.peer is None:
            return False
        caller = self.policy.caller(conn.peer.uid, conn.peer.gids)
        if caller is None:
            log.warning("refused uid %s (pid %s): not a caller", conn.peer.uid, conn.peer.pid)
            return False
        conn.data["caller"] = caller
        return True

    @staticmethod
    def _origin(req: dict) -> tuple[str | None, str | None]:
        origin, user = req.get("origin"), req.get("origin_user")
        if origin is not None and not (isinstance(origin, str) and ORIGIN_RE.fullmatch(origin)):
            raise Refused("bad origin", code="bad-request", field="origin")
        if user is not None and not (isinstance(user, str) and ORIGIN_USER_RE.fullmatch(user)):
            raise Refused("bad origin_user", code="bad-request", field="origin_user")
        return origin, user

    # ── Policy and approval ─────────────────────────────────────────────────
    async def _gate(self, name, summary, read_only, req, conn, before_approval=None):
        """Yield approval progress; raise Refused when the request may not run."""
        caller = conn.data["caller"]
        origin, ouser = self._origin(req)
        level = self.policy.decide(name, caller, origin, read_only)
        who = f"caller={caller} uid={conn.peer.uid} origin={origin or '-'} user={ouser or '-'}"
        if level == "deny":
            log.info("%s: %s: refused by policy", name, who)
            raise Refused("refused by policy", code="forbidden")
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
                log.info("%s: %s: not approved (%s)", name, who, outcome)
                raise Refused(f"not approved ({outcome})", code="not-approved", result=outcome)
            log.info("%s: %s: approved by %s", name, who, final.get("method"))
        elif not read_only:
            log.info("%s: %s: allowed", name, who)

    def _guarded(self, name, action):
        async def handler(ctx, req):
            try:
                if name in VALIDATE:
                    VALIDATE[name](req)
                async for line in self._gate(name, action.summary(req), action.read_only, req, ctx.connection):
                    yield line
                # Once approved, a hang-up does not stop the action halfway.
                result = await asyncio.shield(action.run(self.actx, req))
                yield {"ok": True, **result}
            except Refused as e:
                yield e.reply

        return handler

    async def _forward(self, ctx, req):
        name = req.get("command", "")
        sub = name[len(DESKTOP) :]
        try:
            if not sub or sub in ("subscribe", "describe"):
                raise Refused(f"unknown command {name!r}", code="bad-request")

            def need_session():
                if not self.uplinks.up:
                    raise Refused("no desktop session", code="no-session")

            async for line in self._gate(
                name, f"Desktop: {sub}", desktop_read_only(sub), req, ctx.connection, before_approval=need_session
            ):
                yield line
            fwd = {k: v for k, v in req.items() if k not in ("command", "id", "origin", "origin_user")}
            reply = await asyncio.shield(self.uplinks.call({**fwd, "command": sub}))
            reply.setdefault("ok", False)
            yield reply
        except Refused as e:
            yield e.reply

    def _list_actions(self, req, conn):
        caller = conn.data["caller"]
        origin, _ = self._origin(req)
        names = list(ACTIONS) + [n for n in self.policy.actions if n.startswith(DESKTOP)]
        out = {}
        for n in names:
            ro = ACTIONS[n].read_only if n in ACTIONS else desktop_read_only(n[len(DESKTOP) :])
            out[n] = self.policy.decide(n, caller, origin, ro)
        return {"ok": True, "caller": caller, "actions": out, "session": "up" if self.uplinks.up else "down"}

    # ── Serving ─────────────────────────────────────────────────────────────
    async def start(self, control=None, session=None, fds=None):
        fds = fds or {}
        self.daemon = Daemon(
            self.features(),
            control or "/run/erebor/sysd.sock",
            self.config,
            name="erebor-sysd",
            accept=self._accept,
            sock=fds.get("control"),
        )
        await self.daemon.start()
        if control and "control" not in fds:
            os.chmod(control, 0o660)
        if "session" in fds:
            self._session_server = await asyncio.start_unix_server(
                self.uplinks.accept, sock=fds["session"], limit=64 * 1024, cleanup_socket=False
            )
        elif session:
            try:
                os.unlink(session)
            except FileNotFoundError:
                pass
            self._session_server = await asyncio.start_unix_server(self.uplinks.accept, session, limit=64 * 1024)
            os.chmod(session, 0o666)

    async def stop(self):
        if self._session_server is not None:
            self._session_server.close()
        if self.uplinks.session is not None:
            self.uplinks.session.close()
        if self.daemon is not None:
            await self.daemon.stop()


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s", stream=sys.stderr)
    path = os.environ.get("SYSD_CONFIG")
    if not path:
        sys.exit("erebor-sysd: set SYSD_CONFIG")
    with open(path) as f:
        config = json.load(f)
    sockets = config.get("sockets") or {}

    async def run():
        d = Sysd(config)
        await d.start(sockets.get("control"), sockets.get("session"), listen_fds())
        sd_notify("READY=1")
        log.info("ready: %d actions, %d policy entries", len(ACTIONS), len(d.policy.actions))
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()
        sd_notify("STOPPING=1")
        await d.stop()

    asyncio.run(run())
    return 0
