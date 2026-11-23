"""Signature checks for the yubikey (FIDO2) and mac (SSH agent) methods."""

import base64
import hashlib
import struct

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.serialization import load_ssh_public_key

# Prefix of what the Mac signs, so a signature can't be reused as an SSH login
# or for another protocol.
SSH_NAMESPACE = b"approvald-v1\0"
SSH_KEY_TYPES = (
    "ssh-ed25519",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "ssh-rsa",
)


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


# --- SSH ---


def ssh_strings(blob):
    out, i = [], 0
    while i < len(blob):
        if i + 4 > len(blob):
            raise ValueError("truncated")
        (n,) = struct.unpack(">I", blob[i : i + 4])
        if i + 4 + n > len(blob):
            raise ValueError("truncated")
        out.append(blob[i + 4 : i + 4 + n])
        i += 4 + n
    return out


def read_authorized_keys(text):
    """Key blobs from authorized_keys-style lines (options are ignored)."""
    blobs = []
    for line in text.splitlines():
        parts = line.split()
        for i, p in enumerate(parts[:-1]):
            if p in SSH_KEY_TYPES:
                try:
                    blob = base64.b64decode(parts[i + 1], validate=True)
                    if ssh_strings(blob)[0].decode() == p:
                        blobs.append(blob)
                except (ValueError, IndexError):
                    pass
                break
    return blobs


def ssh_verify(key_blob, signature_blob, data):
    """True if `signature_blob` (SSH wire format) signs `data` with the key."""
    try:
        keytype = ssh_strings(key_blob)[0].decode()
        key = load_ssh_public_key(keytype.encode() + b" " + base64.b64encode(key_blob))
        fmt, sig = ssh_strings(signature_blob)[:2]
        fmt = fmt.decode()
        if isinstance(key, ed25519.Ed25519PublicKey) and fmt == "ssh-ed25519":
            key.verify(sig, data)
        elif isinstance(key, ec.EllipticCurvePublicKey) and fmt == keytype:
            r, s = (int.from_bytes(x, "big") for x in ssh_strings(sig)[:2])
            h = {256: hashes.SHA256(), 384: hashes.SHA384(), 521: hashes.SHA512()}[key.curve.key_size]
            key.verify(encode_dss_signature(r, s), data, ec.ECDSA(h))
        elif isinstance(key, rsa.RSAPublicKey) and fmt in ("rsa-sha2-256", "rsa-sha2-512"):
            h = hashes.SHA256() if fmt == "rsa-sha2-256" else hashes.SHA512()
            key.verify(sig, data, padding.PKCS1v15(), h)
        else:
            return False
        return True
    except (InvalidSignature, ValueError, KeyError, IndexError, TypeError):
        return False


# --- FIDO2 ---


def fido_verify(public_key_cose, rp_id, client_data_hash, auth_data, signature, min_counter):
    """Check a CTAP2 assertion. Returns the new counter, or None if invalid."""
    from fido2 import cbor
    from fido2.cose import CoseKey
    from fido2.webauthn import AuthenticatorData

    try:
        ad = AuthenticatorData(auth_data)
        if ad.rp_id_hash != hashlib.sha256(rp_id.encode()).digest():
            return None
        if not ad.flags & AuthenticatorData.FLAG.UP:
            return None
        CoseKey.parse(cbor.decode(public_key_cose)).verify(auth_data + client_data_hash, signature)
    except Exception:
        return None
    # Keys without a counter always report 0; otherwise it must grow.
    if ad.counter != 0 and ad.counter <= min_counter:
        return None
    return ad.counter
