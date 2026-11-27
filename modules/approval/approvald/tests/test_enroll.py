"""`approval enroll yubikey` against fake keys: PIN token for makeCredential,
unchanged path without a PIN, one-line errors, and the PIN never leaking."""

import getpass
import json
import logging
import types

import fido2.ctap2
import fido2.ctap2.pin
import fido2.hid
import pytest
from fido2.ctap import CtapError

from approvald import client

PIN = "pin-7351-secret"
RealClientPin = fido2.ctap2.pin.ClientPin
ERR = CtapError.ERR


class FakeDev:
    def __init__(self, name="Fake Key"):
        self.product_name = name


class FakeKey:
    """State shared by the fake Ctap2 and ClientPin of one test."""

    def __init__(self, options, pin_error=None, make_error=None, retries=5, protocols=(2, 1)):
        self.options = options
        self.pin_error = pin_error
        self.make_error = make_error
        self.retries = retries
        self.protocols = list(protocols)
        self.made = []
        self.token_requests = []
        self.client_pins = 0


def install(monkeypatch, key, devs=None, pin=PIN):
    devs = [FakeDev()] if devs is None else devs

    class FakeCtap2:
        def __init__(self, dev):
            self.dev = dev
            self.info = types.SimpleNamespace(options=dict(key.options), pin_uv_protocols=key.protocols)

        def make_credential(self, cdh, rp, user, key_params, **kw):
            key.made.append({"cdh": cdh, "rp": rp, **kw})
            if key.make_error is not None:
                raise CtapError(key.make_error)
            cd = types.SimpleNamespace(credential_id=b"cred-id", public_key={1: 2, 3: -7})
            return types.SimpleNamespace(auth_data=types.SimpleNamespace(credential_data=cd))

    class FakeProtocol:
        VERSION = 2

        @staticmethod
        def authenticate(token, message):
            return b"mac:" + token + b":" + message

    class FakeClientPin:
        PERMISSION = RealClientPin.PERMISSION

        def __init__(self, ctap):
            key.client_pins += 1
            self.protocol = FakeProtocol()

        def get_pin_token(self, pin, permissions=None, permissions_rpid=None):
            key.token_requests.append((pin, permissions, permissions_rpid))
            if key.pin_error is not None:
                raise CtapError(key.pin_error)
            return b"token"

        def get_pin_retries(self):
            return (key.retries, None)

    sent = []

    def fake_exchange(msg, wait, on_line=None):
        sent.append(msg)
        return {"result": "enrolled"}

    pin_reads = []

    def fake_getpass(prompt="Password: ", stream=None):
        pin_reads.append(prompt)
        return pin

    monkeypatch.setattr(fido2.hid.CtapHidDevice, "list_devices", staticmethod(lambda: iter(devs)))
    monkeypatch.setattr(fido2.ctap2, "Ctap2", FakeCtap2)
    monkeypatch.setattr(fido2.ctap2.pin, "ClientPin", FakeClientPin)
    monkeypatch.setattr(getpass, "getpass", fake_getpass)
    monkeypatch.setattr(client, "exchange", fake_exchange)
    monkeypatch.setattr(client.os, "geteuid", lambda: 0)
    return sent, pin_reads


PIN_KEY = {"rk": True, "up": True, "plat": False, "clientPin": True, "credentialMgmtPreview": True}


def test_pin_key_gets_token_and_passes_param(monkeypatch):
    key = FakeKey(PIN_KEY)
    sent, reads = install(monkeypatch, key)
    assert client.enroll_yubikey() == {"result": "enrolled"}
    assert len(reads) == 1
    assert key.token_requests == [(PIN, RealClientPin.PERMISSION.MAKE_CREDENTIAL, "approvald")]
    [made] = key.made
    assert made["pin_uv_protocol"] == 2
    # The param authenticates the same client data hash makeCredential gets.
    assert made["pin_uv_param"] == b"mac:token:" + made["cdh"]
    assert made["options"] == {"rk": False}
    assert sent[0]["credential"]["id"] == "Y3JlZC1pZA"


def test_key_without_pin_is_unchanged(monkeypatch):
    key = FakeKey({"rk": True, "up": True, "plat": False})
    sent, reads = install(monkeypatch, key)
    assert client.enroll_yubikey() == {"result": "enrolled"}
    assert reads == [] and key.client_pins == 0
    [made] = key.made
    assert "pin_uv_param" not in made and "pin_uv_protocol" not in made
    assert made["options"] == {"rk": False}
    assert len(sent) == 1


