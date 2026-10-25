"""Safe file edits through the agent's own file tools: ``harness.fs``.

The host performs every edit with the agent's ``edit_file`` or
``write_file``, so it asks for the same permission, shows the same diff, and
can be undone like the agent's own edits. Paths are relative to this
process's working directory.

    import proto_fx as harness

    text = harness.fs.read("app.py")                     # str, with .hash
    harness.fs.replace("app.py", "old()", "new()")      # exactly one match, or AnchorError
    harness.fs.replace("app.py", "x", "y", count=3)     # exactly three
    harness.fs.write("app.py", text.upper(), expect=text.hash)  # StaleWriteError if it changed

A plain ``open(path, "w")`` of a file the agent read, in a command's Python,
raises StaleWriteError when the file changed on disk since then.
"""

from __future__ import annotations

import hashlib
import os

from ._client import request

__all__ = ["FileText", "read", "replace", "write", "digest"]


class FileText(str):
    """A file's text; ``.hash`` is its SHA-256, for ``write(..., expect=)``, and ``.path`` its absolute path."""

    hash: str
    path: str

    def __new__(cls, text: str, hash: str, path: str) -> "FileText":
        value = super().__new__(cls, text)
        value.hash = hash
        value.path = path
        return value


def _absolute(path: str | os.PathLike) -> str:
    return os.path.abspath(os.fspath(path))


def read(path: str | os.PathLike) -> FileText:
    """Reads a UTF-8 text file and records that the agent has seen it."""
    value = request("fs.read", {"path": _absolute(path)})
    return FileText(value["text"], value["hash"], value["path"])


def replace(path: str | os.PathLike, old: str, new: str, count: int = 1) -> int:
    """Replaces ``old`` with ``new`` when it occurs exactly ``count`` times.

    Raises AnchorError, writing nothing, when the file holds another number
    of occurrences. Returns ``count``.
    """
    value = request("fs.replace", {"path": _absolute(path), "old": old, "new": new, "count": count})
    return value["replaced"]


def write(path: str | os.PathLike, text: str, *, expect: str | None = None) -> str:
    """Writes ``text`` as the whole file and returns its new hash.

    With ``expect`` (a ``FileText.hash``), it writes only if the file still
    has that content. Without it, it refuses a file that changed since the
    agent last saw it. Either refusal raises StaleWriteError.
    """
    args = {"path": _absolute(path), "text": text}
    if expect is not None:
        args["expect"] = expect
    return request("fs.write", args)["hash"]


def digest(text: str | bytes) -> str:
    """The hash ``read`` and ``write`` use: SHA-256 of the UTF-8 bytes, in hex."""
    data = text.encode("utf-8") if isinstance(text, str) else text
    return hashlib.sha256(data).hexdigest()
