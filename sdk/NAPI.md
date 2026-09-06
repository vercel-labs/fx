# N-API core implementation

This document describes the internal design of the native Node-API backend used by `libfx`, including its trust boundaries, lifecycle, resource limits, and security invariants. It is maintainer documentation, not part of the supported user-facing API.

## Scope

The native addon implements only the headless core surface. It does not implement a native terminal and it does not duplicate the JavaScript agent API.

The relevant ownership boundaries are:

| Concern | Owner |
| --- | --- |
| Native addon entry point and ACP transport | `src/napi_core_main.zig` |
| Shared ACP server and agent behavior | `src/acp/` |
| Node backend discovery and adaptation | `sdk/node.js` |
| Public JavaScript agent implementation | `sdk/fx-sdk.js` |
| Native build configuration | `build.zig` |
| npm artifact assembly | `sdk/scripts/package-libfx.mjs` |
| Native regression and security tests | `sdk/tests/test-native-core-*.mjs` |

The architecture deliberately reuses the same ACP client and event translation used by the WebAssembly backend. The addon is a native byte transport around the existing ACP server, not an independently maintained agent implementation.

## Architecture

The data path is:

```text
JavaScript createFxAgent()
        |
        v
sdk/node.js selects native backend
        |
        v
createCore(options) in libfx.node
        |
        v
Zig Runtime thread runs acp_server.runWithTransport()
        |
        +---- InputQueue  <---- writeCore(handle, Buffer)
        |
        +---- OutputQueue ----> drainCore(handle)
        |
        +---- FetchBridge <----> sdk/node.js fetch + AbortController
        |
        v
newline-delimited ACP JSON-RPC
        |
        v
shared createFxAgent() logic in sdk/fx-sdk.js
```

`sdk/node.js` supplies a `runtimeFactory` to the shared JavaScript agent implementation. The factory exposes the same small runtime contract expected from the WebAssembly host:

- `write(data)` sends ACP bytes to the addon.
- `closeStdin()` closes the ACP input stream.
- `setLineHandler(handler)` receives parsed ACP messages.
- `exited` settles when the native runtime exits.
- `abort()` aborts Node fetch and closes native input.

Each core has one nonblocking Unix socketpair for readiness. The adapter takes ownership of the reader with `takeCoreReadyFd()` and watches it through `node:net`; Bun adopts the descriptor through `connect()`. The native writer signals when a fetch request becomes pending, output changes from empty to non-empty, or the core exits. Wake bytes carry no state: JavaScript drains the bounded fetch and output queues to quiescence and then checks exit state. While a body pump exists it calls `coreFetchActive()` for that fetch handle. An inactive handle aborts its matching `AbortController` on the next readiness event. ACP output is accumulated to newline boundaries and parsed as JSON. Gateway requests are transferred to Node as bounded request records; Node runs the configured `fetch`, streams bounded response chunks back to Zig, and owns the `AbortController`. This matches the WebAssembly host-fetch boundary and ensures the N-API core never uses the native `std.http` Gateway transport.

The shared JavaScript Agent wrapper emits bounded `transport.start`, `transport.response`, and `transport.error` diagnostics around that host-owned fetch. It allowlists request, generation, model, provider, status, attempt, endpoint, and elapsed-time fields rather than exposing credentials or arbitrary headers.

The shared Agent checks its current turn's cancellation state before invoking host fetch. A request published after cancellation is aborted through the existing runtime boundary, so an earlier idle abort cannot leave the cancelled turn waiting for a response.

The native kernel installs host-stream and host model-catalog providers. It does not inherit CLI billing reconciliation, credits, search, or compaction providers. Token usage comes from the response stream; generation metadata must not trigger native HTTP requests outside the host's fetch function.

## Native module ABI

`napi_register_module_v1` exports a deliberately small low-level interface:

| Export | Purpose |
| --- | --- |
| `libfxApiVersion` | Checks compatibility with the JavaScript loader. Currently `3`. Low-level `createCore` backends must declare this exact version. |
| `createCore(options)` | Allocates a runtime and readiness socketpair, then starts its ACP thread. |
| `takeCoreReadyFd(handle)` | Transfers the readiness reader descriptor to JavaScript exactly once. The caller owns its close. |
| `writeCore(handle, buffer)` | Appends bytes to the bounded input queue. |
| `closeCore(handle)` | Closes input and wakes a blocked ACP reader. |
| `drainCore(handle)` | Returns up to 1 MiB of queued output as a Node Buffer. |
| `takeCoreFetch(runtime)` | Takes the pending bounded Gateway request, including its positive `fetchHandle`, for Node-owned fetch. |
| `coreFetchActive(runtime, fetchHandle)` | Reports whether that request may still receive host response operations. |
| `startCoreFetchResponse(runtime, fetchHandle, status)` | Publishes the matching fetch response status. |
| `pushCoreFetchResponse(runtime, fetchHandle, buffer)` | Appends a bounded matching response chunk. |
| `finishCoreFetch(runtime, fetchHandle)` / `failCoreFetch(runtime, fetchHandle)` | Completes only the matching host stream successfully or with transport failure. |
| `abortCoreFetch(runtime)` | Aborts the current fetch and wakes the Zig worker. Idle calls do not cancel a future fetch; ACP owns turn cancellation. |
| `coreExited(handle)` | Reports whether the ACP thread has exited. |
| `coreExitCode(handle)` | Returns the ACP thread's numeric exit status. |
| `destroyCore(handle)` | Closes input, joins the thread, and releases native memory. |

