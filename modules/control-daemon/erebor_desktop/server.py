"""A small asyncio daemon: JSON per line over a Unix socket, features as plugins.

This module is generic (nothing erebor- or Noctalia-specific) so erebor-sysd
(SYS-140) can reuse it. Its public API is what feature files import, and
nixos-base pins it, so keep these names stable:

    from erebor_desktop.server import Feature

    feature = Feature("modes", events=["mode-changed"])

    @feature.command("get-modes")                 # read-only: never waits
    async def get_modes(ctx, req):
        return {"ok": True, "modes": [...]}

    @feature.command("set-mode", mutates=True)    # under the daemon-wide lock
    async def set_mode(ctx, req):
        r = await ctx.run("erebor-modes", "sync", timeout=60)   # Result(rc, stdout, stderr)
        if ctx.has("set-noctalia-preset"):
            await ctx.call("set-noctalia-preset", {"look": "glass"})  # no deadlock
        ctx.emit("mode-changed", modes=[...])
        return {"ok": True}

    @feature.on_start              # before the socket is ready (sync or async)
    def start(ctx): ...

    @feature.task                  # long-running; restarted with backoff if it fails
    async def watch(ctx): ...

    feature.snapshot = lambda ctx: {...}   # sent in the subscribe reply, under the lock
    feature.status = lambda ctx: {...}     # for a status command (SYS-184)

    cli = feature.cli("set-mode", help="turn a mode on or off")  # erebor-ctl subcommand
    cli.arguments(lambda p: p.add_argument("name"))              # argparse
    cli.request(lambda a: {"command": "set-mode", "name": a.name})
    cli.output(lambda r: print(r["modes"]))                      # default: the JSON

A feature file is a module with a module-level `feature` (or a `features`
list). The daemon loads its own `features/` package and every `*.py` in the
extra feature directories (`--feature-dir`, `EREBOR_DESKTOP_FEATURE_DIRS`),
in name order; files starting with `_` are skipped. A command, event or CLI
name defined twice stops startup with an error naming both features.

Protocol: one JSON object per line each way. A request is
{"command": NAME, ...} with an optional "id" echoed in the reply; a reply has
"ok" and, when false, "error". Requests on one connection are answered in
order. Built in: `subscribe` (then events, {"event": NAME, ...}, follow on
that connection; commands still work there), `describe` (features, commands,
events, protocol version).

Concurrency: commands with mutates=True run under one daemon-wide lock, so
state changes and their events never interleave. ctx.call from inside such a
command (or from code holding ctx.locked()) does not take it again. Reads
never wait. Each subscriber has a bounded queue and its own writer: a client
that does not keep up (queue full, or a write stuck for `drain_timeout`) is
sent {"event": "dropped", "reason": "slow-reader"} on a best-effort basis and
disconnected; nobody else waits for it.
"""

from __future__ import annotations

import asyncio
import collections
import contextlib
import contextvars
import dataclasses
import importlib
import importlib.util
import inspect
import json
import logging
import os
import pkgutil
import signal
import socket
import time
import traceback
from typing import Any, Awaitable, Callable

PROTOCOL = 1
BUILTIN_COMMANDS = ("subscribe", "describe")
MAX_LINE = 64 * 1024

log = logging.getLogger("erebor-desktopd")

Handler = Callable[["Context", dict], Awaitable[dict]]


class UsageError(Exception):
    """Raised by a Cli request builder for bad arguments (erebor-ctl exits 2)."""


# ── Registration ────────────────────────────────────────────────────────────
@dataclasses.dataclass
class Command:
    name: str
    fn: Handler
    mutates: bool
    feature: "Feature"


class Cli:
    """An erebor-ctl subcommand for a command (see the module docstring)."""

    def __init__(self, name: str, help: str | None):
        self.name = name
        self.help = help
        self._arguments: Callable | None = None
        self._request: Callable | None = None
        self._output: Callable | None = None

    def arguments(self, fn):
        self._arguments = fn
        return fn

    def request(self, fn):
        self._request = fn
        return fn

    def output(self, fn):
        self._output = fn
        return fn

    # Used by the client.
    def add_arguments(self, parser) -> None:
        if self._arguments:
            self._arguments(parser)

    def build(self, args) -> dict:
        return self._request(args) if self._request else {"command": self.name}

    def show(self, reply: dict) -> None:
        if self._output:
            self._output(reply)
        else:
            print(json.dumps(reply, indent=2))


