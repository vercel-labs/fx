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

## Native OpenTelemetry (prototype)

Native OTLP trace export is disabled unless `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` or `OTEL_EXPORTER_OTLP_ENDPOINT` is explicitly set. For a local collector, for example:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 fx
```

The integration uses the upstream [OpenTelemetry Zig SDK](https://github.com/open-telemetry/opentelemetry-zig). OTLP/HTTP with protobuf is the SDK default; `http/json` is also supported. Signal-specific variables override generic values. The prototype supports:

- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` and `OTEL_EXPORTER_OTLP_PROTOCOL`
- `OTEL_EXPORTER_OTLP_TRACES_HEADERS` and `OTEL_EXPORTER_OTLP_HEADERS`
- `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT` and `OTEL_EXPORTER_OTLP_TIMEOUT`
- `OTEL_EXPORTER_OTLP_TRACES_COMPRESSION` and `OTEL_EXPORTER_OTLP_COMPRESSION`
- `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`, and `OTEL_SDK_DISABLED`

Protocol encoding, compression, transport, batching, and shutdown behavior are delegated to the SDK. Its batch queue is capped at four spans. The pinned alpha SDK does not yet enforce its timeout for OTLP/HTTP and currently drops resource attributes while cloning spans for batch export; those gaps are called out in the draft PR.

By default, spans exclude prompt and response bodies, tool bodies and paths, session IDs, and credentials. Each `fx.turn` span emits `fx.turn.scope` and `fx.turn.outcome`; it may also emit `fx.turn.provider_disposition` and, for failed turns, `error.type`. The GenAI semantic conventions are intentionally not used because they are still in Development.

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
