#!/usr/bin/env python3
"""Measure time from process start until the model request after a toolbox search, with N stdio MCP servers, on a local fake gateway."""
import argparse
import http.server
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import threading
import time


def summarize(values):
    ordered = sorted(values)
    n = len(ordered)
    p25 = ordered[int(0.25 * (n - 1))]
    p75 = ordered[int(0.75 * (n - 1))]
    p95 = ordered[math.ceil(0.95 * n) - 1]
    return {
        "n": n,
        "median": round(statistics.median(values), 3),
        "mean": round(statistics.fmean(values), 3),
        "stdev": round(statistics.stdev(values), 3) if n >= 2 else 0.0,
        "min": round(ordered[0], 3),
        "max": round(ordered[-1], 3),
        "iqr": round(p75 - p25, 3),
        "p95": round(p95, 3),
        "samples": [round(v, 3) for v in values],
    }


def run_one(binary, server_count, fixture_path, runtime_bin, keep_trace=False):
    # Use a short path under /tmp because Unix domain socket paths are limited to 103 bytes on macOS.
    root = Path(tempfile.mkdtemp(prefix="fx-mcp-ready-", dir="/tmp"))
    home = root / "home"
    fx_home = home / ".fx"
    workspace = root / "workspace"
    fx_home.mkdir(mode=0o700, parents=True)
    workspace.mkdir()
    (fx_home / "settings.json").write_text(
        json.dumps({"provider": "gateway", "model": "openai/gpt-5", "max_agent_steps": 0, "session_titles": False})
    )

    mcp_servers = {}
    pid_paths = []
    wire_paths = []
    for i in range(server_count):
        pid_path = root / f"pid-{i}"
        wire_path = root / f"wire-{i}.jsonl"
        pid_paths.append(pid_path)
        wire_paths.append(wire_path)
        mcp_servers[f"s{i}"] = {
            "command": runtime_bin,
            "args": [str(fixture_path)],
            "enabled": True,
            "environment": {
                "FX_MCP_WIRE_LOG": str(wire_path),
                "FX_MCP_PID_PATH": str(pid_path),
                "FX_MCP_MODE": "normal",
            },
        }
    (fx_home / "mcp.json").write_text(json.dumps({"mcp": mcp_servers}))

    arrivals = []
    bodies = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
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
            self.reply(
                json.dumps(
                    {
                        "object": "list",
                        "data": [{"id": "openai/gpt-5", "type": "language", "tags": ["tool-use"], "context_window": 1000000}],
                    }
                ).encode(),
                "application/json",
            )

        def do_POST(self):
            t = time.monotonic()
            body = self.rfile.read(int(self.headers["Content-Length"])).decode("utf-8", errors="replace")
            idx = len(arrivals)
            arrivals.append(t)
            bodies.append(body)
            if idx == 0:
                events = [
                    {"type": "tool-call", "toolCallId": "call_search", "toolName": "toolbox", "input": {"search": "echo"}},
                    {"type": "finish", "finishReason": {"unified": "tool-calls", "raw": "tool-calls"}, "usage": {"inputTokens": {"total": 3}, "outputTokens": {"total": 5}}},
                ]
            else:
                events = [
                    {"type": "text-delta", "id": "answer", "delta": "MCP_READY_DONE"},
                    {"type": "finish", "finishReason": {"unified": "stop", "raw": "stop"}, "usage": {"inputTokens": {"total": 3}, "outputTokens": {"total": 5}}},
                ]
            self.reply(("".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n").encode(), "text/event-stream")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_port}"

    env = {k: v for k, v in os.environ.items() if not k.startswith(("FX_", "OPENAI_", "GROK_", "XAI_", "AI_GATEWAY_", "VERCEL_"))}
    trace_path = root / "trace.log"
    env.update(
        HOME=str(home),
        AI_GATEWAY_API_KEY="fixture-key",
        FX_GATEWAY_BASE_URL=base_url,
        FX_GATEWAY_CHAT_URL=base_url + "/chat",
        FX_TEST_GATEWAY_CHAT_URL=base_url + "/chat",
        FX_TEST_GATEWAY_MODELS_URL=base_url + "/coding-agent/v1/models",
        FX_MODEL="openai/gpt-5",
        FX_MAX_AGENT_STEPS="0",
        FX_AUTO_UPGRADE="0",
        FX_DISABLE_KEYCHAIN="1",
        FX_SOUND="0",
        FX_PERMISSION_MODE="auto",
        FX_TRACE_LOG=str(trace_path),
        FX_TRACE_SCOPES="mcp,mcp-owner",
    )

    t_spawn = time.monotonic()
    proc = subprocess.Popen(
        [binary, "ask", "--json", "--auto", "--no-save", "Search MCP tools."],
        cwd=workspace,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    out, err = proc.communicate(timeout=60)
    t_exit = time.monotonic()
    server.shutdown()
    server.server_close()

    if proc.returncode != 0:
        raise RuntimeError(f"fx failed code={proc.returncode} stderr={err.decode()} stdout={out.decode()}")
    if len(arrivals) != 2:
        raise RuntimeError(f"expected 2 gateway requests, got {len(arrivals)}")

    # Verify all N servers received tools/list and the search tool-result returned.
    for i, wp in enumerate(wire_paths):
        lines = [json.loads(line) for line in wp.read_text().splitlines() if line.strip()]
        methods = [e["message"].get("method") for e in lines]
        if "tools/list" not in methods:
            raise RuntimeError(f"server s{i} did not receive tools/list: {methods}")
    if "mcp_s0_echo" not in bodies[1]:
        raise RuntimeError("mcp_s0_echo missing from toolbox search result")

    owner_connect_ms = None
    owner_start_ms = None
    if trace_path.exists():
        t_trace_lines = trace_path.read_text().splitlines()
        for line in t_trace_lines:
            if "owner started pid=" in line and owner_start_ms is None:
                owner_start_ms = int(line.split(" ", 1)[0])
            if "owner connected socket=" in line and owner_connect_ms is None:
                owner_connect_ms = int(line.split(" ", 1)[0])

    # Wait for detached owner/fixture processes for this isolated HOME to exit (exit_grace_ms = 500ms).
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        ps = subprocess.run(["pgrep", "-f", str(home)], capture_output=True, text=True)
        if ps.returncode != 0:
            break
        time.sleep(0.05)

    res = {
        "launch_to_ready_ms": (arrivals[1] - t_spawn) * 1000,
        "search_to_ready_ms": (arrivals[1] - arrivals[0]) * 1000,
        "total_ms": (t_exit - t_spawn) * 1000,
        "owner_connect_delta_ms": (owner_connect_ms - owner_start_ms) if (owner_connect_ms and owner_start_ms) else None,
    }
    if not keep_trace:
        shutil.rmtree(root, ignore_errors=True)
    else:
        res["root"] = str(root)
    return res


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--arm", action="append", required=True, help="name=path")
    p.add_argument("--servers", default="1,10")
    p.add_argument("--rounds", type=int, default=10)
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--fixture", default="tests/e2e/fixtures/mcp-modern-stdio.mjs")
    p.add_argument("--runtime", default=shutil.which("bun") or "bun")
    p.add_argument("--out", default=str(Path(tempfile.gettempdir()) / "mcp-tools-ready.json"))
    args = p.parse_args()

    arms = []
    for item in args.arm:
        name, path = item.split("=", 1)
        arms.append((name, str(Path(path).resolve())))
    server_counts = [int(x) for x in args.servers.split(",")]
    fixture_path = Path(args.fixture).resolve()

    all_results = {}
    for count in server_counts:
        for _ in range(args.warmup):
            for _, path in arms:
                run_one(path, count, fixture_path, args.runtime)
        per_arm = {name: [] for name, _ in arms}
        for _ in range(args.rounds):
            for name, path in arms:
                m = run_one(path, count, fixture_path, args.runtime)
                per_arm[name].append(m)
        summary = {}
        for name, _ in arms:
            rows = per_arm[name]
            connects = [x["owner_connect_delta_ms"] for x in rows if x["owner_connect_delta_ms"] is not None]
            summary[name] = {
                "launch_to_ready_ms": summarize([x["launch_to_ready_ms"] for x in rows]),
                "search_to_ready_ms": summarize([x["search_to_ready_ms"] for x in rows]),
                "total_ms": summarize([x["total_ms"] for x in rows]),
                "owner_connect_delta_ms": summarize(connects) if connects else None,
            }
        all_results[f"servers_{count}"] = summary

    Path(args.out).write_text(json.dumps(all_results, indent=2))
    print(json.dumps(all_results, indent=2))


if __name__ == "__main__":
    raise SystemExit(main())
