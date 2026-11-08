# fx extensions to ACP

This folder holds `sh.fx`, the draft specification of the extensions that fx adds to version 1 of the [Agent Client Protocol](https://agentclientprotocol.com) (ACP), and a pinned copy of ACP's own schema that the extensions build on.

fx's ACP server in `src/acp/` and its SDK use the `sh.fx` names, and fx lists the extensions it serves at `initialize`. Several extensions in the specification have not landed in the server yet; each section says what fx does today. A change that lands one updates this folder in the same pull request.

| File | Contents |
| --- | --- |
| `sh-fx.md` | The specification: naming rules, capabilities, and the messages and fields of each extension |
| `sh-fx.schema.json` | The JSON Schema for the types that `sh-fx.md` defines |
| `acp/v1/` | ACP's version 1 schema and method lists, copied unchanged from ACP's repository, and ACP's license |
| `schemas.zig` | Tests that every schema file parses, that `acp/v1/` matches the pinned commit, that `sh-fx.schema.json` uses the JSON Schema draft of ACP's schema and states the naming rules, and that the names and JSON examples in `sh-fx.md` follow those rules and parse |

`zig build test` runs the tests in `schemas.zig`.

## The ACP copy

`acp/v1/` holds these files from [agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol) at commit `7ec5185c18ca`:

| File | Path in ACP's repository | Contents |
| --- | --- | --- |
| `meta.json` | `schema/v1/meta.json` | The names of the stable methods |
| `meta.unstable.json` | `schema/v1/meta.unstable.json` | The stable methods and ACP's draft methods |
| `schema.json` | `schema/v1/schema.json` | The stable types |
| `schema.unstable.json` | `schema/v1/schema.unstable.json` | The stable types and ACP's draft types |
| `LICENSE` | `LICENSE` | The Apache License 2.0 that covers the copy |

ACP is copyright 2025 Zed Industries, Inc. and contributors, and licensed under the Apache License 2.0. The files are unchanged, and `THIRD_PARTY_NOTICES.md` at the repository root lists them.

To move the copy to a newer ACP commit:

1. Set `commit` to the new commit and run these commands from this folder:

   ```sh
   commit=7ec5185c18ca
   base="https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/$commit"
   for f in meta.json meta.unstable.json schema.json schema.unstable.json; do
     curl -fsSL "$base/schema/v1/$f" -o "acp/v1/$f"
   done
   curl -fsSL "$base/LICENSE" -o acp/v1/LICENSE
   ```

2. Replace the digests in `schemas.zig` with the output of `shasum -a 256 acp/v1/*`, or `sha256sum acp/v1/*` on Linux.
3. Replace the commit in this file, in `schemas.zig`, and in `THIRD_PARTY_NOTICES.md`.
4. Run `zig build test`.
5. Check each part of `sh-fx.md` that names an ACP type or proposal against the new files.
