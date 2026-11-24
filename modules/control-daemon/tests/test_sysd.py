"""erebor-sysd end to end on temporary sockets: the policy, approvald-fake
for "approve", a fake desktopd on the uplink, and a fake command runner."""

import asyncio
import json
import os
import pwd
import subprocess
import sys
import tempfile
import time

import pytest

import jsonline
from jsonline import Server
from sysd.daemon import Sysd
from sysd.policy import Policy, stricter

ME = pwd.getpwuid(os.getuid()).pw_name
APPROVAL_RUN = os.environ.get(
    "APPROVAL_RUN", os.path.join(os.path.dirname(__file__), "..", "..", "approval", "run.py")
)


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, 30))


# ── Policy ──────────────────────────────────────────────────────────────────
def policy(actions, callers=None):
    return Policy({"callers": callers or {"local": {"users": [ME]}}, "actions": actions})


def test_unlisted_refused_read_only_allowed():
    p = policy({})
    assert p.decide("power-off", "local") == "deny"
    assert p.decide("get-power-profile", "local", read_only=True) == "none"
    assert p.decide("get-power-profile", None, read_only=True) == "deny"


def test_caller_override_and_origin_only_stricter():
    p = policy(
        {
            "reboot-windows": {
                "approval": "approve",
                "callers": {"local": "none"},
                "origins": {"dashboard": "approve", "kiosk": "deny"},
            },
            "sleep": {"approval": "approve", "origins": {"dashboard": "none"}},
        }
    )
    assert p.decide("reboot-windows", "local") == "none"
    assert p.decide("reboot-windows", "other") == "approve"
    assert p.decide("reboot-windows", "local", "dashboard") == "approve"
    assert p.decide("reboot-windows", "local", "kiosk") == "deny"
    # An origin never loosens.
    assert p.decide("sleep", "local", "dashboard") == "approve"
    # A read-only command the policy lists follows the policy.
    assert policy({"get-power-profile": {"approval": "deny"}}).decide("get-power-profile", "local", read_only=True) == "deny"


def test_caller_matching_uid_before_group():
    import grp

    g = grp.getgrgid(os.getgid()).gr_name
    p = policy({}, {"a-group": {"groups": [g]}, "z-user": {"users": [ME]}})
    assert p.caller(os.getuid(), [os.getgid()]) == "z-user"
    assert p.caller(12345, [os.getgid()]) == "a-group"
    assert p.caller(12345, [54321]) is None


def test_bad_level_rejected():
    with pytest.raises(ValueError):
        policy({"x": {"approval": "maybe"}})


def test_stricter():
    assert stricter("none", "approve") == "approve"
    assert stricter("deny", "none") == "deny"


# ── The daemon ──────────────────────────────────────────────────────────────
class FakeRunner:
    def __init__(self):
        self.calls = []

    async def __call__(self, *argv, timeout=15):
        self.calls.append(argv)
        if "get-property" in argv:
            return '{"type":"s","data":"balanced"}'
        return ""


class Fixture:
    def __init__(self, answer="approve", actions=None, session=True):
        self.dir = tempfile.mkdtemp()
        self.control = os.path.join(self.dir, "sysd.sock")
        self.session = os.path.join(self.dir, "session.sock")
        self.approvald = os.path.join(self.dir, "approvald.sock")
        self.answer = answer
        self.config = {
            "callers": {"local": {"users": [ME]}},
            "actions": actions
            if actions is not None
            else {
                "set-power-profile": {"approval": "none"},
                "sleep": {"approval": "none"},
                "reboot-windows": {"approval": "approve", "methods": ["fake"]},
                "power-off": {"approval": "deny"},
                "desktop.set-noctalia-preset": {"approval": "none", "origins": {"dashboard": "approve"}},
            },
            "approval": {"socket": self.approvald, "timeout": 5, "methods": ["fake"]},
            "session": {"user": ME if session else None},
            "rebootWindowsUnit": "reboot-windows-test.service",
        }
        self.runner = FakeRunner()
        self.fake = None

    async def __aenter__(self):
        await restart_fake(self, "--answer", self.answer)
        self.sysd = Sysd(self.config, runner=self.FakeRunnerProxy(self.runner))
        await self.sysd.start(self.control, self.session)
        return self

    class FakeRunnerProxy:
        def __init__(self, r):
            self.r = r

        async def __call__(self, *argv, timeout=15):
            return await self.r(*argv, timeout=timeout)

    async def __aexit__(self, *exc):
        self.fake.kill()
        self.fake.wait()

    def approval_requests(self):
        self.fake.kill()
        out, _ = self.fake.communicate()
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    async def call(self, req):
        return [line async for line in jsonline.request(self.control, req)]


