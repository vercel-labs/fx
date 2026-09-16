"""Run multi-turn ``fx ask`` conversations per model and summarise the wire evidence."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import time
from dataclasses import dataclass, field

from .proxy import LoggingProxy

DEFAULT_PROMPTS = (
    "Reply with the single word OK.",
    "Read note.txt and reply with its contents.",
    "Reply with the single word DONE.",
)
DEFAULT_NOTE = "GATEWAY_MATRIX_NOTE_OK\n"
DEFAULT_README = "# Gateway matrix workspace\n\nScratch workspace used by scripts/gateway_matrix.\n"


@dataclass
class TurnResult:
    label: str
    model: str
    turn: int
    tag: str
    exit_code: int | None
    wall_ms: int
    session_id: str
    output: str
    tool_calls: object
    error: object
    stderr_tail: str


@dataclass
class MatrixResult:
    turns: list[TurnResult] = field(default_factory=list)
    requests: list[dict[str, object]] = field(default_factory=list)


def prepare_workspace(workspace: pathlib.Path) -> None:
    workspace.mkdir(parents=True, exist_ok=True)
    note = workspace / "note.txt"
    if not note.exists():
        note.write_text(DEFAULT_NOTE, encoding="utf-8")
    readme = workspace / "README.md"
    if not readme.exists():
        readme.write_text(DEFAULT_README, encoding="utf-8")


def safe_model(model: str) -> str:
    return model.replace("/", "_")


def fx_environment(chat_url: str, trace_log: pathlib.Path | None) -> dict[str, str]:
    env = dict(os.environ)
    env["FX_E2E_GATEWAY_CHAT_URL"] = chat_url
    env.setdefault("FX_AUTO_UPGRADE", "0")
    env.setdefault("FX_SOUND", "0")
    env.setdefault("FX_SKIP_ONBOARDING", "1")
    if trace_log is not None:
        env["FX_TRACE_LOG"] = str(trace_log)
        env.setdefault("FX_TRACE_SCOPES", "stream,gateway")
    return env


def run_turn(
    *,
    fx_binary: pathlib.Path,
    model: str,
    prompt: str,
    workspace: pathlib.Path,
    env: dict[str, str],
    resume_id: str | None,
    timeout_seconds: float,
) -> tuple[subprocess.CompletedProcess[str] | None, int]:
    args = [str(fx_binary), "ask", "--json", "--auto", "--model", model]
    if resume_id:
        args += ["--resume-id", resume_id]
    args += ["--", prompt]
    started = time.time()
    try:
        completed = subprocess.run(
            args,
            cwd=workspace,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, int((time.time() - started) * 1000)
    return completed, int((time.time() - started) * 1000)


def parse_ask_output(stdout: str) -> dict[str, object]:
    try:
        payload = json.loads(stdout)
    except ValueError:
        return {"_raw": stdout[:400]}
    return payload if isinstance(payload, dict) else {"_raw": stdout[:400]}


def run_matrix(
    *,
    fx_binary: pathlib.Path,
    models: list[str],
    label: str,
    out_dir: pathlib.Path,
    workspace: pathlib.Path,
    prompts: tuple[str, ...] = DEFAULT_PROMPTS,
    timeout_seconds: float = 180.0,
    trace: bool = False,
    upstream: str | None = None,
) -> MatrixResult:
    prepare_workspace(workspace)
    captures = out_dir / "captures"
    proxy = LoggingProxy(captures, **({"upstream": upstream} if upstream else {}))
    proxy.start()
    result = MatrixResult()
    try:
        for model in models:
            session_id = ""
            for index, prompt in enumerate(prompts, start=1):
                tag = f"{label}__{safe_model(model)}__t{index}"
                if index > 1 and not session_id:
                    result.turns.append(
                        TurnResult(label, model, index, tag, None, 0, "", "", None, "no session id from turn 1", "")
                    )
                    continue
                trace_log = captures / f"trace-{tag}.log" if trace else None
                env = fx_environment(proxy.chat_url(tag), trace_log)
                completed, wall_ms = run_turn(
                    fx_binary=fx_binary,
                    model=model,
                    prompt=prompt,
                    workspace=workspace,
                    env=env,
                    resume_id=session_id or None,
                    timeout_seconds=timeout_seconds,
                )
                if completed is None:
                    result.turns.append(
                        TurnResult(label, model, index, tag, None, wall_ms, session_id, "", None, "timeout", "")
                    )
                    continue
                (captures / f"ask-{tag}.json").write_text(completed.stdout, encoding="utf-8")
                (captures / f"ask-{tag}.stderr").write_text(completed.stderr, encoding="utf-8")
                payload = parse_ask_output(completed.stdout)
                if index == 1:
                    session_id = str(payload.get("session_id") or "")
                result.turns.append(
                    TurnResult(
                        label=label,
                        model=model,
                        turn=index,
                        tag=tag,
                        exit_code=completed.returncode,
                        wall_ms=wall_ms,
                        session_id=session_id,
                        output=str(payload.get("output") or "")[:300],
                        tool_calls=payload.get("tool_calls"),
                        error=payload.get("error"),
                        stderr_tail=completed.stderr[-600:],
                    )
                )
    finally:
        proxy.stop()
    result.requests = list(proxy.records)
    return result


def requests_for_tag(requests: list[dict[str, object]], tag: str, model: str) -> list[dict[str, object]]:
    """Requests fx sent for this turn and model, excluding side requests such as title generation."""
    return [record for record in requests if record.get("tag") == tag and record.get("model_header") == model]


def summarize(result: MatrixResult) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for turn in result.turns:
        matching = requests_for_tag(result.requests, turn.tag, turn.model)
        statuses = [record.get("status") for record in matching]
        system_counts = sorted({int(record.get("leading_system_count") or 0) for record in matching})
        errors: list[str] = []
        for record in matching:
            body = record.get("error_body")
            if isinstance(body, str) and body:
                errors.append(body[:160])
            routing = record.get("routing")
            if isinstance(routing, dict):
                for attempt in routing.get("attempts") or []:
                    if isinstance(attempt, dict) and attempt.get("error"):
                        errors.append(f"{attempt.get('provider')}: {str(attempt.get('error'))[:160]}")
        providers = sorted(
            {
                str(record["routing"].get("final_provider"))
                for record in matching
                if isinstance(record.get("routing"), dict) and record["routing"].get("final_provider")
            }
        )
        rows.append(
            {
                "label": turn.label,
                "model": turn.model,
                "turn": turn.turn,
                "requests": len(matching),
                "leading_systems": system_counts,
                "statuses": statuses,
                "providers": providers,
                "exit_code": turn.exit_code,
                "wall_ms": turn.wall_ms,
                "errors": errors,
                "output": turn.output[:80],
            }
        )
    return rows


def format_table(rows: list[dict[str, object]]) -> str:
    headers = ["label", "model", "turn", "reqs", "sys", "status", "provider", "exit", "error"]
    lines = [" | ".join(headers), " | ".join("---" for _ in headers)]
    for row in rows:
        errors = row.get("errors") or []
        first_error = str(errors[0]) if isinstance(errors, list) and errors else ""
        lines.append(
            " | ".join(
                [
                    str(row["label"]),
                    str(row["model"]),
                    str(row["turn"]),
                    str(row["requests"]),
                    ",".join(str(value) for value in row.get("leading_systems") or []),
                    ",".join(str(value) for value in row.get("statuses") or []),
                    ",".join(str(value) for value in row.get("providers") or []),
                    str(row.get("exit_code")),
                    first_error,
                ]
            )
        )
    return "\n".join(lines)
