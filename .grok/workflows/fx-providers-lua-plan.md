# Providers, Lua, and a first-class viewer

fx stays a Unix-shell coding agent. It does not become an IDE, and it does not embed or fork Neovim. Lua is the native extension language. A read-only code viewer and an optional LSP client give Neovim-like leverage without taking on Neovim's editor.

This plan covers the unfinished provider work and the Lua question in one stack.

## Product decision: do not embed or fork Neovim

| Option | Verdict | Why |
| --- | --- | --- |
| Embed Neovim in-process | No | Production ceiling is 7.800 MiB. Neovim plus runtime is larger than fx. WASM/NAPI cannot ship it. It fights the README: closer to a Unix shell than an IDE in the terminal. |
| Fork a lightweight Neovim | No | A years-long editor project. Duplicates `src/core/terminal/` (already a bounded VT + hosted child). Five exclusive `AlternateScreenOwner`s are already a hard invariant. |
| Host `$EDITOR` / `nvim` as a child | Already exists | `AlternateScreenOwner.terminal_session` plus `TerminalHost` can run nvim, helix, or any TUI after the human write lease. ACP already lets Neovim host fx the other way. |
| Vendor Lua 5.4 and grow `fx.*` | Yes | This is what Dax described: a minimal native harness plus an embedded language. Lua 5.4 C is ~200–300 KiB stripped. |

Neovim's power is not the modal editor. It is a small language that can reach every seam. Map that onto an agent harness, not onto buffers and windows.

| Neovim | fx |
| --- | --- |
| `init.lua` / `~/.config/nvim` | `~/.fx/init.lua`, `~/.fx/lua/`, `<workspace>/.fx/init.lua` |
| `vim.cmd` / user commands | `fx.command` |
| `vim.keymap` | `fx.keymap` |
| autocmd | `fx.hook` on existing hook kinds, then more events |
| `vim.opt` | `fx.opt` over profile settings |
| `vim.lsp` | `fx.lsp` starting user-installed servers |
| buffers / windows | viewer + transcript + composer, not a modal editor |
| plugins | `~/.fx/pack/<name>/lua` |

Humans edit in `$EDITOR`. The agent edits through tools. fx shows code.

## Architecture

### Model backend (new contract)

Today every credential is a Vercel AI Gateway token. `FX_GATEWAY_CHAT_URL` only rewrites the URL; the body is still Gateway v3 (`prompt`, `toolChoice`, `text-delta`). OpenAI-compatible and subscription OAuth cannot ride that parser.

Introduce `ModelBackend` as a first-class profile setting. Do not overload `CredentialSource` (that enum is Gateway access methods: OIDC, env key, fx login, stored key).

```
ModelBackend = vercel_gateway | chatgpt | grok | cursor | openai_compatible
```

Each backend owns auth, request build, stream parse, model catalog, and default model. The existing `stream_provider.Provider` (`build` + `stream` → `GatewayCompletion`) stays the agent seam. New backends adapt into that completion type so the agent loop, tools, and transcript do not fork.

Ownership:

- `src/core/providers/` — backend kind, config, session store, catalog contract
- `src/gateway/openai_compatible.zig` — Chat Completions SSE
- `src/gateway/openai_responses.zig` — Responses API (ChatGPT Codex)
- `src/builtins/providers/` — ChatGPT, Grok, Cursor, OpenAI-compatible adapters
- `src/core/auth/` — stays token/session mechanics; grow PKCE reuse from `src/core/mcp/mcp_auth.zig` rather than a second OAuth stack
- `src/ui/` — login/setup picker only; no product state

Persistence (profile-owned, not project `.fx.json`):

- `~/.fx/settings.json` → `provider`, `openai_compatible.base_url`, `openai_compatible.api_key_env`
- `~/.fx/providers/<backend>/auth.json` — OAuth sessions, same lock/durable-replace pattern as `oauth_session.zig`
- env: `FX_PROVIDER`, `FX_OPENAI_BASE_URL`, `FX_OPENAI_API_KEY`, plus existing `AI_GATEWAY_API_KEY`

`provider`, `openai_compatible`, and subscription tokens are profile-only, same ignore rule as `model` / `credential_source`.

### Lua runtime (new contract)

