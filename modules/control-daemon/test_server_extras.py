"""erebor_desktop.server additions used by erebor-sysd: peer credentials and
the accept hook, streamed replies, cancel on hang-up, prefixes, a socket
from systemd, and dialling out."""

import asyncio
import json
import logging
import os
import socket
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from erebor_desktop import server as srv  # noqa: E402

logging.getLogger("erebor-desktopd").setLevel(logging.CRITICAL)


class Client:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer

    @classmethod
    async def open(cls, path):
        return cls(*await asyncio.open_unix_connection(path))

    async def send(self, obj):
        self.w.write((json.dumps(obj) + "\n").encode())
        await self.w.drain()

    async def line(self, timeout=5):
        raw = await asyncio.wait_for(self.r.readline(), timeout)
        assert raw, "connection closed"
        return json.loads(raw)

    async def call(self, obj):
        await self.send(obj)
        return await self.line()

    def close(self):
        self.w.close()


def feature():
    f = srv.Feature("extra")
    f.store_cancelled = asyncio.Event()

    @f.command("who")
    async def who(ctx, req):
        p = ctx.connection.peer
        return {"ok": True, "uid": p.uid, "gid": p.gids[0], "tag": ctx.connection.data.get("tag")}

    @f.command("steps")
    async def steps(ctx, req):
        yield {"event": "pending"}
        yield {"event": "progress"}
        yield {"ok": True, "done": 1}

    @f.command("wait", cancel_on_hangup=True)
    async def wait(ctx, req):
        yield {"event": "pending"}
        try:
            await asyncio.sleep(60)
        except asyncio.CancelledError:
            f.store_cancelled.set()
            raise
        yield {"ok": True}

    @f.command("via-call")
    async def via_call(ctx, req):
        return {"ok": True, "inner": await ctx.call("steps")}

    @f.prefix("fwd.")
    async def forward(ctx, req):
        return {"ok": True, "got": req["command"]}

    return f


class Base(unittest.IsolatedAsyncioTestCase):
    async def start(self, **kw):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "d.sock")
        self.f = feature()
        self.d = srv.Daemon([self.f], self.path, **kw)
        await self.d.start()
        self.addAsyncCleanup(self.d.stop)
        return self.d


class Extras(Base):
    async def test_peer_and_accept(self):
        await self.start(accept=lambda conn: conn.data.update(tag="seen") or True)
        c = await Client.open(self.path)
        self.assertEqual(await c.call({"command": "who"}),
                         {"ok": True, "uid": os.getuid(), "gid": os.getgid(), "tag": "seen"})
        c.close()

    async def test_accept_refuses(self):
        await self.start(accept=lambda conn: False)
        c = await Client.open(self.path)
        try:
            await c.send({"command": "who"})
            self.assertEqual(await asyncio.wait_for(c.r.readline(), 5), b"")
        except ConnectionError:
            pass

    async def test_streamed_reply_with_id_and_ctx_call(self):
        await self.start()
        c = await Client.open(self.path)
        await c.send({"id": 7, "command": "steps"})
        self.assertEqual([await c.line() for _ in range(3)], [
            {"event": "pending", "id": 7}, {"event": "progress", "id": 7}, {"ok": True, "done": 1, "id": 7}])
        self.assertEqual(await c.call({"command": "via-call"}), {"ok": True, "inner": {"ok": True, "done": 1}})
        c.close()

    async def test_hangup_cancels_only_marked_commands(self):
        await self.start()
        c = await Client.open(self.path)
        self.assertEqual(await c.call({"command": "wait"}), {"event": "pending"})
        c.close()
        await asyncio.wait_for(self.f.store_cancelled.wait(), 5)
        # The daemon keeps serving.
        c = await Client.open(self.path)
        self.assertTrue((await c.call({"command": "who"}))["ok"])
        c.close()

    async def test_pipelined_requests_still_answered_in_order(self):
        await self.start()
        c = await Client.open(self.path)
        c.w.write(b'{"command":"steps"}\n{"command":"fwd.x"}\n')
        await c.w.drain()
        lines = [await c.line() for _ in range(4)]
        self.assertEqual(lines[-2]["done"], 1)
        self.assertEqual(lines[-1], {"ok": True, "got": "fwd.x"})
        c.close()

    async def test_prefix_routing_and_describe(self):
        await self.start()
        c = await Client.open(self.path)
        self.assertEqual(await c.call({"command": "fwd.set-x"}), {"ok": True, "got": "fwd.set-x"})
        self.assertEqual((await c.call({"command": "fw"}))["error"], "unknown command 'fw'")
        self.assertEqual((await c.call({"command": "describe"}))["features"]["extra"]["prefixes"], ["fwd."])
        c.close()

    async def test_socket_from_systemd(self):
        d = tempfile.mkdtemp()
        path = os.path.join(d, "act.sock")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(path)
        sock.listen()
        daemon = srv.Daemon([feature()], "/nonexistent/unused.sock", sock=sock)
        await daemon.start()
        c = await Client.open(path)
        self.assertTrue((await c.call({"command": "who"}))["ok"])
        c.close()
        await daemon.stop()
        self.assertTrue(os.path.exists(path), "a socket from systemd is not removed")

    async def test_dial_serves_outbound_connection_and_reconnects(self):
        await self.start()
        hub_path = os.path.join(self.dir, "hub.sock")
        accepted = asyncio.Queue()

        async def on_accept(reader, writer):
            await accepted.put(Client(reader, writer))

        hub = await asyncio.start_unix_server(on_accept, hub_path)
        self.d.dial(hub_path, min_delay=0.05)
        c = await asyncio.wait_for(accepted.get(), 5)
        self.assertEqual(await c.call({"id": 1, "command": "fwd.ping"}), {"ok": True, "got": "fwd.ping", "id": 1})
        c.close()
        c2 = await asyncio.wait_for(accepted.get(), 5)
        self.assertTrue((await c2.call({"command": "subscribe"}))["subscribed"])
        c2.close()
        hub.close()


class Registration(unittest.TestCase):
    def test_prefix_clashes(self):
        a, b = srv.Feature("a"), srv.Feature("b")

        @a.prefix("x.")
        async def h1(ctx, req):
            return {"ok": True}

        @b.prefix("x.y")
        async def h2(ctx, req):
            return {"ok": True}

        with self.assertRaises(ValueError):
            srv.Registry([a, b])
        c = srv.Feature("c")

        @c.command("x.z")
        async def h3(ctx, req):
            return {"ok": True}

        with self.assertRaises(ValueError):
            srv.Registry([a, c])

    def test_listen_fds(self):
        self.assertEqual(srv.listen_fds(), {})


if __name__ == "__main__":
    unittest.main()
