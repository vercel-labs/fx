# Context: how images reach the model

Line numbers refer to `origin/main` at `b0a90fd3a` unless a line says "this change". The design in `DESIGN.md` moves some of this code. `git show b0a90fd3a:<path>` shows it as cited.

## The report

A libfx user building an AI SDK harness adapter reported that an image in a tool result never reaches the agent unless they pass a custom `model`. The default model, `spacexai/grok-4.7`, is listed in fx's model catalog with `vision` but without `file-input`, and fx requires both. The report held on libfx 0.0.13 and again on 0.0.14. The reproduction is the AI SDK example `examples/ai-functions/src/harness-agent/fx/with-to-model-output.ts`, lines 53–54, which set the model. Removing them makes the image disappear.

Both catalogs fx reads were fetched on 2026-10-19:

| Catalog | Used by | Models | `spacexai/grok-4.7` tags |
| --- | --- | --- | --- |
| `https://ai-gateway.vercel.sh/coding-agent/v1/models` | capability lookups (`src/builtins/gateway.zig:46`, the E2E fake at `tests/e2e/gateway-stream-lifecycle.test.ts:1305`), libfx `listModels` (`sdk/fx-sdk.js:611`) | 263 | `reasoning`, `tool-use`, `implicit-caching`, `vision`, `structured-output` |
| `https://ai-gateway.vercel.sh/v1/models` | the public catalog, and the fallback models path when no web-search path is set (`src/core/app/app_agent_runtime.zig:250`) | 478 | the same |

In `/v1/models`, 73 models list `vision` without `file-input`, including the default and `spacexai/grok-4.6`. None lists `file-input` without `vision`.

