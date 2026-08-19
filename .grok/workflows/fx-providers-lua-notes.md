# Providers, Lua, and viewer — scout notes

Read-only map of current fx seams plus grok-build behaviors worth porting. Plan owner: `.grok/workflows/fx-providers-lua-plan.md`. Do not treat this file as an implementation spec. The plan still wins.

## Current product facts

- Every live model call is Vercel AI Gateway v3. `FX_GATEWAY_CHAT_URL` / `FX_GATEWAY_BASE_URL` rewrite the URL only. The body is still `prompt` + `toolChoice`; the SSE parser still keys on `text-delta`.
- `CredentialSource` is a Gateway access method, not a model backend: `vercel_oidc_token`, `ai_gateway_api_key`, `fx_login`, `stored_key`. Do not overload it with ChatGPT / Grok / Cursor / OpenAI-compatible.
- There is no `src/core/providers/`, no OpenAI Chat Completions parser, no Responses parser, and no Lua runtime.
- Interactive rendering is inline except five exclusive `AlternateScreenOwner`s. A sixth owner (`code_viewer`) is the planned exception.
- Humans already edit in `$EDITOR` via `AlternateScreenOwner.terminal_session`. The agent already edits through tools. fx shows code only as transcript highlight today.

---

## 1. Gateway auth and stream

### What exists

| Role | File | Contract |
| --- | --- | --- |
| Agent stream seam | `src/core/agent/stream_provider.zig` | `Provider { build, stream }` → `types.GatewayCompletion` |
| Bundled gateway port | `src/core/gateway/gateway_provider.zig` | `agent_stream`, `oauth_transport`, `chat_url`, `cli_model_catalog`, `credits`, `generation_usage`, `web_search`, `model_catalog` |
| Gateway v3 builder | `src/builtins/gateway.zig` `buildAgentRequest` | Calls `src/core/gateway/gateway_json.zig` |
| Gateway v3 SSE | `src/gateway/client.zig` | Parses `text-delta`, tool-start, finish-reason, provider-result identity |
| Chat URL | `src/builtins/gateway.zig` | Default `https://ai-gateway.vercel.sh/v3/ai/language-model`; env `FX_GATEWAY_CHAT_URL` |
| Catalog | `src/core/gateway/model_catalog.zig` + `src/builtins/gateway.zig` | `GET /coding-agent/v1/models` through `CatalogAccess` |
| Credits | `src/builtins/gateway.zig` | `GET /coding-agent/v1/credits`; fx-login without a team is rejected |
| Credential resolution | `src/core/auth/credentials.zig` + `src/core/auth/auth_runtime.zig` | Precedence + remembered `credential_source` |
| Device-code OAuth | `src/core/auth/oauth.zig` | Metadata, device auth, poll, revoke |
| Session store | `src/core/auth/oauth_session.zig` | `~/.fx/auth.json`, `auth.lock`, `durableReplaceVerified` |
| PKCE loopback | `src/core/mcp/mcp_auth.zig` `authorizeInteractive` | Binds `127.0.0.1:0`, redirect `http://127.0.0.1:{port}/callback` |
| Request shape | `stream_provider.BuildRequest` | model, tools, messages, tool_choice, vision, verified_images, response_format |

`GatewayCompletion` (`src/core/shared/types.zig`) is the agent-loop result: `content`, `tool_calls`, `generation_id`, `billing`, `finish_reason`, `usage`, plus delivery/identity failure flags. New backends must adapt into this type. Do not fork the agent loop.

`CatalogAccess` is Gateway-shaped (public-only vs authenticated + team). A non-Gateway backend needs its own catalog access type, or a wrapper that never claims Vercel team/credits.

### Files to touch (PR 1–4)

New:

- `src/core/providers/` — `ModelBackend` enum, resolver, catalog contract, session-store helpers
- `src/gateway/openai_compatible.zig` — Chat Completions SSE (`choices[].delta`)
- `src/gateway/openai_responses.zig` — Responses API (ChatGPT Codex)
- `src/builtins/providers/` — `vercel.zig` (thin wrap of today’s provider), `openai_compatible.zig`, `chatgpt.zig`, `grok.zig`, `cursor.zig`

