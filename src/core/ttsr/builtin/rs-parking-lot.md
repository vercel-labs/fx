---
description: Use parking_lot instead of std::sync for Mutex/RwLock
scope: "tool:shell"
interruptMode: never
match:
  if: { lang: [rs, rust] }
  then:
    regex: ["\\.lock\\(\\)\\.unwrap\\(\\)", "\\.read\\(\\)\\.unwrap\\(\\)", "\\.write\\(\\)\\.unwrap\\(\\)"]
    in: code
  else:
    all:
      - regex: ["\\.lock\\(\\)\\.unwrap\\(\\)", "\\.read\\(\\)\\.unwrap\\(\\)", "\\.write\\(\\)\\.unwrap\\(\\)"]
        in: [code, string]
      - llm: "Does this content actually call .lock().unwrap(), .read().unwrap(), or .write().unwrap() on a std::sync lock, rather than quoting or discussing that pattern?"
---

Use `parking_lot::{Mutex, RwLock}` instead of `std::sync::{Mutex, RwLock}` when code immediately unwraps lock results.

## Why

- `lock()`, `read()`, and `write()` return guards directly.
- No poisoning error path to unwrap.
- Guards are smaller and faster in common contention cases.
- The call site shows locking, not error handling boilerplate.

## Migration

```rust
// Before
use std::sync::Mutex;
let data = Mutex::new(Vec::new());
let guard = data.lock().unwrap();

// After
use parking_lot::Mutex;
let data = Mutex::new(Vec::new());
let guard = data.lock();
```

## Equivalents

|std::sync|parking_lot|
|---|---|
|`Mutex<T>`|`Mutex<T>`|
|`RwLock<T>`|`RwLock<T>`|
|`Condvar`|`Condvar`|
|`Once`|`Once`|

## Keep async locks async

Use `tokio::sync::Mutex` / `tokio::sync::RwLock` when a guard is held across `.await` or the lock belongs to async coordination.
