# I/O, Concurrency, and External Boundaries

Read this reference when Zig code touches `std.Io`, files, sockets, subprocesses,
paths, threads, locks, atomics, cancellation, or any externally supplied data.

## I/O as an explicit effect

- Thread `std.Io` through APIs that perform I/O so blocking and cancellation points are
  visible and tests can provide the appropriate implementation.
- Document whether an operation can block, how it is canceled, and what remains valid
  after cancellation.
- Handle partial reads and writes. A successful operation need not consume or produce
  the full requested buffer.
- Bound reads before accumulating them in memory. A transport closing eventually is not
  a memory limit.
- Translate transport- or dependency-specific errors at the boundary when callers should
  reason in domain terms.
- Inject clocks, randomness, environment access, and I/O when deterministic behavior is
  important. Do not introduce abstraction solely for hypothetical testing.
- Standard-library APIs are tied to the compiler version. Inspect the installed source
  or matching official reference when porting examples between Zig releases.
- Take the `Io` from `main(init: std.process.Init)` as `init.io` (a `std.Io.Threaded`)
  and pass it down. `std.Io.Evented` does not compile on 0.17.0 or 0.17.1.

## External input

- Treat files, command output, environment variables, network data, serialized data,
  and FFI values as untrusted until validated.
- Establish maximum file size, message size, nesting depth, field count, token count,
  output capture, and work budget where applicable.
- Validate lengths and offsets before arithmetic or slicing. Check that ranges are
  ordered and contained, not merely that each endpoint fits an integer type.
- Separate parsing from semantic validation. A syntactically valid value can still
  violate application invariants.
- Reject or normalize ambiguous encodings at the boundary. Preserve original bytes only
  when the contract requires them.
- Return errors for malformed input. An assertion or `catch unreachable` turns external
  control into a process crash in safety-enabled builds and illegal behavior otherwise.

## Paths and subprocesses

- Define the allowed path root and whether symlinks may escape it. Lexical removal of
  `..` alone is not a complete containment policy.
- Prefer directory handles or repository-provided path helpers when they encode a safer
  capability boundary.
- For subprocesses, decide stdin/stdout/stderr ownership, output caps, timeouts,
  cancellation, environment inheritance, working directory, and cleanup before spawn.
- Handle `std.process.Child.Term` exhaustively in Zig 0.17:

```zig
switch (result.term) {
    .exited => |code| if (code != 0) return error.ProcessFailed,
    .signal, .stopped, .unknown => return error.ProcessCrashed,
}
```

- When code stops reading an HTTP answer early, close the connection: in 0.17.1
  `std.http.Client.Request.deinit` reads an unread answer to its end, which waits
  forever on a stream or an answer without a length (toolchain.md, "Zig 0.17.1").
- Drain or close pipes in an order that cannot deadlock the child. Do not wait forever
  while a bounded pipe the parent is not reading prevents the child from exiting.
- Preserve useful diagnostics without returning unbounded stdout or stderr.

## Shared state and synchronization

- Prefer single-owner state or message passing when it keeps mutation local. When state
  is shared, name the lock or atomic that protects each field.
- Zig 0.17 provides `std.Io.Mutex`. Its `lock` operation accepts an `std.Io` and is a
  cancellation point; use `lockUncancelable` only when cancellation inside that critical
  transition would violate an invariant.
- Keep critical sections small and do not perform unrelated blocking I/O while holding a
  lock.
- Establish and document lock ordering before code can acquire multiple locks. A small
  lock graph prevents deadlocks better than scattered comments.
- Use atomics only when the state transition and memory ordering can be explained.
  `.seq_cst` is a safe starting point, not permission to skip reasoning about ownership
  or compound invariants.
- Use a thread-safe allocator for allocations shared across workers. Do not share an
  arena concurrently without explicit synchronization.
- Ensure data referenced by a thread outlives the thread. Joining, detaching, and
  cancellation are lifecycle decisions, not cleanup details.

## Shutdown and cancellation

- Define who initiates shutdown, how workers observe it, and which component joins them.
- Make cleanup idempotent when multiple failure paths may converge.
- Do not destroy allocators, locks, buffers, or I/O implementations while background work
  can still access them.
- Test cancellation while blocked, shutdown with queued work, partial initialization,
  worker failure, and repeated cleanup.
- When state is intentionally dropped, make the event observable if it affects callers or
  user-visible work.