This ABI is internal. Consumers should use `createFxAgent()` from `sdk/node.js`; exposing the primitive functions keeps the native boundary small and testable.

The addon ABI version is independent of the public JavaScript API version, which remains `2`. Only low-level core addons must declare version `3`.

Response operations return numeric outcomes: `0` means the operation was stale and ignored, `1` means it was applied, and `2` means a response push encountered bounded backpressure. Stale callbacks never mutate a newer fetch. The addon does not write ambient diagnostics for these outcomes; the JavaScript adapter observes the numeric result and owns any explicit host reporting.

Each handle is a JavaScript object wrapped around a `RuntimeHandle`. It is branded with `napi_type_tag` and checked before every operation. A structurally similar object cannot be substituted for a real handle. The wrapper owns a finalizer, so garbage collection invokes the same destruction path as explicit `destroyCore()`.

`RuntimeHandle.runtime` becomes null during destruction. Later operations fail with `LIBFX_NATIVE_CLOSED`, and repeated destruction is harmless.

## Runtime lifecycle and concurrency

Creating a core performs these steps:

1. Atomically reserve one of 64 process-wide runtime slots.
2. Read and copy bounded configuration strings from the JavaScript options object.
3. Validate the Gateway endpoint.
4. Allocate a `Runtime` and bounded fetch bridge using Zig's C allocator.
5. Spawn one native thread.
6. Run `acp_server.runWithTransport()` on that thread using callback-backed ACP queues and the shared host-stream provider.

The runtime thread never reads or mutates JavaScript values or calls Node-API. It blocks on the fetch bridge while Node owns `fetch`, response-body iteration, and `AbortController`. Queue state remains authoritative when readiness writes coalesce. An environment cleanup hook shuts down and joins every runtime, including worker termination. Explicit destruction unregisters that hook. Destruction marks the bridge shutting down, wakes every wait, joins the runtime thread, and then closes the readiness writer and any unclaimed reader before freeing native memory. The JavaScript adapter destroys its reader socket and waits for its close before settling `exited`.

The addon initializes one process-wide `std.Io.Threaded` instance. Atomic state protects one-time initialization when the addon is loaded in multiple Node worker environments. The same initialization installs inherited process-environment access before any runtime thread starts. It does not configure fx product tracing from ambient `FX_TRACE_*` variables; libfx remains silent unless its JavaScript host explicitly requests SDK observability.

Input and output queues have independent `std.Io.Mutex` protection and condition variables. The ACP reader sleeps while input is empty. An output writer fills available byte capacity, then sleeps until JavaScript drains space. The JSON-RPC writer lock preserves record ordering across these partial writes. Closing the core closes both queues and wakes their waiters before joining the native thread.

Readiness has no callback queue or pending flag. A full socket already contains a wake, so a nonblocking `EAGAIN` needs no retry. Other write failures shut down the writer so the reader observes EOF and fails the runtime instead of hanging. Writes suppress `SIGPIPE`, and descriptors are close-on-exec. This avoids depending on a thread-safe-function dispatcher's drain/idle race.

The runtime handle has a separate mutex that serializes access to the runtime pointer against destruction. Destruction removes the pointer first, then closes input and joins the thread. No runtime allocation is freed while its thread is still running.

The implementation supports:

- multiple runtimes in one Node environment;
- loading and using the addon from multiple Node worker threads;
- garbage collection of abandoned handles;
- worker termination while a runtime has an active request.

These cases have dedicated tests. Any lifecycle change must preserve all four.

## Capability profile

The native core is intentionally more restricted than the native `fx` CLI. Its ACP server configuration sets:

- `allow_native_tools = false`;
- `allow_acp_mcp = false`;
- the background process provider to unavailable;
- the secret store to unavailable;
- file listing and reading limits to zero;
- command output limits to zero.

As a result, the model receives no native tool advertisement, cannot launch commands, cannot read workspace files through fx tools, cannot start ACP-provided MCP servers, and cannot access the native secret store. `home` and `workspaceRoot` still provide identity and session context to shared ACP code, but they do not grant a tool capability by themselves.

