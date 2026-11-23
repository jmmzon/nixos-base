"""The connection to the approval agent in the approving user's session.

The agent (agent.py, a systemd user service) shows notifications, shares links
through KDE Connect and talks to the YubiKey and the forwarded Mac SSH agent,
which all live in the user's session. The daemon trusts it only for the weak
`desktop` method: everything else it returns is a signature the daemon checks.

Wire format: JSON lines. Daemon -> agent {"id": N, "op": ..., ...};
agent -> daemon {"id": N, ...reply}. {"op": "cancel", "id": N} ends call N.
"""

import json
import threading
import time


class AgentHub:
    def __init__(self, log=print):
        self.log = log
        self.lock = threading.Lock()
        self.conn = None
        self.waiters = {}  # id -> [Event, reply]
        self.next_id = 1
        self.probe_cache = (0.0, None)
        self.probe_args = {}  # set by the daemon: kdeconnect device, mac socket

    def connected(self):
        return self.conn is not None

    def attach(self, conn):
        """Serve one agent connection until it closes (blocks)."""
        with self.lock:
            old, self.conn = self.conn, conn
            self.probe_cache = (0.0, None)
        if old is not None:
            try:
                old.close()
            except OSError:
                pass
        self.log("agent connected")
        f = conn.makefile("rb")
        try:
            for line in f:
                if len(line) > 65536:
                    break
                try:
                    msg = json.loads(line)
                    w = self.waiters.get(msg.get("id"))
                except (ValueError, AttributeError):
                    continue
                if w is not None:
                    w[1] = msg
                    w[0].set()
        except OSError:
            pass
        finally:
            with self.lock:
                if self.conn is conn:
                    self.conn = None
            for w in list(self.waiters.values()):
                w[0].set()
            self.log("agent disconnected")

    def _send(self, obj):
        data = (json.dumps(obj) + "\n").encode()
        with self.lock:
            if self.conn is None:
                raise OSError("no agent")
            self.conn.sendall(data)

    def call(self, op, timeout, cancel=None, **args):
        """Send `op`, wait for its reply; None on timeout, cancel or no agent."""
        with self.lock:
            rid = self.next_id
            self.next_id += 1
        w = [threading.Event(), None]
        self.waiters[rid] = w
        try:
            try:
                self._send({"id": rid, "op": op, **args})
            except OSError:
                return None
            end = time.monotonic() + timeout
            while not w[0].is_set():
                left = end - time.monotonic()
                if left <= 0 or (cancel is not None and cancel.is_set()):
                    break
                w[0].wait(min(0.25, left))
            if w[1] is None:
                try:
                    self._send({"id": rid, "op": "cancel"})
                except OSError:
                    pass
            return w[1]
        finally:
            self.waiters.pop(rid, None)

    def dismiss(self, rid_tag):
        """Close notifications the agent shows for a request."""
        try:
            self._send({"id": 0, "op": "dismiss", "tag": rid_tag})
        except OSError:
            pass

    def probe(self):
        """What the session can do now (cached 2 s): kdeconnect, fido, mac."""
        stamp, cached = self.probe_cache
        if cached is not None and time.monotonic() - stamp < 2:
            return cached
        reply = self.call("probe", 4, **self.probe_args) or {}
        self.probe_cache = (time.monotonic(), reply)
        return reply
