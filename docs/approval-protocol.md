# Approval daemon (approvald)

`modules/approval/` is one daemon that holds every approval credential and
asks the user to approve a request through the methods a host enables. Callers
(sudo's PAM step, a control daemon, `approval test`) never see a credential:
they ask over a socket and get `approved` or a refusal.

## Design

```
callers ── /run/approvald/request.sock (0660 root:approval-clients) ──┐
                                                                       ▼
                     approvald (system user, sandboxed, no root): policy,
                     challenge, signature checks, phone pages on loopback
                                                                       ▲
approval-agent (user service in my.approval.user's session) ──────────┘
  /run/approvald/agent.sock (accepted only from that user's uid)
  notifications, KDE Connect, QR codes, the security key, the Mac's agent
```

- **Methods** (`my.approval.methods.<name>`): `phone` (passkey on a one-time
  page; the link reaches the phone by KDE Connect, a desktop notification or a
  QR code), `yubikey` (FIDO2 touch on a key enrolled for the daemon),
  `mac` (signature from the Mac's SSH agent over the Mac approval tunnel),
  `desktop` (Approve/Deny notification; **weak**: any process of the user can
  answer it), `fake` (VM tests only). The enabled, allowed and available
  methods run at once; the first answer decides. A "Deny" refuses at once
  unless `my.approval.onDeny = "continue"`.
- **Binding.** Each request gets a fresh id and nonce. Every strong method
  signs `SHA-256` of the canonical JSON statement `{v, host, request, nonce,
  caller, action, summary, details, risk, user, expires}`: the WebAuthn
  challenge, the FIDO2 client data hash, and (prefixed with
  `approvald-v1\0`) the SSH-agent data. The daemon checks the signature against
  its enrolled key, so the session agent, which only passes data on, cannot
  approve a strong method. The approver shown everywhere is the daemon's
  statement, not the caller's text.
- **Policy.** The peer is identified by `SO_PEERCRED` (uid, then groups) and
  mapped to `my.approval.callers.<name>`, whose `methods` is a ceiling. A
  request's own `methods` narrow it further. `risk = "high"` (the default)
  excludes methods with `allowHighRisk = false` (`desktop` by default). The
  approving user is `my.approval.user`; callers cannot name one. One request
  in flight per caller, a token-bucket rate limit, a journal line per
  decision.
- **Fail closed.** Timeout, a crash, a hang-up or anything but
  `"result": "approved"` is a refusal.
- **Enrollment** (`approval enroll phone|yubikey`, through sudo): the
  daemon accepts `op: enroll` from uid 0 only. Credentials live in
  `/var/lib/approvald/` (public keys only).
- **sudo**: `my.approval.pam.sudo` adds a sufficient `pam_exec` step (after
  the Mac step, before `pam_u2f` and the password) that asks the daemon as
  the built-in caller `sudo` (root). pam_rssh and pam_u2f stay separate PAM
  steps; Polkit is unchanged.

## Request protocol v1

One JSON object per line, UTF-8, at most 4096 bytes per line; one request per
connection.

Request:

```json
{"v":1,"op":"request","action":"reboot-windows",
 "summary":"Reboot into Windows","details":{"origin":"dashboard"},
 "methods":["phone","yubikey"],"risk":"high","timeout":60}
```

| Field | |
|---|---|
| `action` | `[a-z0-9._-]{1,64}` |
| `summary` | shown to the approver; control characters become spaces; ≤ 200 chars |
| `details` | optional string map, ≤ 8 entries, values ≤ 100 chars |
| `methods` | optional; default: the caller's ceiling |
| `risk` | `low` or `high` (default `high`) |
| `timeout` | seconds, clamped to `my.approval.maxTimeout` |

Replies, in order: one `pending` line, any number of `progress` lines, then
one final line, after which the daemon closes the connection:

```json
{"event":"pending","request":"<id>","methods":["phone"],"expires":1764000000}
{"event":"progress","method":"phone","state":"link-sent"}
{"result":"approved","request":"<id>","method":"phone"}
```

Final lines: `{"result": "approved"|"denied", "request", "method"}`,
`{"result": "timeout"|"failed"|"cancelled", "request"}` (`failed`: every
method gave up), or `{"error": code}` with `forbidden`, `bad-request` (plus
`field`), `no-method`, `busy`, `rate-limited`. Closing the connection cancels
the request.

Other operations: `{"v":1,"op":"ping"}` → `{"ok":true,"version":1}`;
`{"v":1,"op":"methods"}` → `{"methods":[{"name","strength","allowHighRisk"}…],"caller"}`.

## Testing a caller

`approvald-fake --socket PATH --answer approve|deny|timeout|failed|error:CODE
[--delay S]` speaks this protocol without asking anyone (and without peer
checks), validates requests like the daemon, and prints each request it got
as a JSON line on stdout.

`scripts/tests/approval-vm.nix` is the daemon's VM test; the unit tests run
in `checks.<system>.approval-unit`.
