"""approval-agent: the approval daemon's helper in the approving user's session.

Connects to the daemon's agent socket and runs what it asks: notifications
(notify-send), KDE Connect shares, QR codes, FIDO2 assertions on a plugged-in
security key and signatures from the forwarded Mac SSH agent. It holds no
credentials; the daemon checks every signature it passes on. Its answers
count only for the weak `desktop` method.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

SOCKET = os.environ.get("APPROVALD_AGENT_SOCKET", "/run/approvald/agent.sock")
DEVICE_RE_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")


def log(msg):
    print(f"approval-agent: {msg}", file=sys.stderr, flush=True)


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def run(cmd, timeout=8):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None


def valid_device(device):
    return isinstance(device, str) and 0 < len(device) <= 64 and set(device) <= DEVICE_RE_OK


# --- Mac: SSH agent protocol (draft-miller-ssh-agent) ---


def ssh_string(b):
    return struct.pack(">I", len(b)) + b


def agent_call(path, payload, timeout):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        s.sendall(ssh_string(payload))
        head = b""
        while len(head) < 4:
            chunk = s.recv(4 - len(head))
            if not chunk:
                raise OSError("agent closed")
            head += chunk
        (n,) = struct.unpack(">I", head)
        body = b""
        while len(body) < n:
            chunk = s.recv(n - len(body))
            if not chunk:
                raise OSError("agent closed")
            body += chunk
        return body
    finally:
        s.close()


def agent_keys(path):
    body = agent_call(path, bytes([11]), 5)  # REQUEST_IDENTITIES
    if body[0] != 12:
        return []
    (count,) = struct.unpack(">I", body[1:5])
    keys, i = [], 5
    for _ in range(count):
        (n,) = struct.unpack(">I", body[i : i + 4])
        keys.append(body[i + 4 : i + 4 + n])
        i += 4 + n
        (m,) = struct.unpack(">I", body[i : i + 4])
        i += 4 + m  # comment
    return keys


def agent_sign(path, key, data, timeout):
    flags = 2 if key.startswith(ssh_string(b"ssh-rsa")) else 0  # rsa-sha2-256
    body = agent_call(path, bytes([13]) + ssh_string(key) + ssh_string(data) + struct.pack(">I", flags), timeout)
    if body[0] != 14:  # SIGN_RESPONSE; 5 is FAILURE (refused or cancelled)
        return None
    (n,) = struct.unpack(">I", body[1:5])
    return body[5 : 5 + n]


class Agent:
    def __init__(self, conn):
        self.conn = conn
        self.wlock = threading.Lock()
        self.cancels = {}  # call id -> Event
        self.procs = {}  # tag -> [Popen]
        self.lock = threading.Lock()

    def send(self, obj):
        with self.wlock:
            self.conn.sendall((json.dumps(obj) + "\n").encode())

    def loop(self):
        for line in self.conn.makefile("rb"):
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            op, rid = msg.get("op"), msg.get("id")
            if op == "cancel":
                ev = self.cancels.get(rid)
                if ev:
                    ev.set()
                continue
            if op == "dismiss":
                self.dismiss(msg.get("tag"))
                continue
            ev = threading.Event()
            self.cancels[rid] = ev
            threading.Thread(target=self.dispatch, args=(rid, op, msg, ev), daemon=True).start()

    def dispatch(self, rid, op, msg, cancel):
        try:
            fn = getattr(self, "op_" + op.replace("-", "_"), None) if isinstance(op, str) else None
            reply = fn(msg, cancel) if fn else {"error": "bad-op"}
        except Exception as e:
            log(f"{op}: {e!r}")
            reply = {"error": type(e).__name__}
        finally:
            self.cancels.pop(rid, None)
        try:
            self.send({"id": rid, **reply})
        except OSError:
            pass

    # --- notifications ---

    def notify(self, tag, args, wait=False, cancel=None):
        p = subprocess.Popen(["notify-send", "-a", "Approval", *args], stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
        with self.lock:
            self.procs.setdefault(tag, []).append(p)
        if not wait:
            return None
        while p.poll() is None:
            if cancel is not None and cancel.is_set():
                p.terminate()
                return None
            time.sleep(0.2)
        return (p.stdout.read() or "").strip()

    def dismiss(self, tag):
        with self.lock:
            procs = self.procs.pop(tag, [])
        for p in procs:
            if p.poll() is None:
                p.terminate()

    def op_probe(self, msg, cancel):
        out = {"kdeconnect": False, "fido": False, "mac": False}
        device = msg.get("kdeconnect_device")
        if valid_device(device):
            r = run(["kdeconnect-cli", "--list-available", "--id-only"], 4)
            out["kdeconnect"] = bool(r and device in r.stdout.split())
        try:
            from fido2.hid import CtapHidDevice

            out["fido"] = any(True for _ in CtapHidDevice.list_devices())
        except Exception:
            pass
        path = msg.get("mac_socket")
        if isinstance(path, str) and path:
            try:
                out["mac"] = bool(agent_keys(path))
            except (OSError, IndexError, struct.error):
                pass
        return out

    def op_confirm(self, msg, cancel):
        answer = self.notify(
            msg.get("tag"),
            ["-u", "critical", "-A", "approve=Approve", "-A", "deny=Deny", str(msg.get("title", "")), str(msg.get("body", ""))],
            wait=True,
            cancel=cancel,
        )
        return {"answer": answer if answer in ("approve", "deny") else None}

    def op_share(self, msg, cancel):
        device, url = msg.get("device"), msg.get("url")
        if not valid_device(device) or not isinstance(url, str) or not url.startswith("https://"):
            return {"ok": False}
        r = run(["kdeconnect-cli", "--device", device, "--share", url])
        return {"ok": bool(r and r.returncode == 0)}

    def op_notification(self, msg, cancel):
        url = msg.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            return {"ok": False}
        tag = msg.get("tag")

        def show():
            if self.notify(tag, ["-A", "open=Open", str(msg.get("title", "")), f"{msg.get('body', '')}\n{url}"], wait=True) == "open":
                run(["xdg-open", url])

        threading.Thread(target=show, daemon=True).start()
        return {"ok": True}

    def op_qr(self, msg, cancel):
        url = msg.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            return {"ok": False}
        fd, png = tempfile.mkstemp(prefix="approval-qr-", suffix=".png", dir=os.environ.get("XDG_RUNTIME_DIR"))
        os.close(fd)
        r = run(["qrencode", "-s", "8", "-o", png, url])
        if not r or r.returncode != 0:
            return {"ok": False}
        self.notify(msg.get("tag"), ["-u", "critical", "-i", png, "-h", f"string:image-path:{png}", str(msg.get("title", "")), "Scan with the phone.\n" + str(msg.get("body", ""))])
        threading.Timer(300, lambda: os.path.exists(png) and os.unlink(png)).start()
        return {"ok": True}

    # --- security key ---

    def op_fido_assert(self, msg, cancel):
        from fido2.ctap2 import Ctap2
        from fido2.hid import CtapHidDevice

        cdh = unb64u(msg["client_data_hash"])
        allow = [{"type": "public-key", "id": unb64u(c)} for c in msg.get("credentials", [])]
        if len(cdh) != 32 or not allow:
            return {"error": "bad-request"}
        self.notify(msg.get("tag"), ["-u", "critical", str(msg.get("title", "")), str(msg.get("body", ""))])
        for dev in CtapHidDevice.list_devices():
            try:
                a = Ctap2(dev).get_assertion(msg["rp_id"], cdh, allow, options={"up": True}, event=cancel)
            except Exception as e:
                log(f"fido: {e!r}")
                continue
            finally:
                self.dismiss(msg.get("tag"))
            return {"credential": b64u(a.credential["id"]), "auth_data": b64u(bytes(a.auth_data)), "signature": b64u(a.signature)}
        return {"error": "no-key"}

    # --- Mac ---

    def op_mac_sign(self, msg, cancel):
        path = msg.get("socket")
        if not isinstance(path, str) or not path:
            return {"error": "no-socket"}
        wanted = {unb64u(k) for k in msg.get("keys", [])}
        data = unb64u(msg["data"])
        reason = str(msg.get("reason", ""))[:300].replace("\n", " ")
        # The Mac's approval tunnel streams this file into a notification.
        runtime = os.environ.get("XDG_RUNTIME_DIR")
        if runtime:
            tmp = os.path.join(runtime, ".approval-reason.tmp")
            with open(tmp, "w") as f:
                f.write(f"{int(time.time())}\t{reason}\n")
            os.replace(tmp, os.path.join(runtime, "approval-reason"))
        for key in agent_keys(path):
            if key in wanted:
                sig = agent_sign(path, key, data, 30)
                if sig is None:
                    return {"refused": True}
                return {"key": b64u(key), "signature": b64u(sig)}
        return {"error": "no-key"}


def main():
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(SOCKET)
            log("connected")
            Agent(s).loop()
            log("daemon closed the connection")
        except OSError as e:
            log(f"{SOCKET}: {e}")
        finally:
            s.close()
        time.sleep(3)


if __name__ == "__main__":
    main()
