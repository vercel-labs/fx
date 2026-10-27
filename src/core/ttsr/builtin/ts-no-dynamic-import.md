---
description: "Do not use `await import()` — use static imports unless dynamic loading is unavoidable"
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
  then:
    regex: 'await import\('
    in: code
  else:
    all:
      - regex: 'await import\('
        in: [code, string]
      - llm: "Does this content actually call `await import(...)` to load a module, rather than quoting or discussing dynamic imports?"
---

Use static imports for modules known at author time. Reach for `await import()` only when the module specifier is genuinely runtime-selected.

## Why

- Static imports fail during build, not under load.
- Bundlers, type checkers, and tree shakers see them.
- The dependency graph remains reviewable.
- Consumers keep precise module types without casts.

## Avoid

```typescript
// Bad — the module path is a literal.
const { createClient } = await import("some-sdk");

// Bad — dynamic import followed by a shape assertion.
const mod = (await import("./known-module")) as { run?: unknown };
```

## Use

```typescript
import { createClient } from "some-sdk";
import { run } from "./known-module";
```

## Exceptions

- Plugin loading from a runtime registry.
- Platform-specific modules that do not exist everywhere.
- Test cases that intentionally exercise module loading boundaries.

Exception? Add a short comment naming why static import cannot work.
