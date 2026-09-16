# Gateway compatibility matrix

Drives a built `fx` binary through the same multi-turn conversation against a list of
Vercel AI Gateway models, with a loopback proxy between fx and the Gateway. For every
request it records the prompt role sequence, the number of leading system messages,
the upstream HTTP status, the route the Gateway chose (`finalProvider`), and any error
body. The result is wire evidence for questions like "which routes reject this prompt
layout?" or "does the fixed binary still send what we expect?".

This is a manual investigation tool. It is not part of `zig build test` or CI, and
every turn costs real Gateway requests billed to the signed-in account. fx also fires a
small title-generation request on the first turn of each session; the summary excludes
those by matching the `ai-language-model-id` header to the model under test.

## Usage

Build fx, then run:

```bash
python3 -m scripts.gateway_matrix --fx zig-out/bin/fx --label main \
  --model alibaba/qwen3.8-max --model moonshotai/kimi-k3
```

The default script is three turns: a text reply, a `read_file` tool call against
`note.txt` in the workspace (which exercises a post-tool continuation), and another text
reply. Override with repeated `--prompt` flags. To compare two builds, run twice with
different `--label` values and the same `--out` directory.

Output goes to `zig-out/gateway-matrix/` by default (already gitignored):

- `captures/requests.jsonl`: one record per request with tag, model header, roles,
  system counts, status, duration, route and error.
- `captures/req-NNN-<tag>.json` and `captures/resp-NNN-<tag>.txt`: raw bodies.
- `captures/ask-<tag>.json|.stderr`: `fx ask --json` output per turn.
- `summary-<label>.json`: the rows printed as the table.

Authentication uses whatever fx already has (stored login or `AI_GATEWAY_API_KEY`).
The proxy forwards the `Authorization` header and never writes it to disk. fx only
honours `FX_E2E_GATEWAY_CHAT_URL` for loopback addresses, which is why the proxy binds
`127.0.0.1`.

## Reading results

- `sys` is the set of leading-system-message counts seen across the turn's requests.
- `status` lists upstream statuses per request; a tool turn has two requests.
- `provider` is the Gateway's `finalProvider`; a 400 from the route shows up in `error`
  as `<provider>: <message>`.
- Models the account cannot use return 403 `no_providers_available` on turn 1 and skip
  the remaining turns.

Unit tests for the parsing and formatting helpers:

```bash
python3 -m unittest scripts.tests.test_gateway_matrix -v
```