def test_pin_supported_but_not_set_is_unchanged(monkeypatch):
    key = FakeKey({"rk": True, "up": True, "clientPin": False})
    _, reads = install(monkeypatch, key)
    assert client.enroll_yubikey() == {"result": "enrolled"}
    assert reads == [] and "pin_uv_param" not in key.made[0]


def test_wrong_pin_reports_retries(monkeypatch, capfd):
    key = FakeKey(PIN_KEY, pin_error=ERR.PIN_INVALID, retries=5)
    sent, _ = install(monkeypatch, key)
    assert client.cli_main(["enroll", "yubikey"]) == 1
    out, err = capfd.readouterr()
    reply = json.loads(out.strip().splitlines()[-1])
    assert reply["error"].startswith("wrong PIN") and "5 attempts left" in reply["error"]
    assert "Traceback" not in out + err
    assert key.made == [] and sent == []


@pytest.mark.parametrize(
    "options, pin_error, make_error, words",
    [
        (PIN_KEY, ERR.PIN_AUTH_BLOCKED, None, "plug it back in"),
        (PIN_KEY, ERR.PIN_BLOCKED, None, "blocked"),
        (PIN_KEY, None, ERR.USER_ACTION_TIMEOUT, "not touched in time"),
        (PIN_KEY, None, ERR.ACTION_TIMEOUT, "not touched in time"),
        ({"up": True}, None, ERR.KEEPALIVE_CANCEL, "cancelled"),
        ({"up": True, "uv": True}, None, ERR.PUAT_REQUIRED, "no PIN set"),
    ],
)
def test_key_errors_are_one_line(monkeypatch, capfd, options, pin_error, make_error, words):
    install(monkeypatch, FakeKey(options, pin_error=pin_error, make_error=make_error))
    assert client.cli_main(["enroll", "yubikey"]) == 1
    out, err = capfd.readouterr()
    reply = json.loads(out.strip().splitlines()[-1])
    assert words in reply["error"] and "\n" not in reply["error"]
    assert "Traceback" not in out + err


def test_no_key(monkeypatch):
    install(monkeypatch, FakeKey(PIN_KEY), devs=[])
    assert client.enroll_yubikey() == {"error": "no security key plugged in"}


def test_several_keys_names_the_first(monkeypatch, capfd):
    key = FakeKey({"up": True})
    install(monkeypatch, key, devs=[FakeDev("Key One"), FakeDev("Key Two")])
    assert client.enroll_yubikey() == {"result": "enrolled"}
    out, _ = capfd.readouterr()
    assert "using Key One" in out and "Key Two" not in out


def test_empty_pin_cancels(monkeypatch):
    key = FakeKey(PIN_KEY)
    install(monkeypatch, key, pin="")
    assert "cancelled" in client.enroll_yubikey()["error"]
    assert key.token_requests == [] and key.made == []


def test_read_pin_refuses_echoing_fallback(monkeypatch):
    """Without a terminal getpass would read stdin with echo; refuse instead."""
    import io

    real_open = getpass.os.open

    def no_tty(path, *a, **kw):
        if path == "/dev/tty":
            raise OSError("no tty")
        return real_open(path, *a, **kw)

    monkeypatch.setattr(getpass.os, "open", no_tty)
    monkeypatch.setattr("sys.stdin", io.StringIO(PIN + "\n"))
    with pytest.raises(getpass.GetPassWarning):
        client.read_pin()


@pytest.mark.parametrize("pin_error", [None, ERR.PIN_INVALID, ERR.PIN_BLOCKED])
def test_pin_never_in_output_or_logs(monkeypatch, capfd, caplog, pin_error):
    caplog.set_level(logging.DEBUG)
    key = FakeKey(PIN_KEY, pin_error=pin_error)
    sent, _ = install(monkeypatch, key)
    client.cli_main(["enroll", "yubikey"])
    out, err = capfd.readouterr()
    assert PIN not in out + err
    assert PIN not in caplog.text
    assert PIN not in json.dumps(sent)
    assert all(PIN not in json.dumps(str(m)) for m in key.made)