Reuse / grow, do not replace:

- `src/core/agent/stream_provider.zig` — keep `Provider.build` + `Provider.stream`
- `src/core/gateway/gateway_provider.zig` — either become a backend-agnostic façade or sit behind a `ModelBackend` switch at composition time (`src/main.zig` wiring only)
- `src/core/auth/oauth.zig` — Grok device-code
- `src/core/mcp/mcp_auth.zig` — extract PKCE loopback helper for ChatGPT / Cursor; do not add a second OAuth stack
- `src/core/auth/oauth_session.zig` — copy lock + durable-replace into `~/.fx/providers/<backend>/auth.json`
- `src/core/shared/profile_paths.zig` — add `providers/` paths
- `src/core/config/settings_store.zig` `UserSettingsPatch` — add `provider`, `openai_compatible.base_url`, `openai_compatible.api_key_env`
- `src/core/config/config_runtime.zig` `isProfileOnlySettingKey` — add `provider` and `openai_compatible` to the ignore list (same as `model` / `credential_source`)
- `src/builtins/gateway.zig` — stay the Vercel adapter; do not teach it OpenAI bodies
- `src/gateway/client.zig` — stay the Gateway v3 parser; never feed it Chat Completions / Responses bytes

Env (profile-only): `FX_PROVIDER`, `FX_OPENAI_BASE_URL`, `FX_OPENAI_API_KEY`, existing `AI_GATEWAY_API_KEY`. Remembered `provider` wins like remembered `credential_source`.

`/credits` on a non-Gateway backend must say the backend has no gateway balance. Do not invent a Vercel credits call.

### Tests / docs for this seam

- Zig: parser + backend resolver next to the new files
- E2E: fake `/v1/chat/completions` and fake issuer (pattern: `tests/e2e/auth-refresh.test.ts`, `tests/e2e/mcp-auth.test.ts`)
- Corpus: login/auth flows **verification-only**; live OAuth **intentional exclusion**
- Docs: `README.md`, `command_specs.zig` help. Do not document subscription OAuth as Vercel-billed Gateway usage

---

## 2. Login / setup UX

### What exists

CLI (`src/core/cli/cli_surface.zig`):

- `fx login` — no args. Device-code via `login_flow.runLogin`. Usage error if any remainder.
- `fx logout` — no args. Deletes `~/.fx/auth.json`.
- `fx setup` — no args. Hidden paste of an AI Gateway key into `host.SecretStore`.
- `fx teams` — Vercel team picker after fx login.

Slash (`src/core/slash_commands/command_specs.zig`, `command_router.zig`, `src/builtins/commands.zig`):

- `/login` — “sign in with Vercel”
- `/logout` — “sign out of fx login”
- `/setup` — “set up AI Gateway access”

TUI (`src/core/app/app_auth_runtime.zig` + `src/core/auth/auth_runtime.zig` `PickerView`):

- Actions: Sign in with Vercel, Add an API key, Change team, Switch credential, Automatic
- Sources: the four `CredentialSource` values
- API-key stage is a masked footer entry, not a second agent loop
- WASM/NAPI: login/setup are host-owned; notices say so

Onboarding opens the picker when no credential exists. Remembered `credential_source` always wins resolution.

### Files to touch

- `src/core/slash_commands/command_specs.zig` — `fx login [vercel|chatgpt|grok|cursor]`, `/login [backend]`, `/logout [backend]`. Bare `fx login` / `/login` stays Vercel.
- `src/core/cli/cli_surface.zig` — accept one optional backend token; keep the no-arg path identical
- `src/core/slash_commands/command_router.zig` — login/logout payloads
- `src/builtins/commands.zig` — help / completion copy
- `src/core/app/app_auth_runtime.zig` — picker rows for OpenAI-compatible URL+key and the three subscription logins
- `src/core/auth/auth_runtime.zig` — `Choice` / `PickerView` grow actions; do not put product state in `src/ui/`
- `src/ui/` — render the picker only (`catalog_screen_layout.zig` if it stays a catalog-style menu)

