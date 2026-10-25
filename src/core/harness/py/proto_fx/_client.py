"""The proto_fx wire client: one request per Unix socket connection.

A request is one JSON line: {"v": 1, "token", "id", "op", "args"}. The host
answers with zero or more event lines {"id", "event", "data"} and then one
final line, {"id", "ok": true, "value"} or {"id", "ok": false, "error":
{"kind", "message"}}.
"""

from __future__ import annotations

import itertools
import json
import os
import socket
import sys
from typing import Any, Callable

PROTOCOL_VERSION = 1
_ids = itertools.count(1)


from _proto_fx_guard import HarnessError, StaleWriteError  # noqa: E402,F401  (one class for the guard and the library)


class Unavailable(HarnessError):
    """No proto-fx host serves this process, or the host lacks this capability."""

    kind = "unavailable"


class PermissionDenied(HarnessError):
    """The person, a rule, or automatic review denied the action."""

    kind = "permission_denied"


class Refused(HarnessError):
    """The node may not do this: the tool is not offered, a limit was reached, or the arguments were invalid."""

    kind = "refused"


class ToolFailed(HarnessError):
    """The tool ran and reported a failure. `output` is what it returned."""

    kind = "tool_failed"

    def __init__(self, message: str, kind: str | None = None, output: str = ""):
        super().__init__(message, kind)
        self.output = output or message


class KernelError(HarnessError):
    """A kernel cell raised or was interrupted. `output` holds what it printed."""

    kind = "kernel_failed"

    def __init__(self, message: str, kind: str | None = None, output: str = ""):
        super().__init__(message, kind)
        self.output = output or message


class Cancelled(HarnessError):
    kind = "cancelled"


class AnchorError(HarnessError):
    """``fs.replace`` found the old text another number of times than ``count``; nothing was written."""

    kind = "anchor_mismatch"


_KINDS = {
    cls.kind: cls
    for cls in (Unavailable, PermissionDenied, Refused, ToolFailed, KernelError, Cancelled, StaleWriteError, AnchorError)
}


_ENDED = (
    "Harness access lasts only while the shell call that started this command runs; "
    "a command left running in the background after its call returned keeps running without it. "
    "Run Python that needs proto_fx in a command that finishes within its call."
)


def available() -> bool:
    """Whether this process can reach a proto-fx host: a proto-fx agent command started it, on Python 3.10 or newer."""
    if sys.version_info < (3, 10):
        return False
    return bool(os.environ.get("PROTO_FX_HARNESS_SOCKET") and os.environ.get("PROTO_FX_HARNESS_TOKEN"))


def _endpoint() -> tuple[str, str]:
    path = os.environ.get("PROTO_FX_HARNESS_SOCKET")
    token = os.environ.get("PROTO_FX_HARNESS_TOKEN")
    if not path or not token:
        raise Unavailable(
            "proto_fx works only inside a command the proto-fx agent runs, where its host is reachable."
        )
    return path, token


def _stream_event(event: str, data: Any) -> None:
    if event == "stdout":
        sys.stdout.write(data)
        sys.stdout.flush()
    elif event == "stderr":
        sys.stderr.write(data)
        sys.stderr.flush()


def request(op: str, args: dict[str, Any] | None = None, on_event: Callable[[str, Any], None] | None = _stream_event) -> Any:
    """Sends one request and returns the host's value, or raises a HarnessError."""
    if sys.version_info < (3, 10):
        raise Unavailable("proto_fx needs Python 3.10 or newer; this is %d.%d" % sys.version_info[:2])
    path, token = _endpoint()
    try:
        import _proto_fx_guard

        _proto_fx_guard.flush()
    except Exception:
        pass
    rid = next(_ids)
    line = json.dumps({"v": PROTOCOL_VERSION, "token": token, "id": rid, "op": op, "args": args or {}}) + "\n"
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            sock.connect(path)
        except (FileNotFoundError, ConnectionRefusedError):
            raise Unavailable("the proto-fx host no longer listens for this command. " + _ENDED, "unauthorized") from None
        except OSError as err:
            raise Unavailable("the proto-fx host is not reachable: %s" % err) from None
        sock.sendall(line.encode())
        reader = sock.makefile("rb")
        for raw in reader:
            msg = json.loads(raw)
            if "event" in msg:
                if on_event is not None:
                    on_event(msg["event"], msg.get("data"))
                continue
            if msg.get("ok"):
                return msg.get("value")
            error = msg.get("error") or {}
            kind = error.get("kind", "internal")
            message = error.get("message", "the host refused the request")
            cls = Unavailable if kind == "unauthorized" else _KINDS.get(kind, HarnessError)
            if cls in (ToolFailed, KernelError):
                raise cls(message, kind, output=error.get("output", ""))
            raise cls(message, kind)
        raise Unavailable("the proto-fx host closed the connection without answering")
    finally:
        sock.close()
