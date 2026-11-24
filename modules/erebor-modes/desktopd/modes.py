"""erebor-desktopd feature: desktop modes (erebor-modes).

The engine stays the `erebor-modes` CLI (the Noctalia hooks, the game watcher
and the notification buttons call it too, under its own file lock); this
feature runs it and owns the ordering:

  get-modes                 state.json, plus which modes set-mode can change
  set-mode NAME on|off      reduce-transparency: the toggle; power-saver: the
                            power profile (off goes back to the profile it
                            replaced, else balanced); game is read-only
  sync-modes                `erebor-modes sync` (the power-profile watcher)
  suspend-modes / resume-modes
                            restore every item while the modes stay on, and
                            apply them again: a preset switch runs between
  modes-changed             the engine's ping after it writes state.json

Event: mode-changed {modes, entering, leaving, items}, once per change of
state.json, whoever made it.

@gdbus@ and @powerprofilesctl@ are filled in by modules/erebor-modes.nix.
"""

from __future__ import annotations

import asyncio
import json
import os

from erebor_desktop.server import Feature

feature = Feature("modes", events=["mode-changed"])

GDBUS = "@gdbus@"
POWERPROFILESCTL = "@powerprofilesctl@"
ENGINE = "erebor-modes"  # the user's profile (Home Manager), on the daemon's PATH
ENGINE_TIMEOUT = 120  # ddcutil detect and WLED timeouts add up

# What set-mode can change, by the mode's kind in the manifest.
PROFILE_MODES = {"power-saver": "power-saver"}  # mode -> power profile


def modes_dir() -> str:
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.environ.get("EREBOR_MODES_STATE_DIR") or os.path.join(base, "erebor-modes")


def read_state() -> dict:
    try:
        with open(os.path.join(modes_dir(), "state.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"modes": []}


class Memory:
    """The profile power-saver replaced (in the daemon's state dir)."""

    def __init__(self, ctx):
        self.path = os.path.join(ctx.state_dir, "modes.json")

    def get(self) -> str | None:
        try:
            with open(self.path) as f:
                return json.load(f).get("profile_before")
        except (OSError, ValueError):
            return None

    def set(self, profile: str | None) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"profile_before": profile}, f)
        os.replace(tmp, self.path)


_last: dict = {"modes": None, "items": None}
_manifest: dict | None = None