Agent creation does not fetch the model catalog. When a prompt needs model capabilities or context capacity, the shared resolver obtains the catalog through the supplied host fetch and caches its metadata for that agent. Initial model-visible system context comes only from the host's explicit `instructions`, including text assembled by the MCP and skills adapters.

Host-stream requests do not opt into the Gateway extended-time header. Live paired testing showed that header caused a recurring multi-second pre-header tail for embedded requests. Session identity and affinity headers remain enabled. The shared JavaScript fetch edge retries a thrown host transport error at most once, before any response reaches the Agent. Cancellation prevents the retry, and a second failure keeps the existing rejection behavior.

This restriction is a security boundary. New tools or host effects must not be enabled merely because the code is running natively. Every new capability needs a typed boundary, permission analysis, explicit configuration, and native security coverage.

## Gateway endpoint policy

The Gateway URL is validated independently in JavaScript and Zig. This duplication is intentional defense in depth because callers can load and call `libfx.node` directly, bypassing `sdk/fx-sdk.js`.

Accepted endpoints are:

- the exact canonical production Gateway URL; or
- explicit HTTP on `127.0.0.1`, `localhost`, or `[::1]`, with a port.

URLs with embedded credentials or fragments are rejected. Arbitrary HTTPS hosts, non-loopback HTTP hosts, and other schemes are rejected. Loopback HTTP exists only for local development and deterministic tests.

Keep the validation in `sdk/fx-sdk.js`, `src/napi_core_main.zig`, and `streamable_http.validateEndpoint()` aligned. Loosening only one layer creates inconsistent behavior and may create a server-side request forgery path for callers using the low-level addon directly.

## Resource limits and backpressure

All untrusted values crossing the native boundary are bounded before allocation or queueing:

| Resource | Limit |
| --- | ---: |
| API key | 64 KiB |
| Model identifier | 1 KiB |
| Home path | 16 KiB |
| Workspace path | 16 KiB |
| Gateway URL | 16 KiB |
| Input queue | 8 MiB |
| Output queue | 8 MiB |
| Encoded output message | 64 MiB |
| Fetch request body and serialized metadata | 8 MiB before body base64 encoding |
| Fetch request record | 11,184,812 bytes including body base64 encoding |
| Fetch response queue | 8 MiB |
| Gateway error body | 1 MiB |
| One output drain | 1 MiB |
| Active runtimes | 64 per process |
| ACP tool result | 64 KiB text; 8 MiB tagged rich result |
| ACP history | 100 turns |
| Agent steps | 64 |

The fetch request budget covers the full model request, including retained history and metadata. Its base64 transfer frame has a separate derived bound; accepting one tool result does not reserve space for later requests.

Host tool responses must also fit the 8 MiB input bound after JSON framing, including the trailing newline. A response that exceeds this bound becomes a small tool error so the model can continue and the agent remains usable.

Input overflow fails synchronously with `LIBFX_NATIVE_BACKPRESSURE`. Output queue pressure blocks the writer until space is available; a single message does not need to fit the queue. Allocation failure or an oversized output message permanently fails the output transport, notifies JavaScript, closes input, and shuts down host fetch. Later writes cannot publish a successful response after that failure.

The JavaScript adapter has one ordered output drain. A shared byte-framing parser preserves UTF-8 characters across native drain boundaries, rejects malformed or oversized records, and waits for SDK event admission before consuming another message. Readiness still services fetch cancellation while output is blocked. The unread event queue applies the same limits and cancellation rules on native and WebAssembly backends. Cancelling a turn releases event admission and discards subsequent cancelled-turn updates while transport framing continues, so the next turn starts on a complete record boundary. Destroying the runtime closes output before joining, including worker cleanup without an active JavaScript reader.

## Argument and handle safety

The native boundary treats all JavaScript values as untrusted:

- Required argument counts are checked before access.
- Configuration properties must have the expected JavaScript type.
- Strings are length-checked before allocation.
- `writeCore()` requires a Node Buffer.
- Runtime objects require the private N-API type tag.
- Closed handles fail instead of dereferencing released memory.
- JavaScript getter and Proxy exceptions are preserved rather than replaced with misleading native errors.
- Partial construction uses cleanup paths that release the runtime slot and every successful allocation.

Do not replace the tagged wrapped object with a numeric pointer, externalized address, or other forgeable handle representation.

## Secret handling

The API key is copied from the JavaScript string into native heap memory and passed as an in-memory credential override. It is not read from process-global environment state, written into generated package artifacts, or intentionally logged. Per-runtime overrides also avoid mutating environment variables shared by concurrent runtimes and workers.

The copied key remains resident for the runtime lifetime and is freed during destruction. The allocation is not currently zeroized before free. Code handling diagnostics, crash reports, heap inspection, or allocator changes must treat this memory as sensitive. A future zeroization change should cover all destruction and partial-construction paths and must not be optimized away.

