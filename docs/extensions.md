# Trusted local extensions

Local extensions add provider catalogs and streaming without an embedded scripting runtime.
The first provider is [fx-opencode-go](../extensions/fx-opencode-go/README.md).
Its 13 selected Go models use Chat Completions, Responses or Messages and supplement the built-in Vercel Gateway, Codex and Grok catalogs.
Registration and model discovery do not launch executables or transmit provider credentials.

## Trust boundary

An extension runs with your OS privileges. It can access files, use the network, and retain delivered credentials. An empty child environment is not a sandbox. Install only executables and catalogs you trust.

Native `ask` confirms the registered provider, canonical executable path and SHA256 before launch. This is a host action, not a model tool. Approval cannot amend or substitute an executable. Native tool permissions remain active. CLI requests need the existing `--prompt-permissions` flag to open a human prompt.

ACP sessions selected through the profile use the same registered providers. Their client receives native executable consent with the unsandboxed warning before activation. Resumed CLI and ACP sessions resolve the credential slot for their restored model namespace.

Explicit profile `extension_execute` rules can authorize activation under `ask` or `auto`. Rule targets contain `<extension-id>:<provider-id>:<executable-identity>`. Broad configured patterns also authorize matching replacement binaries; human approval does not. Current denies override cached approval.

Approval belongs to the exact running child and action. A changed provider, executable digest, supplied session identity or permission mode requires current policy again. Policy changes apply before the next invocation and credential delivery; they cannot undo admitted effects or recall retained secrets.

Unresolved `auto` activation holds closed without opening a prompt. An extension credential cannot review its own unactivated transport or become a Gateway credential. Yolo bypasses permission checks for the entire conversation; it is not required for scoped activation.

## Register an extension

1. Build fx with `zig build -Doptimize=ReleaseSafe` from the checkout root.
2. Build the extension as its README requires.
3. Add its root to `~/.fx/extension.json`, preserving existing registrations:

```json
{
  "version": 1,
  "extensions": [{ "path": "/absolute/path/to/extension-root" }]
}
```

Relative roots resolve under `~/.fx/`. Each root owns an `extension.json` manifest, an executable entrypoint, and cached model catalogs.
The executable and catalogs must remain inside the canonical extension root. Escaping symlinks fail.
Entrypoints are executable paths, not shell commands or argument arrays.

The bundled Go manifest demonstrates provider ID, base URL, key environment slot, cached model file, and headers.
Base URLs require HTTPS except HTTP loopback for local development. URLs with credentials or fragments fail.
Configure `provider: "extension"` and `models.extension` in profile settings to select a registered model.
Public model IDs have the form `<provider-id>/<model-id>`; `wire_id` is the name sent to the provider.

## Credentials and headers

Provider key slots are explicit manifest fields. Credentials do not cross provider ID, full configured URL, or environment-slot boundaries.
Configured headers accept literal strings or these exact bindings:

```json
{
  "x-opencode-session": { "source": "session_id" },
  "x-custom-key": { "source": "env", "name": "CUSTOM_HEADER_KEY" },
  "x-client": "fx-local"
}
```

Header names follow HTTP case rules. Duplicate logical names and unsafe values fail before delivery.
Environment bindings resolve only for an admitted request, not discovery or preparation.
Saved session identity is preserved. Unsaved conversations receive a stable identity for the loaded registry lifetime.
The Go transport includes `x-opencode-session`. Chat Completions and Responses send the admitted
key as managed Bearer authentication; Messages sends managed `x-api-key` and
`anthropic-version: 2023-06-01`. Extension headers cannot override these protocol fields.

## Provider protocol

The executable uses JSON-RPC 2.0, one JSON object per stdio line. Protocol version is `1`.
The methods are `initialize`, `provider.models`, `provider.prepare`, `provider.stream`, `provider.cancel`, and `shutdown`.
Offline fx discovery uses cached catalogs, not `provider.models`.

Preparation receives model metadata, messages, canonical tool schemas, reasoning effort, limits, and optional response format.
It does not receive credentials or configured header values.
Streaming receives the prepared handle, admitted credential, resolved headers, and session identity.
Notifications use `extension.event` with `params.request_id` and `params.handle`, not a top-level notification ID.
Core owns permissions, tool execution, UI delivery, session replay, and usage accounting.
Image parts contain only host-verified snapshot bytes, not filesystem paths.
The standalone Go adapter owns per-wire API routing and effort admission from its pinned catalog.
Tagged replay stays within its API family; switching families retains canonical text/tools while
omitting foreign opaque state. Untagged legacy Chat reasoning remains compatible. Saved turns
retain canonical history, not opaque replay. Malformed same-family replay fails preparation.
Strict schema metadata requires documentation for the selected API, not generic JSON mode.
See the [Go catalog and sources](../extensions/fx-opencode-go/README.md#selected-catalog) for limits,
HY4/Space Bunny forwarding uncertainty, and Muse Contributor consent/account eligibility.

Events and frames are bounded. Foreign handles, oversized events, invalid completion evidence, and uncertain delivery fail terminally.
Fx does not automatically repeat an ambiguous admitted request. Start a fresh user request after resolving the failure.
Executable identity includes canonical path and SHA256; changed executables retire cached children.

## Verification limits

Local proof uses fresh built binaries, fake keys, isolated profiles, loopback HTTP, and real terminal interaction.
Native CLI approval and denial display the unsandboxed warning while preserving JSON stdout.
An approved child cannot reuse ask consent after a switch to auto; unavailable activation retires it before another credential stream.
It does not prove live Go maximum-reasoning, image, or schema acceptance.
Live requests require a real Go key and can consume quota; automated verification makes no live completion requests.
Full CI must pass on the exact commit across Linux x86_64, Linux arm64, macOS Intel, and macOS arm64 before readiness.
Do not push, publish, or mark this work ready without the required approvals and gates.
