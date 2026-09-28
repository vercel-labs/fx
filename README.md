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

## Documentation

Visit [fx.sh/docs](https://fx.sh/docs) for the full manual: sessions, models, custom model connections, permissions, configuration, skills, MCP, subagents, embedding, and the complete CLI and slash command references. Agents can read any page as Markdown by appending `.md` to its URL, or fetch [llms-full.txt](https://fx.sh/llms-full.txt) for everything in one file.

## Custom model connections

Add named connections for any OpenAI Chat Completions endpoint, including local servers such as Ollama and gateways such as OpenRouter, in `~/.fx/settings.json`, then select one for the profile or a single invocation:

```bash
fx provider local
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
```

See [Custom model connections](https://fx.sh/docs/configure-fx/custom-model-connections) for connection JSON, model metadata, and behavior details.

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

## Permission hook

A command you configure can answer the permission prompt fx shows in the interactive terminal, for example an approval app on your phone. fx opens its prompt as usual and runs the command at the same time; the first answer wins. The command can allow that exact action once or deny it. It cannot approve anything fx would not have asked you about, and a configured deny is resolved before any prompt opens.

```jsonc
// ~/.fx/settings.json (top level only; ignored in .fx.json and workspaces overrides)
{
  "permission_hook": {
    "command": ["/usr/local/bin/approve-fx"], // argv, run without a shell
    "timeout_ms": 300000                      // 1000 to 3600000, default 300000
  }
}
```

`command[0]` must be an absolute path, and the command starts in `/`, never in the workspace, so neither a relative path nor the working directory can pull the program or its modules from the repository. It inherits fx's environment, including `PATH` and any credentials fx was started with, so name interpreters and helpers by absolute path too. It reads one JSON document on stdin:

```json
{
  "version": 1,
  "event": "permission_request",
  "request_id": 7,
  "session_id": "…",
  "workspace_root": "/path/to/workspace",
  "origin": "session",
  "tool": { "name": "shell", "call_id": "call_1", "arguments": { "action": "run", "command": "npm publish" } },
  "prompt": { "label": "shell.run npm publish", "command": "# shell.run profile=user shell=/bin/zsh\nnpm publish", "explanation": null, "tool_arguments_preview": null, "file": null },
  "choices": ["allow", "deny"]
}
```

`prompt` carries the label, command and explanation the terminal prompt shows. For file writes and edits, `prompt.file` carries the `kind` (`write` or `edit`), the `intent`, the `path`, the `external_tree` root for a change outside the workspace (otherwise `null`), the `additions` and `deletions` counts, and a preview of at most 6 `lines`, each with an `op` and its `text`. `truncated` is `true` when the preview leaves lines out; the terminal can show you the full review.

It answers on stdout and exits 0:

```json
{ "decision": "allow" }
{ "decision": "deny", "reason": "Denied from my phone" }
{ "decision": "none" }
```

A deny reason is passed to the model. Anything else is no answer and leaves the prompt with you: a missing or non-executable command, a non-zero exit, a crash, output over 64 KiB, invalid JSON, an unknown decision, or running past `timeout_ms`. fx does not run the command when the request would be larger than 1 MiB or the tool arguments are not JSON. The command's stderr is discarded.

The command runs in its own process group. If it is still running when the prompt closes or the timeout passes, fx kills that group and reaps the command. fx does not promise to stop processes the command leaves running after it exits, or any it moves out of its group, for example with `setsid`. If such a process holds stdin without reading it, fx stops waiting to finish writing the request; the unread input is released when that process exits. An answer from the command is recorded in the transcript as an ordinary one-time approval or deny.

The hook runs only for prompts in the interactive terminal. It never runs in full access, for `fx ask`, for ACP clients, or for subagent approvals. A malformed `permission_hook` disables only the hook and is reported by `fx doctor`; one inside a `workspaces` override is reported and ignored.

## Themes

fx ships with `fx-dark` and `fx-light` and follows your terminal's light or dark mode. Pin a variant with `FX_THEME=light` or `FX_THEME=dark`, or drop a VS Code format theme at `~/.fx/themes/<name>.json` and select it with the `theme` setting or `FX_THEME=<name>` per launch. Without an explicitly selected theme, diff markers and edit counts stay monochrome; selecting any theme adds its diff marker colors. See [Configuration](https://fx.sh/docs/configure-fx/configuration) for all environment variables.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). See the [WebAssembly SDK](sdk/README.md) and the runnable Node.js, browser, Next.js, and Nuxt [examples](examples/README.md). The WebAssembly SDK is experimental.

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
`/mcp auth slack --open` in an fx session (or `fx mcp auth slack` from a terminal).
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
