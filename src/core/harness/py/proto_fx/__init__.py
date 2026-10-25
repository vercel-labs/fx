"""proto_fx: ask the proto-fx agent host for help from inside Python.

Import it as ``import proto_fx as harness``. It works in any Python 3.10+
that a proto-fx agent command starts, and in kernel cells. Every call is a
request to the host of the agent that ran the command, and goes through the
same tool admission and permissions as the agent's own tool calls: a tool the
agent may not use raises Refused, a denied approval raises PermissionDenied.

Plain ``python`` is an ordinary, fresh process: nothing you define survives
the command. Keep state in a kernel instead.

    import proto_fx as harness

    text = harness.tool.read_file(path="README.md")      # any tool the agent has
    harness.tool.run_command(command="ls")                # asks for approval like the agent
    answer = harness.agent("Summarize src/core/kernel")   # a subagent below this agent
    review = harness.agent("Review it", name="reviewer")  # a named, persistent subagent
    data = harness.agent("List the files", schema={"type": "array", "items": {"type": "string"}})
    reply = harness.completion("One word for happy?")     # one model reply, no tools
    results = harness.parallel([lambda: harness.agent(t) for t in tasks], max_workers=4)
    out = harness.pipeline(paths, read, summarize)        # each item through each stage
    syms = harness.symbols("pkg/module.py")               # Python files only

    k = harness.kernel("a")       # a persistent namespace, by name, per agent
    k.run("x = 41")
    k.run("x + 1").result         # '42'
    k.exec("analysis.py")         # run a file in that namespace
    k.status(); k.stop(); k.restart()

Errors are HarnessError subclasses: Unavailable, Refused, PermissionDenied,
ToolFailed (with .output), KernelError (with .output) and Cancelled.
"""

from __future__ import annotations

from typing import Any, Callable, Iterable

from ._client import (  # noqa: F401
    Cancelled,
    HarnessError,
    KernelError,
    PermissionDenied,
    Refused,
    ToolFailed,
    Unavailable,
    available,
    request,
)

__all__ = [
    "tool",
    "agent",
    "completion",
    "parallel",
    "pipeline",
    "symbols",
    "kernel",
    "Kernel",
    "available",
    "HarnessError",
    "Unavailable",
    "Refused",
    "PermissionDenied",
    "ToolFailed",
    "KernelError",
    "Cancelled",
]


class _Tools:
    """``harness.tool.<name>(**args)`` calls tool <name> with these arguments.

    It returns the tool's text output, or raises ToolFailed when the tool
    reports a failure. ``dir(harness.tool)`` lists the tools this agent has.
    """

    def __call__(self, name: str, /, **args: Any) -> str:
        value = request("tool", {"name": name, "args": args})
        if value.get("status") != "success":
            output = value.get("output", "")
            raise ToolFailed(output.strip().splitlines()[0] if output.strip() else "%s failed" % name, output=output)
        return value.get("output", "")

    def __getattr__(self, name: str) -> Callable[..., str]:
        if name.startswith("_"):
            raise AttributeError(name)

        def call(**args: Any) -> str:
            return self(name, **args)

        call.__name__ = name
        call.__doc__ = "Calls the %s tool through the proto-fx host." % name
        return call

    def __dir__(self) -> list[str]:
        try:
            return sorted(request("tools"))
        except HarnessError:
            return []


tool = _Tools()


def agent(prompt: str, *, schema: dict | None = None, model: str | None = None, name: str | None = None) -> Any:
    """Runs a subagent below the calling agent and returns its final reply.

    Without ``name`` the child is temporary and takes no follow-up. With a
    ``name`` it is a persistent child: a new name creates it, a later call
    continues it. With a JSON ``schema`` the reply is parsed and returned as
    a Python value. The child gets no wider tools or permissions than this
    agent, and the call blocks until it finishes.
    """
    args: dict[str, Any] = {"prompt": prompt}
    if schema is not None:
        args["schema"] = schema
    if model is not None:
        args["model"] = model
    if name is not None:
        args["name"] = name
    value = request("agent", args)
    return _decode(value, schema)


def completion(prompt: str, *, schema: dict | None = None, model: str | None = None, system: str | None = None) -> Any:
    """Asks the agent's model once, with no tools, and returns the reply text.

    With a JSON ``schema`` the reply is parsed and returned as a Python value.
    """
    args: dict[str, Any] = {"prompt": prompt}
    if schema is not None:
        args["schema"] = schema
    if model is not None:
        args["model"] = model
    if system is not None:
        args["system"] = system
    value = request("completion", args)
    return _decode(value, schema)


