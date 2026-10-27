---
description: "Never use isRecord"
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
  then:
    regex: ["\\bfunction\\s+isRecord(?:\\s*<[^>]*>)?\\s*\\(", "\\b(?:const|let|var)\\s+isRecord\\b\\s*(?::[\\s\\S]{0,300}?)?=\\s*(?:async\\s+)?(?:function\\b|(?:<[^>\\n]*>\\s*)?(?:\\([^)]*\\)|[A-Za-z_$][\\w$]*)\\s*(?::[\\s\\S]{0,300}?)?=>)"]
    in: code
  else:
    all:
      - regex: ["\\bfunction\\s+isRecord(?:\\s*<[^>]*>)?\\s*\\(", "\\b(?:const|let|var)\\s+isRecord\\b\\s*(?::[\\s\\S]{0,300}?)?=\\s*(?:async\\s+)?(?:function\\b|(?:<[^>\\n]*>\\s*)?(?:\\([^)]*\\)|[A-Za-z_$][\\w$]*)\\s*(?::[\\s\\S]{0,300}?)?=>)"]
        in: [code, string]
      - llm: "Does this content actually define or call a local isRecord helper, rather than quoting or discussing one?"
---

## Why it's wrong

- A `Record<string, unknown>` guard proves an object, not its fields.
- Either unnecessarily complicated or insufficiently strong.
- Repeated guards hide the data contract from readers and TypeScript.

## Use

`isRecord`: values narrow to `Record<string, unknown>`; fields remain `unknown`.

Network, config, IPC, persisted, or reused data shapes: parse once at the boundary with the project's schema validator; consume its named output type:

```typescript
const Config = z.object({ retries: z.number().int().nonnegative() });
type Config = z.infer<typeof Config>;

const config = Config.parse(raw);
```

If runtime shape uncertain: check used properties with `typeof`, `Array.isArray`, `in`, or a discriminant. If an existing invariant guarantees shape: assert the named type at that boundary, not a duplicate guard:

```typescript
const config = value as Config;
```

## Avoid

```typescript
function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
	value !== null && typeof value === "object";
```

## Exceptions

A standalone package without a shared type-guard module may define one canonical guard. Export it from the package's type-guard module; never recreate it at individual call sites.