`src/main.zig` stays composition root. Leaf login logic belongs in `src/core/auth/` and `src/builtins/providers/`.

### Contract to reuse

- Device-code poll + cancel: `login_flow.SignInRuntime` (already threaded, cancel-safe)
- PKCE: `mcp_auth.authorizeInteractive`
- Session durability: `oauth_session.Mutation` (lock, durable replace, WASM host store)
- Secret store: `host.SecretStore` for OpenAI-compatible keys (same keychain / profile-file path as Gateway stored keys, but a distinct secret name)

---

## 3. Image attachments and clipboard paste

### What exists in fx

- Contract: `src/core/images/image_attachments.zig`
  - 20 MiB cap, SHA-256 snapshots under a temp dir / session `images/`
  - Placeholders `[Image #N]` via `formatImagePlaceholder`
  - Atomic composer spans (`entity_spans.ImageTokenSpan`)
  - Verified snapshots ride `stream_provider.BuildRequest.verified_images`
- Commands: `src/core/images/image_commands.zig`
  - `/image <path>` (`/img`) — workspace or external path
  - `/images [clear]`
  - `/paste` — clipboard image
- Dispatch: `command_router` `.paste` → `app_commands.commandPasteClipboard`
- Clipboard **read**: `loadClipboardImageAttachment` is **macOS-only** (`osascript` → `clipboard as «class PNGf»` → temp PNG). Other OS: `error.Unsupported`.
- Clipboard **write**: `host.Clipboard` is copy / copy-file only. No host read API. WASM has no clipboard.

Composer already treats image badges as atomic units (`src/ui/input/visual_layout.zig`). Session persist remaps IDs (`session_store.zig`).

Gap vs grok-build: no `Cmd+V` / `Ctrl+V` image paste, no drag-and-drop `file://` classifier, no deferred probe, no Linux/Windows routes, no SSH wrap-host image.

### grok-build behaviors to port (image)

Source: `crates/codegen/xai-grok-pager/src/app/agent_view/paste.rs`, tutorial `03-attach-and-paste.md`, shortcuts `03-keyboard-shortcuts.md`.

Port these, mapped onto fx’s existing `[Image #N]` chips:

1. **Paste key, not only `/paste`.** `Cmd+V` (macOS) / `Ctrl+V` (Linux) / `Alt+V` (Windows). Windows Terminal’s `Ctrl+V` drops rasters; grok uses `Alt+V` as the image chord.
2. **Classifier order.** Dropped / `file://` paths first (image path → chip, non-image → absolute path text). Then raster/file-url probe. Then plain text. A Finder icon on a non-image file must not become a chip.
3. **Deferred probe.** Heavy clipboard decode/persist off the event loop. If the user hits Enter while the probe is in flight, stash the send and reissue after the chip lands. fx should reuse this “paste-then-send stays ordered” rule.
4. **Image wins over caption.** If the clipboard has both a raster and text, attach the image and do not also insert the caption.
5. **Size / type reuse.** Keep fx’s 20 MiB + `detectMediaTypeFromBytes`. Do not add grok’s preview-prep pipeline unless a later PR needs hover previews.
6. **Do not port** OSC 52 paste, PRIMARY middle-click, `grok wrap` host-image magic, or Wayland data-control. Those are grok’s full-screen clipboard stack. fx’s `/paste` + host port is enough for v1; grow Linux/Windows native readers later behind `host.Clipboard`.

Implementation home: grow `image_attachments.zig` + a small host `Clipboard.read_image` port. Do not put OS scripts in `src/ui/`.

---

## 4. Terminal host

### What exists in fx

This is already the right product: host `$EDITOR` / nvim as a child after a human write lease. Do not embed or fork Neovim.

| Piece | File |
| --- | --- |
| Exclusive owner | `AlternateScreenOwner.terminal_session` |
| Enter / leave / handoff | `src/core/app/app_lifecycle.zig`, `src/core/app/app_terminal_takeover_runtime.zig` |
| Lease | `src/core/terminal/contracts.zig` `WriteLease { none, human, agent }` |
| Host daemon | `src/core/terminal/host.zig` (`--fx-internal-terminal-host`, `host.sock`) |
| Engine | `src/core/terminal/engine.zig` (bounded VT, its own alternate-screen for the *child*) |
| Tool | `src/tools/terminal/terminal.zig` — `exec/start/read/screen/write/wait/monitor/inspect/list/resize/signal/close` |
| Policy | `src/core/terminal/host_policy.zig` |

