# Qwen Gateway request investigation handoff

## Task and current scope

The user reported intermittent Qwen failures in fx 0.0.10:

> HTTP 400: AI_APICallError: jinja template rendering failed. System message must be at the beginning.

They requested diagnostic logging and this handoff, explicitly requested
response-body dumps, then authorized autonomous investigation. The initial
change only instrumented the native streaming Gateway transport. Subsequent
live A/B experiments reproduced the failure and verified a single-system
workaround. The current edits now also normalize Qwen's leading instruction
block at the Gateway serialization boundary; routing and durable history are
unchanged. See the newest results immediately below.

Starting checkout: `b12296f016173a2dc24ead22a155917e410f30f4` on `main`.
After the investigation and review follow-up, the user requested a pull request,
authorizing a feature branch, checkpoint commit, push, and draft PR. Earlier
verification notes below describe the pre-PR state. Full CI and the ship gate
remain required before review readiness; this work does not authorize merging,
tag creation, or modifying the installed fx binary.

## Adversarial review follow-up

The reasonable review requests have been addressed without changing runtime
normalization behavior:

- Added the deterministic `Qwen Gateway preserves a tool-free saved-session
  continuation` E2E case. It uses the same Qwen model for two saved-session
  invocations, verifies no tool calls, checks session identity and retained
  prompt/reply content, and requires exact role sequences of `system,user` and
  `system,user,assistant,user`. Its fixture rejects multiple systems once
  assistant history exists. Existing tool and model-switch coverage remains.
- Qualified the model-policy rationale: the live evidence is
  `qwen3.8-max`/Fireworks; selecting the whole family is a compatibility policy,
  not a claim that every route has been independently verified.
- Corrected README and CONTRIBUTING: multiple blocks are combined, while zero
  or one stays unchanged. No empty system message is synthesized.

The adversarial reviewer inspected the follow-up and recommended retain-as-is,
with no remaining findings in these deltas. It did not repeat the test runs.

Verification performed after the changes:

- `zig build`: PASS, exit 0.
- The focused Zig command below: PASS, exit 0, 17 tests including four behavior
  tests and 13 discovery blocks.
- New E2E case alone: PASS, exit 0, 67 assertions:

  ```bash
  cd tests/e2e
  FX_E2E_DISABLE_DOTENV=1 bun test ./gateway-stream-lifecycle.test.ts --test-name-pattern 'Qwen Gateway preserves a tool-free saved-session continuation'
  ```

- Full `gateway request tracing` test-name filter below: PASS, exit 0, nine
  tests and 839 assertions.
- Separate direct CLI smoke through the rebuilt `./zig-out/bin/fx`, using a
  local fake Gateway and an isolated synthetic-key HOME: both invocations of
  `ask --json --auto --model alibaba/qwen3.8-max` exited 0 with no signal, empty
  stderr, and no tool calls. The second used `--resume-id` from the first and
  sent `system,user,assistant,user`. Replies were `FIRST_REVIEW_OK` and
  `SECOND_REVIEW_OK`. The smoke wrapper exited 0; temporary state was removed.
  No additional live-provider requests were needed for this review follow-up.

Full CI and the ship gate remain outstanding. Nothing was committed or pushed.

## Autonomous follow-up: reproducible continuation failure and local fix

The agent subsequently ran controlled live tests through the freshly built
`./zig-out/bin/fx`, using the user's existing fx authentication and a private
temporary workspace containing only `note.txt` with `TRACE_NOTE_OK`. No
credentials were read out or printed. Live testing was limited to synthetic
text replies and one allowed read-file operation, with agent step limits.

Artifacts are retained privately in the macOS temporary directory
`fx-qwen-live-2fykctk7`. Each case has a `.log`, `.stdout.json`, and `.stderr.txt`
file. The directory is private and artifact files were set to mode 0600.
Do not publish them. Text-continuation tests also created separate synthetic
saved sessions; their IDs are in the corresponding stdout JSON files.

### Live comparison