The AI Gateway documents the two tags as separate capabilities. Vision covers images such as a PNG screenshot. File input covers documents such as a PDF ([Inputs and Tools](https://vercel.com/docs/ai-gateway/inputs-and-tools)). For the AI SDK format that fx speaks, image input is "a `file` part with an `image/*` `mediaType`" ([Vision and Image Input](https://vercel.com/docs/ai-gateway/inputs-and-tools/vision)).

## Entry points

| Entry point | Path to the decision |
| --- | --- |
| `fx`, `fx ask` | `processQueuedPromptLoop` (`src/core/agent/runtime/orchestrator.zig:6915`) builds every model request of a turn |
| libfx `createFxEngine` (native and WebAssembly) | The ACP server in the Zig core, then the same loop. A host tool returns `{ type: "libfx.tool-result", text, images }` (`sdk/tests/test-agent-images.mjs:1266`), which becomes `tool_result_memory.tool_images` |
| `read_file` on an image | The same loop, with the image in `tool_result_memory` (`tests/e2e/file-tool-paths.test.ts:349-440`) |

The default model is `spacexai/grok-4.7` (`src/builtins/gateway.zig:43`).

## Data flow today

1. The gateway catalog's `tags` array is parsed into `has_vision` and `has_file_input` (`src/builtins/gateway.zig:2755-2762`, fields at `src/core/gateway/model_catalog.zig:326`).
2. `fromCatalogEntry` copies them to `supports_vision` and `supports_file_input` (`src/core/gateway/model_catalog_metadata.zig:17-18`).
3. `mergeCapabilities` sets `image_input_support` to `.native` only when both are true, and to `.non_native` otherwise (`src/core/config/model_capabilities.zig:100-103`). Without catalog metadata it stays `.unknown` (`src/core/config/model_capabilities.zig:36-40`, `:66`). **This is the bug.**
4. `CapabilityResolver` caches the catalog per process. Its states are `idle`, `ready`, and `failed` (`src/core/gateway/gateway_provider.zig:148-160`). `resolve` fetches only when idle (`:217-219`). When the catalog failed, or the model is missing from it, `resolve` returns the local fallback, whose support is unknown (`:221-228`, `:242-247`). The catalog is refreshed at most every 60 seconds (`src/core/gateway/provider_versions.zig:12`, `gateway_provider.zig:177-181`), and a failed refresh keeps the last good catalog (`gateway_provider.zig:196-197`).
5. At turn start, the orchestrator resolves capabilities when the turn has images or when vision routing needs them (`orchestrator.zig:5772-5783`, `requiresResolvedRequestCapabilities` at `:5606-5618`).
6. For each request in the turn loop:
   - `request_capabilities` is a turn-local copy (`orchestrator.zig:6942`).
   - `visionPolicy` picks the user-image route and the vision tool mode from `image_input_support` (`orchestrator.zig:6196-6213`, called at `:7372-7377`).
   - User images are projected for that route. A request with user images and no route fails with `ModelImageCapabilityUnavailable` or `SubscriptionNativeImageUnavailable` (`:7402-7437`).
   - Only then, if tool images are present and support is unknown, capabilities are resolved again, at most once per turn (`:7485-7493`).
   - Native support materializes the tool images inline (`:7494-7506`). Otherwise `projectToolImageMessages` strips them and adds a notice to the tool message (`src/core/agent/runtime/gateway_step.zig:268-300`).
   - When support is unknown and the catalog is known to be down, the user is told once per turn (`orchestrator.zig:7523-7530`).
7. On the wire, every retained tool image goes out as a `{"type":"file","mediaType":"image/…","data":…}` part in a user message after the tool run (`src/gateway/vercel_protocol.zig:679-716`). The tool-result part keeps only its text (`:718-742`). User images are file parts too (`:780-823`).

## Who owns each piece of state

| State | Owner | Lifetime | Refresh |
| --- | --- | --- | --- |
| Which models take images | The AI Gateway catalog | External | Read by HTTP |
| Cached catalog | `CapabilityResolver` (`gateway_provider.zig:154-160`) | One process | Every 60 s, or when access changes |
| Request capabilities | The turn loop (`orchestrator.zig:5774`, `:6942`) | One turn | Once at turn start, and once more for tool images (`:7489`) |
| Whether the turn re-resolved | `tool_image_capabilities_resolved` (`orchestrator.zig:6943`) | One turn | Set once |
| Whether the user was told | `tool_image_strip_notified` (`orchestrator.zig:7079`) | One turn | Set once |
| Pending user images | `pending_image_ids` (`orchestrator.zig:7028-7033`) | One turn | As the model views them |
| Tool image bytes | The session image store, through `tool_result_memory.tool_images` and `tool_image_handle` (`src/core/shared/types.zig:1320-1338`) | The session | Dropped images keep a name without bytes (`types.zig:1335-1337`). `withholdDroppedImages` turns them into notes (`src/core/images/image_attachments.zig:862-889`) |

## Contracts and saved formats

- `ImageInputSupport` (`model_capabilities.zig:36-40`) is in-memory only. `/model` info prints it next to `supports_vision` and `supports_file_input` (`src/core/app/app_commands.zig:3048-3050`).
- The catalog `tags` array is an external contract that fx reads and never writes.
- The routing decision, the withheld-image notice, and the materialized image bytes are built per request in the overlay arena and never saved (`orchestrator.zig:7494-7507`). Sessions save tool images by handle or name, as before. No saved format records image support.
- The wire format is the AI SDK prompt with `file` parts. It doesn't change.

## Callers of `image_input_support`

`orchestrator.zig:5615`, `:7373`, `:7425`, `:7485`, `:7494`, `:7507`, `:7524`, and `:9849` (a suggestion in a model error), `gateway_step.zig:271-286`, `app_commands.zig:3048`, and tests in `src/core/agent/runtime/tests/gateway_flow.zig`, `tool_flow.zig`, `support.zig`, `src/core/gateway/gateway_provider.zig`, `src/core/subagent/agent_adapter.zig`, and `src/gateway/chat_completions.zig`.

## Constraints

- Zig 0.17, standard library only. The core imports nothing but `std`.
- The decision runs once per model request, never at startup. The startup budget is 2 ms per CLI path (`AGENTS.md`, Benchmarks).
- Permission handling is unchanged. Images from permission-denied results never leave the process (`vercel_protocol.zig:691-704`).
- libfx has two surfaces, native and WebAssembly, that share this Zig code. Both must pass `sdk/tests/test-agent-images.mjs`.
- The model never changes within a turn: `gateway_model` is always `job.model` (`orchestrator.zig:7273`, `:7300`).

## Existing code that makes the wrong design look easy

1. The wire part is named `file` (`vercel_protocol.zig:708`), so the `file-input` tag reads like a requirement for sending it. It isn't. The tag means documents.
2. Three providers that have no `file-input` tag set `has_file_input = vision` to satisfy the rule: configured Chat Completions providers (`src/gateway/chat_completions.zig:235`), Codex (`src/gateway/openai_codex_models.zig:286`), and Grok subscriptions (`src/gateway/xai_grok_models.zig:364`). That kept the bug invisible everywhere except the gateway catalog.
3. Every image test fixture pairs `vision` with `file-input`: `sdk/tests/test-agent-images.mjs:34`, `tests/e2e/file-tool-paths.test.ts:365`, `tests/e2e/vision-route-fake-gateway.test.ts:227-232`, and about 40 more (`git grep -n file-input -- tests sdk`). No test ran a vision-only catalog entry, though 73 live models are vision-only.
4. `processQueuedPrompt routes images natively only when vision and file input are both supported` (`src/core/agent/runtime/tests/gateway_flow.zig:2508-2537`) set `image_input_support` by hand from its expectation. It stated the rule without testing where it comes from.
5. The rule predates `ImageInputSupport`. Commit `77e62a3ac` (2026-08-30, "Hide Vision from native image models") carried `supports_vision and supports_file_input` over from the initial commit (`git show 77e62a3ac^:src/core/agent/runtime/orchestrator.zig`, lines 3462 and 3505).
6. The tool-image re-resolve sits after the route is chosen (`orchestrator.zig:7372` against `:7485`), the easiest place to add it. When it changes support, one request takes its route and vision tool mode from the old value and its tool images from the new one.

## Fakes the drivers use

The only fakes are effect handlers at the edge of a shell:

| Fake | Where | Stands in for |
| --- | --- | --- |
| The catalog reply | `tests/tla/drivers/image_route/code-to-spec.ts`, `spec-to-code.ts` | The result of the core's `resolve_capabilities` effect, and the capabilities a turn starts with, given as a catalog view the harness turns into support with the real `supportFromCatalog` |
| Recording `send`, `fail`, and `notify` | `tests/tla/drivers/image_route/harness.zig` | Sending the request, failing the turn, and printing the notice. The harness prints the effects instead of running them |
| A crash | `Harness.crash` in `tests/tla/drivers/image_route/lib.ts` | A process dying. The driver kills the harness process with `SIGKILL` and starts a new one |
| The fake gateway | `startFakeGateway` (`tests/e2e/tmux-helpers.ts`) in `tests/e2e/file-tool-paths.test.ts` | The catalog and the model, for the built `fx` binary |
| `mockGateway` | `sdk/tests/test-agent-images.mjs:79-101` | The catalog and the model, for libfx |

The drivers call the real `src/core/images/image_route.zig` through the harness. They never reimplement it.
