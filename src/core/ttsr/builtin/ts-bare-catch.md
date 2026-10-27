---
description: Use bare `catch {` when an underscore-prefixed error binding is present; this textual trigger cannot determine semantic usage
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
  then:
    ast: "try { $$$BODY } catch ($E) { $$$HANDLER }"
    where:
      E: "^_"
  else:
    all:
      - regex: 'catch\s*\(\s*_[A-Za-z_$][\w$]*\s*\)'
        in: [code, string]
      - llm: "Does this content actually declare a catch clause whose error binding starts with an underscore, rather than quoting or discussing that shape?"
---

Use bare `catch {}` when the caught value is unused. An underscore-prefixed binding adds noise and still allocates a local name.

## Replace

```typescript
// Bad
try {
	await loadConfig();
} catch (_err) {
	return null;
}

// Good
try {
	await loadConfig();
} catch {
	return null;
}
```

## Keep a real name when used

```typescript
try {
	await saveConfig();
} catch (err) {
	logger.error("save failed", { err });
	throw err;
}
```

Unused error? Bare `catch`. Used error? Name it for what it carries.
