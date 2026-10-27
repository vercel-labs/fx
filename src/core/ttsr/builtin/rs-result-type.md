---
description: Result type aliases must include a defaulted error type parameter
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [rs, rust] }
  then:
    regex: 'type\s+Result<[A-Za-z_]\w*>\s*='
    in: code
  else:
    all:
      - regex: 'type\s+Result<[A-Za-z_]\w*>\s*='
        in: [code, string]
      - llm: "Does this content actually declare a Rust `type Result<T> = ...` alias, rather than quoting or discussing such an alias?"
---

`Result` aliases must expose the error type as a defaulted parameter.

```rust
pub type Result<T, E = anyhow::Error> = std::result::Result<T, E>;
```

Never write:

```rust
type Result<T> = std::result::Result<T, anyhow::Error>;
```

The default keeps common call sites short while preserving escape hatches for precise errors.
