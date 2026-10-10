# fx report server

A minimal receiver for fx remote reports. fx sends one report per process when `FX_REPORT_URL` is set. See [Remote reports](../../README.md#remote-reports).

## Run

```bash
bun apps/report-server/server.ts
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `8787` | Listen port |
| `HOST` | `127.0.0.1` | Listen address. Set `0.0.0.0` to accept remote clients. |
| `REPORT_DATA` | `./data/reports.jsonl` | Append-only report store |
| `REPORT_TOKEN` | unset | When set, every `/v1` route requires `Authorization: Bearer <REPORT_TOKEN>` |

Point fx at it:

```bash
FX_REPORT_URL=http://127.0.0.1:8787/v1/reports FX_REPORT_TOKEN=<token> fx
```

## API

| Route | Description |
| --- | --- |
| `POST /v1/reports` | Store one report (schema 1). Returns `201`. |
| `GET /v1/reports?limit=N` | Most recent reports first. Default 50, max 500. |
| `GET /v1/summary` | Totals by fx version and platform, plus per-model and per-tool call counts, failures, outcomes, and avg/p50/p95/max durations. |
| `GET /health` | Liveness, no auth. |

## Report shape

```json
{
  "schema": 1,
  "run_id": "9f2c41a07be3d815",
  "fx_version": "0.0.8",
  "commit": "abc1234",
  "os": "macos",
  "arch": "aarch64",
  "sent_at_ms": 1791158400000,
  "dropped_network": 0,
  "dropped_tools": 0,
  "network": [
    {
      "kind": "gateway",
      "started_at_ms": 1791158399000,
      "duration_ms": 812,
      "status": 200,
      "response_bytes": 2048,
      "input_tokens": 1200,
      "output_tokens": 80,
      "web_search_requests": 0,
      "subagent": false,
      "model": "anthropic/claude-sonnet-4.6",
      "error": "",
      "stop_reason": ""
    }
  ],
  "tools": [
    { "name": "read_file", "outcome": "succeeded", "started_at_ms": 1791158399500, "duration_ms": 3, "subagent": false }
  ]
}
```

fx buffers up to 256 model calls and 256 tool calls per process. Events past that limit are counted in `dropped_network` and `dropped_tools`.

The end-to-end test lives in `tests/e2e/remote-report.test.ts`.