Ownership: `src/core/scripting/` (runtime, API, load order). UI and tools call in; they do not own Lua state.

- Vendor Lua 5.4 C under `third_party/lua/` and compile it from `build.zig`. LuaJIT is rejected (arch/WASM pain, larger, another JIT).
- Native CLI/TUI first. WASM/NAPI skip Lua until a later host port. Do not block embed surfaces.
- Sandbox: no `os.execute` / `io.popen` unless the permission system grants it. File reads default to `~/.fx/lua`, `~/.fx/pack`, and the workspace `.fx/` tree. Network stays behind existing tools/permissions.
- Load order: `~/.fx/init.lua` then `<workspace>/.fx/init.lua`. Errors are notices; a bad script must not abort startup.
- Reload: `/lua reload`. Status: `/lua` lists loaded files and registered commands.

`fx` API (v1, small on purpose):

- `fx.command(name, fn, opts)` — slash command
- `fx.keymap(lhs, fn, opts)` — composer/global maps
- `fx.hook(kind, fn)` — `pre_tool_use`, `stop`, `post_turn_end`, `attention_required`
- `fx.notify(msg, opts)` — semantic notices
- `fx.opt` — get/set profile settings the user can already change
- `fx.model`, `fx.provider` — read current backend/model
- `fx.view.open(path, opts)` — code viewer
- `fx.lsp` — later PR, same module

No second command router. Lua commands register into the existing slash registry / dispatch path.

### Code viewer (first-class UI, not an editor)

Sixth `AlternateScreenOwner`: `code_viewer`. Same enter/leave contract as the other five (restore main grid, composer, cursor, paste, mouse, focus, keyboard). Document the exception in `CONTRIBUTING.md`.

Reuse `src/ui/render_engine/code_highlight.zig` (already has language profiles). Add:

- line numbers, search, goto line
- open from `/view <path>`, `fx.view.open`, and a tool-result affordance for `read_file` / diffs
- read-only. Write path is the agent tools or `$EDITOR` via terminal takeover

Do not add Treesitter or a modal editor.

### LSP (optional, Lua-driven, no bundled servers)

Not a bundled `rust-analyzer`. A JSON-RPC client:

```lua
fx.lsp.start({
  name = "zls",
  cmd = { "zls" },
  root = fx.workspace.root,
})
```

Shows diagnostics in the viewer; go-to-definition reopens the viewer. Servers are whatever the user already installed. Permission-gated process spawn. This is a later PR after the viewer exists.

## Provider details

AI SDK packages (`@ai-sdk/openai`, `@ai-sdk/openai-compatible`, `@ai-sdk/xai`, community ChatGPT/Cursor OAuth providers) are protocol references only. This repo has no Node runtime. Reimplement the wire format in Zig.

### OpenAI-compatible (foundation)

- Config: `base_url` + API key (`FX_OPENAI_API_KEY` or stored secret)
- Wire: `POST {base}/chat/completions` with `stream: true`, `tools`, SSE `choices[].delta`
- Catalog: `GET {base}/v1/models` when present, else configured ids
- Credits/usage: not claimed. `/credits` says the backend has no gateway balance
- This is also the transport under Grok (xAI is OpenAI-shaped) and a fallback for Cursor

### ChatGPT subscription OAuth

- Official Codex-style ChatGPT login (same class of flow OpenClaw/Cline use)
- PKCE + loopback callback, reuse `mcp_auth.authorizeInteractive` (already binds `127.0.0.1:0` and PKCE)
- Issuer `https://auth.openai.com`; persist refresh token under `providers/chatgpt/`
- Wire: Responses API at `chatgpt.com/backend-api/codex` (not Gateway v3, not plain Chat Completions)
- Device-code fallback if a loopback port cannot bind (headless), only if the issuer documents it
- Models: Codex catalog (gpt-5.x-codex family); do not invent ids

### Grok subscription OAuth (Grok Build)

- Device-code against `accounts.x.ai` (fits existing `oauth.zig`)
- Session under `providers/grok/`
- Wire: Grok Build / xAI OpenAI-compatible chat with the subscription token
- Models: Grok Build catalog (`grok-4`, `grok-build-*`); default the coding model once catalog fetch exists