| Case | System layout | Observed result |
| --- | --- | --- |
| `text-only` | 7 separate systems | Exit 0, `HELLO_TEST` |
| `one-read` | 7 separate systems | Read succeeds; next model call returns the Jinja HTTP 400, exit 1 |
| `merged-one-read` | 1 combined system | Read and answer succeed, exit 0, `TRACE_NOTE_OK` |
| `baseline-one-read-repeat` | 7 separate systems | Read succeeds; next model call returns the same HTTP 400, exit 1 |
| `merged-one-read-repeat` | 1 combined system | Read and answer succeed again, exit 0, `TRACE_NOTE_OK` |
| `baseline-text-turn-1` | 7 separate systems | Exit 0, `FIRST_TEXT_OK` |
| `baseline-text-turn-2` | 7 separate systems | Saved-session continuation returns the same HTTP 400, exit 1, no tools |
| `merged-text-turn-1` | 1 combined system | Exit 0, `FIRST_TEXT_OK` |
| `merged-text-turn-2` | 1 combined system | Saved-session continuation succeeds, exit 0, `SECOND_TEXT_OK` |

No steering or cancellation occurred in these controlled cases. This rules out
steering as a necessary trigger and shows that tools are not necessary either:
ordinary assistant history is sufficient in this reproduction. Successful and
failed provider metadata identify Fireworks. The merged tool continuation also
reported cache reads, so the workaround does not inherently eliminate provider
prefix caching. This is not a general caching-performance guarantee.

The A/B build temporarily supported `FX_RESEARCH_SINGLE_SYSTEM=1`, joining only
the instruction lane with two newlines between blocks. Its disabled mode was
the baseline. That temporary switch was removed, not shipped. The sessions did
not reuse an identical byte-for-byte generated assistant response, so the
comparison is repeated controlled behavior rather than replay of one frozen
provider request.

### Conclusions and limits

- There is a repeatable Gateway/Qwen continuation-format incompatibility with
  multiple leading system blocks. Initial requests can work, explaining the
  apparently intermittent behavior.
- A single combined leading system message fixes the reproduced tool and
  text-continuation paths. The evidence supports this compatibility projection;
  it does not reveal the exact closed-source Gateway/Fireworks transformation
  responsible for treating initial and continuation histories differently.
