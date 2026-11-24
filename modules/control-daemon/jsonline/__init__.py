"""JSON-per-line asyncio server for local control daemons (erebor-sysd,
erebor-desktopd).

A connection carries requests, one JSON object per line:

    {"command": "name", ...}           answered in order
    {"id": 7, "command": "name", ...}  answered concurrently; its lines carry "id": 7

A handler (``async def handler(req, conn)``) returns the reply, or is an async
generator whose earlier items are progress lines (``{"event": "pending", ...}``)
and whose last item is the reply. Every reply has ``ok``; an error reply has
``error``. ``subscribe`` (built in) adds the connection to the event stream and
it may go on sending requests.

Each connection has one bounded output queue and one writer task. An event
that finds the queue full, or a write that does not drain in time, drops that
connection, so a stalled client never blocks a handler or another client.

Feature modules register a table of commands (``server.add(COMMANDS)``) rather
than growing one dispatch chain.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import os
import socket
import struct
import sys
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable

MAX_LINE = 64 * 1024
QUEUE_SIZE = 256
DRAIN_TIMEOUT = 10.0
SO_PEERGROUPS = getattr(socket, "SO_PEERGROUPS", 59)

__all__ = [
    "Command",
    "Conn",
    "Error",
    "Peer",
    "Server",
    "listen_fds",
    "notify",
    "request",
]


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class Error(Exception):
    """A refusal with a message for the client: ``{"ok": false, "error": msg, **extra}``."""

    def __init__(self, error: str, **extra: Any):
        super().__init__(error)
        self.reply = {"ok": False, "error": error, **extra}


@dataclass(frozen=True)
class Peer:
    pid: int
    uid: int
    gids: tuple[int, ...]


def peer_of(sock: socket.socket | None) -> Peer | None:
    """The peer's credentials (SO_PEERCRED, SO_PEERGROUPS) on a Unix socket."""
    if sock is None or sock.family != socket.AF_UNIX:
        return None
    try:
        pid, uid, gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    except OSError:
        return None
    try:
        raw = sock.getsockopt(socket.SOL_SOCKET, SO_PEERGROUPS, 4 * 256)
        gids = struct.unpack(f"{len(raw) // 4}I", raw)
    except OSError:
        gids = ()
    return Peer(pid, uid, (gid, *gids))


@dataclass
class Command:
    handler: Callable[..., Any]
    # Cancel the handler when the client hangs up (for example while an
    # approval is outstanding). Clients must not half-close their side.
    hangup_cancels: bool = False


Handler = Callable[[dict, "Conn"], Any]


@dataclass(eq=False)
class Conn:
    server: "Server"
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    peer: Peer | None
    queue: asyncio.Queue = field(init=False)
    closed: bool = False
    # Free for the daemon: caller name, uplink state, ...
    data: dict = field(default_factory=dict)
    _hangup: asyncio.Event = field(default_factory=asyncio.Event)

    def __post_init__(self):
        self.queue = asyncio.Queue(self.server.queue_size)

    @property
    def subscribed(self) -> bool:
        return self in self.server.subscribers

    def send_nowait(self, obj: dict) -> bool:
        """Queue a line without waiting; a full queue drops the connection."""
        if self.closed:
            return False
        try:
            self.queue.put_nowait(_encode(obj))
            return True
        except asyncio.QueueFull:
            log(f"jsonline: dropping a stalled client (peer {self.peer})")
            self.close()
            return False

    async def send(self, obj: dict) -> None:
        """Queue a reply line, waiting for room (only this client waits)."""
        if self.closed:
            return
        await self.queue.put(_encode(obj))

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self._hangup.set()
        self.server.subscribers.discard(self)
        self.writer.close()
        # Wake senders blocked on a full queue, and the writer task.
        while not self.queue.empty():
            self.queue.get_nowait()
        self.queue.put_nowait(None)
        for cb in list(self.server.on_close):
            try:
                cb(self)
            except Exception as e:  # keep closing
                log(f"jsonline: on_close: {type(e).__name__}: {e}")

    async def wait_closed(self) -> None:
        await self._hangup.wait()

    async def _write_loop(self) -> None:
        try:
            while True:
                line = await self.queue.get()
                if line is None:
                    break
                self.writer.write(line)
                await asyncio.wait_for(self.writer.drain(), self.server.drain_timeout)
        except (OSError, TimeoutError, asyncio.TimeoutError):
            pass
        finally:
            self.close()


