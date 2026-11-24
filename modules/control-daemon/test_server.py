"""erebor_desktop.server with fake features: back-pressure, ordering, locking,
registration, task restarts, socket handling (SYS-170)."""

import asyncio
import json
import logging
import os
import socket
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from erebor_desktop import server as srv  # noqa: E402

logging.getLogger("erebor-desktopd").setLevel(logging.CRITICAL)


def make_feature(name="fake"):
    f = srv.Feature(name, events=["ping", "big"])
    f.snapshot = lambda ctx: {"count": ctx.store.get("count", 0)}

    @f.command("ping")
    async def ping(ctx, req):
        return {"ok": True, "pong": True}

    @f.command("bump", mutates=True)
    async def bump(ctx, req):
        ctx.store["count"] = ctx.store.get("count", 0) + 1
        ctx.emit("ping", n=ctx.store["count"])
        return {"ok": True, "n": ctx.store["count"]}

    @f.command("spam", mutates=True)
    async def spam(ctx, req):
        for i in range(req["n"]):
            ctx.emit("big", i=i, pad="x" * req.get("size", 1))
        return {"ok": True}

    @f.command("slow", mutates=True)
    async def slow(ctx, req):
        await asyncio.sleep(req["s"])
        return {"ok": True}

    @f.command("nested", mutates=True)
    async def nested(ctx, req):
        inner = await ctx.call("bump")
        missing = await ctx.call("no-such-command")
        return {"ok": True, "inner": inner, "missing": missing, "has": ctx.has("bump")}

    @f.command("run")
    async def run(ctx, req):
        r = await ctx.run(*req["argv"], timeout=req.get("timeout", 5))
        return {"ok": True, "rc": r.rc, "stdout": r.stdout, "stderr": r.stderr}

    @f.command("boom")
    async def boom(ctx, req):
        raise RuntimeError("kaputt")

    return f


class Client:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer

    @classmethod
    async def open(cls, path):
        return cls(*await asyncio.open_unix_connection(path, limit=1 << 22))

    async def send(self, obj):
        self.w.write((json.dumps(obj) + "\n").encode())
        await self.w.drain()

    async def recv(self, timeout=5):
        line = await asyncio.wait_for(self.r.readline(), timeout)
        return json.loads(line) if line else None

    async def ask(self, obj, timeout=5):
        await self.send(obj)
        return await self.recv(timeout)

    def close(self):
        self.w.close()


class Base(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "d.sock")

    async def asyncTearDown(self):
        if getattr(self, "d", None):
            await self.d.stop()
        self.tmp.cleanup()

    async def start(self, features=None, **kw):
        self.d = srv.Daemon(features or [make_feature()], self.path, {}, **kw)
        await self.d.start()
        return self.d


class Protocol(Base):
    async def test_basics(self):
        await self.start()
        c = await Client.open(self.path)
        self.assertEqual(await c.ask({"command": "ping", "id": 7}), {"ok": True, "pong": True, "id": 7})
        r = await c.ask({"command": "nope"})
        self.assertFalse(r["ok"])
        self.assertIn("unknown command", r["error"])
        r = await c.ask({"command": "boom"})
        self.assertEqual(r, {"ok": False, "error": "RuntimeError: kaputt"})
        c.w.write(b"not json\n")
        self.assertIn("bad JSON", (await c.recv())["error"])
        d = await c.ask({"command": "describe"})
        self.assertEqual(d["protocol"], srv.PROTOCOL)
        self.assertIn("spam", d["features"]["fake"]["commands"])
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        c.close()

    async def test_long_line(self):
        await self.start()
        c = await Client.open(self.path)
        c.w.write(b"{" + b" " * (srv.MAX_LINE + 10) + b"}\n")
        r = await c.recv()
        self.assertIn("longer than", r["error"])
        self.assertIsNone(await c.recv())  # closed
        # The daemon still serves others.
        c2 = await Client.open(self.path)
        self.assertTrue((await c2.ask({"command": "ping"}))["ok"])
        c2.close()

    async def test_nested_call_and_missing(self):
        await self.start()
        c = await Client.open(self.path)
        r = await asyncio.wait_for(c.ask({"command": "nested"}), 2)  # no deadlock
        self.assertEqual(r["inner"], {"ok": True, "n": 1})
        self.assertFalse(r["missing"]["ok"])
        self.assertTrue(r["has"])
        c.close()

    async def test_reads_do_not_wait_for_the_lock(self):
        await self.start()
        a, b = await Client.open(self.path), await Client.open(self.path)
        await a.send({"command": "slow", "s": 1})
        await asyncio.sleep(0.05)
        t = time.monotonic()
        self.assertTrue((await b.ask({"command": "ping"}))["ok"])
        self.assertLess(time.monotonic() - t, 0.3)
        self.assertTrue((await a.recv())["ok"])
        a.close(), b.close()

    async def test_run(self):
        await self.start()
        c = await Client.open(self.path)
        r = await c.ask({"command": "run", "argv": ["sh", "-c", "echo out; echo err >&2; exit 3"]})
        self.assertEqual((r["rc"], r["stdout"], r["stderr"]), (3, "out\n", "err\n"))
        r = await c.ask({"command": "run", "argv": ["sleep", "5"], "timeout": 0.2})
        self.assertEqual(r["rc"], -1)
        self.assertIn("timed out", r["stderr"])
        r = await c.ask({"command": "run", "argv": ["/nonexistent/x"]})
        self.assertEqual(r["rc"], 127)
        c.close()


