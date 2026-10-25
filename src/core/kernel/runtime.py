# The MIT License (MIT)
#
# Copyright (c) 2025-2026 Prime Intellect Ltd.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# ---
#
# This software is a port of the Prime Agent TypeScript product, originally
# Copyright (c) 2025 Mario Zechner, used under the MIT License.
#
# Adapted for proto-fx: kernel mechanics only. Runtime tools, display and
# host-request hooks, name listing, the snapshot manifest, pruning, legacy
# snapshot restore, and Windows support are removed.

"""Minimal CPython REPL runtime speaking newline-delimited JSON over stdio.

Entry point: ``python -u runtime.py``, or ``runtime.py --zygote`` for the fork
server that starts kernels with these imports already done (``_zygote_main``).
A dedicated JSONL channel carries execute, interrupt, snapshot, restore and
shutdown requests. Cells execute
with top-level await in one persistent ``__main__`` namespace on a single
asyncio event loop. Only macOS and Linux are supported.
"""

from __future__ import annotations

import ast
import asyncio
import codecs
import contextvars
import functools
import inspect
import io
import json
import linecache
import os
import pickle
import platform
import select
import signal
import sys
import tempfile
import threading
import time
import traceback
import types
import uuid
from collections.abc import Awaitable, Callable
from typing import Any


PROTOCOL_VERSION = 4

_SNAPSHOT_MAX_BYTES = 256 * 1024 * 1024
_SNAPSHOT_MAX_VARIABLE_BYTES = 16 * 1024 * 1024

# Every snapshot starts with this header; a file without it is not restored.
_SNAPSHOT_MAGIC = b"PROTO-FX-KERNEL-SNAPSHOT-V2\n"

# Stream writes must fit one protocol frame: the host buffers whole lines
# before its per-execution truncation, and raw fd writes already arrive as
# 64 KiB pump chunks.
_STREAM_FRAME_TEXT_CAP = 64 * 1024
# The host truncates results at a smaller per-execution maxChars, so this only
# bounds a pathological repr or exception text in transit.
_RESULT_TEXT_CAP = 1_048_576
_RESULT_TRUNCATION_MARKER = f"\n[... result truncated at {_RESULT_TEXT_CAP} characters ...]"

# Names the session bootstrap re-creates on every start; never snapshotted.
_ALWAYS_SKIP = {"asyncio", "exit", "quit", "open"}
# The path of the last successful snapshot, remembered so an EOF shutdown
# (the host process died without a graceful dispose) can flush the final
# namespace before exit. `None` until this process has committed a snapshot:
# an EOF before that must not overwrite the on-disk payload with a namespace
# the host never considered durable.
_last_snapshot_path: str | None = None

_protocol_fd: int = -1
# The host's stderr before _setup_fds captures fd 2: the only channel that can
# report a dropped protocol frame without feeding it back into the protocol.
_host_stderr_fd: int = -1
_write_lock = threading.Lock()
_loop: asyncio.AbstractEventLoop | None = None
_serve_task: asyncio.Task[Any] | None = None


# Asyncio tasks copy cell context at creation, so detached tasks retain their
# output attribution. Threads start with a fresh context.
_current_cell: contextvars.ContextVar[str | None] = contextvars.ContextVar("_current_cell", default=None)
_active: dict[str, Any] = {"task": None, "rid": None, "interrupted": False}
_cell_counter = 0
# Interrupt bookkeeping shared between the reader thread and the loop thread.
_interrupt_lock = threading.Lock()
_inflight: set[str] = set()
_pending_interrupts: dict[str, Any] = {"ids": set(), "any": False}
_sigint_target: str | None = None
_finishing_rid: str | None = None
_handoff_interrupted = False


def _send(event: dict[str, Any]) -> None:
    """Write one protocol frame; the locked single write keeps frames atomic."""
    data = (json.dumps(event, separators=(",", ":")) + "\n").encode()
    with _write_lock:
        view = memoryview(data)
        try:
            while view:
                view = view[os.write(_protocol_fd, view) :]
        except OSError as err:
            try:
                os.write(_host_stderr_fd, f"proto_fx_kernel: dropped protocol frame: {err}\n".encode())
            except OSError:
                pass


