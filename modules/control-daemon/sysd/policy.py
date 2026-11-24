"""Who may run what, and with which approval (my.controlDaemon.*).

Callers are matched by the peer's uid first, then its groups (as approvald
does). A request may name its ``origin`` (``dashboard``) and the origin's own
user; neither is proven, so an origin rule can only make approval stricter.
"""

from __future__ import annotations

import grp
import pwd
import re
import sys

LEVELS = ("none", "approve", "deny")  # ordered: later is stricter
ORIGIN_RE = re.compile(r"[a-z0-9._-]{1,32}")
ORIGIN_USER_RE = re.compile(r"[A-Za-z0-9._@-]{1,64}")


def stricter(a: str, b: str) -> str:
    return a if LEVELS.index(a) >= LEVELS.index(b) else b


def _ids(names, lookup, attr):
    out = set()
    for n in names:
        try:
            out.add(getattr(lookup(n), attr))
        except KeyError:
            print(f"erebor-sysd: config: {n} does not exist, ignored", file=sys.stderr, flush=True)
    return out


class Policy:
    def __init__(self, config: dict):
        self.callers = {}
        for name, c in (config.get("callers") or {}).items():
            self.callers[name] = (
                _ids(c.get("users", []), pwd.getpwnam, "pw_uid"),
                _ids(c.get("groups", []), grp.getgrnam, "gr_gid"),
            )
        self.actions = config.get("actions") or {}
        for name, a in self.actions.items():
            for level in [a.get("approval", "deny"), *(a.get("callers") or {}).values(), *(a.get("origins") or {}).values()]:
                if level not in LEVELS:
                    raise ValueError(f"action {name}: approval {level!r} is not one of {', '.join(LEVELS)}")

    def caller(self, uid: int, gids) -> str | None:
        for name in sorted(self.callers):
            if uid in self.callers[name][0]:
                return name
        for name in sorted(self.callers):
            if set(gids) & self.callers[name][1]:
                return name
        return None

    def decide(self, action: str, caller: str | None, origin: str | None = None, read_only: bool = False) -> str:
        """none, approve or deny. Unknown callers and unlisted actions are
        refused, except read-only commands, which any known caller may run
        unless the policy lists them."""
        if caller is None:
            return "deny"
        entry = self.actions.get(action)
        if entry is None:
            return "none" if read_only else "deny"
        level = (entry.get("callers") or {}).get(caller, entry.get("approval", "deny"))
        if origin is not None:
            level = stricter(level, (entry.get("origins") or {}).get(origin, "none"))
        return level

    def approval_options(self, action: str) -> dict:
        entry = self.actions.get(action) or {}
        out = {"risk": entry.get("risk", "high")}
        if entry.get("methods"):
            out["methods"] = entry["methods"]
        return out
