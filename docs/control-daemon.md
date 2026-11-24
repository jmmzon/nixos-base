# System control daemon (erebor-sysd)

`modules/control-daemon/` is one system-wide entry point for machine-level
actions and for the desktop session's commands, with a declarative policy
saying which run freely, which need approval and which are refused.

## Design

```
callers ── /run/erebor/sysd.sock (0660 root:erebor-control) ──┐
 (dashboard, erebor-sys, ...)                                  ▼
            erebor-sysd (system user, sandboxed, no root): policy, approvald
            client, actions through polkit grants to its own user
                                                               ▲
erebor-desktopd (the session user's) ──────────────────────────┘
  connects out to /run/erebor/sysd-session.sock (accepted only from
  my.controlDaemon.sessionUser's uid) and serves sysd over that connection
```

- **Callers** are matched by the peer's uid, then its groups
  (`my.controlDaemon.callers`). Others are refused at connect time.
- **Origin.** A request may name its `origin` (`dashboard`) and the origin's
  user (`origin_user`). They are not proven, so a policy entry for an origin
  can only make approval stricter. They go into the journal line and the
  approval's details. The threat this guards is remote use through the
  dashboard; a program running as the user can reach its own session anyway.
- **Policy** (`my.controlDaemon.actions.<name>`): `approval = none | approve |
  deny`, replaced per caller (`callers.<c>`), made stricter per origin
  (`origins.<o>`). An action not listed is refused, except read-only ones
  (`get-*`, `list-*`, `status`, and the daemon's own read-only actions).
- **Approval.** `approve` asks approvald as caller `sysd`
  (docs/approval-protocol.md) with `my.controlDaemon.approval.methods`
  (default: the enabled ones of phone, yubikey, mac; never the weak desktop
  notification by default). Anything but `approved` refuses. Closing the
  connection while it waits cancels the request.
- **Privilege.** sysd runs as `erebor-sysd` with no capabilities and no
  network. The module grants that user polkit actions only for actions the
  policy can allow: power-profile switching, login1 suspend and power-off
  (inhibitors still apply), and `start` of the Windows reboot unit.
- **Desktop forwarding.** `desktop.<command>` goes to the session's
  erebor-desktopd over its uplink. sysd subscribes first, then sends commands
  tagged with an `id`. Without an uplink a forwarded command fails at once
  with `no-session`, before any approval; nothing is queued. A new uplink
  replaces the old one.

## Protocol

JSON per line (the shared server below). One request per line with a
`command`, answered in order; an `id` is echoed on every line of its
answer.

```json
{"command":"set-power-profile","profile":"balanced","origin":"dashboard","origin_user":"alice"}
```

The answer ends with a line that has `ok`. Before it, an approval streams
`{"event":"approval-pending","methods":[…],"request":…,"expires":…}` and
`approval-progress` lines. Errors: `{"ok":false,"error":text,"code":c}` with
`forbidden` (policy), `not-approved` (plus `result`: denied, timeout, failed,
or approvald's error), `bad-request` (plus `field`), `no-session`,
`session-timeout`, `unavailable`, `failed`.

| Command | |
|---|---|
| `get-power-profile` | read-only: `{"profile"}` |
| `set-power-profile` | `profile`: performance, balanced, power-saver |
| `sleep`, `power-off` | through login1 |
| `reboot-windows` | starts `my.controlDaemon.rebootWindowsUnit` |
| `desktop.<command>` | forwarded to erebor-desktopd (any other fields too) |
| `list-actions` | read-only: each action's level for this caller (and `origin`), and `session` |
| `subscribe` | events: `power-profile-changed`, `session-up` (`desktop`: its state), `session-down`, and desktopd's own events tagged `"source":"desktop"` |

`erebor-sys COMMAND [key=value ...]` is the command-line client
(`erebor-sys subscribe` prints events; `--json` prints every line).

## The server

`modules/control-daemon/erebor_desktop/server.py` is the asyncio
JSON-per-line daemon both sysd and erebor-desktopd are built on (desktopd
copies it from here; import path `erebor_desktop.server`). A daemon is a
set of features, each registering commands, events, CLI subcommands and
supervised tasks; state-changing commands share one lock; each subscriber
has a bounded queue and is dropped when it stalls. For sysd it also has: a
streaming command (an async generator: progress lines, then the reply),
`cancel_on_hangup`, a `prefix` handler (`desktop.`), the client's
credentials (`ctx.connection.peer`) with an `accept` hook, a socket from
systemd (`sock=`, `listen_fds()`), and `dial(path)` to serve a connection
the daemon opens itself (desktopd's uplink). The module docstring is the
reference.

## Testing

`checks.<system>.control-daemon-unit` runs the server, policy and daemon
tests (`test_server.py` came with the server) (approvald-fake for approvals, a fake desktopd on the uplink).
`scripts/tests/control-daemon-vm.nix` is the VM test (polkit grants, the
three policy levels, refused peers, forwarding).