class Subscribers(Base):
    async def test_two_subscribers_get_every_event_in_order(self):
        await self.start()
        s1, s2, c = [await Client.open(self.path) for _ in range(3)]
        r = await s1.ask({"command": "subscribe"})
        self.assertEqual(r, {"ok": True, "subscribed": True, "state": {"fake": {"count": 0}}})
        await s2.ask({"command": "subscribe"})
        for _ in range(50):
            await c.ask({"command": "bump"})
        for s in (s1, s2):
            got = [(await s.recv())["n"] for _ in range(50)]
            self.assertEqual(got, list(range(1, 51)))
        # A subscribed connection still takes commands; the snapshot follows the state.
        self.assertTrue((await s1.ask({"command": "ping"}))["ok"])
        s3 = await Client.open(self.path)
        self.assertEqual((await s3.ask({"command": "subscribe"}))["state"]["fake"]["count"], 50)
        for x in (s1, s2, s3, c):
            x.close()

    async def test_burst_in_one_command_reaches_a_reader(self):
        await self.start(queue_size=4)
        s, c = await Client.open(self.path), await Client.open(self.path)
        await s.ask({"command": "subscribe"})
        await c.ask({"command": "spam", "n": 100, "size": 10})
        self.assertEqual([(await s.recv())["i"] for _ in range(100)], list(range(100)))
        self.assertEqual(len(self.d.subscribers), 1)
        s.close(), c.close()

    async def test_stalled_subscriber_is_dropped_and_nobody_waits(self):
        await self.start(queue_size=8, drain_timeout=1, write_buffer_high=4096)
        stalled = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stalled.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        stalled.setblocking(False)
        await asyncio.get_running_loop().sock_connect(stalled, self.path)
        stalled.send(b'{"command": "subscribe"}\n')  # and never read
        good = await Client.open(self.path)
        await good.ask({"command": "subscribe"})
        for _ in range(50):
            if len(self.d.subscribers) == 2:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(len(self.d.subscribers), 2)
        got = []

        async def read_all():
            while len(got) < 400:
                got.append((await good.recv())["i"])

        reader = asyncio.create_task(read_all())
        c = await Client.open(self.path)
        for k in range(40):
            t = time.monotonic()
            r = await c.ask({"command": "spam", "n": 10, "size": 4000}, timeout=1)
            self.assertTrue(r["ok"])
            self.assertLess(time.monotonic() - t, 0.2, f"spam {k} waited")
            await asyncio.sleep(0.005)
        await asyncio.wait_for(reader, 5)
        self.assertEqual(got, list(range(10)) * 40)
        self.assertEqual([s.writer is not None and not s.dropped for s in self.d.subscribers], [True])
        stalled.close(), good.close(), c.close()

    async def test_slow_but_reading_subscriber_keeps_up(self):
        await self.start(queue_size=8)
        s = await Client.open(self.path)
        await s.ask({"command": "subscribe"})
        c = await Client.open(self.path)
        for i in range(30):
            await c.ask({"command": "bump"})
            self.assertEqual((await s.recv())["n"], i + 1)
        self.assertEqual(len(self.d.subscribers), 1)
        s.close(), c.close()

    async def test_dropped_line(self):
        await self.start(queue_size=2, drain_timeout=0.5, write_buffer_high=1024)
        stalled = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stalled.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
        stalled.connect(self.path)
        stalled.sendall(b'{"command": "subscribe"}\n')
        f = stalled.makefile("rb")
        self.assertTrue(json.loads(await asyncio.to_thread(f.readline))["subscribed"])
        c = await Client.open(self.path)
        await c.ask({"command": "spam", "n": 200, "size": 2000})
        await asyncio.sleep(1.5)
        self.assertEqual(len(self.d.subscribers), 0)
        # Read what made it: events, then EOF (the dropped line only if it fit).
        lines = await asyncio.to_thread(f.readlines)
        self.assertTrue(lines)
        stalled.close(), c.close()


