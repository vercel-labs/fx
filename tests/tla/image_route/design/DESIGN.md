# Design: image route

How fx decides, for each model request, where images go: inline, through the vision tool, or nowhere with a notice. `CONTEXT.md` describes the code on `b0a90fd3a`. Line numbers here refer to that commit too, except those marked "this change", which refer to this branch.

`tests/tla/drivers/image_route/traceability.ts` reads this file. It requires every question below to be answered or listed as not applicable, every rule and law to have a row under Enforcement, and every entry there to name a check that exists.

## Questions

- Q1: Values cross. The catalog sends `tags` strings, the core gets a `Support` enum and five `Request` flags (`image_route.zig:94-105`, this change), and image bytes stay as session handles until the shell materializes them for the provider (`orchestrator.zig:7463-7476`, this change). Logs get the decision's tag names (`orchestrator.zig:7375-7388`, this change).
- Q2: A core event is under 16 bytes, once per request, plus at most one capability request per turn. Images are at most 8 per result and 5 MiB encoded each (`image_data.zig:6-8`). At 100x the images per session, `requestMaxDimension` shrinks each one (`image_data.zig:168`), and the request budget withholds the rest (`request_image_budget.zig`).
- Q3: The gateway catalog owns capability. `CapabilityResolver` caches it per process and refreshes every 60 s (`gateway_provider.zig:167-207`). The core holds one snapshot per turn and refreshes it at most once in the turn, only when images wait on unknown support.
- Q4: The largest inline value is one tool image, 5 MiB encoded at most, bounded by `withholdRequestToolImages` (`execution_memory.zig:800`) and the request budget. Notices are fixed text cut to `max_tool_result_bytes` (`gateway_step.zig:285-293`, this change).
- Q5: Yes. The model gets images only when it can read them, a notice only when they are withheld, and the core gets flags, never bytes.
- Q6: One turn loop per session builds requests. Parallel tools finish before the next request is built, and subagents run their own turn loops. No two writers share a core state.
- Q7: The turn loop is the core state's only writer (`orchestrator.zig:6888-6891`, this change), so nothing is lost.
- Q8: A reply nothing waits for, stale or duplicated, is ignored. A request delivered while a reply is owed replaces the waiting one, and the reply answers the newest. A reply after its turn ended meets a reset state.
- Q9: Yes, today. The route is chosen before tool images trigger a second catalog check (`orchestrator.zig:7372` against `:7485`), so one request can mix two support values. The design asks first and decides after the reply (`image_route.zig:166-190`, this change), and `OneSnapshot` checks it.
- Q10: The resolver's catalog, which its owner already guards against concurrent readers (`gateway_provider.zig:165-166`). It is unchanged. The core's state is a turn-local value.
- Q11: A request delivered twice runs nothing more (`DuplicateRequestIsQuiet`). Model request retries are the gateway step's, unchanged.
- Q12: The capability request is a GET and safe to repeat, but the core never repeats it within a turn. A lost reply ends with the turn, and the next turn asks again.
- Q13: `resolve_capabilities` is idempotent, keyed per turn by `resolved`. `notify_catalog_down` is not idempotent, keyed per turn by `notified`. `send` and `fail` happen once per request, and the core never re-emits them.
- Q14: The catalog fetch keeps the transport's deadline. A timeout leaves the resolver failed and support unknown, so the request goes out without images and with the "could not confirm" notice. The caller assumes nothing about vision.
- Q15: A slow, down, rate-limited, or malformed catalog leaves the resolver failed (`gateway.zig:2713-2715` rejects malformed JSON), which the core sees as unknown support. The request still goes out, without images.
- Q16: The core's state lives in memory and dies with the process. Tool images stay in the session store, and the next process decides again from its first turn.
- Q18: Unknown support with a down catalog: one notice per turn in the transcript (`orchestrator.zig:7493-7496`, this change), and a model-facing note that it may recover. No vision: the model is told to call the vision tool, or to ask for a vision model. Images attached this turn with no route: `ModelImageCapabilityUnavailable` or `SubscriptionNativeImageUnavailable`, and the failed turn is not saved, so its image never enters the history. Images from earlier turns never fail a turn: on a route that cannot carry them they leave the request as one note each (`image_attachments.withholdEarlierImages`), as tool images do, and a down catalog tells the user once per turn. Counting them as attached now once left a session that attached a screenshot, restarted, and could not reach the catalog unable to send even plain text. Each recovers on a later turn once the catalog answers.
- Q19: Nothing. A withheld image stays in the store with a notice (`NoSilentWithhold`), session-dropped images become notes (`image_attachments.zig:883-887`), withheld earlier images become one note each (`image_attachments.withholdEarlierImages`), and the `vision_policy` trace line records the tool image and earlier image decisions.
- Q21: None in the core. The resolver's refresh interval uses `io_mod.milliTimestamp` (`gateway_provider.zig:173`), unchanged.
- Q22: The core has one waiting request and at most two effects per step (`Bounded`). Images in history are bounded by the existing caps in Q2.
- Q24: One `step` call and one scan of the request's messages per model request (`requestHasToolImages`, `orchestrator.zig:6199-6208`, this change). Nothing runs at startup, per keystroke, or per token.
- Q25: The scan is linear in the request's history, like the projections beside it that already walk every message (`withholdDroppedImages`, `materializeToolImages`).
- Q26: One core state per turn, turns run one at a time per session, and each subagent has its own.
- Q27: No saved format or protocol changes. `ImageInputSupport` keeps its tags and moves its definition to `image_route.Support` (`model_capabilities.zig:37`, this change). Saved sessions resume unchanged, and their images now reach vision-only models.
- Q29: `/model` info prints image support (`app_commands.zig:3048-3050`) and now shows `native` for vision-only models. The CLI, TUI, ACP, and libfx share the code. Older releases keep the old rule.
- Q30: The gateway controls the tags over TLS. A repository cannot set capabilities, because project `.fx.json` accepts no profile-owned keys (`config_runtime.zig` `parseProjectSafeFields`). Tool output reaches the core only as a flag that images exist.
- Q31: Nowhere. Core events and the trace line hold only model ids and tag names.
- Q32: No. Images from permission-denied results still never leave the process (`vercel_protocol.zig:691-704`).
- Q33: Dropping `file_input` from one condition (`model_capabilities.zig:100` on `b0a90fd3a`) fixes the first reported bug. The second, an earlier image blocking every turn, needs the shell to split a request's user images at the turn's own message (`orchestrator.zig` `requestUserImages`) and the core to treat earlier ones as it treats tool images.
- Q34: The core extraction. Without it the reported bug is still fixed, but Q9's ordering fix has no function to check against a model. The design keeps it for that reason and for G6; see R10.
- Q35: It reuses the resolver, `projectToolImageMessages`, and the wire encoder. It replaces `visionPolicy` and the inline re-resolve, so no parallel path remains, and it drops both inherited flaws: the `file-input` rule and the late re-resolve. Earlier images reuse the tool image rule (`held`) and the dropped-image note pattern rather than a rule of their own.
- Q36: Nothing. No setting, override, or provider table.
- Q37: `tests/e2e/file-tool-paths.test.ts` through the built binary, `sdk/tests/test-agent-images.mjs` through libfx on both backends, the drivers on the real core, the binary stage on `fx ask` turns of the built binary (`binary-to-spec.ts`), `tests/e2e/vision-route-fake-gateway.test.ts` for a resumed turn while the catalog is down, and a live run of the built binary against the gateway (`GOAL.md`, item 6).
- Q38: The `vision_policy` trace line logs `image_support`, `route`, `mode`, `pending_images`, `tool_images`, and `earlier_images` for every request, and `image_gate` diagnostics record each failure (`orchestrator.zig:7357-7366`, this change).
- Q39: Revert the change. No data needs migrating. Reverting `supportFromCatalog` alone (`image_route.zig:47-52`, this change) restores the old rule.

