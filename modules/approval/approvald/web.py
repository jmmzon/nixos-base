"""The phone method's one-time pages, served on loopback behind Caddy.

GET /r/<token> shows what is being approved and asks the phone for a passkey
assertion over the request's challenge; POST /r/<token>/approve checks it,
POST /r/<token>/deny refuses. /e/<token> enrolls a passkey (root asked for it).
"""

import html
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    PublicKeyCredentialDescriptor,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

ENROLL_SECONDS = 600

PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Approval</title>
<style>
 body {{ font: 17px system-ui, sans-serif; margin: 0; padding: 2rem 1.2rem;
        background: #111418; color: #e8eaed; }}
 h1 {{ font-size: 1.3rem; margin: 0 0 1rem; }}
 .reason {{ font-family: ui-monospace, monospace; background: #1d2228;
           padding: .8rem; border-radius: .6rem; word-break: break-all; }}
 button {{ display: block; width: 100%; font-size: 1.1rem; padding: 1rem;
          margin-top: 1rem; border: 0; border-radius: .8rem; }}
 #ok {{ background: #4c8bf5; color: white; }}
 #no {{ background: #2a3038; color: #e8eaed; }}
 #status {{ margin-top: 1.2rem; min-height: 1.5em; }}
</style></head><body>
<h1>{title}</h1>
{body}
<div id="status"></div>
<script>
const opts = {options};
const kind = "{kind}";
const b64u = {{
  dec: s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0)),
  enc: b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, ""),
}};
const status = t => document.getElementById("status").textContent = t;
function done(t) {{ status(t); document.querySelectorAll("button").forEach(b => b.disabled = true); }}
async function post(path, body) {{
  const r = await fetch(location.pathname + path, {{method: "POST",
    headers: {{"Content-Type": "application/json"}}, body: JSON.stringify(body || {{}})}});
  return [r.ok, await r.text()];
}}
async function go() {{
  try {{
    opts.challenge = b64u.dec(opts.challenge);
    let cred, body;
    if (kind === "enroll") {{
      opts.user.id = b64u.dec(opts.user.id);
      (opts.excludeCredentials || []).forEach(c => c.id = b64u.dec(c.id));
      cred = await navigator.credentials.create({{publicKey: opts}});
      body = {{id: cred.id, rawId: b64u.enc(cred.rawId), type: cred.type,
        response: {{clientDataJSON: b64u.enc(cred.response.clientDataJSON),
                   attestationObject: b64u.enc(cred.response.attestationObject),
                   transports: cred.response.getTransports ? cred.response.getTransports() : []}},
        clientExtensionResults: cred.getClientExtensionResults()}};
    }} else {{
      (opts.allowCredentials || []).forEach(c => c.id = b64u.dec(c.id));
      cred = await navigator.credentials.get({{publicKey: opts}});
      body = {{id: cred.id, rawId: b64u.enc(cred.rawId), type: cred.type,
        response: {{clientDataJSON: b64u.enc(cred.response.clientDataJSON),
                   authenticatorData: b64u.enc(cred.response.authenticatorData),
                   signature: b64u.enc(cred.response.signature),
                   userHandle: cred.response.userHandle ? b64u.enc(cred.response.userHandle) : null}},
        clientExtensionResults: cred.getClientExtensionResults()}};
    }}
    const [ok, text] = await post(kind === "enroll" ? "" : "/approve", body);
    done(text);
  }} catch (e) {{ status("Not approved: " + e.message); }}
}}
document.getElementById("ok").onclick = go;
const no = document.getElementById("no");
if (no) no.onclick = async () => {{ const [, t] = await post("/deny"); done(t); }};
</script></body></html>"""



class PhoneWeb:
    def __init__(self, rp_id, port, log=print):
        self.rp_id = rp_id
        self.origin = f"https://{rp_id}"
        self.port = port
        self.log = log
        self.store = None  # the phone method's credential store
        self.lock = threading.Lock()
        self.entries = {}

    def open(self, kind, user, challenge, expires, text, host):
        token = secrets.token_urlsafe(18)
        entry = {
            "token": token,
            "kind": kind,
            "user": user,
            "challenge": challenge,
            "expires": expires,
            "text": text,
            "host": host,
            "done": threading.Event(),
            "result": "failed",
            "url": f"{self.origin}/{'r' if kind == 'approve' else 'e'}/{token}",
        }
        with self.lock:
            self.entries[token] = entry
        return entry

    def close(self, token):
        with self.lock:
            self.entries.pop(token, None)

    def take(self, token, kind):
        """The live entry for this token and kind, or None."""
        with self.lock:
            e = self.entries.get(token)
        if e is None or e["kind"] != kind or e["done"].is_set() or time.time() > e["expires"]:
            return None
        return e

    def finish(self, entry, result):
        with self.lock:
            if entry["done"].is_set():
                return False
            entry["result"] = result
            entry["done"].set()
            return True

    def serve(self):
        web = self

        class Handler(WebHandler):
            pass

        Handler.web = web
        server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server


class WebHandler(BaseHTTPRequestHandler):
    server_version = "approvald"
    web = None

    def log_message(self, fmt, *args):
        self.web.log("http: " + fmt % args)

    def reply(self, code, text, ctype="text/plain; charset=utf-8"):
        data = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'")
        self.end_headers()
        self.wfile.write(data)

    def parts(self):
        return [p for p in self.path.split("?")[0].split("/") if p]

    def do_GET(self):
        w = self.web
        p = self.parts()
        if len(p) != 2 or p[0] not in ("r", "e"):
            return self.reply(404, "Not found.")
        kind = "approve" if p[0] == "r" else "enroll"
        e = w.take(p[1], kind)
        if e is None:
            return self.reply(410, "This request has expired or was already answered.")
        creds = w.store.user(e["user"])
        host = html.escape(e["host"])
        if kind == "approve":
            options = generate_authentication_options(
                rp_id=w.rp_id,
                challenge=e["challenge"],
                timeout=int(max(1, e["expires"] - time.time()) * 1000),
                allow_credentials=[PublicKeyCredentialDescriptor(id=base64url_to_bytes(c["id"])) for c in creds],
                user_verification=UserVerificationRequirement.REQUIRED,
            )
            title = f"Approve as {html.escape(e['user'])} on {host}?"
            body = (
                f'<div class="reason">{html.escape(e["text"]).replace(chr(10), "<br>")}</div>'
                '<button id="ok">Approve with fingerprint</button>'
                '<button id="no">Deny</button>'
            )
        else:
            options = generate_registration_options(
                rp_id=w.rp_id,
                rp_name=f"{e['host']} approval",
                user_name=e["user"],
                user_id=e["user"].encode(),
                challenge=e["challenge"],
                timeout=ENROLL_SECONDS * 1000,
                authenticator_selection=AuthenticatorSelectionCriteria(
                    resident_key=ResidentKeyRequirement.DISCOURAGED,
                    user_verification=UserVerificationRequirement.REQUIRED,
                ),
                exclude_credentials=[PublicKeyCredentialDescriptor(id=base64url_to_bytes(c["id"])) for c in creds],
            )
            title = f"Add this phone for {html.escape(e['user'])} on {host}"
            body = f"<p>Creates a passkey on this phone that can approve requests on {host}.</p>" '<button id="ok">Create passkey</button>'
        page = PAGE.format(
            title=title,
            body=body,
            kind=kind,
            options=options_to_json(options).replace("</", "<\\/"),
        )
        self.reply(200, page, "text/html; charset=utf-8")

    def do_POST(self):
        w = self.web
        p = self.parts()
        length = min(int(self.headers.get("Content-Length") or 0), 65536)
        raw = self.rfile.read(length)
        if self.headers.get("Origin") != w.origin:
            return self.reply(403, "Wrong origin.")
        if len(p) == 3 and p[0] == "r" and p[2] == "deny":
            e = w.take(p[1], "approve")
            if e is None or not w.finish(e, "denied"):
                return self.reply(410, "Expired.")
            return self.reply(200, "Denied.")
        if len(p) == 3 and p[0] == "r" and p[2] == "approve":
            return self.approve(p[1], raw)
        if len(p) == 2 and p[0] == "e":
            return self.enroll(p[1], raw)
        return self.reply(404, "Not found.")

    def approve(self, token, raw):
        w = self.web
        e = w.take(token, "approve")
        if e is None:
            return self.reply(410, "Expired.")
        try:
            cred = json.loads(raw)
            stored = next(c for c in w.store.user(e["user"]) if c["id"] == cred["id"])
            result = verify_authentication_response(
                credential=cred,
                expected_challenge=e["challenge"],
                expected_rp_id=w.rp_id,
                expected_origin=w.origin,
                credential_public_key=base64url_to_bytes(stored["public_key"]),
                credential_current_sign_count=stored["sign_count"],
                require_user_verification=True,
            )
        except Exception as ex:  # any verification failure is a refusal
            w.log(f"phone {e['user']}: assertion rejected: {ex!r}")
            return self.reply(400, "Verification failed.")
        w.store.update(e["user"], stored["id"], sign_count=result.new_sign_count, last_used=int(time.time()))
        if not w.finish(e, "approved"):
            return self.reply(410, "Expired.")
        return self.reply(200, "Approved.")

    def enroll(self, token, raw):
        w = self.web
        e = w.take(token, "enroll")
        if e is None:
            return self.reply(410, "Expired.")
        try:
            result = verify_registration_response(
                credential=json.loads(raw),
                expected_challenge=e["challenge"],
                expected_rp_id=w.rp_id,
                expected_origin=w.origin,
                require_user_verification=True,
            )
        except Exception as ex:
            w.log(f"phone {e['user']}: enrollment failed: {ex!r}")
            w.finish(e, "failed")
            return self.reply(400, "Registration failed.")
        w.store.add(
            e["user"],
            {
                "id": bytes_to_base64url(result.credential_id),
                "public_key": bytes_to_base64url(result.credential_public_key),
                "sign_count": result.sign_count,
                "created": int(time.time()),
                "agent": self.headers.get("User-Agent", "")[:200],
            },
        )
        w.finish(e, "enrolled")
        return self.reply(200, f"Passkey added. This phone can now approve requests on {e['host']}.")
