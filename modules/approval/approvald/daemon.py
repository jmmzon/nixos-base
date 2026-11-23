"""approvald: the approval daemon.

Sockets come from systemd (socket activation, named by FileDescriptorName):
  request  callers (group-restricted by the socket unit); identified by
           SO_PEERCRED/SO_PEERGROUPS and mapped to my.approval.callers.
  agent    the approving user's session agent (checked by uid).
The protocol is in docs/approval-protocol.md.
"""

import grp
import time
import json
import os
import pwd
import secrets
import socket
import struct
import sys
import threading

from . import core, methods
from .hub import AgentHub
from .web import ENROLL_SECONDS, PhoneWeb

SO_PEERGROUPS = getattr(socket, "SO_PEERGROUPS", 59)
MAX_LINE = 4096


def log(msg):
    print(msg, flush=True)


def peer(conn):
    pid, uid, gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    try:
        raw = conn.getsockopt(socket.SOL_SOCKET, SO_PEERGROUPS, 4 * 256)
        gids = list(struct.unpack(f"{len(raw) // 4}I", raw))
    except OSError:
        gids = []
    return pid, uid, [gid, *gids]


def listen_fds():
    """systemd's sockets by name."""
    if os.environ.get("LISTEN_PID") != str(os.getpid()):
        raise SystemExit("approvald: start me through approvald.socket")
    n = int(os.environ.get("LISTEN_FDS", "0"))
    names = os.environ.get("LISTEN_FDNAMES", "").split(":")
    out = {}
    for i in range(n):
        s = socket.socket(fileno=3 + i)
        out[names[i] if i < len(names) else str(i)] = s
    return out


def resolve(config):
    """Turn caller user and group names into ids (once, at start)."""
    for c in config["callers"].values():
        c["uids"] = [pwd.getpwnam(u).pw_uid for u in c.get("users", []) if _exists(pwd.getpwnam, u)]
        c["gids"] = [grp.getgrnam(g).gr_gid for g in c.get("groups", []) if _exists(grp.getgrnam, g)]
    return config


def _exists(fn, name):
    try:
        fn(name)
        return True
    except KeyError:
        log(f"config: {name} does not exist, ignored")
        return False


class Connection:
    def __init__(self, conn):
        self.conn = conn
        self.wlock = threading.Lock()

    def send(self, obj):
        data = (json.dumps(obj) + "\n").encode()
        with self.wlock:
            self.conn.sendall(data)

    def readline(self):
        buf = b""
        while b"\n" not in buf:
            chunk = self.conn.recv(1024)
            if not chunk:
                break
            buf += chunk
            if len(buf) > MAX_LINE:
                raise ValueError("line too long")
        return buf.split(b"\n", 1)[0]

    def watch_hangup(self, cancel):
        def run():
            try:
                while self.conn.recv(256):
                    pass
            except OSError:
                pass
            cancel.set()

        threading.Thread(target=run, daemon=True).start()


class Daemon:
    def __init__(self, config, state):
        self.config = config
        self.hub = AgentHub(log)
        self.user = pwd.getpwnam(config["user"])
        phone = config["methods"].get("phone", {})
        self.hub.probe_args = {
            "kdeconnect_device": phone.get("kdeconnectDevice"),
            "mac_socket": config["methods"].get("mac", {}).get("socket"),
        }
        self.web = PhoneWeb(phone.get("rpId", "localhost"), int(phone.get("port", 0)), log)
        self.methods = methods.build(config, self.hub, state, self.web)
        self.broker = core.Broker(config, self.methods, config["host"], log)

    def serve_requests(self, sock):
        while True:
            conn, _ = sock.accept()
            threading.Thread(target=self.request, args=(conn,), daemon=True).start()

    def serve_agent(self, sock):
        while True:
            conn, _ = sock.accept()
            try:
                _, uid, _ = peer(conn)
            except OSError:
                conn.close()
                continue
            if uid != self.user.pw_uid:
                log(f"agent: refused uid {uid}")
                conn.close()
                continue
            threading.Thread(target=self.hub.attach, args=(conn,), daemon=True).start()

    def request(self, raw):
        c = Connection(raw)
        try:
            raw.settimeout(10)
            _, uid, gids = peer(raw)
            try:
                msg = json.loads(c.readline())
            except (ValueError, UnicodeDecodeError):
                return c.send({"error": "bad-request"})
            raw.settimeout(None)
            op = msg.get("op") if isinstance(msg, dict) else None
            if op == "ping":
                return c.send({"ok": True, "version": core.PROTOCOL})
            if op == "enroll":
                return self.enroll(c, uid, msg)
            caller = self.broker.caller_for(uid, gids)
            if caller is None:
                log(f"refused uid {uid}: not a configured caller")
                return c.send({"error": "forbidden"})
            if op == "methods":
                return c.send({"methods": self.broker.methods_info(), "caller": caller})
            cancel = threading.Event()
            c.watch_hangup(cancel)
            c.send(self.broker.handle(caller, msg, c.send, cancel))
        except OSError:
            pass
        finally:
            raw.close()

    def enroll(self, c, uid, msg):
        """Root only (the enroll command runs through sudo)."""
        if uid != 0:
            return c.send({"error": "forbidden"})
        user = self.config["user"]
        method = self.methods.get(msg.get("method"))
        if isinstance(method, methods.YubiKey):
            try:
                method.enroll(user, msg["credential"])
            except (KeyError, ValueError, TypeError):
                return c.send({"error": "bad-request"})
            log(f"enroll yubikey {user}: added")
            return c.send({"result": "enrolled"})
        if isinstance(method, methods.Phone):
            entry = self.web.open("enroll", user, secrets.token_bytes(32), time.time() + ENROLL_SECONDS, "", self.config["host"])
            try:
                c.send({"url": entry["url"]})
                if self.hub.connected() and method.device:
                    self.hub.call("share", 8, device=method.device, url=entry["url"])
                entry["done"].wait(ENROLL_SECONDS)
                log(f"enroll phone {user}: {entry['result']}")
                return c.send({"result": entry["result"] if entry["done"].is_set() else "timeout"})
            finally:
                self.web.close(entry["token"])
        return c.send({"error": "no-method"})


def main():
    with open(os.environ["APPROVALD_CONFIG"]) as f:
        config = resolve(json.load(f))
    d = Daemon(config, os.environ["STATE_DIRECTORY"])
    socks = listen_fds()
    if d.web.port and "phone" in d.methods:
        d.web.serve()
    threading.Thread(target=d.serve_agent, args=(socks["agent"],), daemon=True).start()
    log(f"approvald: methods {', '.join(sorted(d.methods)) or 'none'}; approver {config['user']}")
    d.serve_requests(socks["request"])


if __name__ == "__main__":
    sys.exit(main())
