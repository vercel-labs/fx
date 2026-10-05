#!/usr/bin/env python3
"""Per-call cost of captured shell commands that load the user's startup files.

A local Gateway fixture scripts N sequential `ls` shell calls with no profile
field, so the user profile applies, then one `printenv PATH` probe and a final
text. The isolated HOME holds heavy synthetic startup files for both zsh and
bash; the passwd login shell decides which one runs. Every full startup-file
load appends one line to $HOME/rc-loads.log.

rc_loads is the line count after the last `ls` call, before the probe.
Per-call times are gaps between fixture request arrivals. Budgets are enforced
by CI with jq; this script fails only when the run itself fails.
"""
import argparse
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import pwd
import secrets
import signal
import statistics
import subprocess
import threading
import time

ALIASES = 400
FUNCTIONS = 300
PATH_EDITS = 40
FINAL_TEXT = "SHELL_OVERHEAD_COMPLETE"


def startup_file(kind, marker, delay):
    """Return a heavy startup file that logs one line per full load."""
    lines = ["# Synthetic startup file for benchmarks/shell_command_overhead.py."]
    for index in range(PATH_EDITS):
        entry = f"$HOME/bench-path/d{index:02d}"
        lines.append(f'PATH="{entry}:$PATH"' if index % 2 == 0 else f'PATH="$PATH:{entry}"')
    lines.append(f'PATH="$HOME/{marker}:$PATH"')
    lines.append("export PATH")
    lines.extend(f"alias fxb_a{index}='printf %s {index}'" for index in range(ALIASES))
    lines.extend(f"fxb_f{index}() {{ printf '%s\\n' \"fn{index} $*\"; }}" for index in range(FUNCTIONS))
    if delay > 0:
        lines.append(f"sleep {delay:g}")
    lines.append(f"printf '%s %s\\n' {kind} \"$$\" >> \"$HOME/rc-loads.log\"")
    return "\n".join(lines) + "\n"


def write_home(home, marker, delay):
    (home / ".fx").mkdir(parents=True, mode=0o700)
    # Background title generation would consume one fixture response and shift
    # the call accounting, so the fixture profile keeps titles off.
    (home / ".fx/settings.json").write_text(json.dumps({"provider": "gateway", "model": "openai/gpt-5.5", "max_agent_steps": 0, "session_titles": False}))
    for index in range(PATH_EDITS):
        (home / f"bench-path/d{index:02d}").mkdir(parents=True)
    (home / marker).mkdir()
    # zsh -l -i reads .zshrc once per start. bash --login reads only
    # .bash_profile, which sources .bashrc, and an interactive non-login bash
    # reads .bashrc directly, so the counter lives in .bashrc.
    (home / ".zshrc").write_text(startup_file("zsh", marker, delay))
    (home / ".bashrc").write_text(startup_file("bash", marker, delay))
    (home / ".bash_profile").write_text('. "$HOME/.bashrc"\n')


def line_count(path):
    try:
        return len(path.read_text().splitlines())
    except FileNotFoundError:
        return 0


def tool_result(body, call_id):
    """Decode the shell result for call_id from a fixture request body."""
    try:
        prompt = json.loads(body).get("prompt", [])
        for message in reversed(prompt):
            if message.get("role") != "tool":
                continue
            for part in message.get("content", []):
                if part.get("type") == "tool-result" and part.get("toolCallId") == call_id:
                    value = part.get("output", {}).get("value")
                    return json.loads(value) if isinstance(value, str) else value
    except (AttributeError, TypeError, ValueError):
        return None
    return None


