import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from approvald import core, methods, verify
from approvald.agent import ssh_string

# --- helpers ---


class Scripted(core.Method):
    def __init__(self, name, answer, delay=0.0, strength="strong", seen=None):
        self.strength = strength
        super().__init__(name, {})
        self.answer, self.delay, self.seen = answer, delay, seen

    def run(self, ctx):
        if self.seen is not None:
            self.seen.append(ctx.challenge)
        end = time.time() + self.delay
        while time.time() < end and not ctx.cancel.is_set():
            time.sleep(0.01)
        if self.answer == "hang":
            ctx.wait(threading.Event())
            return "failed"
        return self.answer


def config(on_deny="deny", ceiling=("a", "b", "weak")):
    return {
        "user": "alice",
        "host": "testhost",
        "onDeny": on_deny,
        "defaultTimeout": 5,
        "maxTimeout": 10,
        "callers": {
            "sysd": {"uids": [1000], "gids": [500], "methods": list(ceiling), "rateLimit": {"burst": 3, "perMinute": 60}},
            "pam": {"uids": [0], "gids": [], "methods": ["a"], "rateLimit": {"burst": 1, "perMinute": 1}},
        },
    }


def req(**kw):
    return {"v": 1, "op": "request", "action": "reboot", "summary": "Reboot", **kw}


def broker(ms, **kw):
    return core.Broker(config(**kw), {m.name: m for m in ms}, "testhost", log=lambda m: None)


def run(b, msg, caller="sysd"):
    lines = []
    final = b.handle(caller, msg, lines.append)
    return final, lines


# --- parsing and binding ---


def test_parse_rejects_bad_fields():
    for bad in [
        {"v": 2, "op": "request", "action": "x"},
        req(action="Bad Action"),
        req(risk="medium"),
        req(timeout=-1),
        req(timeout=True),
        req(methods="a"),
        req(details={str(i): "x" for i in range(9)}),
    ]:
        with pytest.raises(core.BadRequest):
            core.parse_request(bad, 10, 5)


def test_parse_cleans_and_clamps():
    r = core.parse_request(req(summary="line1\nline2\x1b[31m", timeout=999), 10, 5)
    assert "\n" not in r["summary"] and "\x1b" not in r["summary"]
    assert r["timeout"] == 10
    assert r["risk"] == "high"  # the default is the safe one


def test_challenge_binds_every_field():
    base = {
        "host": "h", "id": "i", "nonce": "n", "caller": "c", "action": "a",
        "summary": "s", "details": {}, "risk": "high", "user": "u", "expires": 1,
    }
    c0 = core.challenge(base)
    for k in base:
        changed = dict(base)
        changed[k] = {"x": "y"} if k == "details" else ("low" if k == "risk" else 2 if k == "expires" else "other")
        assert core.challenge(changed) != c0, k


# --- caller policy ---


def test_caller_mapping_by_uid_then_group():
    b = broker([])
    assert b.caller_for(1000, [1]) == "sysd"
    assert b.caller_for(0, [0]) == "pam"
    assert b.caller_for(1234, [7, 500]) == "sysd"
    assert b.caller_for(1234, [7]) is None


def test_methods_are_intersected_with_ceiling():
    b = broker([Scripted("a", "approved"), Scripted("c", "approved")])
    final, _ = run(b, req(methods=["c"]))
    assert final == {"error": "no-method"}  # c is enabled but not allowed for sysd
    final, lines = run(b, req(methods=["c", "a"]))
    assert final["result"] == "approved" and final["method"] == "a"
    assert lines[0]["methods"] == ["a"]


def test_weak_method_refused_for_high_risk():
    b = broker([Scripted("weak", "approved", strength="weak")])
    assert run(b, req(risk="high"))[0] == {"error": "no-method"}
    assert run(b, req(risk="low"))[0]["result"] == "approved"


def test_unavailable_method_skipped():
    m = Scripted("a", "approved")
    m.available = lambda r: False
    assert run(broker([m]), req())[0] == {"error": "no-method"}


# --- outcomes ---


def test_first_approval_wins_and_challenge_shared():
    seen = []
    b = broker([Scripted("a", "approved", 0.05, seen=seen), Scripted("b", "hang", seen=seen)])
    final, lines = run(b, req())
    assert final["result"] == "approved" and final["method"] == "a"
    assert lines[0]["event"] == "pending"
    assert len(seen) == 2 and seen[0] == seen[1]


def test_deny_wins_by_default():
    b = broker([Scripted("a", "denied"), Scripted("b", "approved", 0.3)])
    final, _ = run(b, req())
    assert final["result"] == "denied" and final["method"] == "a"


