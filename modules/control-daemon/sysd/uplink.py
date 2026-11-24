"""The desktop session's uplink: the user's erebor-desktopd connects out to
sysd's session socket (sysd, a system user, cannot reach the user's runtime
directory). sysd then speaks desktopd's own protocol over that connection:
it subscribes first, then sends forwarded commands tagged with an ``id``.

Only the session user's uid is accepted. A new uplink replaces the old one.
Without one, forwarded commands fail at once with ``no-session``.
"""

from __future__ import annotations

import asyncio
import itertools
import json
import sys
from typing import Callable

from jsonline import Error, peer_of

CALL_TIMEOUT = 30.0
MAX_LINE = 64 * 1024


def log(msg: str) -> None:
    print(f"erebor-sysd: {msg}", file=sys.stderr, flush=True)


class Session:
    def __init__(self, reader, writer, on_event: Callable[[dict], None]):
        self.reader, self.writer = reader, writer
        self.on_event = on_event
        self.pending: dict[int, asyncio.Future] = {}
        self.ids = itertools.count(1)
        self.closed = False

    async def call(self, req: dict, timeout: float = CALL_TIMEOUT) -> dict:
        if self.closed:
            raise Error("no desktop session", code="no-session")
        rid = next(self.ids)
        fut = asyncio.get_running_loop().create_future()
        self.pending[rid] = fut
        try:
            self.writer.write((json.dumps({**req, "id": rid}) + "\n").encode())
            await asyncio.wait_for(self.writer.drain(), timeout)
            reply = await asyncio.wait_for(fut, timeout)
        except (asyncio.TimeoutError, TimeoutError):
            raise Error("the desktop session did not answer", code="session-timeout")
        except (OSError, ConnectionError):
            raise Error("no desktop session", code="no-session")
        finally:
            self.pending.pop(rid, None)
        reply.pop("id", None)
        return reply

    async def run(self) -> None:
        try:
            while True:
                raw = await self.reader.readline()
                if not raw:
                    break
                try:
                    line = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if not isinstance(line, dict):
                    continue
                rid = line.get("id")
                if rid is not None and "ok" in line:
                    fut = self.pending.get(rid)
                    if fut is not None and not fut.done():
                        fut.set_result(line)
                elif "event" in line and rid is None:
                    self.on_event(line)
        except (OSError, ValueError, ConnectionError):
            pass
        finally:
            self.close()

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.writer.close()
        for fut in self.pending.values():
            if not fut.done():
                fut.set_exception(Error("the desktop session went away", code="no-session"))


class Uplinks:
    """Holds the current session and tells subscribers when it comes and goes."""

    def __init__(self, uid: int | None, emit: Callable[[dict], None]):
        self.uid = uid
        self.emit = emit
        self.session: Session | None = None
        self.state: dict | None = None

    @property
    def up(self) -> bool:
        return self.session is not None and not self.session.closed

    async def accept(self, reader, writer) -> None:
        peer = peer_of(writer.get_extra_info("socket"))
        if self.uid is None or peer is None or peer.uid != self.uid:
            log(f"uplink refused (peer {peer})")
            writer.close()
            return
        old = self.session
        s = Session(reader, writer, self._event)
        self.session = s
        if old is not None:
            old.close()
        runner = asyncio.create_task(s.run())
        try:
            hello = await s.call({"command": "subscribe"}, timeout=10)
        except Error as e:
            log(f"uplink: subscribe failed: {e}")
            s.close()
            await runner
            return
        if not hello.get("ok"):
            log(f"uplink: subscribe refused: {hello.get('error')}")
            s.close()
            await runner
            return
        self.state = {k: v for k, v in hello.items() if k not in ("ok", "subscribed")}
        log(f"desktop session up (pid {peer.pid})")
        self.emit({"event": "session-up", "desktop": self.state})
        await runner
        if self.session is s:
            self.session = None
            self.state = None
            log("desktop session down")
            self.emit({"event": "session-down"})

    def _event(self, event: dict) -> None:
        self.emit({**event, "source": "desktop"})

    async def call(self, req: dict) -> dict:
        if not self.up:
            raise Error("no desktop session", code="no-session")
        return await self.session.call(req)
