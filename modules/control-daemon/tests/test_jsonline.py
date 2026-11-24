import asyncio
import json
import os
import socket
import tempfile

import pytest

import jsonline
from jsonline import Command, Error, Server


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, 20))


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


async def started(server):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "s.sock")
    srv = await server.serve_unix(path)
    return srv, path


def test_commands_errors_and_unknown():
    async def main():
        s = Server()

        async def echo(req, conn):
            return {"echo": req.get("x")}

        async def refuse(req, conn):
            raise Error("nope", code="forbidden")

        async def boom(req, conn):
            raise RuntimeError("bad")

        s.add({"echo": echo, "refuse": refuse, "boom": boom})
        srv, path = await started(s)
        c = await Client.open(path)
        assert await c.call({"command": "echo", "x": 1}) == {"echo": 1, "ok": True}
        assert await c.call({"command": "refuse"}) == {"ok": False, "error": "nope", "code": "forbidden"}
        assert (await c.call({"command": "boom"}))["error"] == "RuntimeError: bad"
        assert (await c.call({"command": "what"}))["error"] == "unknown command 'what'"
        c.w.write(b"not json\n")
        assert (await c.line())["error"] == "bad JSON"
        assert (await c.call({"x": 1}))["error"] == "missing command"
        c.close()
        srv.close()

    run(main())


def test_duplicate_command_refused():
    s = Server()
    s.add({"a": lambda r, c: {}})
    with pytest.raises(ValueError):
        s.add({"a": lambda r, c: {}})
    with pytest.raises(ValueError):
        s.add({"subscribe": lambda r, c: {}})


def test_peer_credentials():
    async def main():
        s = Server()
        s.add({"who": lambda req, conn: {"uid": conn.peer.uid, "gid": conn.peer.gids[0]}})
        srv, path = await started(s)
        c = await Client.open(path)
        assert await c.call({"command": "who"}) == {"uid": os.getuid(), "gid": os.getgid(), "ok": True}
        c.close()
        srv.close()

    run(main())


def test_accept_hook_refuses():
    async def main():
        s = Server()
        s.accept = lambda conn: False
        srv, path = await started(s)
        c = await Client.open(path)
        try:
            await c.send({"command": "x"})
            assert await asyncio.wait_for(c.r.readline(), 5) == b""
        except ConnectionError:
            pass
        assert not s.connections
        srv.close()

    run(main())


def test_stalled_subscriber_dropped_others_get_every_event():
    """A subscriber that never reads does not slow a
    command, and is dropped; two live subscribers get every event."""

    async def main():
        s = Server(queue_size=128, drain_timeout=1.0)
        s.hello = lambda conn: {"state": "x"}

        async def fire(req, conn):
            for i in range(req["n"]):
                s.emit({"event": "tick", "i": i, "pad": "x" * 1000})
            return {}

        s.add({"fire": fire})
        srv, path = await started(s)

        # The stalled client: a raw socket with a tiny receive buffer, never read.
        stalled = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stalled.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        stalled.connect(path)
        stalled.sendall(b'{"command":"subscribe"}\n')

        subs = [await Client.open(path) for _ in range(2)]
        for c in subs:
            assert await c.call({"command": "subscribe"}) == {"ok": True, "subscribed": True, "state": "x"}
        await asyncio.sleep(0.1)
        assert len(s.subscribers) == 3

        got = [[], []]

        async def drain(i, c):
            while len(got[i]) < 2000:
                got[i].append((await c.line())["i"])

        readers = [asyncio.create_task(drain(i, c)) for i, c in enumerate(subs)]
        ctl = await Client.open(path)
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        for _ in range(20):
            await ctl.call({"command": "fire", "n": 100})
            await asyncio.sleep(0)  # let the live readers keep up
        assert loop.time() - t0 < 3, "a stalled subscriber slowed the command"
        await asyncio.gather(*readers)
        assert got[0] == got[1] == [i for _ in range(20) for i in range(100)]
        assert len(s.subscribers) == 2, "the stalled subscriber was not dropped"
        stalled.close()
        for c in subs:
            c.close()
        ctl.close()
        srv.close()

    run(main())


