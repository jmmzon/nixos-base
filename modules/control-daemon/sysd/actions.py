"""sysd's own actions. Each is a row in ACTIONS; the daemon wraps every row
in the policy and approval check. Privileged steps go through polkit rules
granted to sysd's system user (modules/control-daemon/default.nix), never root.

Commands are run with ``Runner`` so tests can replace it.
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from .errors import Refused as Error

PROFILES = ("performance", "balanced", "power-saver")
POWER_PROFILES = (
    "org.freedesktop.UPower.PowerProfiles",
    "/org/freedesktop/UPower/PowerProfiles",
    "org.freedesktop.UPower.PowerProfiles",
)
LOGIN1 = ("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager")


class Runner:
    async def __call__(self, *argv: str, timeout: float = 15) -> str:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout)
        except (asyncio.TimeoutError, TimeoutError):
            proc.kill()
            await proc.wait()
            raise Error(f"{argv[0]} timed out", code="failed")
        if proc.returncode != 0:
            raise Error(
                f"{argv[0]} failed: {err.decode(errors='replace').strip()[-300:]}",
                code="failed",
            )
        return out.decode()


@dataclass
class Action:
    run: Callable[["Context", dict], Awaitable[dict]]
    summary: Callable[[dict], str]
    read_only: bool = False


@dataclass
class Context:
    run: Runner
    config: dict
    emit: Callable[[dict], None]


def busctl(*args: str) -> tuple[str, ...]:
    return ("busctl", "--system", "--allow-interactive-authorization=no", *args)


async def get_power_profile(ctx: Context, req: dict) -> dict:
    out = await ctx.run(*busctl("get-property", "--json=short", *POWER_PROFILES, "ActiveProfile"))
    return {"profile": json.loads(out)["data"]}


async def set_power_profile(ctx: Context, req: dict) -> dict:
    profile = req.get("profile")
    await ctx.run(*busctl("set-property", *POWER_PROFILES, "ActiveProfile", "s", profile))
    ctx.emit({"event": "power-profile-changed", "profile": profile})
    return {"profile": profile}


def check_profile(req: dict) -> None:
    if req.get("profile") not in PROFILES:
        raise Error(f"profile must be one of {', '.join(PROFILES)}", code="bad-request", field="profile")


async def login1(method: str, ctx: Context) -> dict:
    # login1 applies polkit and respects inhibitors (no ignore-inhibit grant).
    await ctx.run(*busctl("call", *LOGIN1, method, "b", "false"))
    return {}


async def reboot_windows(ctx: Context, req: dict) -> dict:
    unit = ctx.config.get("rebootWindowsUnit")
    if not unit:
        raise Error("no Windows reboot on this machine", code="unavailable")
    await ctx.run("systemctl", "--system", "--no-ask-password", "start", unit, timeout=65)
    return {}


ACTIONS: dict[str, Action] = {
    "get-power-profile": Action(get_power_profile, lambda r: "Read the power profile", read_only=True),
    "set-power-profile": Action(set_power_profile, lambda r: f"Switch the power profile to {r.get('profile')}"),
    "sleep": Action(lambda ctx, r: login1("Suspend", ctx), lambda r: "Suspend the computer"),
    "power-off": Action(lambda ctx, r: login1("PowerOff", ctx), lambda r: "Power off the computer"),
    "reboot-windows": Action(reboot_windows, lambda r: "Reboot into Windows"),
}

# Arguments checked before the policy, so a bad request never asks for approval.
VALIDATE: dict[str, Callable[[dict], None]] = {
    "set-power-profile": check_profile,
}


def desktop_read_only(command: str) -> bool:
    """Forwarded desktop commands that only read: get-*, list-*, status."""
    return command.startswith(("get-", "list-")) or command == "status"
