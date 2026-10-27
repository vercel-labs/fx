---
description: Prefer Record<K, V> for small static literals; use Set/Map for anything dynamic
scope: "tool:shell"
interruptMode: never
match:
  all:
    # Source of the language itself is classified, so comments and strings cannot
    # trip it; embedded in another language, only its comments are excluded.
    - if: { lang: [ts, tsx, mts, cts, js, jsx, mjs, cjs] }
      then: { regex: '\bnew\s+(Set|Map)\b', in: code }
      else: { regex: '\bnew\s+(Set|Map)\b', in: [code, string] }
    - llm: "Does this content actually build a Set or Map from a fixed literal list of string keys - a table a Record would express better - rather than creating one for dynamic membership, or merely quoting or discussing Set/Map?"
---

Small, static string-keyed lookup tables: `Record<K, V>` / `Record<K, true>`.

`Set` / `Map`: dynamic/non-string keys; runtime insertion/deletion; `.size`, `.clear()`, stable insertion order, or iterator APIs.

```typescript
// Static literal → Record
const LABEL_BY_KIND: Record<string, string> = {
	text: "Text",
	json: "JSON",
	binary: "Binary",
};

// Dynamic membership → Set
const seen = new Set<string>();
for (const item of items) {
	if (seen.has(item.id)) continue;
	seen.add(item.id);
}
```