def test_ids_run_concurrently_and_are_echoed():
    async def main():
        s = Server()
        gate = asyncio.Event()

        async def slow(req, conn):
            await gate.wait()
            return {"slow": True}

        async def fast(req, conn):
            gate.set()
            return {"fast": True}

        s.add({"slow": slow, "fast": fast})
        srv, path = await started(s)
        c = await Client.open(path)
        await c.send({"id": 1, "command": "slow"})
        await c.send({"id": 2, "command": "fast"})
        assert await c.line() == {"fast": True, "ok": True, "id": 2}
        assert await c.line() == {"slow": True, "ok": True, "id": 1}
        c.close()
        srv.close()

    run(main())


def test_streamed_reply_and_hangup_cancels():
    async def main():
        s = Server()
        cancelled = asyncio.Event()

        async def wait(req, conn):
            yield {"event": "pending"}
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                cancelled.set()
                raise
            yield {"ok": True}

        async def steps(req, conn):
            yield {"event": "pending"}
            yield {"event": "progress"}
            yield {"ok": True, "done": 1}

        s.add({"wait": Command(wait, hangup_cancels=True), "steps": steps})
        srv, path = await started(s)
        c = await Client.open(path)
        assert [await c.call({"command": "steps"}), await c.line(), await c.line()] == [
            {"event": "pending"},
            {"event": "progress"},
            {"ok": True, "done": 1},
        ]
        assert await c.call({"command": "wait"}) == {"event": "pending"}
        c.close()
        await asyncio.wait_for(cancelled.wait(), 5)

        # The same with an id.
        cancelled.clear()
        c = await Client.open(path)
        assert await c.call({"id": "a", "command": "wait"}) == {"event": "pending", "id": "a"}
        c.close()
        await asyncio.wait_for(cancelled.wait(), 5)
        srv.close()

    run(main())


def test_pipelined_requests_answered_in_order():
    async def main():
        s = Server()

        async def slow(req, conn):
            await asyncio.sleep(0.2)
            return {"n": req["n"]}

        s.add({"slow": slow})
        srv, path = await started(s)
        c = await Client.open(path)
        c.w.write(b'{"command":"slow","n":1}\n{"command":"slow","n":2}\n')
        await c.w.drain()
        assert [(await c.line())["n"], (await c.line())["n"]] == [1, 2]
        c.close()
        srv.close()

    run(main())


def test_dial_serves_outbound_connection():
    """The uplink shape: the server connects out and answers on that line."""

    async def main():
        d = tempfile.mkdtemp()
        path = os.path.join(d, "up.sock")
        accepted = asyncio.Queue()

        async def on_accept(reader, writer):
            await accepted.put(Client(reader, writer))

        hub = await asyncio.start_unix_server(on_accept, path)
        s = Server()
        s.add({"ping": lambda req, conn: {"pong": True}})
        task = asyncio.create_task(s.dial(path, min_delay=0.05))
        c = await asyncio.wait_for(accepted.get(), 5)
        assert await c.call({"id": 1, "command": "ping"}) == {"pong": True, "ok": True, "id": 1}
        # The hub drops it; the server dials again.
        c.close()
        c2 = await asyncio.wait_for(accepted.get(), 5)
        assert (await c2.call({"command": "ping"}))["pong"]
        task.cancel()
        hub.close()

    run(main())


def test_request_client():
    async def main():
        s = Server()

        async def steps(req, conn):
            yield {"event": "pending"}
            yield {"ok": True}

        s.add({"steps": steps})
        srv, path = await started(s)
        lines = [line async for line in jsonline.request(path, {"command": "steps"})]
        assert lines == [{"event": "pending"}, {"ok": True}]
        srv.close()

    run(main())


def test_notify(tmp_path, monkeypatch):
    path = str(tmp_path / "notify")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(path)
    monkeypatch.setenv("NOTIFY_SOCKET", path)
    assert jsonline.notify()
    assert sock.recv(64) == b"READY=1"
    monkeypatch.delenv("NOTIFY_SOCKET")
    assert not jsonline.notify()
