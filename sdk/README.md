# libfx

`libfx` embeds fx agents and interactive terminals in JavaScript hosts. It exposes the same public APIs in browsers and Node.js:

- `createFxAgent()` for the headless ACP agent
- `createFxTerminal()` for the interactive terminal
- `supportsJspi()` for WebAssembly capability detection
- `encodeXtermKeyEvent()` and `xtermAdapter()` for terminal integration

## Browser

Import the browser entry point and serve the two WebAssembly artifacts beside it:

```js
import { createFxAgent } from "libfx/browser";

const agent = await createFxAgent({
  env: { AI_GATEWAY_API_KEY },
});
```

The default browser assets are `fx-core.wasm` and `fx-term.wasm` beside the JavaScript package. Pass `wasm` explicitly to use another URL, `Response`, byte buffer, or precompiled `WebAssembly.Module`.

Browsers require JavaScript Promise Integration (JSPI), detected by `supportsJspi()`. Use Chrome or Edge 137 or later.

## Node.js

The default `libfx` export is Node-aware:

```js
import { createFxAgent } from "libfx";

const agent = await createFxAgent({
  env: { AI_GATEWAY_API_KEY },
});
```

Node tries a compatible native addon first (`libfx.node`, then a platform-specific `libfx.<platform>-<arch>.node`). The current native addon implements `createFxAgent()` in-process through the ACP core, while Gateway requests use the host's `fetch` implementation and `AbortController`, matching the WebAssembly host boundary. Pass `fetch` to override Node's global implementation. Configure its API key, model, and Gateway URL through `env.AI_GATEWAY_API_KEY`, `env.FX_MODEL`, and `env.FX_GATEWAY_CHAT_URL`. `createFxTerminal()` falls back to WebAssembly. Missing native surfaces always fall back independently.

`nativeAddon` and `env.FX_GATEWAY_CHAT_URL` are trusted host configuration, not request or tenant input. The native backend sends production credentials only to the canonical Vercel AI Gateway endpoint. Custom endpoints are limited to explicit loopback HTTP URLs for local development. Never pass user-controlled module paths, URLs, or environment objects into these options.

The WebAssembly fallback requires JSPI. On Node versions where JSPI is still behind a flag, start Node with:

```sh
node --experimental-wasm-jspi app.mjs
```

If neither a compatible native addon nor JSPI is available, `libfx` rejects with `code === "LIBFX_JSPI_REQUIRED"` and an actionable message. Control backend selection with `backend: "auto" | "native" | "wasm"`; tests and custom distributions may provide `nativeAddon` as a module, path, URL, or `false`.

## Local development

Build the native core addon and both WebAssembly surfaces from the repository root:

```sh
zig build -Dnapi-surface=core -Doptimize=ReleaseSafe
zig build -Dwasm-surface=core -Doptimize=ReleaseSmall
zig build -Dwasm-surface=term -Doptimize=ReleaseSmall
python3 -m http.server 8080
```

Then open:

- [Core debugger](http://localhost:8080/sdk/index.html)
- [Interactive terminal](http://localhost:8080/sdk/term-demo.html)

The local demos pass their development WASM URLs explicitly. Stage a publishable package after both builds with:

```sh
node sdk/scripts/package-libfx.mjs /tmp/libfx-package
```

The staging script includes `zig-out/lib/libfx.node` by default for local testing. When explicit addon paths are passed for publishing, it requires exactly one `ReleaseSafe` binary for each supported target: Linux x64, Linux arm64, macOS x64, and macOS arm64. Published WebAssembly artifacts use `ReleaseSmall`.

The npm `latest` dist-tag is the stable channel. The `dev` dist-tag tracks successful builds from `main` and uses immutable prerelease versions. Publishing runs through `.github/workflows/publish-libfx.yml` with npm trusted publishing and provenance. Configure the npm trusted publisher for the `vercel-labs/fx` repository, workflow filename `publish-libfx.yml`, and GitHub environment `npm`. Because npm requires a package to exist before trusted publishing can be configured, the first `libfx` version must be published once by a maintainer before enabling that relationship.

JavaScript hosts can provide configuration, prompt history, session persistence, device login, URL opening, and a foreground workspace. The optional workspace adapter exposes only `terminal` with `{ action: "exec", command }`; command execution is delegated to the host with the workspace's validated current directory.

The workspace metadata contract has two exact versions:

| Version | Git | Storage | Current directory |
| --- | --- | --- | --- |
| 1 | unavailable | ephemeral | must equal `root` |
| 2 | available | persistent | `root` or a directory beneath it |

Both versions require normalized absolute `root`, `cwd`, and `home` paths plus a permission of `allow-sandboxed` or `prompt`. Hosts own workspace provisioning, persistence, source synchronization, and cleanup; FX keeps provider lifecycle code and dependencies outside the SDK. Command execution remains bounded to 64 KiB of input and output, a 30-second maximum deadline, and host `AbortSignal` cancellation.

WebAssembly builds do not include native processes, OS sandboxing, native MCP, subagents, skills, auto-upgrade, clipboard integration, arbitrary WASI filesystem access, or web search.
