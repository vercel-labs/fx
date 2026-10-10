```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent CLI written in Zig: a small native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

## Highlights

- **Any model:** Vercel AI Gateway, ChatGPT or Grok subscriptions, or your own OpenAI-compatible endpoint such as Ollama or OpenRouter
- **Any interface:** interactive shell, one-shot `fx ask` for scripts, or embedded through libfx and ACP
- **Shell-like output:** inline rendering that preserves your terminal scrollback
- **Extensible:** skills, MCP servers, and subagents

<p>
  <a href="https://vercel.com/labs#labs-products"><img alt="Vercel Labs Product" src="https://img.shields.io/badge/LABS-PRODUCT-0a0a0a.svg?style=for-the-badge&amp;logo=Vercel&amp;labelColor=000000" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/releases/latest"><img alt="fx CLI release" src="https://img.shields.io/github/v/release/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000&amp;label=release" height="28"></a>
  <a href="https://github.com/vercel-labs/fx/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/github/license/vercel-labs/fx.svg?style=for-the-badge&amp;labelColor=000000" height="28"></a>
</p>

## Install

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Get started

Sign in with one of:

- `fx login`: Vercel AI Gateway
- `fx login codex`: ChatGPT subscription (OpenAI Codex OAuth)
- `fx login grok`: Grok subscription (xAI OAuth)
- `fx setup`: AI Gateway API key

fx loads Grok models from your subscription's live catalog, so new supported models appear without a static model list. Public xAI metadata enriches image support but does not filter subscription models.

Then start the interactive shell from a project:

```bash
cd your_project
fx
```

Or make a one-shot request:

```bash
fx ask "explain the changes in this repository"
```

Inside the shell, run `/help` to browse interactive commands.

In tmux, use your usual prefix bindings to switch sessions or enter copy mode.
fx preserves those tmux views while resizing, including when the switcher zooms a split pane.

The interactive shell reports its state with the [Program Status Protocol (OSC 7501)](https://www.superlogical.com/rex/docs/build/program-status), so a terminal that supports it can show when fx is working, waiting for your approval or answer, done, or stopped by an error. Approval and question reports include the request or question text. When fx exits or is suspended, it clears the terminal's status records. Terminals without support ignore the reports.

## Images

Paste an image, attach one with `fx ask --image PATH`, or ask fx to `read_file` a PNG, JPEG, GIF, or WebP. File-backed attachments retain the original image. Before each model request, it checks the complete image count and sends only images that fit: at most 8000 pixels per side with 20 or fewer images, or 2000 pixels per side with more than 20. The encoded per-image limit is 5 MiB.

When a file-backed image cannot be sent, the model receives its source path and the reason. It can use an image tool already on your system, such as `sips` on macOS or `ffmpeg` on Linux, to save a smaller **new** file and read that copy. fx does not automatically install image tools or overwrite the original. If no usable file or tool is available, the model should ask you for a smaller copy or permission before installing software.

Every request re-sends the images already in the conversation, so image-heavy sessions keep requests under 30 MiB and 100 images. When a request would be larger, fx leaves the oldest images out of that request and tells the model how to load each one again; your conversation history is unchanged. If a provider still rejects a request as too large, fx lowers the limit for that model in the current conversation and retries with fewer images instead of compacting.

## Shell commands

Commands run in your login shell, zsh or bash, with your startup files applied, so your aliases, functions, and `PATH` work as they do in your terminal. fx runs the startup files once and restores their result for each command, so a slow `.zshrc` does not slow down every call.

- fx reloads automatically when your zsh or bash startup files change, such as `.zshrc`, `.zprofile`, `.bash_profile`, or `.bashrc`. After changing a file they source, run `/shell reload`.
- Each command starts fresh: `cd`, `export`, and alias changes do not carry over to the next one.
- Tools that switch the environment by directory, such as direnv or mise hooks, apply the environment of the directory where fx captured the startup files, usually your workspace.
- If the startup files cannot be captured, fx says so once and runs them for every command instead.
- Terminals opened with `tty: true` run your full login shell and end when fx exits.

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
fx provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

## Ultrafast mode

Ultrafast mode is off by default. It requests OpenAI's higher-cost Gateway service tier with `openai.serviceTier: "ultrafast"` for models whose Gateway metadata advertises Ultra eligibility. `ultrafast_requested` in `fx status --json` and `/status` reports the request, not a guarantee that a provider served the tier.

Set a profile default in `~/.fx/settings.json`:

```jsonc
{
  "provider": "gateway",
  "models": { "gateway": "openai/gpt-6-astra" },
  "ultrafast_mode": true
}
```

Use it explicitly in an interactive session, a one-shot request, or ACP:

```bash
fx --ultrafast
fx ask --ultrafast "review this change"
fx acp --ultrafast
```

Use `/ultrafast on`, `/ultrafast off`, or `/ultrafast status` in the shell. The Settings menu includes an Ultra mode row. `FX_ULTRAFAST=1` and `--ultrafast` are process-local opt-ins and are not persisted. `FX_ULTRAFAST=0`, `--no-ultrafast`, and `/ultrafast off` explicitly disable it. A resumed session keeps its saved request unless a higher-precedence explicit disable applies.

Ultra mode is available only through the Vercel AI Gateway's OpenAI service tier. Gateway metadata currently marks Astra eligible. fx does not select Ultra automatically, and switching models clears an existing Ultra request. Subagents inherit the parent turn's request; an explicit parent disable and capability checks override an existing child preference. Background side calls, including titles, reviews, and compaction, do not use Ultra mode.

ACP clients get the same per-session choice as the shell. The config options from `session/new`, `session/load`, `session/resume`, and `session/set_config_option` include `fast` only for models with a Fast lane and `ultrafast` only for Ultra-eligible models, each with the values `false` and `true`. Turning one on turns the other off, enabling a lane the model lacks returns an error, and switching models turns off a lane the new model lacks. The choice is saved with the session. An unknown config option id returns an error. To show these choices before a session exists, `fx models --json` describes each Gateway model by the same rules: its display `name`, the `efforts` it accepts besides `auto`, and whether it has `fast` and `ultrafast` lanes. `fx status --json` run in the workspace reports the `model` and `effort` a new session there starts with.

## Gateway provider routing

When the active model goes through the Vercel AI Gateway, one model is often served by several providers (for example Anthropic directly, AWS Bedrock, or Google Vertex). fx can tell the gateway which providers to use, in what order:

```jsonc
// ~/.fx/settings.json
{
  "provider_order": ["bedrock", "anthropic"], // try Bedrock first, then Anthropic
  "provider_strict": false                     // true restricts requests to only these providers
}
```

Both keys also work in a committed project `.fx.json`, and per launch:

```bash
fx --provider-order azure,openai --provider-strict
fx ask --provider-order bedrock "review this change"
FX_PROVIDER_ORDER=vertex FX_PROVIDER_STRICT=1 fx
```

Slugs are the gateway's provider identifiers (letters, digits, dashes, for example `anthropic`, `bedrock`, `vertexAnthropic`), listed on the [models page](https://vercel.com/ai-gateway/models). An empty `provider_order` in a higher-precedence layer clears a list set by a lower one. Routing applies to gateway requests only; custom model connections ignore it.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Context compaction

When a conversation fills the model's context, fx compacts it so the work can continue. The newest few turns stay unchanged. Every compacted turn keeps your messages and the assistant's final reply word for word. The conversation's own model adds a short note on what the assistant did in between, and a line for each tool call: fx writes what the call was from the call itself, like `shell zig build test (failed, exit 1, 3120 bytes)`, and the model adds why it was used and what it showed. The model also keeps numbered entries for your rules, quoted word for word, and for facts, decisions, status and open questions, plus a list of the skills and MCP tools used. Entries are never rewritten: a later entry can say it replaces an earlier one, and a status entry can close an open entry it answers or finishes. At the next compaction, the one before it is saved whole with an ID like `L2`, and in its place the agent sees a short summary the model writes of all earlier compactions, plus their rules, status and open entries still in force, word for word. The turns of earlier compactions leave the agent's view however many compactions a session has; only those kept entries grow with it. In a session that is not saved, nothing can be stored, so earlier compactions stay in view. fx checks every new note and entry, and marks without removing one that names no source, quotes words you did not write, states a path, long number, version or quoted text found in none of the compacted turns and tool calls or the turns that stay after them, names an ID that does not exist, or calls a failed tool call a success; turns the model skipped, or a missing summary of earlier compactions, are asked for once more. Only when the compacted conversation would leave too little room to continue are its longest texts shortened to their start and end, each naming the saved turn that keeps it whole. Every compacted turn is saved word for word with an ID like `M3`, every tool call with its input and output as the model saw them, plus the handle of any full output saved separately, with an ID like `T12`, and every earlier compaction with an ID like `L2`. The agent can search them by text or open one by ID with `read_tool_result`; a search also says how many saved records hold all of its words, and which came first and last.

Automatic compaction asks the model right after the conversation, exactly as the agent was about to send it and with the same settings, so the provider can reuse what it has cached. When that request does not fit or fails, and when you run `/compact` to compact now, fx writes the turns out in a separate request at the model's lowest reasoning; turns too large for one such request go oldest first, in as many requests as it takes. If a separate request fails or comes back empty on AI Gateway, fx retries it once with a model from another provider.

Automatic compaction starts when a request reaches 80 percent of the model's usable input. Set `auto_compact_percent` in `~/.fx/settings.json` to any value from 10 to 80, or `FX_AUTO_COMPACT_PERCENT` for a single launch:

```jsonc
// ~/.fx/settings.json
{ "auto_compact_percent": 60 }
```

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

ACP clients can keep their MCP tools loaded on every turn, steer a running turn, supply a session system prompt, serve MCP servers over the ACP connection, and choose each session's workspace. See [ACP embedding](CONTRIBUTING.md#acp-embedding).

ACP sessions offer the CLI's permission modes, `auto` (the default), `ask`, and `full-access`, as the `mode` config option and in `modes`. A session starts in the saved `permission_mode`, and choosing a mode with `session/set_config_option` or `session/set_mode` saves it, like `/permissions` in the shell. Any other mode returns an error. To show the choice before a session exists, `fx status --json` run in the workspace reports the `mode` a new session there starts in and lists the `modes`, each with its `id`, `name`, and `description`.

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

## Connect your Slack account

Run `/mcp add slack` in an fx session, or `fx mcp add slack` from your terminal.
The command saves Slack's MCP URL and the public fx Client ID to your profile,
opens the fx.sh authorization flow, and connects Slack after you consent. Keep
fx running while you authorize in a browser on the same computer. In an fx
session, Slack's tools become available without a restart. The **Servers** tab
in `/mcp` also offers **Add Slack** with the `s` key.

You don't need to edit `~/.fx/mcp.json` or run `fx slack install` to connect your
personal account. Workspace app approval may still be required. fx reports
`Slack connected. You can now use Slack.` after the connection succeeds.

Running the command again uses an existing working connection or starts
missing authorization. It restores a missing fx Client ID and preserves other
servers, timeouts, and explicit scope overrides. A conflicting Slack endpoint,
Client ID, or authentication configuration stops setup with guidance instead of
being overwritten. Use `/mcp auth slack --open` to reauthorize an existing
configuration. Removing and re-adding the fx preset restores its configuration;
it does not revoke credentials. Use `/mcp logout slack` to sign out.

## Slack workspace installation

Run `fx slack install` to install the fx bot in the configured Vercel Slack
workspace. Keep the command running and authorize Slack in a browser on the same
computer. The HTTPS callback at fx.sh returns the authorization to the CLI;
PKCE state and the verifier stay in memory. The companion web bridge must be
deployed and configured first.

After the CLI saves the installation, the browser returns to an fx.sh confirmation
page. You can close that tab or refresh it after the command exits.

`fx slack status --json` reports local installation metadata without tokens.
Plain-text output omits Slack IDs and shows expiration as a readable UTC date
and time. JSON output retains the IDs and Unix timestamps for scripts.
`fx slack refresh` rotates the local bot credentials when needed. Credentials
live in the owner-only file `~/.fx/slack/installation.json`; no hosted database
or background refresh service is created. An expired refresh token requires
installation again. This workspace operation is separate from each employee's
MCP user authorization. Employees connect their own account with
`/mcp add slack` in an fx session (or `fx mcp add slack` from a terminal).
For `https://mcp.slack.com/mcp`, the CLI recognizes the fx app by its public
Client ID and uses the HTTPS callback for personal login. Changing that Client
ID requires a CLI update. OAuth uses the canonical form of Slack's advertised
resource, `https://mcp.slack.com/`, while the MCP transport remains at
`https://mcp.slack.com/mcp`. First login and reauthorization request the full shared
`user_scopes` list from fx.sh. If local `scopes` are configured, they must include
every shared scope; extra local scopes are not requested. A narrower or explicitly
empty list stops authorization before opening the browser, leaving the configuration
and stored credentials unchanged. Remove the override only if you want to authorize
the full shared scope set. Per-user read-only subsets are not supported for the fx app. Saved scopes,
Slack's advertised capabilities, and scope challenges cannot expand this
request. The shared list contains nine personal scopes configured for fx and
advertised by Slack MCP; changing it requires a deliberate configuration update
and any necessary Slack approval. This does not revoke
permissions on previously issued tokens or change token refresh behavior. It
opens an ephemeral loopback listener instead of the configured `callback_port`,
keeps PKCE and personal tokens in the CLI, and shows “Slack connected” after
saving to the existing MCP credential store. Other MCP providers and different
Slack app Client IDs retain their direct callback behavior without contacting
fx.sh. Fx app authorization requires fx.sh to be available; an unavailable
metadata endpoint returns `SlackBridgeUnavailable`. Deploy the web
personal-authorization routes and scope metadata before releasing this CLI.
Missing or invalid shared scopes stop authorization rather than falling back
to Slack's broader capabilities. Keep the registered
localhost callback for older clients until they have upgraded. Slack workspace
approval requirements still apply to personal authorization.

Bot installation does not establish whether
Slack will display a hoverable “Sent using @fx” attribution; that requires a
live message test.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## Security

Report security vulnerabilities through the [contact page](https://fx.sh/contact) instead of a public issue.

## License

[Apache-2.0](LICENSE). Third-party licenses and attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