async def restart_fake(f, *args):
    """(Re)start approvald-fake and wait until it answers a ping."""
    if f.fake is not None and f.fake.poll() is None:
        f.fake.kill()
        f.fake.wait()
    try:
        os.unlink(f.approvald)
    except FileNotFoundError:
        pass
    f.fake = subprocess.Popen(
        [sys.executable, "-I", APPROVAL_RUN, "fake", "--socket", f.approvald, *args],
        stdout=subprocess.PIPE,
        text=True,
    )
    for _ in range(200):
        try:
            r, w = await asyncio.open_unix_connection(f.approvald)
            w.write(b'{"v":1,"op":"ping"}\n')
            await w.drain()
            ok = await r.readline()
            w.close()
            if ok:
                f.fake.stdout.readline()  # the ping it echoed
                return
        except OSError:
            pass
        await asyncio.sleep(0.05)
    raise AssertionError("approvald-fake did not start")


class FakeDesktop:
    """Stands in for erebor-desktopd: a jsonline server that dials the uplink."""

    def __init__(self, path):
        self.server = Server()
        self.state = {"look": "glass", "layout": "glass"}
        self.got = []

        async def get(req, conn):
            return dict(self.state)

        async def set_(req, conn):
            self.got.append(req)
            self.state.update({k: req[k] for k in ("look", "layout") if req.get(k)})
            self.server.emit({"event": "preset-changed", **self.state})
            return dict(self.state)

        self.server.hello = lambda conn: dict(self.state)
        self.server.add({"get-noctalia-preset": get, "set-noctalia-preset": set_})
        self.task = asyncio.create_task(self.server.dial(path, min_delay=0.05))

    def stop(self):
        self.task.cancel()
        for c in list(self.server.connections):
            c.close()


async def until(pred, timeout=5):
    end = time.monotonic() + timeout
    while not pred():
        assert time.monotonic() < end, "timed out"
        await asyncio.sleep(0.02)


def test_no_approval_action_runs():
    async def main():
        async with Fixture() as f:
            assert await f.call({"command": "set-power-profile", "profile": "power-saver"}) == [
                {"ok": True, "profile": "power-saver"}
            ]
            assert f.runner.calls[-1][-2:] == ("s", "power-saver")
            # Read-only, not in the policy: allowed.
            assert (await f.call({"command": "get-power-profile"}))[-1] == {"ok": True, "profile": "balanced"}
            assert f.approval_requests() == []

    run(main())


def test_bad_argument_refused_before_policy():
    async def main():
        async with Fixture() as f:
            r = await f.call({"command": "set-power-profile", "profile": "turbo"})
            assert r[-1]["code"] == "bad-request" and not f.runner.calls
            r = await f.call({"command": "sleep", "origin": "Bad Origin"})
            assert r[-1]["code"] == "bad-request"

    run(main())


def test_deny_action_refused():
    async def main():
        async with Fixture() as f:
            r = await f.call({"command": "power-off"})
            assert r == [{"ok": False, "error": "refused by policy", "code": "forbidden"}]
            # Not in the policy at all: refused too.
            f.config["actions"].pop("sleep")
            f.sysd.policy = Policy(f.config)
            assert (await f.call({"command": "sleep"}))[-1]["code"] == "forbidden"
            assert not f.runner.calls

    run(main())


def test_approve_action_waits_for_approval():
    async def main():
        async with Fixture("approve") as f:
            r = await f.call({"command": "reboot-windows", "origin": "dashboard", "origin_user": "alice"})
            assert r[0]["event"] == "approval-pending" and r[0]["methods"] == ["fake"]
            assert r[-1] == {"ok": True}
            assert f.runner.calls == [
                ("systemctl", "--system", "--no-ask-password", "start", "reboot-windows-test.service")
            ]
            [req] = f.approval_requests()
            assert req["action"] == "reboot-windows" and req["summary"] == "Reboot into Windows"
            assert req["details"] == {"caller": "local", "origin": "dashboard", "user": "alice"}
            assert req["methods"] == ["fake"] and req["risk"] == "high"

    run(main())


@pytest.mark.parametrize("answer,outcome", [("deny", "denied"), ("failed", "failed"), ("error:busy", "busy")])
def test_refused_approval_does_not_run(answer, outcome):
    async def main():
        async with Fixture(answer) as f:
            r = await f.call({"command": "reboot-windows"})
            assert r[-1] == {"ok": False, "error": f"not approved ({outcome})", "code": "not-approved", "result": outcome}
            assert not f.runner.calls

    run(main())


def test_approvald_missing_fails_closed():
    async def main():
        async with Fixture() as f:
            f.config["approval"]["socket"] = os.path.join(f.dir, "nowhere.sock")
            r = await f.call({"command": "reboot-windows"})
            assert r[-1]["code"] == "not-approved" and not f.runner.calls

    run(main())