async def engine(ctx, *args: str) -> dict:
    r = await ctx.run(ENGINE, *args, timeout=ENGINE_TIMEOUT)
    if r.returncode != 0:
        raise RuntimeError(f"erebor-modes {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
    return r


async def manifest(ctx) -> dict:
    global _manifest
    if _manifest is None:
        r = await engine(ctx, "manifest")
        _manifest = json.loads(r.stdout)
    return _manifest


async def settable(ctx) -> dict:
    """mode id -> how set-mode changes it ("toggle" or "profile")."""
    out = {}
    for m in (await manifest(ctx)).get("modes", []):
        if m.get("kind") == "toggle":
            out[m["id"]] = "toggle"
        elif m["id"] in PROFILE_MODES:
            out[m["id"]] = "profile"
    return out


def changed_event(state: dict) -> dict | None:
    """mode-changed for state if it differs from the last one emitted."""
    modes = list(state.get("modes") or [])
    items = {i: v.get("status") for i, v in (state.get("items") or {}).items()}
    if _last["modes"] == modes and _last["items"] == items:
        return None
    before = _last["modes"] or []
    _last.update(modes=modes, items=items)
    return {
        "event": "mode-changed",
        "modes": modes,
        "entering": [m for m in modes if m not in before],
        "leaving": [m for m in before if m not in modes],
        "items": items,
    }


def emit_if_changed(ctx) -> None:
    ev = changed_event(read_state())
    if ev:
        ctx.emit(ev)


async def profile(ctx) -> str:
    r = await ctx.run(POWERPROFILESCTL, "get", timeout=10)
    return r.stdout.strip()


# ── Commands ────────────────────────────────────────────────────────────────


@feature.command("get-modes")
async def get_modes(ctx, req):
    return {"ok": True, "settable": await settable(ctx), **read_state()}


@feature.command("set-mode", mutates=True)
async def set_mode(ctx, req):
    name, to = req.get("mode"), req.get("to")
    if to not in ("on", "off"):
        return {"ok": False, "error": "to must be on or off"}
    kinds = await settable(ctx)
    if name not in kinds:
        known = [m["id"] for m in (await manifest(ctx)).get("modes", [])]
        if name in known:
            return {"ok": False, "error": f"{name} follows its condition and cannot be set"}
        return {"ok": False, "error": f"no mode {name!r} (settable: {', '.join(kinds)})"}
    if kinds[name] == "toggle":
        await engine(ctx, "toggle", name, to)
    else:
        mem = Memory(ctx)
        want = PROFILE_MODES[name]
        cur = await profile(ctx)
        if to == "on" and cur != want:
            mem.set(cur)
            await ctx.run(POWERPROFILESCTL, "set", want, timeout=10)
        elif to == "off" and cur == want:
            back = mem.get() or "balanced"
            mem.set(None)
            await ctx.run(POWERPROFILESCTL, "set", back, timeout=10)
        await engine(ctx, "sync")
    emit_if_changed(ctx)
    state = read_state()
    return {"ok": True, "mode": name, "on": name in state.get("modes", []), "modes": state.get("modes", [])}


@feature.command("sync-modes", mutates=True)
async def sync_modes(ctx, req):
    await engine(ctx, "sync")
    emit_if_changed(ctx)
    return {"ok": True, "modes": read_state().get("modes", [])}


@feature.command("suspend-modes", mutates=True)
async def suspend_modes(ctx, req):
    if not read_state().get("modes"):
        return {"ok": True, "modes": [], "restored": [], "kept": []}
    r = await engine(ctx, "suspend")
    return {"ok": True, **json.loads(r.stdout)}


@feature.command("resume-modes", mutates=True)
async def resume_modes(ctx, req):
    r = await engine(ctx, "resume")
    emit_if_changed(ctx)
    return {"ok": True, **json.loads(r.stdout)}


@feature.command("modes-changed")
async def modes_changed(ctx, req):
    # Not mutating: the engine may ping while this daemon holds the lock and
    # waits for that same engine run.
    emit_if_changed(ctx)
    return {"ok": True}


def snapshot(ctx) -> dict:
    s = read_state()
    return {"modes": s.get("modes", []), "items": {i: v.get("status") for i, v in (s.get("items") or {}).items()}}


feature.snapshot = snapshot


# ── The power profile, followed without Noctalia's hook ─────────────────────


async def watch_profile(ctx):
    """Sync when power-profiles-daemon's ActiveProfile changes (the Noctalia hook
    can miss it, e.g. while Noctalia restarts); a second sync is harmless."""
    changed_event(read_state())  # the state at start is the baseline, not a change
    proc = await asyncio.create_subprocess_exec(
        GDBUS, "monitor", "--system",
        "--dest", "org.freedesktop.UPower.PowerProfiles",
        "--object-path", "/org/freedesktop/UPower/PowerProfiles",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        await ctx.call("sync-modes", {})  # catch up with a change made while we were down
        while line := await proc.stdout.readline():
            if b"ActiveProfile" not in line:
                continue
            if await profile(ctx) != PROFILE_MODES["power-saver"]:
                Memory(ctx).set(None)  # left power-saver some other way: forget
            await ctx.call("sync-modes", {})
        raise RuntimeError(f"gdbus monitor exited ({await proc.wait()})")
    finally:
        if proc.returncode is None:
            proc.kill()


feature.task = watch_profile


# ── erebor-ctl ──────────────────────────────────────────────────────────────


@feature.cli("get-modes", help="print the active modes and their items")
def _get_modes(p):
    def fmt(r):
        out = ["modes: " + (", ".join(r.get("modes") or []) or "none")]
        for iid, i in (r.get("items") or {}).items():
            extra = f" ({i['reason']})" if i.get("reason") else ""
            out.append(f"  {iid}: {i['status']}{extra}")
        out.append("settable: " + ", ".join(r.get("settable") or {}))
        return "\n".join(out)

    return fmt


@feature.cli("set-mode", help="switch a mode on or off (reduce-transparency, power-saver)")
def _set_mode(p):
    p.add_argument("mode")
    p.add_argument("to", choices=["on", "off"])

    def fmt(r):
        return f"{r['mode']}: {'on' if r['on'] else 'off'}"

    return fmt
