# Goal

## Problem

fx never sends an image, from a tool or from the user, to a model that the catalog lists with `vision` but without `file-input`. The image stays in the session, and the model gets a notice that it should call the vision tool instead. fx's own default model, `spacexai/grok-4.7`, is one of the 73 models the gateway catalog lists this way (`CONTEXT.md`, The report). A libfx user hit this when an AI SDK tool returned an image to the default model: the agent never saw the image unless they set a different model.

The cause is one rule: image input counts as native only when the catalog lists both `vision` and `file-input` (`src/core/config/model_capabilities.zig:100-103` on `b0a90fd3a`). The AI Gateway uses `file-input` for documents such as PDFs. fx sends images as AI SDK file parts with an image media type, and those need only `vision`.

The same code has a second flaw. When tool images appear while support is unknown, the turn asks the catalog again, but only after the request's route and vision tool mode are already chosen (`orchestrator.zig:7372` against `:7485`). That one request can mix two capability values.

## Success criteria

Each criterion is a check that passes on this change and failed, or could fail, before it.

| # | Criterion | Check |
| --- | --- | --- |
| G1 | A `read_file` image reaches a model the catalog lists with the default model's exact tags, inline, as an `image/png` file part. | `tests/e2e/file-tool-paths.test.ts`, "read_file attaches a workspace image inline for a vision model without file input". It fails on `b0a90fd3a` |
| G2 | A libfx host tool's image reaches that model inline, on the native and WebAssembly backends, and the model is not offered the vision tool. | `sdk/tests/test-agent-images.mjs native` and `wasm`. The new case fails on `b0a90fd3a` |
| G3 | A model listed without `vision` still gets the vision tool notice, and unknown support still sends no image. | The text-only E2E case, plus `UnknownNeverInline` in `ImageRoute.tla` and on code traces |
| G4 | Every request's route, vision tool mode, and tool image handling come from one capability value. | `OneSnapshot` in `ImageRoute.tla` and on code traces, and planted bugs S2 and C7 |
| G5 | No extra catalog traffic: at most one capability request per turn from the image decision, and none for a request without images. | `ResolveOncePerTurn` and `ResolveOnlyWhenNeeded` |
| G6 | The decision is one pure function, checked against its model in both directions. | `bun run verify` in `tests/tla/image_route` |
| G7 | Nothing slows startup or adds network I/O on a path without images. | The `Startup Latency` CI job, and `ResolveOnlyWhenNeeded` |
| G8 | An image from an earlier turn never fails a later turn: while support is unknown, the turn is sent with the image withheld and a note in its place, and only an image attached now can fail. | `FailExactlyWhenUnroutable` and planted bugs S20 and C19, the binary stage of `bun run verify`, and `tests/e2e/vision-route-fake-gateway.test.ts`, "a resumed text-only turn is sent while the catalog is down, with the earlier image withheld". Both fail on the binary before this change |

## Non-goals

- Supporting documents (PDFs) as tool results. The `file-input` tag would govern that, and fx does not send documents today.
- Changing the gateway catalog or asking for different tags.
- Removing the `has_file_input = vision` stand-ins in the Codex, Grok subscription, and Chat Completions providers (`CONTEXT.md`, item 2). They are now harmless, and changing them changes only what `/model` info prints.
- Sending images once and referring to them afterwards (rule R2). The AI SDK prompt has no reference form, so every request resends the images in its history, as it already does for models with `file-input`.
- A setting or override for image support.

## What 100% done means

Every item below passes for the exact commit that ships.

1. `bun run verify` in `tests/tla/image_route` exits 0: the model check, spec to code over every edge, code to spec, every planted bug caught, and traceability.
2. `zig fmt --check src/` exits 0.
3. `zig build test` exits 0.
4. `FX_SOUND=0 bun test file-tool-paths.test.ts -t 'read_file (attaches|image is withheld)'` in `tests/e2e` passes all three cases.
5. `node sdk/tests/test-agent-images.mjs native` and `node --experimental-wasm-jspi sdk/tests/test-agent-images.mjs wasm` pass.
6. A live run of `./zig-out/bin/fx` with `FX_MODEL=spacexai/grok-4.7`, reading a PNG with `read_file`, answers with what the image shows, with clean stderr.
7. CI passes for the exact commit: `Build & Test`, `E2E (deterministic)`, `Shellcheck`, `Startup Latency`, and `macOS arm64`. This needs a pushed branch, which happens only when asked.
8. `tests/tla/README.md` lists `image_route/`. The release note belongs to the next release PR, which the maintainer writes.