def test_unknown_peer_refused():
    async def main():
        f = Fixture()
        f.config["callers"] = {"someone-else": {"users": ["root"]}}
        async with f:
            with pytest.raises(ConnectionError):
                await f.call({"command": "get-power-profile"})

    run(main())


def test_forwarding_and_session_events():
    async def main():
        async with Fixture() as f:
            # No session: refused at once, before any approval.
            r = await f.call({"command": "desktop.set-noctalia-preset", "look": "x", "origin": "dashboard"})
            assert r == [{"ok": False, "error": "no desktop session", "code": "no-session"}]
            assert f.approval_requests() == []
            await restart_fake(f)

            sub_r, sub_w = await asyncio.open_unix_connection(f.control)
            sub_w.write(b'{"command":"subscribe"}\n')
            await sub_w.drain()
            hello = json.loads(await sub_r.readline())
            assert hello == {"ok": True, "subscribed": True, "session": "down", "desktop": None}

            d = FakeDesktop(f.session)
            assert json.loads(await sub_r.readline()) == {
                "event": "session-up",
                "desktop": {"look": "glass", "layout": "glass"},
            }
            # Read-only, not in the policy: allowed.
            assert (await f.call({"command": "desktop.get-noctalia-preset"}))[-1] == {
                "ok": True,
                "look": "glass",
                "layout": "glass",
            }
            r = await f.call({"command": "desktop.set-noctalia-preset", "look": "glass-pbsio2", "origin_user": "x"})
            assert r == [{"ok": True, "look": "glass-pbsio2", "layout": "glass"}]
            assert {k: v for k, v in d.got[0].items() if k != "id"} == {
                "command": "set-noctalia-preset",
                "look": "glass-pbsio2",
            }
            assert json.loads(await sub_r.readline()) == {
                "event": "preset-changed",
                "look": "glass-pbsio2",
                "layout": "glass",
                "source": "desktop",
            }
            # From the dashboard it needs approval (origin rule).
            r = await f.call({"command": "desktop.set-noctalia-preset", "look": "glass", "origin": "dashboard"})
            assert r[0]["event"] == "approval-pending" and r[-1]["ok"]
            # Not in the policy and not read-only: refused.
            assert (await f.call({"command": "desktop.render"}))[-1]["code"] == "forbidden"
            assert (await f.call({"command": "desktop.subscribe"}))[-1]["error"].startswith("unknown command")
            assert (await f.call({"command": "nonsense"}))[-1]["error"] == "unknown command 'nonsense'"

            la = (await f.call({"command": "list-actions", "origin": "dashboard"}))[-1]
            assert la["actions"]["desktop.set-noctalia-preset"] == "approve"
            assert la["actions"]["get-power-profile"] == "none"
            assert la["actions"]["power-off"] == "deny"
            assert la["session"] == "up"

            # The session goes away.
            await asyncio.sleep(0.05)  # drain the event of the second switch
            d.stop()
            while True:
                ev = json.loads(await asyncio.wait_for(sub_r.readline(), 5))
                if ev["event"] == "session-down":
                    break
            r = await f.call({"command": "desktop.get-noctalia-preset"})
            assert r[-1]["code"] == "no-session"
            sub_w.close()

    run(main())


def test_new_uplink_replaces_old_and_wrong_uid_refused():
    async def main():
        async with Fixture() as f:
            d1 = FakeDesktop(f.session)
            await until(lambda: f.sysd.uplinks.up)
            s1 = f.sysd.uplinks.session
            d2 = FakeDesktop(f.session)
            d2.state["look"] = "second"
            await until(lambda: f.sysd.uplinks.session is not s1 and f.sysd.uplinks.up)
            assert (await f.call({"command": "desktop.get-noctalia-preset"}))[-1]["look"] == "second"
            d1.stop()
            d2.stop()
            f.sysd.uplinks.uid = 0 if os.getuid() != 0 else 1
            await until(lambda: not f.sysd.uplinks.up)
            d3 = FakeDesktop(f.session)
            await asyncio.sleep(0.3)
            assert not f.sysd.uplinks.up
            d3.stop()

    run(main())


def test_hangup_while_waiting_cancels_approval():
    async def main():
        f = Fixture("approve")
        async with f:
            await restart_fake(f, "--delay", "3")
            r, w = await asyncio.open_unix_connection(f.control)
            w.write(b'{"command":"reboot-windows"}\n')
            await w.drain()
            assert json.loads(await r.readline())["event"] == "approval-pending"
            w.close()
            await asyncio.sleep(3.5)
            assert not f.runner.calls, "ran after the caller hung up"

    run(main())