Invariants to keep:

- Terminal-session owner is entered only from the manager after `TerminalHost` grants the human write lease.
- No permanent fx chrome while the session owns the buffer.
- Release the lease on detach (`Ctrl-]` prefix in takeover runtime).
- Exclusive: `enterAlternateScreen` errors with `AlternateScreenAlreadyOwned`.
- Shutdown / job-control / approval handoff all go through `leaveAlternateScreens`.

### grok-build terminal

`crates/codegen/ptyctl` is a PTY server (spawn, resize, wait-for text/regex/stable-ms, screen snapshot, WebSocket subscribe). It is closer to fx’s existing `TerminalHost` + tool than to a UI pane.

Grok Build itself is a **full-screen** ratatui app (`xai-grok-pager`). It is not an inline Unix-shell TUI. It has `--no-alt-screen` / `[terminal] alt_screen` as an escape hatch (Zellij, tmux control mode). That is the opposite of fx’s default.

**Do not port** grok’s always-fullscreen pager, dashboard, or in-TUI terminal pane as a second hosted-terminal path.

**Do port** nothing new for the editor/terminal question. The plan already says: host `$EDITOR` via the existing takeover. ACP already lets Neovim host fx the other way.

---

## 5. Highlight

### What exists

- `src/ui/render_engine/code_highlight.zig` — `highlight(alloc, source, profile, theme) ![]u8`
- `src/ui/render_engine/code_highlight_languages.zig` — `Profile` (label, aliases, line/block comments, quotes, keywords, literals, detection)
- Consumers: `src/ui/render_engine/transcript_blocks.zig` (fenced blocks), theme from `ask_presentation.zig`

This is a small keyword/string/number/comment highlighter. Dark/light palettes. No Treesitter, no incremental parse, no scopes.

The viewer must reuse this. Do not add Treesitter or a second highlighter.

Languages already present (non-exhaustive): zig, ts/js/tsx, json, sh, python, plus later profiles in the same file (css, sql, html, go, rust, dockerfile, …). Add a language by growing `code_highlight_languages.zig`, not a viewer-local table.

---

## 6. AlternateScreenOwner

### Current enum (`src/ui/shell_runtime.zig`)

```
none | file_approval | full_transcript | catalog_menu | subagent_manager | terminal_session
```

Helpers: `fileApprovalScreenActive`, `fullTranscriptScreenActive`, `catalogMenuScreenActive`, `subagentManagerScreenActive`, `terminalSessionScreenActive`.

Enter/leave live in `src/core/app/app_lifecycle.zig`:

- `enterAlternateScreen` / `leaveAlternateScreen` — exclusive, writes `\x1b[?1049h/l`, restores mouse
- `leaveAlternateScreens` — switch used by shutdown and SIGTSTP
- Explicit handoffs: full-transcript → approval, catalog → subagent manager, approval → subagent manager, terminal session → subagent manager

Docs that list “five owners” and must gain a sixth:

- `CONTRIBUTING.md` (alternate-screen rule)
- `AGENTS.md` (reproducing render bugs)

### Sixth owner: `code_viewer`

Same enter/leave contract. No permanent chrome leak. Restore main grid, composer, cursor, paste, mouse, focus, keyboard.

Files to touch when the viewer PR lands:

- `src/ui/shell_runtime.zig` — add `code_viewer` + helper
- `src/core/app/app_lifecycle.zig` — enter/leave + `leaveAlternateScreens` arm
- New `src/ui/code_viewer_screen.zig` (or `src/ui/viewer/`) — layout only
- New `src/core/app/app_code_viewer_runtime.zig` — open/search/goto/quit; no product state beyond viewer session
- `src/core/slash_commands/command_specs.zig` + `command_router.zig` — `/view <path>`
- `src/core/app/app_commands.zig` — handler
- `src/ui/resize_tests.zig` — enter/leave/resize restore
- `CONTRIBUTING.md`, `AGENTS.md`

