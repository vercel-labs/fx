"""Loopback logging proxy between fx and Vercel AI Gateway.

fx only honours ``FX_E2E_GATEWAY_CHAT_URL`` for loopback addresses, so the proxy
binds 127.0.0.1, forwards each request to the real Gateway unchanged, streams the
response back, and writes one JSON record per request plus the raw request and
response bodies. The ``Authorization`` header is forwarded but never written to
disk.
"""

from __future__ import annotations

import http.client
import json
import pathlib
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_UPSTREAM = "ai-gateway.vercel.sh"
MAX_CAPTURED_RESPONSE_BYTES = 4_000_000
HOP_BY_HOP = {"host", "content-length", "connection", "accept-encoding"}
RESPONSE_SKIP = {"transfer-encoding", "content-length", "connection", "content-encoding"}


def describe_prompt(body: bytes) -> dict[str, object]:
    """Summarise a Gateway request body: role sequence and system-message counts."""
    record: dict[str, object] = {}
    try:
        payload = json.loads(body or b"{}")
    except ValueError as error:
        record["parse_error"] = repr(error)
        return record
    prompt = payload.get("prompt") if isinstance(payload, dict) else None
    roles = [message.get("role") for message in prompt or [] if isinstance(message, dict)]
    record["roles"] = roles
    record["system_count"] = sum(1 for role in roles if role == "system")
    record["leading_system_count"] = next(
        (index for index, role in enumerate(roles) if role != "system"), len(roles)
    )
    tools = payload.get("tools") if isinstance(payload, dict) else None
    record["tools"] = len(tools) if isinstance(tools, list) else 0
    return record


def describe_response(status: int, text: str) -> dict[str, object]:
    """Pull error bodies, in-stream errors, finish events and tool-call counts out of a response."""
    record: dict[str, object] = {}
    if status >= 400:
        record["error_body"] = text[:2000]
        return record
    lines = text.splitlines()
    record["stream_error"] = [line[:500] for line in lines if '"type":"error"' in line][:3]
    record["finish"] = [line[:300] for line in lines if '"type":"finish"' in line][:2]
    record["tool_calls"] = sum(1 for line in lines if '"type":"tool-call"' in line)
    routing = _routing_summary(lines)
    if routing:
        record["routing"] = routing
    return record


def _routing_summary(lines: list[str]) -> dict[str, object] | None:
    """Extract the Gateway's upstream routing decision from the finish event, if present."""
    for line in lines:
        if '"routing"' not in line:
            continue
        payload = line[len("data: "):] if line.startswith("data: ") else line
        try:
            event = json.loads(payload)
        except ValueError:
            continue
        routing = _find_key(event, "routing")
        if not isinstance(routing, dict):
            continue
        attempts = []
        for model_attempt in routing.get("modelAttempts") or []:
            for attempt in model_attempt.get("providerAttempts") or []:
                attempts.append(
                    {
                        "provider": attempt.get("provider"),
                        "status": attempt.get("statusCode"),
                        "error": attempt.get("error"),
                    }
                )
        return {
            "final_provider": routing.get("finalProvider"),
            "fallbacks_available": routing.get("fallbacksAvailable"),
            "attempts": attempts,
        }
    return None


def _find_key(value: object, key: str) -> object:
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = _find_key(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _find_key(child, key)
            if found is not None:
                return found
    return None


class LoggingProxy:
    """Run the proxy on a background thread; ``records`` fills as requests complete."""

    def __init__(self, out_dir: pathlib.Path, upstream: str = DEFAULT_UPSTREAM, port: int = 0) -> None:
        self.out_dir = out_dir
        self.upstream = upstream
        self.records: list[dict[str, object]] = []
        self._lock = threading.Lock()
        self._sequence = 0
        handler = self._handler_class()
        ThreadingHTTPServer.daemon_threads = True
        self._server = ThreadingHTTPServer(("127.0.0.1", port), handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    @property
    def port(self) -> int:
        return int(self._server.server_address[1])

    def chat_url(self, tag: str) -> str:
        query = urllib.parse.urlencode({"tag": tag})
        return f"http://127.0.0.1:{self.port}/v4/ai/language-model?{query}"

    def start(self) -> None:
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._thread.start()

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()

    def _next_sequence(self) -> int:
        with self._lock:
            self._sequence += 1
            return self._sequence

    def _log(self, record: dict[str, object]) -> None:
        with self._lock:
            self.records.append(record)
            with (self.out_dir / "requests.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record) + "\n")

    def _handler_class(self) -> type[BaseHTTPRequestHandler]:
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args: object) -> None:
                return

            def do_POST(self) -> None:
                proxy._relay(self)

            def do_GET(self) -> None:
                proxy._relay(self)

        return Handler

    def _relay(self, handler: BaseHTTPRequestHandler) -> None:
        sequence = self._next_sequence()
        started = time.time()
        url = urllib.parse.urlsplit(handler.path)
        tag = urllib.parse.parse_qs(url.query).get("tag", ["untagged"])[0]
        length = int(handler.headers.get("Content-Length", "0") or 0)
        body = handler.rfile.read(length) if length else b""
        record: dict[str, object] = {
            "n": sequence,
            "tag": tag,
            "path": url.path,
            "model_header": handler.headers.get("ai-language-model-id"),
            "streaming_header": handler.headers.get("ai-language-model-streaming"),
            "req_bytes": len(body),
        }
        record.update(describe_prompt(body))
        (self.out_dir / f"req-{sequence:03d}-{tag}.json").write_bytes(body)

        headers = {key: value for key, value in handler.headers.items() if key.lower() not in HOP_BY_HOP}
        headers["Host"] = self.upstream
        headers["Content-Length"] = str(len(body))
        headers["Accept-Encoding"] = "identity"
        connection = http.client.HTTPSConnection(self.upstream, timeout=600)
        try:
            connection.request(handler.command, url.path, body=body, headers=headers)
            response = connection.getresponse()
        except OSError as error:
            record["proxy_error"] = repr(error)
            record["duration_ms"] = int((time.time() - started) * 1000)
            self._log(record)
            handler.send_response(502)
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            connection.close()
            return

        record["status"] = response.status
        handler.send_response(response.status, response.reason)
        content_length = response.getheader("Content-Length")
        chunked = content_length is None
        for key, value in response.getheaders():
            if key.lower() in RESPONSE_SKIP:
                continue
            handler.send_header(key, value)
        if chunked:
            handler.send_header("Transfer-Encoding", "chunked")
        else:
            handler.send_header("Content-Length", content_length)
        handler.end_headers()

        captured = bytearray()
        try:
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                if len(captured) < MAX_CAPTURED_RESPONSE_BYTES:
                    captured += chunk
                if chunked:
                    handler.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                else:
                    handler.wfile.write(chunk)
                handler.wfile.flush()
            if chunked:
                handler.wfile.write(b"0\r\n\r\n")
                handler.wfile.flush()
        except OSError as error:
            record["relay_error"] = repr(error)
        finally:
            connection.close()

        record["duration_ms"] = int((time.time() - started) * 1000)
        record["resp_bytes"] = len(captured)
        text = captured.decode("utf-8", "replace")
        (self.out_dir / f"resp-{sequence:03d}-{tag}.txt").write_text(text, encoding="utf-8")
        record.update(describe_response(response.status, text))
        self._log(record)