def _decode(value: dict, schema: dict | None) -> Any:
    text = value.get("text", "")
    if schema is None:
        return text
    import json

    body = text.strip()
    if body.startswith("```"):
        body = body.strip("`")
        if body.startswith("json"):
            body = body[4:]
    try:
        return json.loads(body)
    except ValueError:
        raise ToolFailed("the reply was not JSON matching the schema", output=text) from None


def parallel(thunks: Iterable[Callable[[], Any]], max_workers: int = 8) -> list[Any]:
    """Calls each zero-argument function on a thread and returns their results in order.

    If any call raised, the first exception is raised after all of them end.
    """
    from concurrent.futures import ThreadPoolExecutor

    items = list(thunks)
    if not items:
        return []
    with ThreadPoolExecutor(max_workers=max(1, min(max_workers, len(items)))) as pool:
        futures = [pool.submit(fn) for fn in items]
        errors = [f.exception() for f in futures]
    for error in errors:
        if error is not None:
            raise error
    return [f.result() for f in futures]


def pipeline(items: Iterable[Any], *stages: Callable[[Any], Any], max_workers: int = 8) -> list[Any]:
    """Passes each item through every stage in turn, items in parallel; returns the last stage's results in order."""

    def run(item: Any) -> Any:
        for stage in stages:
            item = stage(item)
        return item

    return parallel([(lambda item=item: run(item)) for item in items], max_workers=max_workers)


def symbols(path: str) -> list[dict[str, Any]]:
    """Top-level and nested definitions of a Python file: name, kind, line, end line.

    proto-fx has no parser for other languages; for those use
    ``harness.tool.read_file`` or a search command.
    """
    import ast

    if not path.endswith((".py", ".pyi")):
        raise Refused("symbols reads Python files only; proto-fx has no parser for %s" % path)
    with open(path, "rb") as handle:
        tree = ast.parse(handle.read(), filename=path)
    found: list[dict[str, Any]] = []

    def visit(node: ast.AST, scope: str) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                kind = "class" if isinstance(child, ast.ClassDef) else "function"
                qualified = scope + child.name
                found.append({"name": qualified, "kind": kind, "line": child.lineno, "end_line": child.end_lineno})
                visit(child, qualified + ".")

    visit(tree, "")
    return found


class RunResult:
    """What one kernel cell produced. Its output already streamed to stdout and stderr."""

    def __init__(self, value: dict):
        self.status: str = value.get("status", "ok")
        self.stdout: str = value.get("stdout", "")
        self.stderr: str = value.get("stderr", "")
        self.result: str = value.get("result", "")
        self.output: str = value.get("output", "")

    @property
    def ok(self) -> bool:
        return self.status == "ok"

    def __repr__(self) -> str:
        return "RunResult(status=%r, result=%r)" % (self.status, self.result)


class Kernel:
    """A persistent Python namespace owned by the calling agent, keyed by name.

    ``"default"`` is the agent's own kernel, the one ``/kernel`` controls.
    Other names are extra kernels of the same agent. Globals survive between
    calls and are saved when the kernel is parked to free memory; open files,
    sockets, threads and running tasks do not survive parking.
    """

    def __init__(self, name: str = "default"):
        self.name = name

    def run(self, code: str, *, timeout: float | None = None) -> RunResult:
        """Runs ``code`` as one cell. Raises KernelError if it raised or was interrupted."""
        args: dict[str, Any] = {"name": self.name, "code": code}
        if timeout is not None:
            args["timeout_ms"] = int(timeout * 1000)
        result = RunResult(request("kernel.run", args))
        if not result.ok:
            raise KernelError("the kernel cell %s" % ("was interrupted" if result.status == "aborted" else "raised"), output=result.output)
        return result

    def exec(self, path: str, *, timeout: float | None = None) -> RunResult:
        """Runs a Python file in this kernel's namespace."""
        import os

        absolute = os.path.abspath(path)
        code = "exec(compile(open(%r, 'rb').read(), %r, 'exec'), globals())" % (absolute, absolute)
        return self.run(code, timeout=timeout)

    def status(self) -> str:
        return request("kernel.status", {"name": self.name})["state"]

    def stop(self) -> str:
        """Saves the globals and stops the process; the next run restores them."""
        return request("kernel.stop", {"name": self.name})["state"]

    def restart(self) -> str:
        """Discards the process without a final save; the next run restores the last saved globals."""
        return request("kernel.restart", {"name": self.name})["state"]

    def __repr__(self) -> str:
        return "Kernel(%r)" % self.name


def kernel(name: str = "default") -> Kernel:
    """The calling agent's kernel named ``name``; it starts on first use."""
    return Kernel(name)