Handoff policy: if approval or terminal-session needs the buffer, close the viewer (do not nest). Follow full-transcript’s “close or hand off, never share” pattern.

Catalog menus already use alternate screen (`models`, `skills`, `settings`, `resume`, `help`). `/view` is not a catalog. Do not reuse `catalog_menu`.

---

## 7. Lua runtime (later PR, seams only)

Ownership: new `src/core/scripting/`. UI and tools call in.

Existing seams Lua v1 should bind, not replace:

| Lua API | Existing fx seam |
| --- | --- |
| `fx.command` | `src/core/slash_commands/command_specs.zig` + `command_router.zig` + `src/core/mods/registry.zig` `CommandRegistry` |
| `fx.keymap` | composer / global maps in `src/core/app/app_input_runtime.zig` (no second keymap owner) |
| `fx.hook` | `src/core/hooks/definitions.zig` `HookKind`: `pre_tool_use`, `stop`, `post_turn_end`, `attention_required` |
| `fx.notify` | existing domain-notice path (`writeDomainNotice`) |
| `fx.opt` | `src/core/config/settings_store.zig` `UserSettingsPatch` + `src/core/config/settings_catalog.zig` |
| `fx.model` / `fx.provider` | resolver after `ModelBackend` exists |
| `fx.view.open` | code viewer runtime |

No second command router. A bad `~/.fx/init.lua` or `<workspace>/.fx/init.lua` is a notice, not a startup abort. WASM/NAPI skip Lua.

Vendor: `third_party/lua/` + `build.zig`. Not LuaJIT.

---

## 8. grok-build: code viewer

Source: `crates/codegen/xai-grok-pager/src/app/agent_view/viewer.rs` plus `views/file_search/line_viewer`.

What grok actually ships:

- **Line viewer** — modal over the fullscreen TUI. `open_line_viewer(path, optional line range)`. Search / filter / goto live in a `ListPane` input bar. `Ctrl+F` toggles fullscreen-inside-modal. `Esc` / `q` / `Ctrl+C` close (`Esc` first clears visual selection or search). Mouse: scrollbar, close, fullscreen button, gutter drag in plan mode.
- **Block viewer** — fullscreen of a *transcript* block (`Enter` / `Ctrl+F` from scrollback). Raw-toggle, copy, click-outside close. This is grok’s “expand this card”, not a file editor.
- **Plan viewer** — same line-viewer chassis with comment / approve / abandon. Out of scope for fx.

Port to fx (mapped onto a sixth alternate-screen owner, not a ratatui modal):

- Open from `/view <path>`, `fx.view.open`, and a tool-result affordance on `read_file` / diffs
- Line numbers
- Search and goto-line
- Scroll, then quit restores the main grid
- Read-only. Write path remains tools or `$EDITOR` takeover

Do not port: plan comments, visual-mode selection, gutter-drag line ranges into the prompt, vim-mode bindings, or grok’s block-viewer-as-IDE. fx already expands command output inline; that stays inline.

---

## 9. grok-build: inline diff viewer

Source: `crates/codegen/xai-grok-pager-diff/src/lib.rs`.

This crate is **not** a fullscreen editor. It turns edit-tool output into line-tagged hunks for the *inline* scrollback:

- `DiffLine { text, lo, ln, tag }` and `DiffHunk = Vec<DiffLine>`
- `build_diff_hunks(&[SearchReplaceEditDetail])` with 3 lines of context
- `diff_hunks_from_strings(old, new, start_line)` for ACP `ToolCallContent::Diff`
- `stitch_overlapping_hunks` — merge adjacent same-file edits; bail rather than render a lie
- `extract_edit_hunks` — structured raw_output, then Diff.meta, then full-text fallback
- `diff_hunks_to_patch` — unified diff for clipboard / `git apply`

**Port the idea, not the crate.** fx already renders tool results inline. A later viewer PR can open a file at the hunk line. Do not add a seventh alternate-screen owner for diffs. If fx grows structured edit hunks, keep them in the transcript (training E2E if they sit on the render path).

