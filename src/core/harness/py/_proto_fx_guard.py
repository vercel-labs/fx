# proto-fx stale-write guard. sitecustomize installs `hook` as an audit hook
# in every Python an agent command starts, once PROTO_FX_HARNESS_TOKEN is set.
# Before a process opens an existing file for writing, truncates it, or
# renames onto it, the guard asks the agent's host whether the file changed
# since the agent last saw it, and raises StaleWriteError if it did. Reads
# are batched and reported so they count as seen. It fails open: when the
# host cannot be reached, the write goes ahead. Keep this module light: it
# imports nothing that the interpreter has not already loaded, apart from
# _socket and atexit when it first needs them.
import os
import sys


class HarnessError(Exception):
    """A request the host refused or could not complete."""

    kind = "internal"

    def __init__(self, message, kind=None):
        super().__init__(message)
        self.message = message
        if kind is not None:
            self.kind = kind


class StaleWriteError(HarnessError):
    """The file changed on disk since the agent last read it.

    Read it again (any read counts) and redo the change.
    """

    kind = "stale"


_EVENTS = frozenset(("open", "os.truncate", "os.rename"))
_WRITE_FLAGS = (
    getattr(os, "O_WRONLY", 0)
    | getattr(os, "O_RDWR", 0)
    | getattr(os, "O_APPEND", 0)
    | getattr(os, "O_CREAT", 0)
    | getattr(os, "O_TRUNC", 0)
)
_here = os.path.dirname(os.path.abspath(__file__))
_skip_prefixes = tuple(
    sorted(
        {
            p.rstrip(os.sep) + os.sep
            for p in (sys.prefix, sys.base_prefix, sys.exec_prefix, getattr(sys, "base_exec_prefix", sys.prefix), _here)
            if p
        }
        | {"/dev/", "/proc/", "/sys/", "/System/", "/usr/lib/", "/usr/share/", "/Library/Frameworks/"}
    )
)
_skip_parts = (os.sep + "site-packages" + os.sep, os.sep + "__pycache__" + os.sep, os.sep + ".git" + os.sep)
_skip_suffixes = (".pyc", ".so", ".dylib", ".pyd")
_pending = []
_busy = False
_registered = False


def _normal(path):
    if isinstance(path, bytes):
        try:
            path = os.fsdecode(path)
        except (TypeError, ValueError):
            return None
    elif not isinstance(path, str):
        return None
    if not path:
        return None
    ap = os.path.abspath(path)
    if ap.startswith(_skip_prefixes) or ap.endswith(_skip_suffixes):
        return None
    for part in _skip_parts:
        if part in ap:
            return None
    return ap


def _json(value):
    out = ['"']
    for ch in value:
        code = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif code < 0x20 or 0xD800 <= code <= 0xDFFF:
            out.append("\\u%04x" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _seen_json(entries):
    return "[" + ",".join('{"path":%s,"mtime_ns":%d,"size":%d}' % (_json(p), m, s) for p, m, s in entries) + "]"


def _send(op, args_json, want_reply):
    """One request; returns the reply line, or None if the host is unreachable."""
    path = os.environ.get("PROTO_FX_HARNESS_SOCKET")
    token = os.environ.get("PROTO_FX_HARNESS_TOKEN")
    if not path or not token:
        return None
    import _socket

    line = '{"v":1,"token":%s,"id":0,"op":%s,"args":%s}\n' % (_json(token), _json(op), args_json)
    sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    try:
        sock.settimeout(5.0 if want_reply else 0.5)
        sock.connect(path)
        sock.sendall(line.encode("utf-8", "surrogatepass"))
        if not want_reply:
            return None
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if chunk.endswith(b"\n"):
                break
        return b"".join(chunks).decode("utf-8", "replace")
    except OSError:
        return None
    finally:
        sock.close()


def flush():
    """Reports the reads this process made since the last report."""
    global _busy
    if not _pending:
        return
    batch = _pending[:]
    del _pending[:]
    previous = _busy
    _busy = True
    try:
        _send("fs.seen", '{"seen":%s}' % _seen_json(batch), False)
    finally:
        _busy = previous


def _note_read(ap):
    global _registered
    try:
        st = os.stat(ap)
    except OSError:
        return
    if (st.st_mode & 0o170000) != 0o100000:
        return
    _pending.append((ap, st.st_mtime_ns, st.st_size))
    if not _registered:
        _registered = True
        import atexit

        atexit.register(flush)
    if len(_pending) >= 256:
        flush()


def _check_write(ap):
    try:
        st = os.stat(ap)
    except OSError:
        return
    if (st.st_mode & 0o170000) != 0o100000:
        return
    batch = _pending[:]
    del _pending[:]
    reply = _send("fs.check", '{"path":%s,"seen":%s}' % (_json(ap), _seen_json(batch)), True)
    if not reply or '"ok":true' in reply:
        return
    import json

    try:
        error = json.loads(reply).get("error") or {}
    except ValueError:
        return
    if error.get("kind") == "stale":
        raise StaleWriteError(error.get("message") or "%s changed since the agent last read it" % ap)


def hook(event, args):
    global _busy
    if event not in _EVENTS or _busy:
        return
    _busy = True
    try:
        if event == "open":
            ap = _normal(args[0])
            if ap is None:
                return
            mode = args[1] if len(args) > 1 else None
            flags = args[2] if len(args) > 2 else 0
            writing = (isinstance(mode, str) and ("w" in mode or "a" in mode or "x" in mode or "+" in mode)) or (
                isinstance(flags, int) and flags & _WRITE_FLAGS
            )
            if writing:
                _check_write(ap)
            else:
                _note_read(ap)
        elif event == "os.truncate":
            ap = _normal(args[0])
            if ap is not None:
                _check_write(ap)
        else:
            ap = _normal(args[1]) if len(args) > 1 else None
            if ap is not None:
                _check_write(ap)
    except StaleWriteError:
        raise
    except Exception:
        pass
    finally:
        _busy = False