- The public AI SDK Fireworks adapter uses its OpenAI-compatible converter. That
  converter preserves system entries in order, joins assistant text/reasoning,
  and expands tool results to tool-role messages; it does not coalesce leading
  systems or insert a system after tool results. Inspected public source at
  commit `6e405ae81b6bbe1b29ba2ece7d8600340ba80b60`:
  [Fireworks provider](https://github.com/vercel/ai/blob/6e405ae81b6bbe1b29ba2ece7d8600340ba80b60/packages/fireworks/src/fireworks-provider.ts),
  [message converter](https://github.com/vercel/ai/blob/6e405ae81b6bbe1b29ba2ece7d8600340ba80b60/packages/openai-compatible/src/chat/convert-to-openai-compatible-chat-messages.ts).
  This public version is not proof of the version or extra transformations
  deployed inside Gateway. Adding that SDK alone is not an established fix.
- Gateway exposing provider identity is documented, not inferred from model
  naming. See its [model fallback metadata documentation](https://vercel.com/docs/ai-gateway/models-and-providers/model-fallbacks).
  The actual logs include `finalProvider` and provider-attempt records.

### Permanent local compatibility change

Owner and contract: `vercel_model_policy.uses_single_system_message(model)`
selects the `alibaba/qwen` family. `buildAgentRequest` constructs a temporary
single-system wire projection from the existing instruction lane, preserving
all contents and their order with `\n\n` separators. It checks the existing
build budget while composing the block. Zero or one instruction is unchanged.
Core instruction arrays, durable conversation history, and non-Qwen layouts
remain untouched, including after model switching. Invalid late systems still
fail validation instead of being promoted into instructions.

No new library, runtime dependency, persistence state, CLI flag, or JSON output
contract was added. This is a small policy and serializer change, not a second
provider layer. The deterministic E2E owner remains the existing PGSO-training
`gateway-stream-lifecycle.test.ts`, now also covering Qwen tools and switches
away from Qwen and back. README and CONTRIBUTING describe the wire policy.

### Verification of the permanent implementation

- `zig build`: PASS, exit 0.
- Focused Qwen unit tests: PASS, exit 0, four behavior tests plus 13 discovery
  blocks, 17 total:

  ```bash
  zig test -lc -O ReleaseSafe --dep build_options -Mroot=src/main.zig -Mbuild_options=.zig-cache/c/9f794cd47824d583f33947bf8e56645e/options.zig --test-filter 'Qwen'
  ```

- Focused native fake-Gateway E2E after review follow-up: PASS, exit 0, nine
  tests, 839 assertions:

  ```bash
  cd tests/e2e
  FX_E2E_DISABLE_DOTENV=1 bun test ./gateway-stream-lifecycle.test.ts --test-name-pattern 'gateway request tracing'
  ```

- Final real-Gateway exercises used the rebuilt binary with no experimental
  flag. `fixed-one-read` returned `TRACE_NOTE_OK`, exit 0, one successful read,
  and only expected read-progress output on stderr. `fixed-text-turn-1` and
  `fixed-text-turn-2` returned `FIRST_TEXT_OK` and `SECOND_TEXT_OK`, both exit 0
  and empty stderr. No process aborted. The final script exited 0.
- The file-read command was:

  ```bash
  ./zig-out/bin/fx ask --json --auto --no-color --model alibaba/qwen3.8-max --no-save 'Use read_file to read note.txt in this workspace, then answer with its one-word content. Use no other tools. Do not modify anything.'
  ```

  It ran from the private fixture workspace with an absolute reference to this
  checkout's binary. Text cases omitted `--no-save` and the second used
  `--resume-id` with its newly created synthetic session. Runtime overrides
  disabled auto-upgrade, sound, and dotenv loading; they enabled gateway/agent
  tracing and sensitive response capture, with `FX_MAX_AGENT_STEPS=3`.
- Full CI, ship gate, and all-platform verification remain NOT RUN. No commit,
  push, tag, or PR was created. Do not call this release-ready.

Remaining research, if needed: correlate the retained request IDs with
Gateway/Fireworks logs to explain the initial-versus-continuation conversion.
The locally verified compatibility fix does not require that private access.

## Earlier live capture: 2026-09-15 15:30 UTC

At the time of this capture, no compatibility fix had been applied. This section
qualified the initial inference that multiple leading system messages always
fail or that Alibaba-versus-Fireworks routing alone explains the intermittence.
The later A/B experiments above narrow this to a continuation incompatibility.

Private artifacts supplied by the user:

- `/trace` report: `fx-trace-2026-09-15-153017-5abda2a23db6.md` in the macOS
  temporary directory.
- Persistent log: `$HOME/.fx/logs/qwen-20260915-082928.log`, discovered in the
  report's `trace_log` field. The report says `FX_TRACE: off`, but the explicit
  `FX_TRACE_LOG` path enabled logging. The new events confirm sensitive body
  capture was enabled and the relevant bodies were not truncated.
- Build: fx 0.0.10, Debug, revision `b12296f01617`, macOS arm64.

The new log contains both a successful Qwen call and the actual failing HTTP
response, not merely quoted conversation text. All Qwen request summaries have
`system_count=8`, `leading_system_count=8`, `first_nonleading_system=none`, and
`roles_omitted=0`. No system message appears after the conversation in the
Gateway payload sent by fx.

| Request ID | Log lines | Request suffix after eight systems | Result |
| --- | --- | --- | --- |
| 2 | 21, 59–73 | user | HTTP 200 stream started, then cancelled by steering |
| 3 | 86, 163, 167 | user, user | HTTP 200, completed tool-calls |
| 5 | 242, 251–260 | user, user, assistant, tool | Cancelled before response headers by steering |
| 6 | 269, 278–282 | user, user, assistant, tool, user | HTTP 400, exact Jinja system-position error |

Request 3 was 59333 bytes / 10 prompt entries; request 6 was 67324 bytes /
13 entries. Both kept eight leading systems. The `tool` entry groups two tool
results on the Gateway wire. This capture follows one active root turn with
steering, not three fully settled independent turns:

1. The user sent `hello`.
2. `what does this repo do` interrupted the first in-flight response. The next
   Qwen response completed with a README read and a shell tool call.
3. After those tools ran, `thanks` interrupted the post-tool model request.
4. fx included that new user message and sent request 6, which failed.

Do not blame the user for steering. The runtime supports this interaction; the
resulting provider request path must handle it correctly. The cancelled
post-tool request has no response, so it does not establish whether a plain
post-tool continuation without steering would succeed or fail.

### Provider evidence and corrected diagnosis

At log line 163, the successful Qwen SSE finish payload has
`providerMetadata.gateway.routing.finalProvider="fireworks"` and one successful
Fireworks provider attempt. At line 281, the HTTP 400 body has one failed
Fireworks provider attempt and the actual message:

> jinja template rendering failed. System message must be at the beginning.

The failed body reports `resolvedProvider="alibaba"`, but that is not evidence
of an Alibaba execution: inspect `modelAttempts[].providerAttempts[]`, which
explicitly records `provider="fireworks"`. No other provider attempt occurred
for that failed request. Success and failure therefore used the same recorded
provider, although internal Fireworks deployment differences are not exposed.

This establishes a real downstream template rejection after a tool/steering
history change, while fx's top-level Gateway role order remains valid. It does
**not** establish the precise transformation or template condition responsible.
The earlier claim that the second leading system alone necessarily causes this
incident was too strong: Fireworks successfully handled a Gateway request with
the same eight-system prefix. Multiple systems may still interact with the
history-dependent conversion and combining them may be a workaround, but this
must be tested, not assumed.

Successful and failed Fireworks request IDs, Gateway generation IDs, and edge
IDs are retained in the private log (lines 163 and 279–281). Use those for
Gateway/Fireworks-side correlation if access is authorized. Do not post the
whole log: it contains unredacted response metadata and model output from other
internal requests too. The OpenAI title and permission-review calls are separate
requests, not Qwen routing fallbacks.

### Next discriminating checks

- Compare Gateway-to-Fireworks messages for request 3 versus request 6 using the
  recorded provider request IDs. The current capture records fx-to-Gateway role
  order, not the downstream serialized messages or deployed template.
- Reproduce a tool loop while waiting for each answer to settle, then repeat
  with steering during the post-tool request. This isolates tool continuation
  from interruption/steering.
- Compare one combined system message versus eight, keeping history and routing
  otherwise equivalent. This is an experiment, not the established fix.
- Inspect the Gateway provider adapter's system-message normalization and tool
  history conversion before adding custom client logic. If necessary, isolate
  provider replay or caching effects with controlled comparisons; neither has
  been demonstrated as the cause.

## Initial evidence before sensitive logging

The user supplied a private `/trace` report named
`fx-trace-2026-09-15-001542-e8718250de59.md` in the macOS temporary directory.
Its contents have not been copied into the repository. Ask for its location if
it is no longer available in the conversation; do not publish the report.

The report identifies fx `0.0.10 (1210c2756ea8)`, ReleaseSafe, macOS arm64.
Its network-call record at line 75 describes a request at
`2026-09-15T00:15:36.923Z`:

- Requested model: `alibaba/qwen3.8-max`.
- Result: HTTP 400 after 828 ms, 1078 response bytes.
- Correlation: turn 10, step 75, parent session.
- Serialized request: 427137 bytes, 61 prompt entries.
- Entries 0 through 7 are separate system messages.
- Entry 8 is user, 9 assistant, 10 user, 11 assistant.
- The remaining 49 entries are omitted by the old summary. The retained summary
  itself is truncated to 512 bytes.

The timeline shows a switch to Qwen followed by the user's `hello` immediately
before this failure. This specific failed request was Qwen, not OpenAI.

Crucial limitations:

- The report does not show that latest 400 response body. Occurrences of the
  Jinja error in the report are the user's earlier pasted error, searches, and
  our discussion. They are not independent evidence of the latest error body.
- `FX_TRACE` was off. There was no persistent event-log tail.
- The recent-network ring retains only 32 calls. There is no successful Qwen
  request body or role summary to compare with the failure.
- The original screenshot switched the displayed model to OpenAI near a Qwen
  failure. A running job retains its captured model while queued work can be
  updated. That could explain the display mismatch, but its exact timing was
  not established.

## Initial working hypothesis, qualified by the latest capture

fx constructs several independent system instruction messages: base rules,
project context, runtime context, permissions, and other enabled instructions.
It puts all of them before the chronological conversation.

A [published Qwen template](https://huggingface.co/Qwen/Qwen3.6-27B/blob/main/chat_template.jinja)
contains this condition:

```jinja2
if message.role == "system" and not loop.first:
    raise_exception("System message must be at the beginning.")
```

That condition rejects the second system message even when every system message
is in a contiguous leading block. This is narrower than fx's current validity
rule. We have not obtained the template actually deployed for
`alibaba/qwen3.8-max` behind the failed Gateway route.

The [Qwen upstream discussion](https://github.com/QwenLM/Qwen3.8/issues/144)
notes that Alibaba's official endpoint supports multiple system messages,
while the published template has the stricter condition. Different provider
routes were initially considered as an explanation. The latest capture instead
records Fireworks for both success and failure with eight leading systems.
The simple multiple-system-count hypothesis is insufficient; investigate the
history-dependent downstream conversion and template behavior.

## Relevant source ownership

- `src/core/agent/runtime/prompt_context.zig`, `buildProviderPrompt`: separates
  instruction messages from chronological history/current user/turn suffix.
- `src/core/agent/runtime/orchestrator.zig`, `appendStablePromptContext`:
  constructs separate system instruction blocks. Runtime overlays are rebuilt
  for requests rather than appended after conversation history.
- `src/builtins/context.zig`, `appendStatic` and `appendTransient`: adds project,
  workspace, permissions, and interactive-verification system messages.
- `src/core/agent/stream_provider.zig`, `validate_prompt_lanes`: instructions
  must be system messages; chronological messages cannot be system messages.
- `src/builtins/gateway.zig`, `buildAgentRequest`: prepends instructions to
  messages and serializes the actual provider payload.
- `src/gateway/vercel_protocol.zig`, `buildGatewayRequestBodyValidated`: rejects
  systems after conversation begins, but allows and separately serializes any
  number of leading systems. These relevant serializers matched the local
  `v0.0.10` tag during the investigation.
- `src/core/session/session_commands.zig`, `setResolvedModelRuntime`, and
  `src/core/agent/worker_runtime.zig`, `syncQueuedPromptModel`: model selection
  and queued-job updates; switching does not rewrite an active job's model.
- `src/core/app/app_commands.zig`: `/trace` exports a private report including
  the recent network ring, transcript, and a bounded tail of an active debug
  log. It is not a full persistent network capture.

## Library reuse and responsibility boundary

The user explicitly asked not to reinvent LLM integration unnecessarily.
Current evidence: `build.zig.zon` has an empty dependency set. The native path
uses `std.http.Client` plus local request serializers and SSE parsing, not an
external LLM client SDK. The Gateway endpoint is
`https://ai-gateway.vercel.sh/v4/ai/language-model`; fx sends the Gateway protocol,
not a Qwen Jinja template. The template failure occurs downstream of fx.

This diagnostic change reuses the existing trace logger and HTTP/SSE path. It
does not introduce another provider abstraction, HTTP client, or SDK. Before
implementing a compatibility workaround, determine whether Gateway already
normalizes system-message blocks, whether routing selects providers with
inconsistent normalization, and whether an upstream Gateway/provider fix is the
correct owner. If broader client changes are needed, evaluate reusable client
or protocol support against the Zig/native constraints before extending custom
integration code. No SDK ecosystem evaluation has been performed yet; do not
claim a suitable library does or does not exist without researching it.

## Existing GitHub work

These states were checked during this investigation; recheck before updating
issues or basing new work on them.

- [fx #109](https://github.com/vercel-labs/fx/issues/109), open: the same Qwen
  error text, originally reported against fx 0.0.3. Not the exact reproduction
  above and not a confirmed diagnosis.
- [fx PR #376](https://github.com/vercel-labs/fx/pull/376), closed without merge:
  proposed making system messages contiguous and strictly leading, explicitly
  targeting #109. Closure cites superseding work at `a0b3937`.
- [fx PR #630](https://github.com/vercel-labs/fx/pull/630), merged: provider
  recovery/history ordering fixes, including `479bd254`. It separates
  instructions from conversation; it does not combine multiple leading systems.
- [fx PR #657](https://github.com/vercel-labs/fx/pull/657), merged: work associated
  with `a0b3937`. Its superseding relationship is not proof the stricter
  single-system-template compatibility issue is fixed.

No issue or PR was created or commented on. Bounded searches found no explicit
fix for collapsing the multiple leading systems in this reproduction.

## Instrumentation added

Owner: `src/gateway/request_trace.zig`, with calls in
`src/gateway/client.zig`. The `Attempt` value is stack-owned; no headers or
response data escape their transport lifetime. `src/main.zig` only adds test
module discovery, not feature logic.

Enabled by existing `FX_TRACE_LOG` (or `FX_TRACE=1`) and the `gateway` scope:

- `request_shape`: per-attempt process-local `request_id`, attempt number,
  actual requested model, serialized bytes, total prompt/system/leading-system
  counts, first nonleading system index, invalid role count, and role sequence.
  The first 512 roles are shown; `roles_omitted` is explicit. Counts scan the
  whole prompt. Unknown roles never become arbitrary log text.
- `response_headers`: response HTTP status, before body consumption.
- `response_id`: only `x-request-id`, `request-id`, and `x-vercel-id`. Header
  matching is case-insensitive; the first occurrence is used. Values are
  limited to 128 bytes and a safe token character set, otherwise `omitted`.
  `x-vercel-id` is an edge correlation ID, not proof of a provider backend.
- `request_outcome`: status, transport outcome, finish reason, internal error
  name, body size, and a fixed error category. The category scans at most
  64 KiB for known template-error text; it is a diagnostic hint, not an
  authoritative provider error code. `completed` means transport/SSE decoding
  completed; inspect `finish_reason` rather than treating every HTTP 200 as a
  successful model answer.

Parsing and capture are gated before diagnostic work. Failures to allocate or
write diagnostics do not replace the product request's result. Request IDs are
process-local, so keep files from different launches separate.

### Sensitive response dumps requested by the user

`FX_TRACE_GATEWAY_BODIES=1` additionally enables `response_body` events. It does
nothing without enabled Gateway tracing.

- Non-200 HTTP response bodies are dumped after collection.
- For HTTP 200 streams, each consumed SSE data payload is dumped before JSON
  parsing, including malformed payloads. This is not wire framing or a dump of
  data that the parser never consumes after completion.
- Dumps deliberately preserve provider text and metadata, including any echoed
  prompts, secrets, model output, and tool arguments. Control bytes are escaped
  by the shared trace logger, not silently removed or semantically redacted.
- Payload capture is limited to 256 KiB total per attempt, in chunks of at most
  2048 source bytes. Correlation, body-event index, aggregate offset, event
  offset, and original event size accompany chunks. Outcomes report seen/logged
  byte totals and truncation. Text escaping can make the log larger than the
  source payload limit.
- Request payloads and arbitrary response headers are never directly dumped.
  An echoed request inside an opted-in response can nevertheless expose it.
- Existing HTTP error-body transport collection remains unbounded; this change
  bounds diagnostic output, not the existing transport buffer.
- Native streaming requests are covered. Catalog GETs, non-streaming fetches,
  and JavaScript-host transports are outside this instrumentation.

No new persisted session state, public CLI flag, or JSON product-output schema
was introduced. README and CONTRIBUTING document the opt-in and privacy limits.

## Reproduce with the local build

Do not use an installed `fx` from PATH. From this checkout:

```bash
zig build
(
  umask 077
  export FX_TRACE_LOG="$HOME/.fx/logs/qwen-$(date +%Y%m%d-%H%M%S).log"
  export FX_TRACE_SCOPES=gateway,agent,worker,session
  export FX_TRACE_STDERR=0
  export FX_TRACE_GATEWAY_BODIES=1
  ./zig-out/bin/fx
)
```

Select Qwen, reproduce a successful first turn if possible, then a failed
continuation. Run `/trace` immediately afterward, and retain the original event
log too: the report contains only a short tail. Avoid unrelated tasks while
capturing. Keep all logs local and private; review before any sharing.

Find `request_shape` for the actual model, then correlate `response_headers`,
`response_id`, `response_body`, and `request_outcome` by `request_id`, plus the
turn/step/subagent fields. Prefer the recorded response body over an earlier
quoted error in conversation. Note whether a system appears after conversation,
whether there are multiple leading systems, and whether success and failure
share the same structural shape. Use returned response IDs with Gateway-side
logs if authorized; do not infer provider identity from an edge ID.

Unset `FX_TRACE_GATEWAY_BODIES` after testing. Do not upload or commit raw logs.

## Verification and follow-up

The initial environment lacked Zig and Bun; with user authorization Homebrew
installed Zig 0.16.0 and Bun 1.4.2. No application dependencies were added.

Local verification on the edited checkout:

- `zig build`: PASS, exit 0, native Debug binary.
- Focused Zig tests: PASS, exit 0, 21 tests total: seven module tests, one
  transport retry-correlation regression, and 13 test-discovery blocks. The
  command used was:

  ```bash
  zig test -lc -O ReleaseSafe --dep build_options -Mroot=src/main.zig -Mbuild_options=.zig-cache/c/9f794cd47824d583f33947bf8e56645e/options.zig --test-filter 'gateway request trace'
  ```

  The options path is generated locally by the build and may change in another
  checkout. Use the native `build_options` path from `zig build` output rather
  than assuming this cache file exists elsewhere. The test module is explicitly
  registered in the root test-discovery block; the first earlier filtered run
  found only discovery blocks and was not counted as diagnostics verification.

- Focused E2E: PASS, exit 0, seven cases, 705 assertions, no failures:

  ```bash
  cd tests/e2e
  FX_E2E_DISABLE_DOTENV=1 bun test ./gateway-stream-lifecycle.test.ts --test-name-pattern 'gateway request tracing'
  ```

  Keep the `./` prefix: without it Bun also selects the similarly named TUI file.
  An initial assertion incorrectly required empty stderr for a tool execution;
  it now checks the exact expected full-access notice and file-read progress.

- Separate direct CLI smoke: PASS, wrapper exit 0. A local fake Gateway and an
  isolated synthetic-key HOME were used to launch the freshly built binary
  twice with `./zig-out/bin/fx ask --json --auto --no-save hello` (absolute binary
  path when cwd was the isolated workspace), both times with response dumps on.
  Success returned `MANUAL_TRACE_OK`, exit 0, no signal, empty stderr, status 200,
  finish reason `stop`, 190 captured payload bytes, and `manual-success-id`.
  The controlled error returned exit 1, no signal, only the expected HTTP 400
  diagnostic on stderr, category `system_message_not_first`, 95 captured body
  bytes, and `manual-error-id`. Neither process aborted. The first smoke wrapper
  incorrectly required empty stderr for the error too; the corrected run checks
  its exact expected diagnostic. Temporary fixtures/logs were removed.
- At the end of the initial logging-only phase, the agent had run only local
  fake-Gateway checks. Subsequent user capture and agent-run live A/B tests are
  documented at the top of this handoff; they supersede that earlier limitation.
- Full CI and ship gate: NOT RUN. No commit, push, or PR was created.

- `zig fmt --check src/`: PASS, exit 0.
- `git diff --check`: PASS, exit 0.
- After the retry-correlation repair and final rebuild, a separate direct
  `./zig-out/bin/fx ask --json --auto --no-save hello` smoke against the local
  fixture again passed: exit 0, no signal, empty stderr, `FINAL_TRACE_OK`,
  `final-smoke-id`, 189 captured SSE payload bytes, and no truncation.

Review caught and repaired an outcome gap: connection-setup and response-head
retries now preserve the triggering transport error before `continue`. A new
real-loopback test injects one setup failure, then succeeds, requiring two
separate request IDs and the correct outcome for each attempt. Further optional
coverage includes mid-stream socket failure/cancellation and unread SSE tails.

Tests added:

- Zig unit tests in `request_trace.zig`: role ordering and bounds, malformed
  input, privacy defaults, error classification, token safety, scope gating,
  header allowlisting, and nonfatal summary allocation failure. The additional
  transport regression in `client.zig` exercises failed-setup retry correlation.
- The `gateway request tracing` block in
  `tests/e2e/gateway-stream-lifecycle.test.ts`: actual built-binary HTTP requests,
  tool-loop roles, response IDs, default privacy, opted-in HTTP/SSE dumps,
  chunk limits, scope gating, and resumed model changes.

The E2E file remains PGSO training: it owns common Gateway runtime behavior.
New tests inherit that classification. No new root E2E file was created.

Current next step: the single-system compatibility fix is implemented and
locally verified, including live Qwen tool and text continuations. Optional
upstream research can use the retained IDs to explain the downstream template
behavior; the public SDK converter alone did not explain the distinction.
Do not discard instruction content or alter durable history as an alternative
workaround, and do not claim identical downstream messages without observing
the Gateway's provider-facing serialization.

Full CI for the exact checkpoint commit and the ship gate remain required before
release readiness. The user subsequently authorized creating a draft PR; the
local and live passes alone are not a release-ready claim.