def _encode(obj: dict) -> bytes:
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode()


class Server:
    def __init__(
        self,
        *,
        queue_size: int = QUEUE_SIZE,
        drain_timeout: float = DRAIN_TIMEOUT,
        max_line: int = MAX_LINE,
    ):
        self.commands: dict[str, Command] = {}
        self.subscribers: set[Conn] = set()
        self.connections: set[Conn] = set()
        self.queue_size = queue_size
        self.drain_timeout = drain_timeout
        self.max_line = max_line
        # Hooks, all optional:
        # accept(conn) -> bool: refuse a connection (closed without a reply).
        self.accept: Callable[[Conn], bool] | None = None
        # hello(conn) -> dict | awaitable: merged into the subscribe reply.
        self.hello: Callable[[Conn], Any] | None = None
        # fallback(req, conn): for commands not in the table.
        self.fallback: Handler | Command | None = None
        # check(name, req, conn) -> None | awaitable; raise Error to refuse.
        self.check: Callable[[str, dict, Conn], Any] | None = None
        self.on_close: list[Callable[[Conn], None]] = []
        self._tasks: set[asyncio.Task] = set()

    # ── Commands ────────────────────────────────────────────────────────────
    def add(self, table: dict[str, Handler | Command]) -> None:
        """Register a module's commands; a name may be registered once."""
        for name, h in table.items():
            if name in self.commands or name == "subscribe":
                raise ValueError(f"command {name!r} registered twice")
            self.commands[name] = h if isinstance(h, Command) else Command(h)

    def command(self, name: str, *, hangup_cancels: bool = False):
        def deco(fn):
            self.add({name: Command(fn, hangup_cancels)})
            return fn

        return deco

    # ── Events ──────────────────────────────────────────────────────────────
    def emit(self, event: dict) -> None:
        """Send an event to every subscriber; never waits."""
        for c in list(self.subscribers):
            c.send_nowait(event)

    # ── Serving ─────────────────────────────────────────────────────────────
    async def serve_unix(self, path: str, mode: int = 0o600) -> asyncio.base_events.Server:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        srv = await asyncio.start_unix_server(self.handle, path, limit=self.max_line)
        os.chmod(path, mode)
        return srv

    async def serve_socket(self, sock: socket.socket) -> asyncio.base_events.Server:
        return await asyncio.start_unix_server(self.handle, sock=sock, limit=self.max_line)

    async def dial(
        self,
        path: str,
        *,
        min_delay: float = 1.0,
        max_delay: float = 30.0,
        on_connect: Callable[[Conn], Any] | None = None,
    ) -> None:
        """Connect out to ``path`` and serve that connection as a client's;
        reconnect with backoff, forever (cancel the task to stop)."""
        delay = min_delay
        while True:
            try:
                reader, writer = await asyncio.open_unix_connection(path, limit=self.max_line)
            except OSError:
                await asyncio.sleep(delay)
                delay = min(max_delay, delay * 2)
                continue
            delay = min_delay
            await self.handle(reader, writer, on_connect=on_connect)
            await asyncio.sleep(min_delay)

    async def handle(self, reader, writer, *, on_connect=None) -> None:
        conn = Conn(self, reader, writer, peer_of(writer.get_extra_info("socket")))
        if self.accept is not None and not self.accept(conn):
            writer.close()
            return
        self.connections.add(conn)
        writer_task = asyncio.create_task(conn._write_loop())
        running: set[asyncio.Task] = set()
        next_read: asyncio.Task | None = None
        try:
            if on_connect is not None:
                r = on_connect(conn)
                if inspect.isawaitable(r):
                    await r
            while not conn.closed:
                if next_read is None:
                    next_read = asyncio.create_task(reader.readline())
                try:
                    raw = await next_read
                except (ValueError, asyncio.LimitOverrunError):
                    await conn.send({"ok": False, "error": "line too long"})
                    break
                except (ConnectionError, OSError):
                    break
                finally:
                    next_read = None
                if not raw:
                    break
                if not raw.strip():
                    continue
                try:
                    req = json.loads(raw)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    req = None
                if not isinstance(req, dict):
                    await conn.send({"ok": False, "error": "bad JSON"})
                    continue
                if "id" in req:
                    t = asyncio.create_task(self._run(conn, req))
                    running.add(t)
                    t.add_done_callback(running.discard)
                    continue
                # In order: read ahead meanwhile, so a hang-up is seen at once.
                work = asyncio.create_task(self._run(conn, req))
                next_read = asyncio.create_task(reader.readline())
                await asyncio.wait({work, next_read}, return_when=asyncio.FIRST_COMPLETED)
                if next_read.done() and not work.done():
                    if next_read.exception() is not None or next_read.result() == b"":
                        conn._hangup.set()
                await work
        finally:
            if next_read is not None:
                next_read.cancel()
            conn._hangup.set()
            # Requests still running finish unless they asked to stop on hang-up.
            if running:
                await asyncio.gather(*running, return_exceptions=True)
            # Let queued replies go out before closing.
            if not conn.closed:
                conn.queue.put_nowait(None)
                try:
                    await asyncio.wait_for(writer_task, self.drain_timeout)
                except (asyncio.TimeoutError, TimeoutError):
                    pass
            conn.close()
            writer_task.cancel()
            self.connections.discard(conn)

    async def _run(self, conn: Conn, req: dict) -> None:
        rid = req.get("id")

        def tag(obj: dict) -> dict:
            return {**obj, "id": rid} if "id" in req else obj

        name = req.get("command")
        if not isinstance(name, str):
            await conn.send(tag({"ok": False, "error": "missing command"}))
            return
        if name == "subscribe":
            hello = {}
            if self.hello is not None:
                hello = self.hello(conn)
                if inspect.isawaitable(hello):
                    hello = await hello
            self.subscribers.add(conn)
            await conn.send(tag({"ok": True, "subscribed": True, **hello}))
            return
        cmd = self.commands.get(name)
        if cmd is None and self.fallback is not None:
            cmd = self.fallback if isinstance(self.fallback, Command) else Command(self.fallback)
        if cmd is None:
            await conn.send(tag({"ok": False, "error": f"unknown command {name!r}"}))
            return
        work = asyncio.create_task(self._call(name, cmd, req, conn, tag))
        if not cmd.hangup_cancels:
            await work
            return
        hangup = asyncio.create_task(conn.wait_closed())
        try:
            await asyncio.wait({work, hangup}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            hangup.cancel()
        if not work.done():
            work.cancel()
            await asyncio.gather(work, return_exceptions=True)

    async def _call(self, name, cmd: Command, req: dict, conn: Conn, tag) -> None:
        replied = False
        try:
            if self.check is not None:
                r = self.check(name, req, conn)
                if inspect.isawaitable(r):
                    await r
            out = cmd.handler(req, conn)
            if inspect.isasyncgen(out):
                async for item in out:
                    replied = replied or "ok" in item
                    await conn.send(tag(item))
                if not replied:
                    await conn.send(tag({"ok": False, "error": "no reply"}))
                return
            if inspect.isawaitable(out):
                out = await out
            out = dict(out or {})
            out.setdefault("ok", True)
            await conn.send(tag(out))
        except Error as e:
            await conn.send(tag(e.reply))
        except asyncio.CancelledError:
            raise
        except Exception as e:  # keep serving
            log(f"jsonline: {name}: {type(e).__name__}: {e}")
            await conn.send(tag({"ok": False, "error": f"{type(e).__name__}: {e}"}))


# ── systemd ────────────────────────────────────────────────────────────────
def listen_fds() -> dict[str, socket.socket]:
    """systemd's sockets by FileDescriptorName (empty without activation)."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()):
        return {}
    n = int(os.environ.get("LISTEN_FDS", "0"))
    names = os.environ.get("LISTEN_FDNAMES", "").split(":")
    out = {}
    for i in range(n):
        s = socket.socket(fileno=3 + i)
        out[names[i] if i < len(names) and names[i] else str(i)] = s
    for k in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"):
        os.environ.pop(k, None)
    return out


def notify(state: str = "READY=1") -> bool:
    """sd_notify without libsystemd; False without NOTIFY_SOCKET."""
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return False
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
        s.connect(addr)
        s.sendall(state.encode())
    return True


# ── A small async client ───────────────────────────────────────────────────
async def request(path: str, obj: dict, *, timeout: float | None = 10.0):
    """Send one request and yield every line until the reply (the line with "ok")."""
    reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(path, limit=MAX_LINE), timeout)
    try:
        writer.write(_encode(obj))
        await writer.drain()
        while True:
            raw = await reader.readline()
            if not raw:
                raise ConnectionError("connection closed before the reply")
            line = json.loads(raw)
            yield line
            if "ok" in line:
                return
    finally:
        writer.close()