def test_on_deny_continue_lets_another_method_approve():
    b = broker([Scripted("a", "denied"), Scripted("b", "approved", 0.3)], on_deny="continue")
    assert run(b, req())[0]["result"] == "approved"


def test_on_deny_continue_still_denies_when_nothing_approves():
    b = broker([Scripted("a", "denied"), Scripted("b", "failed", 0.1)], on_deny="continue")
    assert run(b, req())[0]["result"] == "denied"


def test_timeout():
    b = broker([Scripted("a", "hang")])
    t = time.time()
    final, _ = run(b, req(timeout=1))
    assert final["result"] == "timeout" and time.time() - t < 3


def test_all_failed():
    b = broker([Scripted("a", "failed")])
    assert run(b, req())[0]["result"] == "failed"


def test_broken_method_never_approves():
    m = Scripted("a", "approved")
    m.run = lambda ctx: 1 / 0
    assert run(broker([m]), req())[0]["result"] == "failed"


def test_cancel_when_caller_hangs_up():
    b = broker([Scripted("a", "hang")])
    cancel = threading.Event()
    threading.Timer(0.2, cancel.set).start()
    assert b.handle("sysd", req(timeout=5), lambda l: None, cancel)["result"] == "cancelled"


def test_one_pending_per_caller_and_rate_limit():
    b = broker([Scripted("a", "approved", 0.5)])
    out = []
    t = threading.Thread(target=lambda: out.append(run(b, req())[0]))
    t.start()
    time.sleep(0.1)
    assert run(b, req())[0] == {"error": "busy"}
    t.join()
    assert out[0]["result"] == "approved"
    # pam: burst 1, 1 per minute
    assert run(b, req(), caller="pam")[0]["result"] == "approved"
    assert run(b, req(), caller="pam")[0] == {"error": "rate-limited"}


def test_rate_limit_refills():
    now = [0.0]
    r = core.RateLimit(2, 60, clock=lambda: now[0])
    assert r.take() and r.take() and not r.take()
    now[0] += 1.0
    assert r.take() and not r.take()


# --- signatures ---


def ssh_blob_ed25519(key):
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return ssh_string(b"ssh-ed25519") + ssh_string(raw)


def test_ssh_ed25519_and_authorized_keys():
    key = ed25519.Ed25519PrivateKey.generate()
    blob = ssh_blob_ed25519(key)
    line = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()
    assert verify.read_authorized_keys(f"# c\nrestrict {line} mac\n") == [blob]
    data = verify.SSH_NAMESPACE + b"x" * 32
    sig = ssh_string(b"ssh-ed25519") + ssh_string(key.sign(data))
    assert verify.ssh_verify(blob, sig, data)
    assert not verify.ssh_verify(blob, sig, data + b"y")
    other = ssh_blob_ed25519(ed25519.Ed25519PrivateKey.generate())
    assert not verify.ssh_verify(other, sig, data)