class _Pump:
    """Reads one captured-output pipe and ships its bytes as stream events."""

    def __init__(self, read_fd: int, write_fd: int, stream: str) -> None:
        self._read_fd = read_fd
        # Private write end: a cell closing/reclaiming fd 1/2 cannot hijack drain tokens.
        self._token_fd = os.dup(write_fd)
        self._stream = stream
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._lock = threading.Lock()
        self._watch: tuple[bytes, threading.Event] | None = None
        self._buf = b""
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def drain(self) -> None:
        """Block until every byte written to the fd so far has been shipped."""
        token = b"\xff<drain:" + uuid.uuid4().hex.encode() + b">\xff"
        seen = threading.Event()
        with self._lock:
            self._watch = (token, seen)
        try:
            os.write(self._token_fd, token)
            # Backstop only: a dead pump (read end closed under it) can never set seen.
            while not seen.wait(0.1):
                if not self._thread.is_alive():
                    return
        except OSError:
            return
        finally:
            with self._lock:
                self._watch = None

    def _run(self) -> None:
        while True:
            try:
                chunk = os.read(self._read_fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            self._feed(chunk)

    def _feed(self, chunk: bytes) -> None:
        data = self._buf + chunk
        self._buf = b""
        with self._lock:
            watch = self._watch
        if watch is None:
            self._emit(data)
            return
        token, seen = watch
        while True:
            i = data.find(token)
            if i == -1:
                break
            self._emit(data[:i])
            self._finish_decode()
            seen.set()
            data = data[i + len(token) :]
        # Hold back a tail that could be the start of a token split across reads.
        hold = 0
        for k in range(min(len(data), len(token) - 1), 0, -1):
            if data.endswith(token[:k]):
                hold = k
                break
        if hold:
            self._buf = data[len(data) - hold :]
            data = data[: len(data) - hold]
        self._emit(data)

    def _emit(self, data: bytes) -> None:
        if not data:
            return
        text = self._decoder.decode(data)
        if text:
            # Raw fd bytes have no provable owner (os.write, C extensions,
            # subprocesses, threads from earlier cells): never credit a cell.
            _send({"event": self._stream, "id": None, "text": text})

    def _finish_decode(self) -> None:
        text = self._decoder.decode(b"", final=True)
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        if text:
            _send({"event": self._stream, "id": None, "text": text})


class _TaggedBuffer(io.RawIOBase):
    """Binary proxy for _TaggedWriter.buffer: bytes go to the raw fd channel.

    Byte ownership cannot be proven at this layer, so buffer writes ride the
    captured pipe and surface as id:null stream events (drained before done
    like any other raw fd write).
    """

    def __init__(self, fallback_fd: int) -> None:
        self._fallback_fd = fallback_fd

    def write(self, data: Any) -> int:
        # memoryview (unlike bytes()) rejects int, matching a real buffer's TypeError.
        view = memoryview(data).cast("B")
        total = len(view)
        # Pipe writes can be short for payloads above the pipe capacity.
        while view:
            view = view[os.write(self._fallback_fd, view) :]
        return total

    def flush(self) -> None:
        pass

    def fileno(self) -> int:
        return self._fallback_fd

    def writable(self) -> bool:
        return True


class _TaggedWriter(io.TextIOBase):
    """sys.stdout/sys.stderr replacement tagging writes with the writer's cell id.

    Python-level writes carry write-time provenance from the _current_cell
    contextvar (asyncio tasks inherit the spawning cell's id; user threads see
    None) and ship straight to the protocol, bypassing the fd pipe. fileno()
    and .buffer expose the captured pipe so subprocesses, C-level writers, and
    sys.stdout.buffer.write() keep working through the raw channel
    (null-attributed).
    """

    def __init__(self, stream: str, fallback_fd: int) -> None:
        self._stream = stream
        self._fallback_fd = fallback_fd
        # Keeps one write()'s frames contiguous under concurrent writers.
        self._frame_lock = threading.Lock()
        self._buffer = _TaggedBuffer(fallback_fd)

    def write(self, text: str) -> int:
        if not isinstance(text, str):
            raise TypeError(f"write() argument must be str, not {type(text).__name__}")
        if text:
            cell_id = _current_cell.get()
            with self._frame_lock:
                for start in range(0, len(text), _STREAM_FRAME_TEXT_CAP):
                    _send(
                        {
                            "event": self._stream,
                            "id": cell_id,
                            "text": text[start : start + _STREAM_FRAME_TEXT_CAP],
                        }
                    )
        return len(text)

    def flush(self) -> None:
        pass

    def fileno(self) -> int:
        return self._fallback_fd

    def writable(self) -> bool:
        return True

    @property
    def buffer(self) -> _TaggedBuffer:
        return self._buffer

    @property
    def encoding(self) -> str:
        return "utf-8"

    @property
    def errors(self) -> str:
        return "replace"


def _consume_task_exception(task: asyncio.Task[Any]) -> None:
    """Retrieve a killed task's exception so no never-retrieved noise is logged."""
    if not task.cancelled():
        task.exception()


def _sigint_handler(signum: int, frame: types.FrameType | None) -> None:
    global _handoff_interrupted
    task = _active["task"]
    # No lock (the main thread may hold it): the rid equality revalidates the
    # target so a SIGINT delayed past its request's finish cannot hit a later cell.
    if task is None or task.done() or _active["rid"] != _sigint_target:
        if _sigint_target is not None and _sigint_target == _active["rid"]:
            # Handoff: the task is done but _run_guarded's finally has not run
            # yet, so the main thread may be inside loop internals where raising
            # would kill the serve loop. Record it; the finishing phase consumes it.
            _handoff_interrupted = True
            return
        # Post-run repr/drain is synchronous main-thread work: raise into it.
        # The equality revalidation drops a SIGINT delayed past the done send.
        if _sigint_target is not None and _sigint_target == _finishing_rid:
            raise KeyboardInterrupt
        return
    _active["interrupted"] = True
    # Handler runs in the main (loop) thread: current_task is whose step the signal interrupted.
    running = asyncio.current_task(_loop) if _loop is not None else None
    if running is task:
        # The active request's own step (sync bytecode or an EINTR-woken syscall): raise into it.
        raise KeyboardInterrupt
    # Loop idle in select() or another task mid-step: cancel the active task (same thread, safe).
    task.cancel()
    if running is not None and running is not _serve_task:
        # A background task blocked in sync code occupies the only thread and would keep the
        # cancel from ever running: raise into it to unwind its step; it dies with the KI.
        running.add_done_callback(_consume_task_exception)
        raise KeyboardInterrupt


def _request_interrupt(target: str | None) -> None:
    """Deliver an interrupt now, or park it for the request it targets.

    Runs on the reader thread. Without a target id the interrupt applies to
    the running request, else to the next queued one; with a target id it
    applies to that request only. A request finishing its post-run repr/drain
    is still interrupted (never parked: parking would hit the NEXT request).
    Interrupts for finished or unknown requests are dropped.
    """
    global _sigint_target
    with _interrupt_lock:
        rid = _active["rid"]
        if rid is not None and (target is None or target == rid):
            # Active, or in the done-task handoff before _run_guarded's finally:
            # either way the rid still owns the interrupt (parking here would
            # leak it onto the next request); the handler decides delivery.
            _sigint_target = rid
        elif _finishing_rid is not None and (target is None or target == _finishing_rid):
            _sigint_target = _finishing_rid
        elif target is not None:
            if target in _inflight:
                _pending_interrupts["ids"].add(target)
            return
        elif _inflight:
            _pending_interrupts["any"] = True
            return
        else:
            return
    # SIGINT must land on the main thread, where cells execute.
    signal.pthread_kill(threading.main_thread().ident, signal.SIGINT)
    if _loop is not None:
        # Wake the selector so a cancel scheduled by the handler runs promptly.
        _loop.call_soon_threadsafe(lambda: None)


def _consume_pending_interrupt(rid: str) -> bool:
    """Check-and-clear any interrupt parked for this request."""
    pending = _pending_interrupts["any"] or rid in _pending_interrupts["ids"]
    _pending_interrupts["any"] = False
    _pending_interrupts["ids"].discard(rid)
    return pending


def _consume_handoff_interrupt() -> bool:
    """Check-and-clear an interrupt that landed in the done-task handoff."""
    global _handoff_interrupted
    with _interrupt_lock:
        pending = _handoff_interrupted
        _handoff_interrupted = False
        return pending


def _finish_locked(rid: str) -> None:
    """Drop a finished request; a parked untargeted interrupt survives while others are inflight."""
    global _finishing_rid, _handoff_interrupted, _sigint_target
    if _finishing_rid == rid:
        # An unconsumed handoff interrupt dies with its request (state requests
        # have no cancellable post-run work); it must never hit the next request.
        _finishing_rid = None
        _handoff_interrupted = False
    if _sigint_target == rid:
        # The target dies with its request: a later request reusing this id must
        # not match a stale target when a delayed/external SIGINT arrives.
        _sigint_target = None
    _inflight.discard(rid)
    _pending_interrupts["ids"].discard(rid)
    if not _inflight:
        _pending_interrupts["any"] = False


def _finish_request(rid: str) -> None:
    with _interrupt_lock:
        _finish_locked(rid)


_RUNTIME_FILE = __file__


def _cell_stack(stack: traceback.StackSummary) -> traceback.StackSummary | None:
    """Frames from the first cell frame on, minus runtime-internal frames.

    Returns None when no cell frame exists (e.g. a compile-time SyntaxError).
    """
    start = next((i for i, f in enumerate(stack) if f.filename.startswith("<cell-")), None)
    if start is None:
        return None
    return traceback.StackSummary.from_list([f for f in stack[start:] if f.filename != _RUNTIME_FILE])


def _safe_str(exc: BaseException) -> str:
    try:
        return str(exc)
    except BaseException:  # noqa: BLE001 - a broken __str__ must not kill the runtime
        return "<exception str() failed>"


def _cap_text(text: str) -> str:
    if len(text) > _RESULT_TEXT_CAP:
        return text[:_RESULT_TEXT_CAP] + _RESULT_TRUNCATION_MARKER
    return text


def _cap_traceback_lines(lines: list[str]) -> list[str]:
    """Bound the aggregate, not just each entry: an exception chain can carry
    thousands of entries, and per-entry caps alone would still let one error
    event exceed the host's protocol line limit. Keep the newest entries — the
    outermost exception carries the actionable failure — and lead with a
    truncation marker."""
    total = sum(len(line) for line in lines)
    if total <= _RESULT_TEXT_CAP:
        return lines
    kept: list[str] = []
    remaining = _RESULT_TEXT_CAP
    for line in reversed(lines):
        if len(line) > remaining:
            if not kept:
                # Never drop the newest entry: it names the raised exception.
                kept.append(line)
            break
        kept.append(line)
        remaining -= len(line)
    kept.reverse()
    kept.insert(
        0,
        f"[... traceback truncated: kept the newest {len(kept)} of {len(lines)} entries "
        f"to fit {_RESULT_TEXT_CAP} characters ...]\n",
    )
    return kept


def _error_event(cell_id: str, exc: BaseException) -> dict[str, Any]:
    # No cell frame (e.g. SyntaxError): exception-only keeps filename, source, and caret.
    te = traceback.TracebackException.from_exception(exc)
    stack = _cell_stack(te.stack)
    if stack is None:
        lines = traceback.format_exception_only(type(exc), exc)
    else:
        te.stack = stack
        lines = list(te.format())
    return {
        "event": "error",
        "id": cell_id,
        "ename": type(exc).__name__,
        "evalue": _cap_text(_safe_str(exc)),
        "traceback": _cap_traceback_lines([_cap_text(line) for line in lines]),
    }


def _interrupt_event(cell_id: str, exc: BaseException) -> dict[str, Any]:
    """Report a cancelled await-suspended cell as a KeyboardInterrupt."""
    stack = _cell_stack(traceback.extract_tb(exc.__traceback__))
    lines = []
    if stack:
        lines = ["Traceback (most recent call last):\n"]
        lines.extend(stack.format())
    lines.append("KeyboardInterrupt\n")
    return {"event": "error", "id": cell_id, "ename": "KeyboardInterrupt", "evalue": "", "traceback": lines}


def _compile_cell(code: str, filename: str) -> tuple[list[types.CodeType], bool]:
    """Compile a cell; a trailing expression compiles separately in eval mode."""
    linecache.cache[filename] = (len(code), None, code.splitlines(keepends=True), filename)
    tree = ast.parse(code, filename)
    trailing: ast.Expression | None = None
    if tree.body and isinstance(tree.body[-1], ast.Expr):
        trailing = ast.Expression(tree.body.pop().value)
    flags = ast.PyCF_ALLOW_TOP_LEVEL_AWAIT
    codes: list[types.CodeType] = []
    if tree.body:
        codes.append(compile(tree, filename, "exec", flags=flags, dont_inherit=True))
    if trailing is not None:
        codes.append(compile(trailing, filename, "eval", flags=flags, dont_inherit=True))
    return codes, trailing is not None


async def _run_codes(codes: list[types.CodeType], ns: dict[str, Any]) -> Any:
    value: Any = None
    for code_obj in codes:
        value = eval(code_obj, ns)  # noqa: S307 - executing the model's cell is the runtime's job
        if code_obj.co_flags & inspect.CO_COROUTINE:
            value = await value
    return value


async def _run_guarded(task: asyncio.Task[Any], rid: str) -> tuple[str, Any, dict[str, Any] | None]:
    """Await a request task; returns (status, value, error event or None)."""
    with _interrupt_lock:
        _active["interrupted"] = False
        _active["rid"] = rid
        _active["task"] = task
        if _consume_pending_interrupt(rid):
            # Interrupt parked before activation: cancel before the first step.
            _active["interrupted"] = True
            task.cancel()
    try:
        value = await task
        return "ok", value, None
    except asyncio.CancelledError as exc:
        if _active["interrupted"]:
            return "error", None, _interrupt_event(rid, exc)
        return "error", None, _error_event(rid, exc)
    except BaseException as exc:  # noqa: BLE001 - every cell failure becomes an error event
        return "error", None, _error_event(rid, exc)
    finally:
        with _interrupt_lock:
            global _finishing_rid
            # The rid stays inflight and interrupt-targetable through the
            # post-run repr/drain; the handler closes the window via _finish_request.
            # Set before clearing _active: the lock-free handler must always see
            # the rid in one of the two slots, never a torn in-between state.
            _finishing_rid = rid
            _active["task"] = None
            _active["rid"] = None


async def _handle_execute(req: dict[str, Any], ns: dict[str, Any]) -> None:
    global _cell_counter
    cell_id = req["id"]
    _cell_counter += 1
    filename = f"<cell-{_cell_counter}>"
    cell_token = _current_cell.set(cell_id)
    try:
        codes, has_trailing = _compile_cell(req["code"], filename)
        assert _loop is not None
        task = _loop.create_task(_run_codes(codes, ns))
        status, value, error = await _run_guarded(task, cell_id)
        result_text: str | None = None
        try:
            if _consume_handoff_interrupt() and status == "ok":
                # SIGINT landed between the task's completion and the finishing
                # phase: it targeted this request, so cancel its remaining work.
                status, error = "error", _error_event(cell_id, KeyboardInterrupt())
            if status == "ok" and has_trailing and value is not None:
                try:
                    ns["_"] = value
                    result_text = repr(value)
                except BaseException as exc:  # noqa: BLE001 - a broken __repr__ is a cell error
                    status, error = "error", _error_event(cell_id, exc)
            if result_text is not None:
                result_text = _cap_text(result_text)
            _drain_output()
        finally:
            # Close the interrupt window before the protocol sends so a
            # handler-raised KeyboardInterrupt can never tear a frame mid-_send.
            _finish_request(cell_id)
        if result_text is not None:
            _send({"event": "result", "id": cell_id, "text": result_text})
        if error is not None:
            _send(error)
        _send({"event": "done", "id": cell_id, "status": status})
    finally:
        _current_cell.reset(cell_token)


def _drain_output() -> None:
    # Per-stream, and ValueError too: a cell may close sys.stdout/sys.stderr, and
    # flushing a closed file raises ValueError, or rebind them to a flush-less
    # object (AttributeError); neither may kill the serve loop nor skip flushing
    # the other stream.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except (OSError, ValueError, AttributeError):
            pass
    _pump_out.drain()
    _pump_err.drain()


class _SnapshotSizeLimitExceeded(Exception):
    pass


class _CappedWriter:
    def __init__(self, sink: Any, limit: int) -> None:
        self._sink = sink
        self._limit = limit
        self.written = 0

    def write(self, chunk: Any) -> int:
        size = len(chunk)
        if self.written + size > self._limit:
            raise _SnapshotSizeLimitExceeded()
        self._sink.write(chunk)
        self.written += size
        return size


def _read_snapshot_records(fh: Any) -> dict[str, bytes]:
    """Framing damage is a corrupt snapshot: a restore error, never a partial namespace.
    Length fields are bounds-checked before their reads, so a corrupt header cannot force a huge
    allocation; the writer's own per-record and aggregate caps bound every blob read, so a
    sparse multi-gigabyte file cannot OOM the process either."""
    fh.seek(0, os.SEEK_END)
    size = fh.tell()
    fh.seek(len(_SNAPSHOT_MAGIC))
    records: dict[str, bytes] = {}
    total = 0
    while fh.tell() < size:
        header = fh.read(4)
        if len(header) < 4:
            raise ValueError("truncated snapshot record")
        name_len = int.from_bytes(header, "little")
        if fh.tell() + name_len + 8 > size:
            raise ValueError("truncated snapshot record")
        # The name is bounded by the same aggregate cap as the blobs: a
        # corrupt or sparse snapshot declaring a multi-gigabyte name must
        # fail the cap BEFORE the read allocates it (the same OOM class
        # the blob caps close).
        if name_len > _SNAPSHOT_MAX_BYTES:
            raise ValueError("snapshot record name exceeds the aggregate byte cap")
        name = fh.read(name_len)
        raw_len = fh.read(8)
        blob_len = int.from_bytes(raw_len, "little")
        if len(raw_len) < 8 or fh.tell() + blob_len > size:
            raise ValueError("truncated snapshot record")
        if blob_len > _SNAPSHOT_MAX_VARIABLE_BYTES:
            raise ValueError("snapshot record exceeds the per-variable byte cap")
        total += blob_len
        if total > _SNAPSHOT_MAX_BYTES:
            raise ValueError("snapshot payload exceeds the aggregate byte cap")
        blob = fh.read(blob_len)
        if len(blob) < blob_len:
            raise ValueError("truncated snapshot record")
        records[name.decode("utf-8")] = blob
    return records


def _import_dill() -> Any:
    """dill, from the interpreter or, for a project environment without it,
    from the folder the host names in PROTO_FX_KERNEL_DILL_PATH."""
    try:
        import dill
    except ImportError:
        extra = os.environ.get("PROTO_FX_KERNEL_DILL_PATH")
        if not extra:
            raise
        if extra not in sys.path:
            sys.path.append(extra)
        import dill
    return dill


def _snapshot_state(
    ns: dict[str, Any],
    path: str,
    committed: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    try:
        dill = _import_dill()
    except Exception as err:  # noqa: BLE001 - dill is provisioned by the host, not a hard dep
        return {"error": f"dill unavailable: {err}"}
    dill.settings["recurse"] = True

    saved: list[str] = []
    skipped: list[dict[str, str]] = []
    missing = object()

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    # A unique same-directory temp: a fixed '.tmp' name could collide with a
    # concurrent snapshot, and the same directory keeps the final rename atomic.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=os.path.basename(path) + ".", suffix=".tmp")
    result: dict[str, Any] | None = None
    handler_installed = False
    previous = None
    try:
        try:
            try:
                fh = os.fdopen(fd, "wb")
            except BaseException:
                os.close(fd)  # fdopen never took ownership: the raw fd would leak
                raise
            with fh:
                # Single pass: each variable is dill-serialized exactly once, streamed
                # into the staged temp. The record header is charged against the aggregate
                # cap up front, so a completed record can never overflow it.
                total = fh.write(_SNAPSHOT_MAGIC)
                for name in list(ns.keys()):
                    if name.startswith("_") or name in _ALWAYS_SKIP:
                        continue
                    value = ns.get(name, missing)
                    if value is missing:
                        # A background thread deleted the name after the key listing.
                        skipped.append({"name": name, "reason": "deleted during snapshot"})
                        continue
                    try:
                        encoded = name.encode("utf-8")
                    except UnicodeEncodeError as err:
                        # A lone-surrogate name (e.g. "\ud800") cannot ride the
                        # record header; skip it like any other unserializable
                        # name instead of failing the whole snapshot.
                        skipped.append({"name": name, "reason": f"{type(err).__name__}: {_safe_str(err)[:200]}"})
                        continue
                    # Record header: 4-byte name length + 8-byte blob length, plus the name itself.
                    budget = _SNAPSHOT_MAX_BYTES - total - 12 - len(encoded)
                    buffer = io.BytesIO()
                    try:
                        dill.dump(value, _CappedWriter(buffer, min(_SNAPSHOT_MAX_VARIABLE_BYTES, budget)))
                        blob = buffer.getvalue()
                    except _SnapshotSizeLimitExceeded:
                        cap = "aggregate" if budget < _SNAPSHOT_MAX_VARIABLE_BYTES else "per-variable"
                        skipped.append({"name": name, "reason": f"exceeds {cap} snapshot size cap"})
                        continue
                    except Exception as err:  # noqa: BLE001 - one unpicklable name must not abort the snapshot
                        skipped.append({"name": name, "reason": f"{type(err).__name__}: {_safe_str(err)[:200]}"})
                        continue
                    fh.write(len(encoded).to_bytes(4, "little"))
                    fh.write(encoded)
                    fh.write(len(blob).to_bytes(8, "little"))
                    fh.write(blob)
                    total += 12 + len(encoded) + len(blob)
                    saved.append(name)
                saved.sort()
        except BaseException as err:  # noqa: BLE001 - Exception -> error dict, rest propagates
            if not isinstance(err, Exception):
                raise  # e.g. KeyboardInterrupt: clean up (outer finally), then propagate
            return {"error": f"write failed: {err}"}

        # A SIGINT-raised KeyboardInterrupt between the commit and publishing the
        # result would misreport a committed snapshot as failed: park SIGINT until
        # the end. The parked interrupt is consumed, not re-raised: it targeted this
        # now-complete request.
        previous = signal.signal(signal.SIGINT, lambda signum, frame: None)
        handler_installed = True
        try:
            os.replace(tmp, path)
        except OSError as err:
            return {"error": f"write failed: {err}"}
        result = {"saved": saved, "skipped": skipped, "bytes": total}
        # Publish while still parked: a later KeyboardInterrupt into this task finds the committed result (see _handle_state).
        if committed is not None:
            committed.append(result)
    finally:
        # The nested finally makes the handler restore the guaranteed last action
        # even when removing the uncommitted temp fails.
        try:
            if result is None:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        finally:
            if handler_installed:
                signal.signal(signal.SIGINT, previous)
    return result


def _revive_with_live_globals(
    value: Any,
    ns: dict[str, Any],
    backfill: list[tuple[str, Any]] | None = None,
    memo: dict[int, Any] | None = None,
) -> Any:
    """Rebind restored __main__ callables onto the live namespace, collecting
    names their saved globals carry but ns lacks as backfill for the caller
    to apply at commit (live ns values always win)."""
    import functools

    if memo is None:
        memo = {}
    if id(value) in memo:
        return memo[id(value)]

    def revive(dep: Any) -> Any:
        return _revive_with_live_globals(dep, ns, backfill, memo)

    if isinstance(value, functools.partial):
        # No placeholder memo entry: a partial is immutable, so it could never be patched;
        # every cycle passes through a function, which is memoized before recursing.
        rebuilt = revive(value.func)
        changed = rebuilt is not value.func
        args = []
        keywords = {}
        for arg in value.args:
            revived = revive(arg)
            changed = changed or revived is not arg
            args.append(revived)
        for key, arg in value.keywords.items():
            revived = revive(arg)
            changed = changed or revived is not arg
            keywords[key] = revived
        if not changed:
            # An unchanged partial still carries its original attributes:
            # __main__ callables there would keep frozen snapshot globals, so
            # revive them in place. Memoize first — an attribute can cycle
            # back to this partial.
            memo[id(value)] = value
            value.__dict__.update({key: revive(attr) for key, attr in value.__dict__.items()})
            return value
        rebuilt_partial = functools.partial(rebuilt, *args, **keywords)
        # Memoize before the attribute walk: attributes can hold the partial
        # itself (a self-cycle or mutual partials), and unlike the function
        # branch below there is no outer memo entry yet. Once set, the
        # not-changed fast path also returns the rebuilt one.
        memo[id(value)] = rebuilt_partial
        rebuilt_partial.__dict__.update({key: revive(attr) for key, attr in value.__dict__.items()})
        return rebuilt_partial
    atoms = (int, float, str, bytes, bool, type(None))
    # dill loads __main__.__dict__ by reference, so a saved globals() IS the live ns: never walk it.
    if value is ns:
        return value
    if isinstance(value, (list, dict, set)):
        # Memoized before recursing and revived in place: cycles and identity come for free.
        # Skipping atoms keeps the walk over million-element containers near dill.loads cost.
        memo[id(value)] = value
        if isinstance(value, set):
            # Iterate a snapshot: discard+add during iteration would skip members.
            for item in list(value):
                revived = item if type(item) in atoms else revive(item)
                if revived is not item:
                    value.discard(item)
                    value.add(revived)
        elif isinstance(value, list):
            for key, item in enumerate(value):
                revived = item if type(item) in atoms else revive(item)
                if revived is not item:
                    value[key] = revived
        else:
            # Keys can be __main__ callables too: revive them, or lookups
            # through the dict keep observing frozen globals. The snapshot
            # tolerates the delete+reinsert a rebuilt key needs.
            for key, item in list(value.items()):
                revived = item if type(item) in atoms else revive(item)
                revived_key = key if type(key) in atoms else revive(key)
                if revived_key is not key:
                    del value[key]
                    value[revived_key] = revived
                elif revived is not item:
                    value[key] = revived
        return value
    if type(value) is tuple:
        items = tuple(item if type(item) in atoms else revive(item) for item in value)
        if all(new is old for new, old in zip(items, value)):
            items = value
        return memo.setdefault(id(value), items)
    if type(value) is frozenset:
        # Immutable: rebuild when any member revived (identity equality makes
        # the comparison exact — a rebuilt function never equals the original).
        items = frozenset(item if type(item) in atoms else revive(item) for item in value)
        if items == value:
            items = value
        return memo.setdefault(id(value), items)
    if not isinstance(value, types.FunctionType) or value.__module__ != "__main__":
        return value
    # Defaults and cell contents are revived only after the rebound function is memoized, so a
    # function reachable from its own defaults or closure resolves to it. Cells are revived in
    # place: holders this walk never sees (attribute-held siblings) must keep sharing them.
    rebound = types.FunctionType(value.__code__, ns, value.__name__, None, value.__closure__)
    memo[id(value)] = rebound
    if backfill is not None:
        for name, dep in value.__globals__.items():
            # Snapshots never save _-prefixed or skip-listed names; backfill must not smuggle them past that policy.
            if name in ns or name.startswith("_") or name in _ALWAYS_SKIP:
                continue
            backfill.append((name, revive(dep)))
    if value.__defaults__:
        rebound.__defaults__ = tuple(revive(dep) for dep in value.__defaults__)
    if value.__kwdefaults__:
        rebound.__kwdefaults__ = {key: revive(dep) for key, dep in value.__kwdefaults__.items()}
    for cell in value.__closure__ or ():
        if id(cell) in memo:
            continue
        memo[id(cell)] = cell
        try:
            contents = cell.cell_contents
        except ValueError:
            continue
        cell.cell_contents = revive(contents)
    rebound.__doc__ = value.__doc__
    rebound.__dict__.update({key: revive(attr) for key, attr in value.__dict__.items()})
    rebound.__annotations__ = value.__annotations__
    rebound.__qualname__ = value.__qualname__
    rebound.__module__ = value.__module__
    # PEP 695 generics carry their type params here on 3.12+; plain 3.11
    # functions lack the attribute entirely, hence the getattr guard.
    params = getattr(value, "__type_params__", None)
    if params is not None:
        rebound.__type_params__ = params
    return rebound


def _snapshot_unpickler(dill: Any) -> type:
    """Unpickler that refuses to reopen a pickled raw fd number in this kernel.

    dill serializes a pipe/socket-backed file as its fd NUMBER; restoring a
    saved closed one reopens that number here and closes it again, killing
    whatever owns the fd now (e.g. the event loop's self-pipe). The refusal
    fails just that record; every other name still restores.
    """
    create_filehandle = dill._dill._create_filehandle

    def refuse_raw_fd(name: Any, *args: Any) -> Any:
        if isinstance(name, int):
            raise pickle.UnpicklingError(
                f"refusing to reopen raw file descriptor {name} from a snapshot"
            )
        return create_filehandle(name, *args)

    class GuardedUnpickler(dill.Unpickler):
        def find_class(self, module: str, name: str) -> Any:
            target = super().find_class(module, name)
            return refuse_raw_fd if target is create_filehandle else target

    return GuardedUnpickler


def _restore_state(
    ns: dict[str, Any],
    path: str,
    committed: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    if not os.path.exists(path):
        return {"restored": [], "failed": [], "reason": "snapshot not found"}
    try:
        dill = _import_dill()
    except Exception as err:  # noqa: BLE001
        return {"error": f"dill unavailable: {err}"}
    unpickler = _snapshot_unpickler(dill)
    try:
        with open(path, "rb") as fh:
            if fh.read(len(_SNAPSHOT_MAGIC)) != _SNAPSHOT_MAGIC:
                return {"error": "load failed: unsupported snapshot format"}
            payload = _read_snapshot_records(fh)
    except Exception as err:  # noqa: BLE001 - a corrupt snapshot yields an empty restore
        return {"error": f"load failed: {_safe_str(err)}"}

    staged: dict[str, Any] = {}
    failed: list[dict[str, str]] = []
    for name, blob in payload.items():
        try:
            staged[name] = unpickler(io.BytesIO(blob)).load()
        except Exception as err:  # noqa: BLE001 - revive every other name regardless
            failed.append({"name": name, "reason": f"{type(err).__name__}: {_safe_str(err)[:200]}"})
    # Revive every staged name before parking: a failure must never abort the
    # apply halfway and leave the namespace half old, half new.
    prepared: dict[str, Any] = {}
    backfill: list[tuple[str, Any]] = []
    revive_failed: list[dict[str, str]] = []
    for name, value in staged.items():
        # The backfill entries a name's revival produced merge only if THAT
        # name revives: a failed revival adds nothing (its saved globals
        # would partially restore state the failure report says failed).
        name_backfill: list[tuple[str, Any]] = []
        try:
            prepared[name] = _revive_with_live_globals(value, ns, name_backfill)
        except Exception as err:  # noqa: BLE001 - one broken revival must not abort the restore
            revive_failed.append({"name": name, "reason": f"{type(err).__name__}: {_safe_str(err)[:200]}"})
            continue
        backfill.extend(name_backfill)
    result = {"restored": sorted(prepared), "failed": failed + revive_failed}
    # Park SIGINT across the whole apply so it is all-or-nothing; the parked interrupt is consumed by the commit (as in snapshot).
    previous = signal.signal(signal.SIGINT, lambda signum, frame: None)
    try:
        for name, value in prepared.items():
            ns[name] = value
        for name, value in backfill:
            # prepared names already sit in ns here: a restored value always beats backfill.
            if name not in ns:
                ns[name] = value
        # Publish while still parked: a later KeyboardInterrupt into this task finds the committed result (see _handle_state).
        if committed is not None:
            committed.append(result)
    finally:
        signal.signal(signal.SIGINT, previous)
    return result


async def _handle_state(req: dict[str, Any], ns: dict[str, Any]) -> None:
    """Run snapshot/restore as an interruptible task and reply in the done event."""
    rid = req["id"]
    committed: list[dict[str, Any]] = []

    async def run() -> dict[str, Any]:
        if req["type"] == "snapshot":
            return _snapshot_state(ns, req["path"], committed)
        return _restore_state(ns, req["path"], committed)

    assert _loop is not None
    task = _loop.create_task(run())
    outcome: tuple[str, Any, dict[str, Any] | None] | None = None
    try:
        outcome = await _run_guarded(task, rid)
        _finish_request(rid)  # no post-run repr/drain: close the interrupt window now
    except KeyboardInterrupt:
        # A finishing-targeted SIGINT can raise anywhere between _run_guarded's
        # finally publishing _finishing_rid and _finish_request clearing it; the
        # handler only raises once _finishing_rid is set, so the task is already
        # complete (destructively so for a pruning snapshot). Consume the
        # interrupt and report the task's real outcome; escaping to the backstop
        # would misreport a committed snapshot as failed.
        _finish_request(rid)
        if outcome is None:
            # The KeyboardInterrupt pre-empted _run_guarded's return: recover
            # the completed task's outcome with _run_guarded's failure mapping.
            try:
                outcome = ("ok", task.result(), None)
            except asyncio.CancelledError as exc:
                event = _interrupt_event(rid, exc) if _active["interrupted"] else _error_event(rid, exc)
                outcome = ("error", None, event)
            except BaseException as exc:  # noqa: BLE001 - every request failure becomes an error event
                outcome = ("error", None, _error_event(rid, exc))
    status, result, error = outcome
    if (
        committed
        and _active["interrupted"]
        and error is not None
        and error.get("ename") == "KeyboardInterrupt"
    ):
        # Recover only a protocol interrupt that landed after the commit; a user KeyboardInterrupt keeps interrupted reporting.
        status, result, error = "ok", committed[0], None
    if status != "ok":
        reason = "interrupted" if error and error.get("ename") == "KeyboardInterrupt" else (
            f"{error.get('ename')}: {error.get('evalue')}" if error else "failed"
        )
        _send({"event": "done", "id": rid, "status": "error", "reason": reason})
        return
    if "error" in result:
        _send({"event": "done", "id": rid, "status": "error", "reason": result["error"]})
        return
    if req["type"] == "snapshot":
        global _last_snapshot_path
        _last_snapshot_path = req["path"]
    _send({"event": "done", "id": rid, "status": "ok", **result})


def _flush_final_snapshot(ns: dict[str, Any]) -> None:
    """EOF-only best-effort final snapshot before exit.

    The host died without a graceful dispose (crash, SIGKILL, worker exit
    path that skipped `shutdown`), so its debounced snapshots stop at the
    last one. Flush the current namespace to the last-known target so a
    resume revives state up to the EOF instead of up to the debounce.
    Atomic staging (temp + rename) means an interrupted flush leaves the
    previous payload intact, never a torn one.
    """
    if _last_snapshot_path is None:
        return
    try:
        _snapshot_state(ns, _last_snapshot_path)
    except BaseException:  # noqa: BLE001 - never block or crash the shutdown path
        pass


async def _handle_request(
    handler: Callable[[dict[str, Any], dict[str, Any]], Awaitable[None]],
    req: dict[str, Any],
    ns: dict[str, Any],
) -> None:
    # Backstop: one broken request (e.g. RecursionError in compile) fails alone, never the serve loop.
    try:
        await handler(req, ns)
    except BaseException as exc:  # noqa: BLE001 - any per-request failure becomes error+done
        rid = req["id"]
        with _interrupt_lock:
            # Only a still-inflight request (never reached _run_guarded, e.g. compile
            # failure) owns a parked interrupt; after _run_guarded finished it, a parked
            # "any" belongs to the next request and must survive.
            if rid in _inflight:
                _consume_pending_interrupt(rid)
            _finish_locked(rid)
        _send(_error_event(rid, exc))
        _send({"event": "done", "id": rid, "status": "error"})


async def _serve(queue: asyncio.Queue[dict[str, Any]], ns: dict[str, Any]) -> None:
    while True:
        req = await queue.get()
        signal.signal(signal.SIGINT, _sigint_handler)
        kind = req["type"]
        if kind == "shutdown":
            if req.get("eof"):
                _flush_final_snapshot(ns)
            tasks = {task for task in asyncio.all_tasks() if task is not asyncio.current_task()}
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.wait(tasks, timeout=1.0)
            if isinstance(req.get("id"), str):
                _send({"event": "done", "id": req["id"], "status": "ok"})
            return
        handlers = {"execute": _handle_execute, "snapshot": _handle_state, "restore": _handle_state}
        await _handle_request(handlers[kind], req, ns)


_REQUIRED_FIELDS = {
    "execute": ("id", "code"),
    "snapshot": ("id", "path"),
    "restore": ("id", "path"),
    "shutdown": (),
}


def _protocol_error(message: str) -> None:
    _send({"event": "error", "id": None, "ename": "ProtocolError", "evalue": message, "traceback": []})


def _handle_request_line(raw: bytes, queue: asyncio.Queue[dict[str, Any]]) -> None:
    assert _loop is not None
    req = json.loads(raw)
    if not isinstance(req, dict):
        raise ValueError("request is not a JSON object")
    rtype = req.get("type")
    if rtype == "interrupt":
        if "id" in req and not isinstance(req["id"], str):
            _protocol_error("interrupt request id must be a string")
            return
        _request_interrupt(req.get("id"))
        return
    if not isinstance(rtype, str) or rtype not in _REQUIRED_FIELDS:
        _protocol_error(f"unknown request type: {rtype!r}")
        return
    missing = [f for f in _REQUIRED_FIELDS[rtype] if not isinstance(req.get(f), str)]
    if missing:
        _protocol_error(f"{rtype} request needs string fields: {', '.join(missing)}")
        return
    if rtype in ("execute", "snapshot", "restore"):
        with _interrupt_lock:
            # A reused in-flight id would corrupt interrupt/finish bookkeeping.
            duplicate = req["id"] in _inflight
            if not duplicate:
                _inflight.add(req["id"])
        # The protocol write can block on backpressure: never send under the lock.
        if duplicate:
            _protocol_error(f"duplicate in-flight request id: {req['id']!r}")
            return
    _loop.call_soon_threadsafe(queue.put_nowait, req)


def _read_requests(stdin_fd: int, queue: asyncio.Queue[dict[str, Any]]) -> None:
    assert _loop is not None
    with os.fdopen(stdin_fd, "rb") as stream:
        while True:
            raw = stream.readline(32 * 1024 * 1024 + 1)
            if not raw:
                break
            if len(raw) > 32 * 1024 * 1024:
                while raw and not raw.endswith(b"\n"):
                    raw = stream.readline(64 * 1024)
                _protocol_error("request exceeds 32 MiB")
                continue
            raw = raw.strip()
            if not raw:
                continue
            try:
                # The whole per-line handling sits inside the backstop: hostile
                # input (RecursionError from pathological nesting, unhashable
                # field types, ...) must never kill the reader thread.
                _handle_request_line(raw, queue)
            except BaseException as err:  # noqa: BLE001
                _protocol_error(f"{type(err).__name__}: {_safe_str(err)}")
    # Host closed stdin: shut the runtime down. The marker distinguishes
    # this from the host's explicit shutdown request (which runs after the
    # host flushed its own final snapshot, so no runtime-side flush runs).
    _loop.call_soon_threadsafe(queue.put_nowait, {"type": "shutdown", "eof": True})


def _resolve_owner_pid() -> int:
    raw = os.environ.get("PROTO_FX_KERNEL_OWNER_PID", "")
    try:
        owner = int(raw)
    except ValueError:
        owner = 0
    return owner if owner > 0 else os.getppid()


def _owner_alive_posix(owner: int, initial_ppid: int) -> bool:
    # Reparenting is the race-free parent-death signal when the owner is the
    # parent; the kill-0 probe covers an env-designated non-parent owner.
    if initial_ppid == owner and os.getppid() != initial_ppid:
        return False
    try:
        os.kill(owner, 0)
    except ProcessLookupError:
        return False
    except OSError:
        pass  # EPERM etc.: alive but unprobeable
    return True


def _wait_owner_posix(owner: int, initial_ppid: int) -> None:
    # Blocks until the owner exits: the OS exit notification (kqueue NOTE_EXIT
    # on macOS/BSD, a pidfd on Linux) wakes this thread once, with no polling.
    # Registration binds whichever process holds the pid right now, so the
    # liveness check after it catches a parent owner that died (and whose pid
    # may be reused) before the watch existed.
    try:
        if hasattr(select, "kqueue"):
            kq = select.kqueue()
            # max_events=0 makes a registration error raise (ESRCH for a gone
            # owner) instead of arriving as an EV_ERROR event.
            kq.control(
                [select.kevent(owner, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)],
                0,
                0,
            )
            wait_for_exit = functools.partial(kq.control, None, 1)
        else:
            poller = select.poll()
            poller.register(os.pidfd_open(owner), select.POLLIN)
            wait_for_exit = poller.poll
    except ProcessLookupError:
        return  # already gone
    except (AttributeError, OSError):
        # Slow fallback, only where exit notification is unavailable: Linux
        # before 5.3, a seccomp filter denying pidfd_open, a CPython built
        # without os.pidfd_open.
        while _owner_alive_posix(owner, initial_ppid):
            time.sleep(30.0)
        return
    if _owner_alive_posix(owner, initial_ppid):
        wait_for_exit()


def _owner_watchdog(owner: int, initial_ppid: int) -> None:
    _wait_owner_posix(owner, initial_ppid)
    # Event-loop-independent by design: a synchronous cell monopolizes the
    # loop, so the queued EOF shutdown can never run; hard-exit from here.
    os._exit(1)


def _start_owner_watchdog() -> None:
    threading.Thread(
        target=_owner_watchdog, args=(_resolve_owner_pid(), os.getppid()), daemon=True
    ).start()


_pump_out: _Pump
_pump_err: _Pump


def _setup_fds() -> int:
    """Reserve stdout for the protocol; route fds 1/2 through captured pipes."""
    global _protocol_fd, _pump_out, _pump_err, _host_stderr_fd
    _protocol_fd = os.dup(1)
    os.set_inheritable(_protocol_fd, False)
    _host_stderr_fd = os.dup(2)
    os.set_inheritable(_host_stderr_fd, False)
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    os.dup2(out_w, 1)
    os.dup2(err_w, 2)
    os.close(out_w)
    os.close(err_w)
    sys.stdout = _TaggedWriter("stdout", fallback_fd=os.dup(1))
    sys.stderr = _TaggedWriter("stderr", fallback_fd=os.dup(2))
    stdin_fd = os.dup(0)
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    os.close(devnull)
    sys.stdin = open(os.devnull, "r")  # user input() sees EOF, never protocol frames
    _pump_out = _Pump(out_r, 1, "stdout")
    _pump_err = _Pump(err_r, 2, "stderr")
    return stdin_fd


def main() -> None:
    global _loop, _serve_task
    stdin_fd = _setup_fds()
    _start_owner_watchdog()

    # A real __main__ module makes dill pickle user functions/classes by value.
    user_module = types.ModuleType("__main__")
    user_module.__dict__["__builtins__"] = __builtins__
    # asyncio is omitted from snapshots because every fresh kernel supplies it.
    user_module.__dict__["asyncio"] = asyncio
    sys.modules["__main__"] = user_module

    _loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_loop)
    queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
    signal.signal(signal.SIGINT, _sigint_handler)
    threading.Thread(target=_read_requests, args=(stdin_fd, queue), daemon=True).start()

    _send({"event": "ready", "protocol": PROTOCOL_VERSION, "python": platform.python_version()})

    _serve_task = _loop.create_task(_serve(queue, user_module.__dict__))
    # A KeyboardInterrupt escaping a cell or background task stops
    # run_until_complete; the interrupt is already recorded, so resume serving.
    while not _serve_task.done():
        try:
            _loop.run_until_complete(_serve_task)
        except KeyboardInterrupt:
            continue
    _loop.close()


def _reap_children(signum: int, frame: types.FrameType | None) -> None:
    """Zygote only: reap every exited kernel at once, so none lingers as a zombie."""
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return


def _recv_exact(sock: Any, size: int) -> bytes:
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


def _zygote_child(sock: Any, fds: list[int], req: dict[str, Any]) -> None:
    """Become a kernel exactly as a direct spawn would; never returns."""
    code = 1
    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        os.setpgid(0, 0)
        for target, fd in enumerate(fds):
            os.dup2(fd, target)
        # Detach first: the socket object must never close a reused fd number later.
        sock.detach()
        fd_dir = "/proc/self/fd" if os.path.isdir("/proc/self/fd") else "/dev/fd"
        for name in os.listdir(fd_dir):
            if int(name) > 2:
                try:
                    os.close(int(name))
                except OSError:
                    pass
        os.chdir(req["cwd"])
        os.environ.clear()
        os.environ.update(req["env"])
        sys.argv = sys.argv[:1]
        main()
        code = 0
    except SystemExit as exc:
        code = exc.code if isinstance(exc.code, int) else 1
    except BaseException:  # noqa: BLE001 - a kernel must never return into the zygote loop
        traceback.print_exc()
    finally:
        try:
            import atexit

            atexit._run_exitfuncs()
            sys.stdout.flush()
            sys.stderr.flush()
        finally:
            os._exit(code)


def _zygote_main() -> None:
    """Pre-imported, single-threaded fork server; one per interpreter per host process.

    The host's socket is fd 0. Each request is an 8-byte little-endian length that
    carries the kernel's stdin, stdout and stderr by SCM_RIGHTS, then a JSON body
    naming the kernel's cwd and environment. The reply line names the forked pid.
    Nothing here may start a thread or load a library that is unsafe to fork.
    """
    import socket

    sock = socket.socket(fileno=os.dup(0))
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.close(devnull)
    signal.signal(signal.SIGCHLD, _reap_children)
    # A kernel imports dill only to snapshot or restore, but every saved kernel
    # snapshots soon after its first cell. Imported here, its pages are shared:
    # measured on 3.11, a forked kernel then holds about 10.6 MiB privately
    # after its first snapshot instead of 14.1 MiB.
    try:
        _import_dill()
    except Exception:  # noqa: BLE001 - the probe guarantees dill; a kernel reports its absence
        pass
    # Frozen objects are never scanned by the collector, so a kernel's GC
    # passes leave the pages it shares with the zygote untouched.
    import gc

    gc.freeze()
    sock.sendall(json.dumps({"ready": PROTOCOL_VERSION}).encode() + b"\n")
    while True:
        try:
            header, fds, _, _ = socket.recv_fds(sock, 8, 3)
            if not header:
                os._exit(0)
            header += _recv_exact(sock, 8 - len(header))
            req = json.loads(_recv_exact(sock, int.from_bytes(header, "little")))
        except (EOFError, OSError):
            os._exit(0)
        if len(fds) != 3:
            for fd in fds:
                os.close(fd)
            sock.sendall(b'{"error":"expected three descriptors"}\n')
            continue
        try:
            pid = os.fork()
        except OSError as err:
            pid = -1
            reply = {"error": f"fork failed: {err}"}
        if pid == 0:
            _zygote_child(sock, fds, req)
        for fd in fds:
            os.close(fd)
        if pid > 0:
            reply = {"pid": pid}
        try:
            sock.sendall(json.dumps(reply).encode() + b"\n")
        except OSError:
            os._exit(0)


if __name__ == "__main__":
    if sys.argv[1:] == ["--zygote"]:
        _zygote_main()
    else:
        main()
