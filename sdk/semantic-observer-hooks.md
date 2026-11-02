# Semantic observer hooks

libfx exposes execution facts to host-owned instrumentation through `hooks`.
See [the SDK contract](README.md#instrumentation-hooks) for usage and
`sdk/types/libfx.d.cts` for event types.

The JavaScript host owns trace topology, span names, attribute conventions,
capture policy, and export. fx doesn't depend on a tracing library, an
OpenTelemetry SDK, or a collector.

## Separate observation from control

`src/core/hooks/hooks.zig` already owns product hooks such as `PreToolUse` that
can modify or reject work. Instrumentation must not reuse that control contract.
The existing SDK `onEvent` reports diagnostics, and turn iterators report UI
output. Neither is a complete semantic execution stream.

`src/core/agent/runtime/observation.zig` defines the optional borrowed typed sink.
`src/acp/libfx_hooks.zig` projects safe fields onto versioned `libfx/hook`
notifications. Both native and Wasm libfx use that same adapter. The JavaScript
host dispatches them through `hooks.onEvent`; disabled hooks don't serialize or
send semantic events. The standalone CLI doesn't install an observer sink.
An ACP host can opt in on `session/new`, `session/load`, or `session/resume`
through `_meta.fx.hooks`, with the same capture option and event protocol. The
response confirms hooks version 1; omitting the option on a new/load/resume
request disables hooks, including a reload of the active session. This doesn't
change ACP permission policy.

Clients should wait for the prompt response before creating, loading, or resuming
another session. A parent observer captures its setting at prompt start; native
children read the active session's setting when they start. Reconfiguration
during ongoing work isn't an atomic change to the whole parent/child tree.

## Event contract

The envelope carries a protocol version, epoch timestamp, session ID, logical
turn ID, worker execution ID, and execution-local step ordinal. Model-call IDs
are unique within the execution, including retries. Authoritative tool call IDs
link execution and results to the issuing `model.end`. These aren't span IDs.

| Family | Facts reported |
| --- | --- |
| Turn | Start or resume; input; execution disposition; handoff annotation from the host |
| Step | Execution-local ordinal; entry and exit, without claiming successful completion |
| Model | Provider/model, purpose, request messages/instructions/tool definitions, streaming milestones, response metadata, finish reason, usage, and error |
| Tool | Authoritative call ID, arguments, execution start/result/error, conversation acceptance, and explicit rerun flag |
| Permission | Whole admission evaluation and its decision/error, not an inferred human wait |
| Input wait | Actual approval/question/MCP form or URL request, owning call, request identity, bounded content, and outcome |
| MCP | Configured server and original tool/action, owning call, transport/correlation identity, and terminal status |
| Delegation | Accepted dispatch, child session and durable work ID, replay/yield/completion/cancellation |
| Persistence | Restored position and open turn; validated append cursor and sequence range; failure/fencing |

The main model, compaction, review, vision, and title paths report distinct
purposes without synthesizing user turns for auxiliary calls. Review retries
have separate model-call IDs. Title tasks borrow an observer only while their
owner guarantees a join before releasing it. MCP instrumentation stays in fx's
host boundary; the isolated MCP engine has no tracing imports.

Native child runtimes allocate a fresh execution observer and carry the existing
durable message/work identity. They don't retain a pointer to a parent's
turn-scoped observer. Host-created JavaScript children receive the equivalent
parent relationship through `context.observation.childHooks()`.

## Lifecycle and durability rules

- Execution starts, returned results, and accepted durable results are distinct
  phases. An event emitted before a write is not proof that the write committed.
- libfx's persistence owner reports append acceptance only after its existing
  `append()` resolves with a valid cursor. A fenced write isn't accepted work.
- Restore and replay are explicit. Loading a completed call must not present it
  as a newly executed call. A permitted rerun retains the logical call ID and
  gets a distinct attempt identity.
- Yield, handoff, worker deadline, and fencing don't imply a failed logical turn.
  A consumer can keep that invocation open and continue it on another worker.
- Observers don't own scheduling, permission decisions, replay policy, or the
  durable journal. They must not create a second session or effect log.
- Native event slices are borrowed for the callback. A retaining consumer copies
  them. SDK callback payloads are detached from mutable execution state.
- Callback failures are contained and reported through a separate observer-error
  channel. They never replace application values/errors, cause a tool/model call
  to run again, or become an unhandled rejected promise.
- Per-operation ordering is defined; concurrently executing tools need not have
  a total execution order. Durable acceptance follows the journal's order.
- Content is opt-in. Request headers, credentials, opaque provider replay state,
  and raw image bytes aren't observation payloads. Content limits and omission
  markers are explicit; a consumer's export policy is not a permission policy.

## Proof and remaining boundaries

`sdk/tests/test-hooks.mjs` drives real native and Wasm engines through parallel
tools, errors, content limits, observer failures, durable yield/resume, and fenced
appends. `sdk/tests/test-types.mjs` checks the public types across Node, CommonJS,
browser, and explicit Wasm entry points. The gateway unit fixture exercises model
start/end pairing through success, transport failure, and cancellation.

The focused ACP fixtures exercise real command approval, MCP calls and
elicitation, and native child execution. Core fixtures cover question outcomes,
review retries, title generation, and batched vision calls. SDK fixtures cover
host-owned input effects, MCP correlation, and child engines on both backends.

The host still owns span topology, asynchronous export, and any trace-state
recovery. No trace continuation state, durable export outbox, or tracing package
is added to fx or its checkpoint format. The standalone CLI doesn't configure
a sink or collector; native runtime consumers can install the typed sink.
