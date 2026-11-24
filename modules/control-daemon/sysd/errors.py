"""A refusal with a message for the client."""


class Refused(Exception):
    """Becomes the reply ``{"ok": false, "error": error, "code": code, **extra}``."""

    def __init__(self, error: str, code: str = "failed", **extra):
        super().__init__(error)
        self.code = code
        self.reply = {"ok": False, "error": error, "code": code, **extra}