Not applicable: Q17, Q20, Q23, Q28 (the core writes nothing that can be partial, holds no process, file, lock, or connection, consumes one synchronous event at a time, and changes no saved format, so nothing needs migrating).

## Laws

The laws `step` obeys. Each one is a named invariant or property in `spec/ImageRoute.tla`, checked by TLC over the whole model and on traces of the real core.

- **L1 VisionImpliesNative**: a model the catalog lists with `vision` takes images inline, whatever its `file-input` tag says. One listed without vision does not, and an unlisted model or an unreachable catalog leaves support unknown.
- **L2 RouteModeCoherent**: the vision tool is offered exactly on the fallback route.
- **L3 NativeExcludesFallback**: native delivery and the vision tool never meet in one request.
- **L4 OneSnapshot**: a request's route, vision tool mode, and tool image handling all follow the one support value the state holds after the step (ordering).
- **L5 UnknownNeverInline**: no image goes to a model the catalog has not confirmed (ownership: the catalog decides).
- **L6 NoSilentWithhold**: tool images and images from earlier turns are attached, or withheld with a notice the model can act on, never neither. The vision tool is required exactly while images attached this turn wait for it (`RequiredWhenPending`).
- **L7 FailExactlyWhenUnroutable**: a request whose images were attached this turn and have no route fails, with the reason that matches support. Nothing else fails, so an image from an earlier turn never blocks a turn.
- **L8 ResolveOncePerTurn**: the core asks for capabilities only when images wait on unknown support (`ResolveOnlyWhenNeeded`), and at most once per turn (idempotence). This also makes the shell's effect loop end.
- **L9 NotifyOncePerTurn**: the user hears about a down catalog only for images it withholds (`NotifyOnlyWhenDown`), and at most once per turn (idempotence).
- **L10 DuplicateRequestIsQuiet**: a request delivered while a reply is owed runs nothing, and a reply nothing waits for changes nothing (`StaleReplyIsQuiet`) (idempotence and ordering).
- **L11 Bounded**: at most one waiting request, and at most two effects per step, a notice and then one answer (bounds).
- **L12 Answered**: every request that waits for a reply is answered, unless its turn ends first (liveness).
- **L13 DecideOnlyWhenReady**: a decision comes only once no reply is owed. While one is owed, the turn has asked once and decided nothing (`PendingWaitsForReply`) (ordering).
- **L14 TurnResets**: a new turn, and a new process after a crash, start with no request waiting and no capability request or notice spent.
- **L15 AskedBeforeUnknown**: a turn judges support unknown, by withholding images as unconfirmed or by failing for it, only after it asked the catalog in that turn (ordering).