## Native code trust boundary

A `.node` addon is executable native code loaded into the Node process. N-API provides ABI stability, not sandboxing. A compromised or substituted addon has the full authority of the host process regardless of the fx capability restrictions described above.

Consequently:

- only package-produced addons should be selected automatically;
- callers that pass `nativeAddon` explicitly are choosing to execute that module;
- artifact naming and assembly must not accept unexpected platform files;
- publishing must preserve provenance and use the exact tested artifacts;
- addon load failures must not be mistaken for a safe sandbox boundary.

The JavaScript loader searches for `libfx.node` first for local development, then `libfx.<platform>-<arch>.node` for packaged builds. It validates `libfxApiVersion` and the expected export shape before use. `backend: "native"` fails closed if a compatible addon is unavailable. `backend: "auto"` may fall back to WebAssembly when JSPI is available.

## Build and packaging

The build is enabled with:

```sh
zig build -Dnapi-surface=core -Doptimize=ReleaseSafe
```

`addNapiArtifact()` builds `src/napi_core_main.zig` as a stripped dynamic library, links libc, includes `node_api.h`, allows unresolved shared-library symbols for Node to resolve, and installs the artifact as `zig-out/lib/libfx.node`.

The N-API artifact currently forces `ReleaseSafe` in `build.zig`; the command-line optimization value does not change that module's mode. Retaining safety checks is intentional for code processing untrusted JavaScript and protocol input.

Published packages contain one addon for each supported tuple:

- `linux-x64`;
- `linux-arm64`;
- `darwin-x64`;
- `darwin-arm64`.

`package-libfx.mjs` requires exactly those four names when assembling a publishable multi-platform package. It rejects missing, duplicate, or unexpected addon names. The publish workflow builds and tests each addon on its native runner before combining the artifacts with both WebAssembly surfaces, the README, and the Apache-2.0 license.

## Error model

Native errors use stable codes where JavaScript needs to distinguish failure classes:

| Code | Meaning |
| --- | --- |
| `LIBFX_INVALID_ARGUMENT` | Missing, mistyped, oversized, invalid, or forged input. |
| `LIBFX_NATIVE_LIMIT` | The process-wide runtime limit was reached. |
| `LIBFX_NATIVE_BACKPRESSURE` | The bounded input queue cannot accept more bytes. |
| `LIBFX_NATIVE_CLOSED` | An operation targeted a closed runtime. |
| `LIBFX_NATIVE_OOM` | Native allocation failed. |
| `LIBFX_NATIVE_THREAD` | Runtime thread creation failed. |
| `LIBFX_NATIVE_IO` | Native queue or Buffer transfer failed. |
| `LIBFX_NAPI` | A Node-API operation failed unexpectedly. |

The JavaScript loader adds `LIBFX_NATIVE_UNAVAILABLE` for forced-native selection failures and `LIBFX_JSPI_REQUIRED` when neither native execution nor JSPI-backed WebAssembly is available.

## Verification

Build and run the focused native lane from the repository root:

```sh
zig build -Dnapi-surface=core -Doptimize=ReleaseSafe
npm run --prefix sdk test:node-napi
```

The lane covers:

- malformed arguments, oversized values, fake handles, and use after close;
- input backpressure and the process-wide runtime cap;
- ambient fx trace isolation for stdout, stderr, and trace files;
- repeated failed construction without file descriptor leakage;
- blocked ACP MCP servers and absent native tool advertisement;
- same-environment concurrency and Node worker isolation;
- finalization of abandoned handles and active worker termination;
- ACP initialization, sessions, streaming, cancellation, and graceful shutdown;
- loader selection, API version checks, endpoint validation, and fallback diagnostics.

When changing the transport or lifecycle, run the individual failing test directly while iterating, then run the complete N-API lane. Changes to shared JavaScript loading also require the Node plus WebAssembly lane because `sdk/node.js` owns both paths.

## Review checklist

For changes to this surface, verify that:

1. The addon remains a narrow ACP transport rather than a second agent implementation.
2. Native tools, ACP MCP, background processes, and secret-store access remain disabled unless a separately reviewed capability is introduced.
3. Gateway validation remains enforced in both JavaScript and native code.
4. Every allocation and runtime slot has cleanup on partial failure.
5. Handles remain type-tagged, wrapped, finalizable, and safe after explicit destruction.
6. Queue and string bounds are preserved with overflow-safe arithmetic.
7. Destruction closes input before joining and cannot free a running runtime.
8. Multiple workers, concurrent runtimes, garbage collection, and worker termination still pass.
9. Secrets are not logged, serialized, or moved into process-global environment state.
10. The exact ReleaseSafe addon is built and exercised through `sdk/node.js` before shipping.
