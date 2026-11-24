"""A small async client for approvald's request protocol v1
(docs/approval-protocol.md). Fail closed: anything but ``"result":
"approved"`` is a refusal."""

from __future__ import annotations

import asyncio
import json
from typing import AsyncIterator

MAX_LINE = 4096


def _clip(text: str, n: int) -> str:
    text = "".join(" " if ord(ch) < 32 else ch for ch in str(text))
    return text if len(text) <= n else text[: n - 1] + "…"


async def ask(
    socket_path: str,
    *,
    action: str,
    summary: str,
    details: dict | None = None,
    methods: list[str] | None = None,
    risk: str = "high",
    timeout: int = 60,
) -> AsyncIterator[dict]:
    """Yield approvald's ``pending`` and ``progress`` lines, then one final
    line: ``{"result": ...}`` or ``{"error": ...}``. Closing (cancelling)
    the generator hangs up, which cancels the request."""
    req = {
        "v": 1,
        "op": "request",
        "action": action,
        "summary": _clip(summary, 200),
        "risk": risk,
        "timeout": timeout,
    }
    if details:
        req["details"] = {str(k)[:32]: _clip(v, 100) for k, v in list(details.items())[:8] if v is not None}
    if methods:
        req["methods"] = list(methods)
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(socket_path, limit=MAX_LINE), 5)
    except (OSError, asyncio.TimeoutError, TimeoutError) as e:
        yield {"result": "failed", "reason": f"approvald unreachable: {e}"}
        return
    try:
        writer.write((json.dumps(req) + "\n").encode())
        await writer.drain()
        # A little longer than the request's own timeout: approvald answers it.
        deadline = asyncio.get_running_loop().time() + timeout + 15
        while True:
            left = deadline - asyncio.get_running_loop().time()
            try:
                raw = await asyncio.wait_for(reader.readline(), max(left, 0.1))
            except (asyncio.TimeoutError, TimeoutError):
                yield {"result": "timeout"}
                return
            if not raw:
                yield {"result": "failed", "reason": "approvald hung up"}
                return
            try:
                line = json.loads(raw)
            except json.JSONDecodeError:
                yield {"result": "failed", "reason": "bad reply"}
                return
            if not isinstance(line, dict):
                yield {"result": "failed", "reason": "bad reply"}
                return
            yield line
            if "result" in line or "error" in line:
                return
    except (OSError, ValueError) as e:
        yield {"result": "failed", "reason": str(e)}
    finally:
        writer.close()


def approved(final: dict) -> bool:
    return final.get("result") == "approved"