## Enforcement

### Rules

| Rule | Status | Reason | Enforced by |
| --- | --- | --- | --- |
| R1 | pass | Core events carry flags only. Bytes stay as session handles until the shell materializes them, and base64 exists only in the AI SDK file part at the transport (`vercel_protocol.zig:706-712`). | `zig:src/core/images/image_route.zig#requests carry flags, not image bytes`, `review:the shell's materialization and the wire encoder are unchanged; a reviewer checks any new caller of image_route passes flags, which the Request type enforces at compile time` |
| R2 | fail | Inherited and accepted. The AI SDK prompt has no image reference form, so every request resends the images in its history, now also for vision-only models. The existing caps bound each request. | `review:per-request image bytes stay bounded by request_image_budget.zig and withholdRequestToolImages; sending once by reference would need provider-side storage, a non-goal in GOAL.md` |
| R3 | pass | Notices are fixed text cut to the result limit. Images are bounded by the existing caps, and the core never holds bytes. | `zig:src/core/agent/runtime/gateway_step.zig#projectToolImageMessages names the dead end when no fallback exists`, `inv:Bounded` |
| R4 | pass | The gateway catalog is the source, the resolver caches it, and the core keeps one snapshot per turn that only a reply to its own request replaces. | `inv:VisionImpliesNative`, `inv:OneSnapshot`, `prop:StaleReplyIsQuiet` |
| R5 | pass | One event per request, at most one capability request per turn, at most two effects per step. Image bytes per request are capped as in Q2. | `inv:Bounded`, `prop:ResolveOncePerTurn`, `inv:ResolveOnlyWhenNeeded` |
| R6 | pass | Only the capability request repeats safely, and the core still sends it once per turn. Sends, failures, and notices are never re-emitted. | `prop:DuplicateRequestIsQuiet`, `prop:NotifyOncePerTurn`, `prop:ResolveOncePerTurn` |
| R7 | pass | Crashes, a down or missing catalog, and lost, stale, and duplicated replies are actions in the model, and the code is checked on traces that inject them. | `inv:UnknownNeverInline`, `inv:TurnResets`, `prop:Answered`, `inv:FailExactlyWhenUnroutable`, `driver:code-to-spec`, `driver:binary-to-spec` |
| R8 | n/a | No saved format or protocol changes (Q27). The routing decision is never saved. | |
| R9 | pass | It drops two inherited flaws: the `file-input` rule and the re-resolve after the route is chosen. | `mutation:S1`, `mutation:C1`, `mutation:S2`, `mutation:C7`, `inv:OneSnapshot` |
| R10 | fail | Accepted. The reported bug needs one line. The pure core, its harness, and the drivers exist so the ordering fix (Q9) is checkable against a model, as G6 requires. | `review:the core adds no setting, cache, or provider table; Q34 and Final design name what could be removed`, `driver:spec-to-code` |
| R11 | n/a | No mutable resource is opened by more than one process. The core's state is a value local to one turn. | |

