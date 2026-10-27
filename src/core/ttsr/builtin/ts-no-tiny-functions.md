---
description: "Do not extract named one-return functions or expression-bodied variable arrows that only wrap an expression — inline them"
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
  then:
    regex: '(?m)\bfunction\s+[A-Za-z_$][\w$]*\s*(?:<[^>{}\n]*>\s*)?\([^{}\n]*\)\s*\{\s*return\b[^{};\n]+;?\s*\}|\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*(?:\([^()\n]*\)|[A-Za-z_$][\w$]*)\s*=>(?!\s*\{)\s*[^\n;]+'
    in: code
  else:
    all:
      - regex: '(?m)\bfunction\s+[A-Za-z_$][\w$]*\s*(?:<[^>{}\n]*>\s*)?\([^{}\n]*\)\s*\{\s*return\b[^{};\n]+;?\s*\}|\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*(?:\([^()\n]*\)|[A-Za-z_$][\w$]*)\s*=>(?!\s*\{)\s*[^\n;]+'
        in: [code, string]
      - llm: "Does this content actually define a function whose whole body is a single return of an expression, rather than quoting or discussing such functions?"
---

Inline functions whose whole body: one expression or `return`, unless name creates a durable contract.

## Why

- One-line wrappers: no real behavior.
- Readers: jump to verify trivial code.
- Signature: freezes shape too early.
- Inline expressions: better search and type flow.

## Avoid

```typescript
// Bad — pure rename, no behavior added.
function isEmpty(value: string): boolean {
	return value.length === 0;
}

const getDisplayName = (user: User) => user.profile.displayName;

function double(value: number) {
	return value * 2;
}

if (isEmpty(name)) { ... }
```

## Use

```typescript
if (name.length === 0) { ... }
const displayName = user.profile.displayName;
const doubled = value * 2;
```

## Allowed tiny functions

- Three or more call sites need lockstep behavior.
- Exported name: stable domain concept.
- Callback identity matters.
- Type guard preserves narrowing.
- Public API, test seam, or DI boundary needs indirection.
- Names non-obvious formula or magic-constant computation the inlined expression would not explain alone.

If none apply, inline it.
