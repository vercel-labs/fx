---
description: "Use `import type`, not inline `import('pkg').Type` or indexed type references"
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
  then:
    regex: "import(?=\\s*\\(\\s*[\"'][^\"'\\n]+[\"']\\s*\\)\\s*(?:\\.|\\[))"
    in: code
  else:
    all:
      - regex: "(?m)(?:^|[,:=<(\\[|&])\\s*import\\s*\\(\\s*[\"'][^\"'\\n]+[\"']\\s*\\)\\s*(?:\\.|\\[)"
        in: [code, string]
      - llm: "Does this content actually use an inline `import(\"pkg\").Type` reference in a type position, rather than quoting or discussing it?"
---

Use top-level `import type` declarations for type-only dependencies. NEVER write `import("pkg").Type` inside source annotations.

## Why

- Top-level imports expose dependencies immediately.
- Import sorting and deduplication can manage them.
- Signatures stay readable and reviewable.
- Re-exports do not inherit noisy inline paths.

## Avoid

```typescript
// Bad — inline imports hide dependencies in signatures.
function run(client: import("some-sdk").Client, input: import("arktype").infer<Schema>): Promise<Output>;

// Bad — annotations become path dumps.
const options: import("some-sdk/config").ClientOptions = { ... };
```

## Use

```typescript
import type { Client } from "some-sdk";
import type { ClientOptions } from "some-sdk/config";
import type { infer as Infer } from "arktype";

function run(client: Client, input: Infer<Schema>): Promise<Output>;
const options: ClientOptions = { ... };
```

## Exceptions

- Ambient `.d.ts` globals that must not become modules.
- Generated files whose generator owns import management.

In normal `.ts` / `.tsx` source, use `import type`.