### Laws

| Law | Statement | Enforced by |
| --- | --- | --- |
| L1 | Vision means native | `inv:VisionImpliesNative`, `trace:VisionImpliesNative`, `mutation:S1`, `mutation:C1`, `zig:src/core/images/image_route.zig#a catalog that lists vision makes image input native with or without file input`, `zig:src/core/config/model_capabilities.zig#image input support distinguishes unknown native and non native capability`, `zig:src/core/agent/runtime/tests/gateway_flow.zig#processQueuedPrompt routes images natively whenever the catalog lists vision`, `e2e:tests/e2e/file-tool-paths.test.ts#read_file attaches a workspace image inline for a vision model without file input`, `sdk:sdk/tests/test-agent-images.mjs#A host tool's image reaches a model the catalog lists with vision but not` |
| L2 | Vision tool only on the fallback route | `inv:RouteModeCoherent`, `trace:RouteModeCoherent`, `mutation:S18`, `mutation:C17`, `zig:src/core/images/image_route.zig#every decision reads one support value` |
| L3 | Native excludes the vision tool | `inv:NativeExcludesFallback`, `trace:NativeExcludesFallback`, `mutation:S19`, `mutation:C18`, `sdk:sdk/tests/test-agent-images.mjs#a native image model is not offered the vision tool` |
| L4 | One snapshot per request | `inv:OneSnapshot`, `trace:OneSnapshot`, `mutation:S2`, `mutation:C7` |
| L5 | Unknown never inline | `inv:UnknownNeverInline`, `trace:UnknownNeverInline`, `mutation:S5`, `mutation:C4`, `zig:src/core/agent/runtime/gateway_step.zig#projectToolImageMessages tells the truth when the catalog is unavailable`, `mutation:S21`, `mutation:C20`, `driver:binary-to-spec` |
| L6 | No silent withhold | `inv:NoSilentWithhold`, `inv:RequiredWhenPending`, `trace:NoSilentWithhold`, `trace:RequiredWhenPending`, `mutation:S17`, `mutation:C16`, `mutation:S10`, `mutation:C10`, `zig:src/core/agent/runtime/orchestrator.zig#requestHasToolImages ignores images the session dropped`, `e2e:tests/e2e/file-tool-paths.test.ts#read_file image is withheld with guidance for a text-only model`, `mutation:S22`, `mutation:C21`, `zig:src/core/images/image_attachments.zig#requests leave out earlier images the route cannot carry, each with a note`, `zig:src/core/images/image_attachments.zig#earlier images withheld from seeded random histories always leave a note` |
| L7 | Fail exactly when unroutable | `inv:FailExactlyWhenUnroutable`, `trace:FailExactlyWhenUnroutable`, `mutation:S8`, `mutation:C9`, `zig:src/core/images/image_route.zig#user images without a route fail the request and never send`, `mutation:S20`, `mutation:C19`, `zig:src/core/images/image_route.zig#an earlier image never blocks a turn`, `zig:src/core/agent/runtime/orchestrator.zig#requestUserImages splits kept images at the turn's own message`, `zig:src/core/agent/runtime/tests/gateway_flow.zig#processQueuedPrompt sends a text-only turn while a down catalog withholds an earlier image`, `e2e:tests/e2e/vision-route-fake-gateway.test.ts#a resumed text-only turn is sent while the catalog is down, with the earlier image withheld`, `driver:binary-to-spec` |
| L8 | One capability request per turn, only for images | `inv:ResolveOnlyWhenNeeded`, `prop:ResolveOncePerTurn`, `trace:ResolveOnlyWhenNeeded`, `trace:ResolveOncePerTurn`, `mutation:S3`, `mutation:C2`, `mutation:S15`, `mutation:C14`, `zig:src/core/images/image_route.zig#a turn asks for capabilities at most once and answers the request it held` |
| L9 | One catalog-down notice per turn, only when down | `inv:NotifyOnlyWhenDown`, `prop:NotifyOncePerTurn`, `trace:NotifyOnlyWhenDown`, `trace:NotifyOncePerTurn`, `mutation:S4`, `mutation:C3`, `mutation:S16`, `mutation:C15`, `zig:src/core/images/image_route.zig#the catalog-down notice reaches the user once per turn`, `driver:binary-to-spec` |
| L10 | Duplicates and stale replies are quiet | `prop:DuplicateRequestIsQuiet`, `prop:StaleReplyIsQuiet`, `trace:DuplicateRequestIsQuiet`, `trace:StaleReplyIsQuiet`, `mutation:S6`, `mutation:C5`, `mutation:S7`, `mutation:C6` |
| L11 | Bounded | `inv:Bounded`, `trace:Bounded`, `mutation:S12`, `mutation:C11`, `zig:src/core/images/image_route.zig#abstract maps the pending request onto a sequence of at most one` |
| L12 | Every waiting request is answered | `prop:Answered`, `mutation:S11`, `review:a finite trace cannot show liveness; TLC proves Answered over the whole model under fairness of replies, and ConformsToSpec makes each recorded reply clear its request` |
| L13 | Decide only when no reply is owed | `inv:DecideOnlyWhenReady`, `inv:PendingWaitsForReply`, `trace:DecideOnlyWhenReady`, `trace:PendingWaitsForReply`, `mutation:S13`, `mutation:C12`, `mutation:S14`, `mutation:C13` |
| L14 | Turns and processes start clean | `inv:TurnResets`, `trace:TurnResets`, `mutation:S9`, `mutation:C8` |
| L15 | Unknown only after asking | `inv:AskedBeforeUnknown`, `trace:AskedBeforeUnknown`, `mutation:S23`, `mutation:C22`, `zig:src/core/images/image_route.zig#the core keeps the model's laws on arbitrary event sequences`, `zig:src/core/images/image_route.zig#the core keeps the model's laws on seeded random event sequences` |

