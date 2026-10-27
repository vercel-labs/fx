---
description: Use match ergonomics instead of ref/ref mut patterns
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [rs, rust] }
  then:
    regex: ["\\(ref mut ", "\\(ref [a-z_]"]
    in: code
  else:
    all:
      - regex: ["\\(ref mut ", "\\(ref [a-z_]"]
        in: [code, string]
      - llm: "Does this content actually bind a Rust pattern with `ref` or `ref mut`, rather than quoting or discussing those patterns?"
---

Use match ergonomics instead of explicit `ref` / `ref mut` patterns. Borrow the scrutinee and let bindings receive references.

## Shared references

```rust
// Before
match value {
    Some(ref item) => println!("{item}"),
    None => {}
}

// After
match &value {
    Some(item) => println!("{item}"),
    None => {}
}

if let Some(item) = &value {
    println!("{item}");
}
```

## Mutable references

```rust
// Before
match value {
    Some(ref mut item) => *item += 1,
    None => {}
}

// After
match &mut value {
    Some(item) => *item += 1,
    None => {}
}

if let Some(item) = &mut value {
    *item += 1;
}
```

## Result

```rust
// Before
match result {
    Ok(ref data) => println!("{data}"),
    Err(ref err) => eprintln!("{err}"),
}

// After
match &result {
    Ok(data) => println!("{data}"),
    Err(err) => eprintln!("{err}"),
}
```

Modern Rust rarely needs `ref` in patterns. Borrow the value being matched.