def test_ssh_ecdsa_p256():
    key = ec.generate_private_key(ec.SECP256R1())
    line = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()
    blob = verify.read_authorized_keys(line)[0]
    data = b"payload"
    r, s = decode_dss_signature(key.sign(data, ec.ECDSA(hashes.SHA256())))

    def mpint(n):
        b = n.to_bytes((n.bit_length() + 8) // 8, "big")
        return ssh_string(b)

    sig = ssh_string(b"ecdsa-sha2-nistp256") + ssh_string(mpint(r) + mpint(s))
    assert verify.ssh_verify(blob, sig, data)
    assert not verify.ssh_verify(blob, sig, b"other")


def soft_fido(rp_id, counter, cdh, key, flags=0x01):
    ad = hashlib.sha256(rp_id.encode()).digest() + bytes([flags]) + struct.pack(">I", counter)
    return ad, key.sign(ad + cdh, ec.ECDSA(hashes.SHA256()))


def cose(key):
    from fido2 import cbor
    from fido2.cose import ES256

    return cbor.encode(dict(ES256.from_cryptography_key(key.public_key())))


def test_fido_verify():
    key = ec.generate_private_key(ec.SECP256R1())
    cdh = os.urandom(32)
    ad, sig = soft_fido("approvald", 5, cdh, key)
    assert verify.fido_verify(cose(key), "approvald", cdh, ad, sig, 4) == 5
    assert verify.fido_verify(cose(key), "approvald", cdh, ad, sig, 5) is None  # replayed counter
    assert verify.fido_verify(cose(key), "other", cdh, ad, sig, 0) is None
    assert verify.fido_verify(cose(key), "approvald", os.urandom(32), ad, sig, 0) is None
    ad2, sig2 = soft_fido("approvald", 9, cdh, key, flags=0x00)
    assert verify.fido_verify(cose(key), "approvald", cdh, ad2, sig2, 0) is None  # no user presence


# --- methods through a fake session agent ---


class FakeHub:
    def __init__(self, handler, probe=None):
        self.handler = handler
        self._probe = probe or {}

    def connected(self):
        return True

    def probe(self):
        return self._probe

    def call(self, op, timeout, cancel=None, **args):
        return self.handler(op, args)

    def dismiss(self, tag):
        pass


def ctx_for(b_req):
    full = {
        **core.parse_request(b_req, 10, 5),
        "id": "rid", "nonce": "n", "caller": "sysd", "user": "alice", "host": "h",
        "expires": int(time.time() + 5),
    }
    return core.Context(full, lambda l: None)


def test_yubikey_method_checks_assertion(tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
    cid = verify.b64u(b"cred")
    counter = [0]

    def agent(op, args):
        assert op == "fido-assert" and args["credentials"] == [cid]
        counter[0] += 1
        cdh = verify.unb64u(args["client_data_hash"])
        ad, sig = soft_fido(args["rp_id"], counter[0], cdh, key)
        return {"credential": cid, "auth_data": verify.b64u(ad), "signature": verify.b64u(sig)}

    m = methods.YubiKey("yubikey", {}, FakeHub(agent, {"fido": True}), str(tmp_path))
    ctx = ctx_for(req())
    assert not m.available(ctx.req)
    m.enroll("alice", {"id": cid, "public_key": verify.b64u(cose(key))})
    assert m.available(ctx.req)
    assert m.run(ctx) == "approved"
    assert m.run(ctx_for(req())) == "approved"  # counter moved on
    # A different key (e.g. another FIDO device) is refused.
    other = ec.generate_private_key(ec.SECP256R1())
    key_backup, key = key, other
    assert m.run(ctx_for(req())) == "failed"


def test_mac_method_checks_signature(tmp_path):
    key = ed25519.Ed25519PrivateKey.generate()
    line = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()
    (tmp_path / "alice.keys").write_text(line + "\n")
    signed = []

    def agent(op, args):
        data = verify.unb64u(args["data"])
        signed.append(data)
        sig = ssh_string(b"ssh-ed25519") + ssh_string(key.sign(data))
        return {"key": args["keys"][0], "signature": verify.b64u(sig)}

    m = methods.Mac("mac", {"keysDir": str(tmp_path), "socket": "/x"}, FakeHub(agent, {"mac": True}))
    ctx = ctx_for(req())
    assert m.available(ctx.req)
    assert m.run(ctx) == "approved"
    assert signed[0] == verify.SSH_NAMESPACE + ctx.challenge

    def forger(op, args):  # an agent replaying a signature over other data
        sig = ssh_string(b"ssh-ed25519") + ssh_string(key.sign(b"something else"))
        return {"key": args["keys"][0], "signature": verify.b64u(sig)}

    m.hub = FakeHub(forger, {"mac": True})
    assert m.run(ctx_for(req())) == "failed"


def test_desktop_method():
    m = methods.Desktop("desktop", {}, FakeHub(lambda op, a: {"answer": "deny"}))
    assert m.strength == "weak" and not m.allow_high_risk
    assert m.run(ctx_for(req())) == "denied"
    m = methods.Desktop("desktop", {"allowHighRisk": True}, FakeHub(lambda op, a: None))
    assert m.allow_high_risk
    assert m.run(ctx_for(req())) == "failed"


def test_fake_method_needs_testing():
    cfg = {"methods": {"f": {"enable": True, "type": "fake"}}}
    with pytest.raises(SystemExit):
        methods.build(cfg, None, "/tmp", None)
    assert "f" in methods.build({**cfg, "testing": True}, None, "/tmp", None)


# --- the fake daemon speaks the protocol ---


def test_fake_daemon_roundtrip(tmp_path):
    path = str(tmp_path / "s")
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    p = subprocess.Popen(
        [sys.executable, os.path.join(here, "run.py"), "fake", "--socket", path, "--answer", "deny"],
        stdout=subprocess.PIPE,
    )
    try:
        for _ in range(100):
            if os.path.exists(path):
                break
            time.sleep(0.05)
        os.environ["APPROVALD_SOCKET"] = path
        from approvald import client

        client.SOCKET = path
        r = client.request("reboot", "Reboot", timeout=5)
        assert r["result"] == "denied" and r["method"] == "fake"
        assert client.exchange({"v": 1, "op": "request", "action": "Bad!"}, 5)["error"] == "bad-request"
    finally:
        p.kill()