## Final design

### The fix

`supportFromCatalog` (`src/core/images/image_route.zig:47-52`, this change) returns `native` when the catalog lists `vision` and `non_native` when it lists the model without it, and `unknown` for a missing model or a down catalog. `file-input` plays no part. `mergeCapabilities` calls it (`src/core/config/model_capabilities.zig:97-100`, this change), so the CLI, TUI, ACP, and libfx all change at once. `ImageInputSupport` is now an alias of `image_route.Support` (`model_capabilities.zig:37`, this change).

### The core

`src/core/images/image_route.zig` (this change) imports only `std` outside its tests.

- **State** (`:107-116`): `support`, the turn's one capability snapshot; `resolved` and `notified`, the turn's spent capability request and notice; `pending`, the request waiting for a reply, if any.
- **Events** (`:118-127`): `turn_started(Support)`, `request_ready(Request)`, and `capabilities_resolved(Support)`. Time does not enter. I/O results arrive as `capabilities_resolved`, and failures arrive as the support value they produce.
- **Effects** (`:135-146`), a tagged union of values: `resolve_capabilities`, `notify_catalog_down`, `send(Decision)`, and `fail(FailReason)`. At most two per step, returned in a fixed buffer with no allocation (`:148-156`).
- **`step`** (`:158-164`) dispatches to three pure functions: `onRequest` (`:166-181`), `onResolved` (`:183-190`), and `decide` (`:192-205`). `decision` (`:207-225`) maps one support value and one request to a route, a vision tool mode, and a tool image handling. Absence is `?Request`, and errors are the `fail` effect. Nothing panics, and mutation is limited to `var next` copies inside one function.
- **`abstract`** (`:235-251`) maps a state onto the spec's `support`, `resolved`, `notified`, and `pending`.