class Feature:
    def __init__(self, name: str, events: list[str] | tuple[str, ...] = (), *, flat_snapshot: bool = False):
        self.name = name
        self.events = tuple(events)
        self.commands: dict[str, Command] = {}
        self.clis: dict[str, Cli] = {}
        self.starts: list[Callable] = []
        self.tasks: list[Callable] = []
        self.snapshot: Callable[[Context], dict] | None = None
        self.status: Callable[[Context], dict] | None = None
        # Also put the snapshot's keys at the top of the subscribe reply
        # (compatibility: presets did before features existed).
        self.flat_snapshot = flat_snapshot
        self.source = "?"

    def command(self, name: str, *, mutates: bool = False):
        def deco(fn: Handler) -> Handler:
            if not inspect.iscoroutinefunction(fn):
                raise TypeError(f"{self.name}: command {name} must be async")
            if name in self.commands:
                raise ValueError(f"{self.name}: command {name} defined twice")
            self.commands[name] = Command(name, fn, mutates, self)
            return fn

        return deco

    def cli(self, name: str, *, help: str | None = None) -> Cli:
        if name in self.clis:
            raise ValueError(f"{self.name}: cli {name} defined twice")
        c = self.clis[name] = Cli(name, help)
        return c

    def on_start(self, fn):
        self.starts.append(fn)
        return fn

    def task(self, fn):
        if not inspect.iscoroutinefunction(fn):
            raise TypeError(f"{self.name}: task {fn.__name__} must be async")
        self.tasks.append(fn)
        return fn


class Registry:
    """Features with their command, event and CLI names checked for clashes."""

    def __init__(self, features: list[Feature]):
        self.features: dict[str, Feature] = {}
        self.commands: dict[str, Command] = {}
        self.events: dict[str, Feature] = {}
        self.clis: dict[str, tuple[Feature, Cli]] = {}
        errors = []

        def clash(kind, name, a: Feature, b: Feature):
            errors.append(f"{kind} {name!r} defined by both {a.name} ({a.source}) and {b.name} ({b.source})")

        for f in features:
            if f.name in self.features:
                clash("feature", f.name, self.features[f.name], f)
                continue
            self.features[f.name] = f
            for name, c in f.commands.items():
                if name in BUILTIN_COMMANDS:
                    errors.append(f"command {name!r} of {f.name} ({f.source}) is built in")
                elif name in self.commands:
                    clash("command", name, self.commands[name].feature, f)
                else:
                    self.commands[name] = c
            for name in f.events:
                if name == "dropped":
                    errors.append(f"event 'dropped' of {f.name} ({f.source}) is built in")
                elif name in self.events:
                    clash("event", name, self.events[name], f)
                else:
                    self.events[name] = f
            for name, c in f.clis.items():
                if name in BUILTIN_COMMANDS or name == "call":
                    errors.append(f"cli {name!r} of {f.name} ({f.source}) is built in")
                elif name in self.clis:
                    clash("cli", name, self.clis[name][0], f)
                else:
                    self.clis[name] = (f, c)
        if errors:
            raise ValueError("feature conflicts:\n  " + "\n  ".join(errors))

    def describe(self) -> dict:
        return {
            name: {"commands": sorted(f.commands), "events": list(f.events), "source": f.source}
            for name, f in self.features.items()
        }


def _features_of(module, source: str) -> list[Feature]:
    found = getattr(module, "features", None)
    if found is None:
        found = [getattr(module, "feature", None)]
    out = [f for f in found if isinstance(f, Feature)]
    if not out:
        raise ValueError(f"{source}: no `feature` (or `features`) defined")
    for f in out:
        f.source = source
    return out


