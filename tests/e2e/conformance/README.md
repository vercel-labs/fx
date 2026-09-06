# MCP conformance baseline

This package runs the official MCP client conformance suite against the freshly
built fx binary. It is pinned to:

- MCP protocol version `2026-07-28`
- `@modelcontextprotocol/conformance@0.2.0-alpha.10`
- conformance repository revision
  `a9896553900a2ef61787b57adfcbbe936a8ab1f9`

This directory is an isolated npm subproject. npm owns its checked-in
`package-lock.json` and installs the pinned official runner. Bun executes fx's
TypeScript adapter after installation; it does not resolve dependencies here.
Do not run `bun install` or create a Bun lockfile in this directory.

The package requires Node 22 or newer, npm 10 or newer, and the Bun version
used by the surrounding E2E suite. Local `.npmrc` policy requires the lockfile,
rejects unsupported engines, and disables dependency lifecycle scripts.

From the repository root:

```sh
FX_SOUND=0 zig build
cd tests/e2e/conformance
npm ci
FX_SOUND=0 npm test
```

`npm ci` must leave `package-lock.json` unchanged. Update the lock only when the
pinned conformance package changes intentionally. The runner also fails before
starting scenarios when the freshly built `zig-out/bin/fx` is missing.

`expected-failures.yml` lists individual check IDs rather than whole scenarios.
The runner exits nonzero when a new check fails or a listed check starts
passing, so any conformance change requires an intentional baseline update.

`client.ts` uses the runner's scenario/context variables to select the fake
Gateway tool calls and requested protocol. It opts into the newer discovery
lifecycle for the `2026-07-28` suite; the legacy scenarios use MCP v1. It then
launches `./zig-out/bin/fx` without implementing MCP messages or transport
behavior.