### The shell

The turn loop in `processQueuedPromptLoop` is the only code that runs effects.

- It starts the core's state with `turn_started` (`orchestrator.zig:6888-6891`, this change).
- For each request, it builds the `Request` flags, including whether a tool image survives `withholdDroppedImages` (`requestHasToolImages`, `:6199-6208`).
- It then runs the effect loop: a capability request becomes `deps.resolve_model_capabilities` and its reply event, a notice is recorded, and `send` or `fail` is taken (`:7325-7366`).
- The decision drives the user-image projection, the vision tool mode, tool image materialization, and the notice (`:7367-7496`).
- `projectToolImageMessages` takes the core's `ToolImages` value instead of recomputing it from support and a flag (`gateway_step.zig:264-295`, this change).

`visionPolicy`, `ImageRoute`, `VisionPolicy`, and the per-turn flags `tool_image_capabilities_resolved` and `tool_image_strip_notified` are gone, along with their tests. The core's tests and the model cover the same laws.

### Earlier images

A request's user images are split at the turn's own user message (`orchestrator.zig` `requestUserImages`): `user_images` are the ones attached this turn and `earlier_images` the ones earlier turns left in the history, counting only images the session still holds. Only `user_images` can fail a request (L7). `decision` gives earlier images the tool image rule (`held` in `image_route.zig`), so they go inline to a model listed with vision, through the vision tool's image references on the fallback route, and otherwise leave the request as one note each (`image_attachments.withholdEarlierImages`). A down catalog that withholds them tells the user once per turn (`catalogDownNotice`), and the turn asks the catalog before judging support unknown (L15).

`binary-to-spec.ts` checks this through the built binary: each `fx ask` turn is recorded with the catalog view it saw, the flags the spec says the shell computes from the turn, and what its first request carried, and `BinaryImageRoute.tla` holds every turn to `DecideOut`. On the binary before this change it fails on exactly the text-only turns after an earlier image while the catalog is missing or down.

### Mechanisms added, and the answers that required them

| Mechanism | Required by |
| --- | --- |
| Support from `vision` alone | Q1 and R9: the inherited rule reads a document tag as an image tag |
| Asking before deciding, with the request held in `pending` | Q9: deciding first splits one request across two snapshots |
| `pending` replaced by a newer request, and stale replies ignored | Q8 and Q11 |
| `earlier_images`, split from `user_images` | Q18: an earlier image failed every later turn while support was unknown |
| The binary stage and `BinaryImageRoute.tla` | Q37: the shell's flags, which caused the second bug, are outside what the core harness can see |
| A pure core with `abstract` and a harness | Q37 and G6: the orchestrator cannot be checked against a model, and a pure step can |

### Rules this design breaks

- **R2, send only what is needed.** Every request still resends the images in its history, now also to the 73 vision-only models. The AI SDK prompt offers no reference form, and the existing caps bound each request. Sending by reference would need provider-side storage, a non-goal in `GOAL.md`.
- **R10, build only what the problem needs.** The reported bug needs only `supportFromCatalog`'s one condition. The core extraction (about 250 lines with tests), the harness, and the drivers exist for the verification this workspace is for, and they make the ordering fix (Q9) checkable. Without that requirement, the smallest design is the one-line fix plus moving the orchestrator's re-resolve ahead of `visionPolicy`.