def summarize(values):
    if not values:
        return {"median": None, "mean": None, "p95": None, "min": None, "max": None, "samples": []}
    ordered = sorted(values)
    return {
        "median": round(statistics.median(values), 3),
        "mean": round(statistics.fmean(values), 3),
        "p95": round(ordered[math.ceil(0.95 * len(ordered)) - 1], 3),
        "min": round(ordered[0], 3),
        "max": round(ordered[-1], 3),
        "samples": [round(value, 3) for value in values],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="./zig-out/bin/fx")
    parser.add_argument("--output", required=True)
    parser.add_argument("--calls", type=int, default=100)
    parser.add_argument("--rc-delay", type=float, default=0.2, help="seconds each startup-file load sleeps")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if args.calls < 1:
        parser.error("--calls must be at least 1")
    if args.rc_delay < 0:
        parser.error("--rc-delay must not be negative")
    binary = str(Path(args.binary).resolve())
    binary_sha256 = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    root = Path(args.output).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    home, workspace = root / "home", root / "workspace"
    marker = f"fx-bench-marker-{secrets.token_hex(4)}"
    marker_dir = str(home / marker)
    write_home(home, marker, args.rc_delay)
    workspace.mkdir()
    (workspace / "README.txt").write_text("shell command overhead fixture\n")
    (workspace / "src").mkdir()
    rc_log = home / "rc-loads.log"

    arrivals = []
    results = []
    rc_loads_after_ls = None

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        # Headers and body go out in separate writes. With Nagle on, the body
        # waits for the client's delayed ACK, about 40 ms per reply on Linux.
        disable_nagle_algorithm = True

        def log_message(self, *_):
            pass

        def reply(self, data, content_type):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(json.dumps({"object": "list", "data": [{"id": "openai/gpt-5.5", "type": "language", "tags": ["tool-use"], "context_window": 1000000}]}).encode(), "application/json")

        def do_POST(self):
            nonlocal rc_loads_after_ls
            arrival = time.monotonic()
            body = self.rfile.read(int(self.headers["Content-Length"]))
            index = len(arrivals)
            arrivals.append(arrival)
            if index > 0:
                results.append(tool_result(body, f"shell_{index}"))
            if index == args.calls:
                rc_loads_after_ls = line_count(rc_log)
            if index <= args.calls:
                command = "ls" if index < args.calls else "printenv PATH"
                request = {"action": "run", "command": command, "yield_time_ms": 30000}
                events = [{"type": "tool-call", "toolCallId": f"shell_{index + 1}", "toolName": "shell", "input": {"request": request}}]
                reason = "tool-calls"
            else:
                events = [{"type": "text-delta", "id": "answer", "delta": FINAL_TEXT}]
                reason = "stop"
            events.append({"type": "finish", "finishReason": {"unified": reason, "raw": reason}, "usage": {"inputTokens": {"total": 3}, "outputTokens": {"total": 5}}})
            self.reply(("".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n").encode(), "text/event-stream")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FX_", "OPENAI_", "GROK_", "XAI_", "AI_GATEWAY_", "VERCEL_"))}
    # These would redirect or add startup files outside the isolated HOME.
    for key in ("ZDOTDIR", "BASH_ENV", "ENV"):
        env.pop(key, None)
    base_url = f"http://127.0.0.1:{server.server_port}"
    env.update(HOME=str(home), AI_GATEWAY_API_KEY="fixture-key", FX_GATEWAY_BASE_URL=base_url, FX_E2E_GATEWAY_CHAT_URL=base_url + "/chat", FX_E2E_GATEWAY_MODELS_URL=base_url + "/coding-agent/v1/models", FX_MODEL="openai/gpt-5.5", FX_MAX_AGENT_STEPS="0")

    timed_out = False
    with (root / "stdout.json").open("w") as out, (root / "stderr.log").open("w") as err:
        started = time.monotonic()
        proc = subprocess.Popen([binary, "ask", "--json", "--yolo", "--no-save", "Run the scripted shell commands until the fixture finishes."], cwd=workspace, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err, start_new_session=True)
        try:
            code = proc.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGKILL)
            code = proc.wait()
        finished = time.monotonic()
    server.shutdown()

    try:
        result = json.loads((root / "stdout.json").read_text())
    except json.JSONDecodeError:
        result = {}
    calls = result.get("tool_calls", [])
    ls_results = results[: args.calls]
    probe = results[args.calls] if len(results) > args.calls else None
    ls_failures = sum(1 for item in ls_results if not (isinstance(item, dict) and item.get("state") == "completed" and item.get("exit_code") == 0))
    ls_failures += args.calls - len(ls_results)
    marker_present = isinstance(probe, dict) and probe.get("exit_code") == 0 and marker_dir in str(probe.get("output_delta", ""))
    expected_commands = ["ls"] * args.calls + ["printenv PATH"]
    reported_ok = (
        len(calls) == args.calls + 1
        and [call.get("command_result", {}).get("command") for call in calls] == expected_commands
        and all(call.get("name") == "shell" and call.get("status") == "success" and call.get("command_result", {}).get("exit_code") == 0 for call in calls)
    )
    completed = (
        not timed_out
        and code == 0
        and len(arrivals) == args.calls + 2
        and result.get("final_output") == FINAL_TEXT
        and ls_failures == 0
        and marker_present
        and reported_ok
    )

    kinds = sorted({line.split(" ", 1)[0] for line in rc_log.read_text().splitlines()}) if rc_log.exists() else []
    per_call = [(arrivals[i] - arrivals[i - 1]) * 1000 for i in range(1, min(len(arrivals), args.calls + 1))]
    report = {
        "binary": binary,
        "binary_sha256": binary_sha256,
        "calls": args.calls,
        "rc_delay_ms": round(args.rc_delay * 1000, 3),
        "startup_file_contents": {"aliases": ALIASES, "functions": FUNCTIONS, "path_edits": PATH_EDITS},
        "login_shell": pwd.getpwuid(os.getuid()).pw_shell,
        "shell_kind": kinds[0] if len(kinds) == 1 else ",".join(kinds) or None,
        "code": code,
        "timed_out": timed_out,
        "completed": completed,
        "requests": len(arrivals),
        "rc_loads": rc_loads_after_ls,
        "rc_loads_total": line_count(rc_log),
        "ls_failures": ls_failures,
        "path_marker": marker_dir,
        "path_marker_present": marker_present,
        "total_ms": round((finished - started) * 1000, 3),
        "first_request_ms": round((arrivals[0] - started) * 1000, 3) if arrivals else None,
        "per_call_ms": summarize(per_call),
        "path_probe_ms": round((arrivals[args.calls + 1] - arrivals[args.calls]) * 1000, 3) if len(arrivals) > args.calls + 1 else None,
    }
    (root / "measurements.json").write_text(json.dumps(report, indent=2))
    printed = dict(report, per_call_ms={k: v for k, v in report["per_call_ms"].items() if k != "samples"})
    print(json.dumps(printed, indent=2))
    return 0 if completed else 1


if __name__ == "__main__":
    raise SystemExit(main())
