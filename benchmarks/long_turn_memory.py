#!/usr/bin/env python3
"""Bounded Linux RSS measurement of a saved fx turn against a local Gateway fixture.

Only fx is measured. The fixture never retains requests; changing file contents
make each read useful.
Artifacts include RSS samples, stdout/stderr and the private session directory.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="./zig-out/bin/fx")
    parser.add_argument("--output", required=True)
    parser.add_argument("--steps", type=int, default=1000)
    parser.add_argument("--bytes", type=int, default=1024)
    parser.add_argument("--limit-mib", type=int, default=2048)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("RSS measurement requires Linux /proc")
    binary = str(Path(args.binary).resolve())
    binary_sha256 = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    root = Path(args.output).resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    home, workspace = root / "home", root / "workspace"
    (home / ".fx").mkdir(parents=True, mode=0o700)
    workspace.mkdir()
    (home / ".fx/settings.json").write_text(json.dumps({"provider": "gateway", "model": "openai/gpt-5.5", "max_agent_steps": 0}))
    count = 0
    request_bytes = 0

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

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
            nonlocal count, request_bytes
            size = int(self.headers["Content-Length"])
            self.rfile.read(size)
            request_bytes = size
            count += 1
            if count <= args.steps:
                text = str(count)
                (workspace / "evidence.txt").write_text(text + " " + "x" * args.bytes + "\n")
                call = f"read_{count}"
                events = [{"type": "tool-call", "toolCallId": call, "toolName": "read_file", "input": {"path": "evidence.txt"}}]
                reason = "tool-calls"
            else:
                events = [{"type": "text-delta", "id": "answer", "delta": "LONG_TURN_COMPLETE"}]
                reason = "stop"
            events.append({"type": "finish", "finishReason": {"unified": reason, "raw": reason}, "usage": {"inputTokens": {"total": 3}, "outputTokens": {"total": 5}}})
            self.reply(("".join("data: " + json.dumps(e) + "\n\n" for e in events) + "data: [DONE]\n\n").encode(), "text/event-stream")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FX_", "OPENAI_", "GROK_", "XAI_", "AI_GATEWAY_", "VERCEL_"))}
    base_url = f"http://127.0.0.1:{server.server_port}"
    env.update(HOME=str(home), AI_GATEWAY_API_KEY="fixture-key", FX_GATEWAY_BASE_URL=base_url, FX_E2E_GATEWAY_CHAT_URL=base_url + "/chat", FX_E2E_GATEWAY_MODELS_URL=base_url + "/coding-agent/v1/models", FX_MODEL="openai/gpt-5.5", FX_MAX_AGENT_STEPS="0")

    def limits():
        resource.setrlimit(resource.RLIMIT_AS, (args.limit_mib * 1024**2,) * 2)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    started = time.monotonic()
    samples = []
    with (root / "stdout.json").open("w") as out, (root / "stderr.log").open("w") as err:
        proc = subprocess.Popen([binary, "ask", "--json", "--yolo", "Read the changing evidence file until the fixture finishes."], cwd=workspace, env=env, stdout=out, stderr=err, preexec_fn=limits, start_new_session=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        while proc.poll() is None:
            try:
                status = dict(line.split(":", 1) for line in Path(f"/proc/{proc.pid}/status").read_text().splitlines() if ":" in line)
                rss = int(status.get("VmRSS", "0 kB").split()[0])
                samples.append({"seconds": round(time.monotonic() - started, 3), "requests": count, "rss_kib": rss, "request_bytes": request_bytes})
            except FileNotFoundError:
                break
            if time.monotonic() - started > args.timeout:
                os.killpg(proc.pid, signal.SIGKILL)
                break
            time.sleep(0.1)
        code = proc.wait()
    server.shutdown()
    retained = {"execution_json_bytes": 0, "tool_output_bytes": 0, "tool_steps": 0, "conversation_json_bytes": 0}

    def measure(value):
        if isinstance(value, dict):
            if isinstance(value.get("tool_steps"), list):
                size = len(json.dumps(value, separators=(",", ":")).encode())
                if size > retained["execution_json_bytes"]:
                    retained.update(execution_json_bytes=size, tool_steps=len(value["tool_steps"]), tool_output_bytes=sum(result.get("output_bytes", 0) for step in value["tool_steps"] for result in step.get("tool_results", [])))
            for child in value.values():
                measure(child)
        elif isinstance(value, list):
            for child in value:
                measure(child)

    for checkpoint in list((home / ".fx/sessions").glob("*/checkpoint.json")) + list((home / ".fx/sessions").glob("*/recovery.json")):
        measure(json.loads(checkpoint.read_text()))
    for event_log in (home / ".fx/sessions").glob("*/events.jsonl"):
        retained["conversation_json_bytes"] += event_log.stat().st_size
        result_count = 0
        output_bytes = 0
        for line in event_log.open():
            value = json.loads(line)
            measure(value)
            result = value.get("event", {}).get("tool_result")
            if isinstance(result, dict):
                result_count += 1
                output_bytes += result.get("output_bytes", 0)
        # This workload has one read per step. Completed v4 turns use normalized
        # conversation events instead of an embedded execution snapshot.
        if result_count > retained["tool_steps"]:
            retained.update(tool_steps=result_count, tool_output_bytes=output_bytes)
    try:
        result = json.loads((root / "stdout.json").read_text())
    except json.JSONDecodeError:
        result = {}
    calls = result.get("tool_calls", [])
    expected = (
        code == 0
        and count == args.steps + 1
        and result.get("final_output") == "LONG_TURN_COMPLETE"
        and len(calls) == args.steps
        and all(call.get("name") == "read_file" and call.get("status") == "success" for call in calls)
        and retained["tool_steps"] == args.steps
    )
    report = {"binary": binary, "binary_sha256": binary_sha256, "steps_requested": args.steps, "requests": count, "code": code, "completed": expected, "elapsed_seconds": round(time.monotonic() - started, 3), "peak_rss_kib": max((s["rss_kib"] for s in samples), default=0), "limit_mib": args.limit_mib, "retained": retained, "samples": samples}
    (root / "measurements.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({k: v for k, v in report.items() if k != "samples"}, indent=2))
    return 0 if expected else 1


if __name__ == "__main__":
    raise SystemExit(main())
