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

fx is a coding agent CLI written in Zig: a 6.17 MiB native binary that is open source (Apache-2.0), model-agnostic, and embeddable as a harness in larger systems. Its interface stays closer to a Unix shell than an IDE in the terminal.

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

## Custom model connections

The native CLI can use a user-configured OpenAI Chat Completions endpoint, including local servers and gateways such as Ollama and OpenRouter. Add named connections to `~/.fx/settings.json`; keep existing unrelated settings. For example:

```json
{
  "provider": "local",
  "providers": {
    "local": {
      "protocol": "openai-chat-completions",
      "base_url": "http://localhost:11434/v1",
      "auth": { "type": "none" }
    },
    "openrouter": {
      "protocol": "openai-chat-completions",
      "base_url": "https://openrouter.ai/api/v1",
      "auth": { "type": "bearer", "env": "OPENROUTER_API_KEY" }
    }
  },
  "models": {
    "local": "qwen2.5:7b",
    "openrouter": "openai/gpt-4.1"
  }
}
```

Use a model actually available on your server. `base_url` includes the API prefix, such as `/v1`; fx adds `/chat/completions`. Remote endpoints require HTTPS. Loopback HTTP is supported for local servers. Anonymous connections send no Authorization header; bearer connections read only their named environment variable, not a Gateway or subscription credential.

```bash
fx provider local
fx ask "explain this repository"
FX_PROVIDER=openrouter FX_MODEL=openai/gpt-4.1 fx ask "review this change"
fx status --json
```

`fx provider` saves a preference. `FX_PROVIDER` and `FX_MODEL` affect the invocation without rewriting settings. User-owned workspace overrides can select a connection; committed project `.fx.json` cannot define or select model endpoints. The interactive sign-in picker remains for built-in providers. Configured connections are selected through the file or CLI and work in the interactive shell, `fx ask`, and native ACP.

An explicit model does not require catalog discovery. `fx models` lists model IDs supplied in the connection's optional `model_metadata` object. Its per-model fields are `context_window`, `max_output_tokens`, `supports_tool_use`, and `supports_vision`. Set token limits to the server's actual configuration; without a known context window, automatic compaction cannot determine its threshold. Native image input is not yet implemented by this adapter, even if the backend supports it.

Text and function-tool streaming are supported. Streams must include a finish reason followed by `[DONE]`; partial tool arguments never execute. Provider-specific reasoning/replay formats and the Responses API are not part of this adapter. The default `tool_choice_mode` is `omit` for servers with partial OpenAI compatibility; set it to `send` only when the server supports that field. Required tool outcomes are still validated locally.

Automatic permission review uses the selected model on the same connection. An optional `reviewer_model` in that connection can select another model there. A model that cannot produce a valid review decision leaves the action unapproved; fx never silently uses a cloud reviewer or changes permission mode. Gateway-only search, credits and vision fallback are unavailable on custom connections. Token usage is reported when provided; unknown cost is not treated as zero.

Saved custom sessions retain the connection name and a non-secret endpoint/authentication fingerprint. Changing or removing that connection prevents an implicit resume against a different destination. Existing history remains readable. Built-in sessions retain their existing provider representation; custom sessions require a build that supports configured connections. Invalid profile configuration fails model startup rather than falling back to Gateway. An unsafe profile directory still permits interactive inspection and local recovery, but model requests stay disabled until you repair the profile and restart fx.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

The SDK is published to npm as [libfx](https://www.npmjs.com/package/libfx). For runnable Node.js, browser, Next.js, and Nuxt applications, see the [libfx examples](examples/README.md).

## Extend fx

- [Skills](https://fx.sh/docs/capabilities/skills): reusable instructions the agent loads when invoked
- [MCP](https://fx.sh/docs/capabilities/mcp): connect external tools and servers
- [Subagents](https://fx.sh/docs/capabilities/subagents): delegate independent work

## Documentation

Read the [fx documentation](https://fx.sh/docs) for sessions, models, permissions, configuration, and the full CLI and slash command references.

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