### Cursor subscription OAuth

- PKCE + loopback, same auth helper as ChatGPT
- Session under `providers/cursor/`
- Wire: Cursor's OpenAI-compatible agent endpoint with their required headers
- ToS is the grayest of the three. Ship it because it was requested; keep client id/endpoints in one adapter file so they can be dropped without touching the agent loop
- If Cursor rejects unofficial clients, `/login cursor` fails cleanly with their error body

### Login / setup UX

- `fx login [vercel|chatgpt|grok|cursor]` and `/login [backend]`
- Bare `fx login` / `/login` stays Vercel (no behavior change for current users)
- `/setup` picker grows: Vercel key, OpenAI-compatible URL+key, and the three subscription logins
- `/logout` logs out the active backend's session; `/logout vercel|chatgpt|...` targets one
- Remembered `provider` wins like remembered `credential_source`

## What not to do

- Do not send OpenAI-compatible payloads through the Gateway v3 parser
- Do not add a second agent loop
- Do not put provider keys or OAuth tokens in project `.fx.json`
- Do not grow `src/main.zig` with leaf login or Lua logic
- Do not bundle language servers or Treesitter grammars
- Do not add Lua as a general-purpose OS scripting host (permissions stay first)
- Do not document subscription OAuth as if it were Vercel-billed Gateway usage

## PR stack

Each PR is one `type:` label, one user-facing seam, focused tests plus `./zig-out/bin/fx` on the happy path.

1. **type: feature — Add OpenAI-compatible model backend**  
   `ModelBackend`, config, Chat Completions builder/parser, `/setup` URL+key, catalog, docs. Default remains Vercel Gateway.

2. **type: feature — Add ChatGPT subscription OAuth**  
   PKCE helper extracted from MCP auth if needed, ChatGPT session store, Responses stream adapter, `/login chatgpt`.

3. **type: feature — Add Grok Build subscription OAuth**  
   Device-code login, Grok adapter on the OpenAI-compatible transport, `/login grok`.

4. **type: feature — Add Cursor subscription OAuth**  
   PKCE login, Cursor adapter, `/login cursor`. Isolated so ToS breakage does not unwind 1–3.

5. **type: feature — Embed Lua 5.4 for commands, keymaps, and hooks**  
   Vendor Lua, load `init.lua`, `fx.command` / `fx.keymap` / `fx.hook` / `fx.notify` / `fx.opt`, `/lua`. Native only.

6. **type: feature — Add a read-only code viewer**  
   Sixth alternate-screen owner, `/view`, highlight reuse, `fx.view.open`.

7. **type: feature — Add an optional Lua LSP client**  
   `fx.lsp.start`, diagnostics + definition in the viewer. No bundled servers.

## Tests and docs (per PR)

- Zig unit tests next to the new parser, backend resolver, Lua API, and viewer layout
- E2E: login picker / `/login chatgpt` dry path with a fake issuer (pattern from `tests/e2e/auth-refresh.test.ts` and MCP OAuth fixtures). Classify in `scripts/pgso/corpus.json`: auth/login flows are **verification-only**; Lua command registration is **training** if it sits on the startup path
- Live OAuth against real ChatGPT/Grok/Cursor is an **intentional exclusion** (credentialed, nondeterministic)
- Docs: `README.md` login/setup, `command_specs.zig` help, CONTRIBUTING alternate-screen list
- Binary size: Lua vendor + two stream parsers will show up on the 50 KiB warning. Stay under 7.800 MiB; strip Lua, do not ship Lua headers/docs

## Verification (Declaring Work Ready)

For each PR: `zig fmt --check src/`, focused Zig tests, `zig build`, then exercise `./zig-out/bin/fx` (not PATH):

- OpenAI-compatible: `/setup` URL+key against a local fake `/v1/chat/completions`, one streamed reply
- Each OAuth: start `/login <backend>` against a fake issuer; confirm URL/code, cancel, persisted session file
- Lua: `~/.fx/init.lua` that registers `/hello`; run it; broken `init.lua` must not crash
- Viewer: `/view src/main.zig`, scroll, search, quit, confirm main grid restored
- Confirm stderr clean and no abort

Full CI + ship gate on the exact commit before marking ready.
