# Types, Memory, Errors, and Control Flow

Read this reference when a Zig change affects data modeling, ownership, allocators,
errors, arithmetic, casts, pointers, optionals, generics, or state machines.

## Model the domain with types

- Use concrete types at module and public boundaries. Local inference is useful when the
  type remains obvious; it should not hide a contract a caller must understand.
- Use enums for closed sets instead of string comparisons. Use tagged unions when the
  valid payload depends on the active state.
- Use optionals only when absence is a valid state. Do not combine a boolean flag with an
  optional payload when a tagged union can express the actual states.
- Give semantically different identifiers, handles, and units distinct types. A small
  wrapper struct prevents accidentally exchanging values that share an integer
  representation.
- Replace boolean-heavy call sites with an enum or options struct whose field names make
  intent visible.
- Use explicit-width integers at wire, file, database, and ABI boundaries. Use `usize`
  for in-memory indexing and allocation sizes unless the domain requires another width.
- Name quantities precisely: `index`, `count`, `offset`, `length`, `capacity`, and `size`
  are not interchangeable. Include units such as `_bytes`, `_ms`, or `_ns` where the type
  cannot encode them.

The goal is not to wrap every primitive. Introduce a type when it prevents a realistic
mix-up, makes an invariant constructible in one place, or enables exhaustive handling.

## Make ownership explicit

- Every allocation has one owner. Document whether a returned slice is owned, borrowed,
  static, arena-backed, or valid only until the next mutation.
- Prefer allocator-explicit operations because the call site then reveals allocation.
  Storing an allocator is appropriate when an object owns allocations across methods;
  document that fact and use the same compatible allocator for teardown.
- Put `defer` immediately after successful acquisition when the current scope owns the
  resource. Use `errdefer` beside a fallible acquisition when later initialization can
  fail and transfer has not completed.
- Match allocator strategy to lifetime:
  - `std.testing.allocator` in tests, and `std.heap.SafeAllocator` for leak and misuse
    checks in development builds (`DebugAllocator` is deprecated in 0.17; an entry point
    taking `std.process.Init` already gets a `SafeAllocator` as `init.gpa` in Debug and
    ReleaseSafe);
  - `std.heap.ArenaAllocator` for clearly bounded batch/request lifetimes;
  - `std.heap.FixedBufferAllocator` for scratch space with a real upper bound;
  - a thread-safe allocator such as `std.heap.smp_allocator` for shared concurrent use
    when measurement and ownership justify it.
- Do not share an arena between threads unless access is externally synchronized and the
  lifetime semantics remain sound. Per-worker arenas are usually simpler.
- Decide the OOM policy at the correct boundary. Libraries normally propagate
  `error.OutOfMemory`; an application may deliberately terminate if recovery cannot
  preserve useful behavior. Do not accidentally convert OOM into `unreachable`.

### Allocator-explicit container pattern

```zig
var values: std.ArrayList(Item) = .empty;
defer values.deinit(allocator);

try values.append(allocator, item);
```

An append, insertion, rehash, or capacity change may invalidate interior pointers and
slices. Reserve sufficient capacity before taking them or reacquire them after mutation.

## Design useful error contracts

- Prefer named error sets at stable public or module boundaries so callers can see and
  exhaustively handle the contract. Inferred error sets reduce duplication inside
  private implementation code.
- Avoid `anyerror` unless intentional error-set erasure is itself part of the boundary.
- Use `try` when the current layer cannot add useful handling. Use `catch` only to
  recover, translate, add diagnostics, or implement an explicit fallback.
- Reserve `catch unreachable` for structurally proven impossibility. Configuration,
  external data, files, subprocesses, networks, and user input do not qualify.
- Translate implementation-specific errors at a boundary when exposing them would leak
  an unstable dependency contract.
- Zig errors have no payload. When callers need offsets, tokens, status codes, or other
  context, provide a diagnostics structure or result type while keeping the error set
  useful for control flow.
- Test meaningful error variants and cleanup paths. A declared error that is never
  produced or handled increases API noise.

```zig
pub const ParseError = error{
    UnexpectedToken,
    Truncated,
    DepthExceeded,
};
```

## Arithmetic and conversions

- Validate externally supplied sizes before multiplication, addition, allocation, or
  slicing. Use checked helpers such as `std.math.add` and `std.math.mul` when failure is
  part of normal validation.
- Choose overflow semantics deliberately:
  - ordinary `+`, `-`, and `*` when overflow is a violated invariant in safety-enabled
    builds;
  - `+%`, `-%`, and `*%` for intentionally wrapping arithmetic;
  - `+|`, `-|`, and `*|` for intentionally saturating arithmetic;
  - overflow-returning builtins when the caller must branch on overflow.
- Use `std.math.cast` when narrowing can legitimately fail. Use `@intCast` only after the
  source range is established by type, validation, or a nearby invariant.
- Make signedness changes explicit, especially around lengths and sentinel values.
- Choose division semantics deliberately (`@divTrunc`, `@divFloor`, `@divExact`, and
  related operations) rather than relying on an unstated mathematical assumption.

ReleaseFast and ReleaseSmall remove safety checks. Code must not depend on a safe-mode
panic to validate data that production accepts.

## Pointers, slices, optionals, and sentinels

- Prefer slices to many-pointers because slices retain length. Reserve many-pointers for
  interfaces such as C where the length is represented separately.
- Never return a pointer or slice to stack storage. Return owned memory, write into a
  caller-provided buffer, or borrow storage whose lifetime clearly exceeds the return.
- Track sentinel types explicitly. `[:0]const u8` and `[]const u8` have different
  contracts; convert at the boundary that requires the sentinel.
- Default bindings and pointer views to `const`. Introduce mutability only where state is
  actually changed.
- Do not retain a slice into internal mutable storage unless the API documents the exact
  invalidation rule.

## Assertions and control flow

- Use `std.debug.assert` for preconditions, postconditions, and invariants wholly under
  program control. Return errors for external violations.
- Use compile-time checks for required sizes, alignment, field layout, and generic
  contracts when a mismatch would make the program invalid.
- Split unrelated assertions so a failure identifies the broken invariant.
- Prefer exhaustive `switch` for closed enums and tagged unions. Avoid an `else` that
  silently accepts future variants when each variant has distinct semantics.
- Keep control flow shallow and make state transitions explicit. Labeled loops and
  switches are useful for parsers and protocol machines when they clarify the transition
  model; they are not a requirement for ordinary branching.
- Put explicit limits on retries, recursion, queues, and work per iteration. Termination
  behavior is part of the contract.

## Generics and comptime

- Use `anytype` for genuinely generic algorithms, not to avoid designing an interface.
  Each distinct instantiation can increase compile time and binary size.
- Prefer concrete types at boundaries that need stable documentation, diagnostics, or
  separate compilation behavior.
- Use comptime to validate and generate straightforward structure. Avoid metaprogramming
  that makes control flow or failure behavior harder to inspect.
- Do not force `inline` merely because a function is small. Let optimization decide
  unless comptime semantics require it or measurement proves a hot-path benefit.
- Use explicit named re-exports rather than flattening namespaces with removed or
  version-incompatible constructs such as `usingnamespace`.