def load_features(package: str | None = None, dirs: list[str] = ()) -> list[Feature]:
    """The features of a package's modules, then of every *.py in dirs."""
    out: list[Feature] = []
    if package:
        pkg = importlib.import_module(package)
        for m in sorted(pkgutil.iter_modules(pkg.__path__), key=lambda m: m.name):
            if not m.name.startswith("_"):
                mod = importlib.import_module(f"{package}.{m.name}")
                out += _features_of(mod, mod.__file__ or m.name)
    for i, d in enumerate(dirs):
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".py") or fn.startswith("_"):
                continue
            path = os.path.join(d, fn)
            spec = importlib.util.spec_from_file_location(f"_erebor_feature_{i}_{fn[:-3]}", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            out += _features_of(mod, path)
    return out


def feature_dirs(extra: list[str] = ()) -> list[str]:
    env = os.environ.get("EREBOR_DESKTOP_FEATURE_DIRS", "")
    return [d for d in env.split(":") if d] + list(extra)


# ── Running ─────────────────────────────────────────────────────────────────
@dataclasses.dataclass
class Result:
    rc: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.rc == 0

    @property
    def output(self) -> str:
        return (self.stdout + self.stderr).strip()


_holding = contextvars.ContextVar("erebor_desktop_holding_lock", default=False)


@dataclasses.dataclass
class TaskHealth:
    running: bool = False
    restarts: int = 0
    last_error: str | None = None
    since: float | None = None


class Context:
    """What a feature's code gets: its own store, the daemon's services."""

    def __init__(self, daemon: "Daemon", feature: Feature):
        self.daemon = daemon
        self.feature = feature
        self.config = daemon.config
        self.store: dict[str, Any] = {}
        self.log = logging.getLogger(f"erebor-desktopd.{feature.name}")

    def emit(self, event: str, **fields) -> None:
        if event not in self.feature.events:
            raise ValueError(f"{self.feature.name} did not declare event {event!r}")
        self.daemon.emit({"event": event, **fields})

    async def run(self, *cmd: str, timeout: float = 30, input: str | None = None) -> Result:
        """Run a program without blocking the loop. Never raises: a missing
        program is rc 127, a timeout kills it and is rc -1."""
        try:
            p = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE if input is not None else asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except OSError as e:
            return Result(127, "", str(e))
        try:
            out, err = await asyncio.wait_for(
                p.communicate(input.encode() if input is not None else None), timeout
            )
        except TimeoutError:
            p.kill()
            out, err = await p.communicate()
            msg = f"{cmd[0]}: timed out after {timeout:g} s"
            self.log.warning(msg)
            return Result(-1, out.decode(errors="replace"), (err.decode(errors="replace") + "\n" + msg).strip())
        return Result(p.returncode, out.decode(errors="replace"), err.decode(errors="replace"))

    def has(self, command: str) -> bool:
        return command in self.daemon.registry.commands

    async def call(self, command: str, req: dict | None = None) -> dict:
        """Another feature's command, as a client would send it (minus the
        socket). Inside a mutating command it does not take the lock again."""
        return await self.daemon.dispatch({**(req or {}), "command": command})

    @contextlib.asynccontextmanager
    async def locked(self):
        """The daemon-wide lock, for a task that changes state (re-entrant)."""
        async with self.daemon.locked():
            yield

    def health(self) -> dict:
        """Every feature's task health and status() output (for SYS-184)."""
        return self.daemon.health()


class Subscriber:
    """One connection's outgoing lines once it has subscribed. A line goes
    straight to the transport while it is below its high-water mark and
    nothing is queued; otherwise it waits in the queue for pump(). Replies
    take the same path so a reply and the events around it keep their order;
    only events count toward the bound."""

    def __init__(self, daemon: "Daemon", writer: asyncio.StreamWriter):
        self.daemon = daemon
        self.writer = writer
        self.lines: collections.deque[tuple[bytes, bool]] = collections.deque()
        self.events = 0
        self.wake = asyncio.Event()
        self.dropped = False
        self.task: asyncio.Task | None = None

    def push(self, line: bytes, event: bool) -> None:
        if self.dropped:
            return
        t = self.writer.transport
        if not self.lines and t.get_write_buffer_size() < t.get_write_buffer_limits()[1]:
            # Nothing waiting and the transport has room: no need to queue
            # (also lets a burst of events in one command reach a fast reader).
            try:
                t.write(line)
            except Exception:
                self.drop("gone", quiet=True, tell=False)
            return
        if event and self.events >= self.daemon.queue_size:
            self.drop("queue full")
            return
        self.lines.append((line, event))
        self.events += event
        self.wake.set()

    async def pump(self) -> None:
        try:
            while not self.dropped:
                await self.wake.wait()
                self.wake.clear()
                while self.lines and not self.dropped:
                    line, event = self.lines.popleft()
                    self.events -= event
                    self.writer.write(line)
                    await asyncio.wait_for(self.writer.drain(), self.daemon.drain_timeout)
        except TimeoutError:
            self.drop("write stalled")
        except (ConnectionError, OSError):
            self.drop("gone", quiet=True, tell=False)

    def drop(self, why: str, quiet: bool = False, tell: bool = True) -> None:
        if self.dropped:
            return
        self.dropped = True
        self.lines.clear()
        self.daemon.subscribers.discard(self)
        if not quiet:
            log.warning("dropped a subscriber: %s", why)
        t = self.writer.transport
        if not t.is_closing():
            # Best effort: it lands only if the client's buffer has room.
            if tell:
                with contextlib.suppress(Exception):
                    t.write(b'{"event": "dropped", "reason": "slow-reader"}\n')
            t.close()
            asyncio.get_running_loop().call_later(1, t.abort)
        if self.task and self.task is not asyncio.current_task():
            self.task.cancel()


class Daemon:
    def __init__(
        self,
        features: list[Feature],
        socket_path: str,
        config: dict | None = None,
        *,
        queue_size: int = 256,
        drain_timeout: float = 10,
        backoff: tuple[float, float, float] = (1, 60, 300),
        write_buffer_high: int | None = None,
    ):
        self.registry = Registry(features)
        self.socket_path = socket_path
        self.config = config or {}
        self.queue_size = queue_size
        self.drain_timeout = drain_timeout
        self.backoff = backoff  # first delay, max delay, healthy-after seconds
        self.write_buffer_high = write_buffer_high
        self.lock = asyncio.Lock()
        self.subscribers: set[Subscriber] = set()
        self.contexts = {name: Context(self, f) for name, f in self.registry.features.items()}
        self.task_health: dict[str, TaskHealth] = {}
        self._tasks: list[asyncio.Task] = []
        self._server: asyncio.Server | None = None
        self._inode: int | None = None
        self._connections: set[asyncio.Task] = set()

    # Locking and dispatch
    @contextlib.asynccontextmanager
    async def locked(self):
        if _holding.get():
            yield
            return
        async with self.lock:
            token = _holding.set(True)
            try:
                yield
            finally:
                _holding.reset(token)

    async def dispatch(self, req: dict) -> dict:
        name = req.get("command")
        c = self.registry.commands.get(name)
        if c is None:
            return {"ok": False, "error": f"unknown command {name!r}"}
        ctx = self.contexts[c.feature.name]
        try:
            if c.mutates:
                async with self.locked():
                    reply = await c.fn(ctx, req)
            else:
                reply = await c.fn(ctx, req)
        except Exception as e:  # keep serving
            log.error("%s failed:\n%s", name, traceback.format_exc())
            return {"ok": False, "error": f"{type(e).__name__}: {e}"}
        if not isinstance(reply, dict):
            return {"ok": False, "error": f"{name} returned {type(reply).__name__}, not a dict"}
        return reply

    def emit(self, event: dict) -> None:
        line = (json.dumps(event) + "\n").encode()
        for s in list(self.subscribers):
            s.push(line, True)

    def snapshot(self) -> dict:
        flat, state = {}, {}
        for name, f in self.registry.features.items():
            if f.snapshot:
                s = f.snapshot(self.contexts[name])
                state[name] = s
                if f.flat_snapshot:
                    flat.update(s)
        return {**flat, "state": state}

    def health(self) -> dict:
        out = {}
        for name, f in self.registry.features.items():
            entry: dict[str, Any] = {
                "tasks": {
                    k.split("/", 1)[1]: dataclasses.asdict(h)
                    for k, h in self.task_health.items()
                    if k.split("/", 1)[0] == name
                }
            }
            if f.status:
                try:
                    entry["status"] = f.status(self.contexts[name])
                except Exception as e:
                    entry["status"] = {"error": f"{type(e).__name__}: {e}"}
            out[name] = entry
        return out

    # Connections
    async def _connection(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._connections.add(asyncio.current_task())
        if self.write_buffer_high is not None:
            writer.transport.set_write_buffer_limits(high=self.write_buffer_high)
        sub: Subscriber | None = None

        async def send(obj: dict) -> None:
            line = (json.dumps(obj) + "\n").encode()
            if sub:
                sub.push(line, False)
            else:
                writer.write(line)
                await asyncio.wait_for(writer.drain(), self.drain_timeout)

        try:
            while True:
                try:
                    raw = await reader.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    await send({"ok": False, "error": f"request longer than {MAX_LINE} bytes"})
                    break
                if not raw:
                    break
                if sub and sub.dropped:
                    break
                try:
                    req = json.loads(raw)
                    if not isinstance(req, dict):
                        raise ValueError
                except ValueError:
                    await send({"ok": False, "error": "bad JSON (want one object per line)"})
                    continue
                if req.get("command") == "subscribe":
                    if sub:
                        reply = {"ok": True, "subscribed": True, "already": True}
                    else:
                        # Snapshot and registration under the lock: the first
                        # event this client gets is the first after the snapshot.
                        async with self.locked():
                            try:
                                reply = {"ok": True, "subscribed": True, **self.snapshot()}
                            except Exception as e:
                                log.error("snapshot failed:\n%s", traceback.format_exc())
                                reply = {"ok": False, "error": f"{type(e).__name__}: {e}"}
                            else:
                                sub = Subscriber(self, writer)
                                sub.task = asyncio.create_task(sub.pump())
                                self.subscribers.add(sub)
                elif req.get("command") == "describe":
                    reply = {"ok": True, "protocol": PROTOCOL, "features": self.registry.describe()}
                else:
                    reply = await self.dispatch(req)
                if "id" in req:
                    reply = {**reply, "id": req["id"]}
                await send(reply)
        except (TimeoutError, ConnectionError, OSError):
            pass
        except asyncio.CancelledError:
            raise
        finally:
            self._connections.discard(asyncio.current_task())
            if sub:
                # Let queued lines (replies, events) go out before closing.
                if not sub.dropped:
                    with contextlib.suppress(Exception):
                        await asyncio.wait_for(self._flush(sub), self.drain_timeout)
                sub.dropped = True
                self.subscribers.discard(sub)
                if sub.task:
                    sub.task.cancel()
            writer.close()

    async def _flush(self, sub: Subscriber) -> None:
        while sub.lines and sub.task and not sub.task.done():
            await asyncio.sleep(0.01)

    # Tasks
    async def _supervise(self, f: Feature, fn) -> None:
        key = f"{f.name}/{fn.__name__}"
        h = self.task_health[key] = TaskHealth()
        first, most, healthy = self.backoff
        delay = first
        ctx = self.contexts[f.name]
        while True:
            h.running, h.since = True, time.monotonic()
            try:
                await fn(ctx)
                h.running = False
                log.info("task %s finished", key)
                return
            except asyncio.CancelledError:
                h.running = False
                raise
            except Exception as e:
                h.running = False
                h.last_error = f"{type(e).__name__}: {e}"
                if time.monotonic() - h.since >= healthy:
                    delay = first
                log.error("task %s failed (restart in %g s):\n%s", key, delay, traceback.format_exc())
                await asyncio.sleep(delay)
                h.restarts += 1
                delay = min(delay * 2, most)

    # Lifecycle
    def _claim_socket(self) -> None:
        """Refuse to start if a daemon answers there; remove a stale socket."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(self.socket_path)
        except (FileNotFoundError, ConnectionRefusedError):
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.socket_path)
        else:
            raise SystemExit(f"erebor-desktopd: already running on {self.socket_path}")
        finally:
            s.close()

    async def start(self) -> None:
        for name, f in self.registry.features.items():
            for fn in f.starts:
                r = fn(self.contexts[name])
                if inspect.isawaitable(r):
                    await r
        self._claim_socket()
        old = os.umask(0o177)  # the socket is 0600 from the start
        try:
            self._server = await asyncio.start_unix_server(self._connection, self.socket_path, limit=MAX_LINE)
        finally:
            os.umask(old)
        self._inode = os.stat(self.socket_path).st_ino
        for f in self.registry.features.values():
            for fn in f.tasks:
                self._tasks.append(asyncio.create_task(self._supervise(f, fn)))

    async def stop(self) -> None:
        if self._server:
            self._server.close()
        for t in self._tasks + list(self._connections):
            t.cancel()
        for s in list(self.subscribers):
            s.drop("shutdown", quiet=True, tell=False)
        await asyncio.gather(*self._tasks, *self._connections, return_exceptions=True)
        with contextlib.suppress(FileNotFoundError):
            if os.stat(self.socket_path).st_ino == self._inode:
                os.unlink(self.socket_path)

    async def serve_forever(self) -> None:
        await self.start()
        sd_notify("READY=1")
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()
        sd_notify("STOPPING=1")
        await self.stop()


def sd_notify(state: str) -> None:
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
        s.connect(addr)
        s.sendall(state.encode())