Do not vendor grok-build Rust. Reimplement in Zig if/when edit-tool results need hunk stitching.

---

## 10. grok-build: auth / models (protocol reference only)

Grok Build (`xai-grok-pager` docs):

- Browser OAuth at `auth.x.ai`; device-code via `grok login --device-auth`
- Session: `~/.grok/auth.json` (0600), auto-refresh, 30-day fallback expiry
- Fallback: `XAI_API_KEY` after logout
- Custom models: `api_backend = chat_completions | responses | messages`, `base_url`, `env_key`, `extra_headers`
- Default coding model in their tree: `grok-4.5` (confirm catalog at adapter time; do not invent ids)

For fx’s Grok backend: device-code against `accounts.x.ai` (fits `oauth.zig`), persist under `~/.fx/providers/grok/auth.json`, wire through the OpenAI-compatible transport with the subscription token. Catalog: `grok-4`, `grok-build-*` once fetch exists.

ChatGPT: PKCE + loopback (`mcp_auth.authorizeInteractive`), issuer `https://auth.openai.com`, Responses at `chatgpt.com/backend-api/codex`. Not Chat Completions. Not Gateway v3.

Cursor: PKCE + loopback, OpenAI-compatible agent endpoint, isolate client id/URLs in one adapter file.

---

## 11. PR-by-PR file map

### PR 1 — OpenAI-compatible `ModelBackend`

Touch: new `src/core/providers/*`, `src/gateway/openai_compatible.zig`, `src/builtins/providers/openai_compatible.zig`, settings/config ignore list, `/setup` URL+key row, `command_specs`, `cli_surface`, README. Wire at composition in `src/main.zig` only.

Reuse: `stream_provider.Provider`, `GatewayCompletion`, `UserSettingsPatch`, `isProfileOnlySettingKey`, `host.SecretStore`.

Do not touch: `src/gateway/client.zig` parser, agent loop, `CredentialSource`.

### PR 2 — ChatGPT OAuth

Touch: PKCE helper extracted from `mcp_auth.zig`, `src/builtins/providers/chatgpt.zig`, `src/gateway/openai_responses.zig`, `~/.fx/providers/chatgpt/`, `/login chatgpt`.

Reuse: `authorizeInteractive`, `oauth_session` lock/replace, `SignInRuntime` cancel.

### PR 3 — Grok Build OAuth

Touch: `src/builtins/providers/grok.zig`, device-code issuer config, `~/.fx/providers/grok/`, `/login grok`.

Reuse: `oauth.zig` device-code, OpenAI-compatible transport from PR 1.

### PR 4 — Cursor OAuth

Touch: `src/builtins/providers/cursor.zig` only (plus `/login cursor` specs). Isolated so a ToS break does not unwind 1–3.

### PR 5 — Lua 5.4

Touch: `third_party/lua/`, `build.zig`, `src/core/scripting/*`, `/lua` in command specs/router, hook dispatch in `src/core/hooks/`.

Reuse: `HookKind`, slash registry, `writeDomainNotice`, `UserSettingsPatch`.

### PR 6 — Read-only code viewer

Touch: sixth `AlternateScreenOwner`, lifecycle enter/leave, new UI + app runtime, `/view`, highlight reuse, CONTRIBUTING/AGENTS.

Reuse: `code_highlight.zig`, `enterAlternateScreen` / `leaveAlternateScreen`, resize tests.

### PR 7 — Lua LSP

Later. `fx.lsp.start` only after the viewer exists. Permission-gated spawn. No bundled servers.

---

## 12. Hard constraints (from plan + this scout)

- Do not send OpenAI-compatible payloads through the Gateway v3 parser
- Do not add a second agent loop
- Do not put provider keys or OAuth tokens in project `.fx.json`
- Do not grow `src/main.zig` with leaf login or Lua logic
- Do not embed or fork Neovim
- Do not add a second hosted-terminal path
- Do not add Treesitter
- Do not add Lua as a general-purpose OS scripting host
- Verify only with `./zig-out/bin/fx`
- Keep `pub` surface minimal; allocator passed explicitly
)