class Registration(unittest.TestCase):
    def test_clashes_name_both(self):
        a, b = make_feature("a"), make_feature("b")
        a.source, b.source = "a.py", "b.py"
        with self.assertRaises(ValueError) as e:
            srv.Registry([a, b])
        self.assertIn("command 'ping' defined by both a (a.py) and b (b.py)", str(e.exception))
        self.assertIn("event 'big'", str(e.exception))

    def test_builtin_names_refused(self):
        f = srv.Feature("x")

        @f.command("subscribe")
        async def s(ctx, req):
            return {}

        with self.assertRaises(ValueError):
            srv.Registry([f])

    def test_undeclared_event(self):
        f = srv.Feature("x", events=["a"])
        d = srv.Daemon.__new__(srv.Daemon)
        d.registry = srv.Registry([f])
        d.config = {}
        ctx = srv.Context(d, f)
        with self.assertRaises(ValueError):
            ctx.emit("b")

    def test_sync_command_refused(self):
        f = srv.Feature("x")
        with self.assertRaises(TypeError):
            f.command("c")(lambda ctx, req: {})

    def test_load_feature_dir(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "extra.py"), "w") as fh:
                fh.write(
                "from erebor_desktop.server import Feature\n"
                "feature = Feature('extra', events=['extra-changed'])\n"
                "@feature.command('get-extra')\n"
                "async def g(ctx, req):\n    return {'ok': True}\n"
            )
            with open(os.path.join(d, "_skipped.py"), "w") as fh:
                fh.write("raise SystemExit('loaded')\n")
            os.environ["EREBOR_DESKTOP_FEATURE_DIRS"] = d
            try:
                fs = srv.load_features(None, srv.feature_dirs())
            finally:
                del os.environ["EREBOR_DESKTOP_FEATURE_DIRS"]
            reg = srv.Registry(fs)
            self.assertIn("get-extra", reg.commands)
            self.assertEqual(reg.features["extra"].source, os.path.join(d, "extra.py"))


class Tasks(Base):
    async def test_crashing_task_restarts_with_backoff(self):
        f = make_feature()
        runs = []

        @f.task
        async def flaky(ctx):
            runs.append(time.monotonic())
            if len(runs) < 3:
                raise RuntimeError(f"fail {len(runs)}")
            await asyncio.sleep(10)

        await self.start([f], backoff=(0.05, 0.2, 100))
        for _ in range(100):
            if len(runs) >= 3:
                break
            await asyncio.sleep(0.02)
        self.assertEqual(len(runs), 3)
        self.assertGreaterEqual(runs[2] - runs[1], 0.09)  # doubled
        h = self.d.health()["fake"]["tasks"]["flaky"]
        self.assertEqual((h["running"], h["restarts"], h["last_error"]), (True, 2, "RuntimeError: fail 2"))
        c = await Client.open(self.path)
        self.assertTrue((await c.ask({"command": "ping"}))["ok"])
        c.close()


class Socket(Base):
    async def test_refuses_when_running_and_replaces_stale(self):
        await self.start()
        other = srv.Daemon([make_feature()], self.path, {})
        with self.assertRaises(SystemExit):
            await other.start()
        await self.d.stop()
        self.assertFalse(os.path.exists(self.path))
        # A stale socket file (nobody listening) is replaced.
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(self.path)
        s.close()
        self.d = srv.Daemon([make_feature()], self.path, {})
        await self.d.start()
        c = await Client.open(self.path)
        self.assertTrue((await c.ask({"command": "ping"}))["ok"])
        c.close()


if __name__ == "__main__":
    unittest.main()
