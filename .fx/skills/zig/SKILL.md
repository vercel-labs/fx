---
name: zig
description: >-
  Write, review, refactor, and upgrade Zig 0.17 code (0.17.0 and 0.17.1) with
  correct ownership, error sets, I/O, concurrency, tests, and build modes, and
  without removed, deprecated, or silently changed 0.17 APIs. Use for any .zig
  or build.zig edit; for allocator, lifetime, error-set, std.Io, thread,
  fuzzing, ReleaseSafe or ReleaseFast, and binary size questions; when 0.16
  code fails on 0.17, or 0.17 code fails on 0.16 with errors such as "no field
  or member function named 'print'"; when replacing std.fmt.allocPrint,
  bufPrint, std.mem.indexOf, copyForwards, std.fs.path, builtin.os,
  DebugAllocator, or @intFromEnum; when `**`, errdefer captures, @cImport, or
  @hasDecl behave differently; when migrating 0.16 code, merging an upgraded
  main into a 0.16 branch, or installing 0.17 next to another Zig; when asked
  what 0.17 or 0.17.1 changed, fixed, or still breaks; or when the user
  invokes $zig.
---

# Zig 0.17

What Zig 0.17.x changed, and the rules that keep Zig correct under failure,
concurrency, and later change. The facts were checked against the 0.17.0 and
0.17.1 standard library and compiler and a real 0.16 to 0.17 port. Trust them
and the bundled scripts; read std source only for an API this skill lacks.

Repository instructions (`AGENTS.md` and similar), `build.zig`, and
`build.zig.zon` come first and override this skill. Keep established patterns
unless they cause a correctness, safety, or ownership defect. For another Zig
release, use only the version-independent references and check std in its source.

## Check the compiler first

Read `.minimum_zig_version` in `build.zig.zon` and run `zig version`. Neither
0.16 nor 0.17 enforces that field, so a wrong compiler fails late and misleadingly.

- **0.16 on a 0.17 project:** do not build with it. It reports correct code as
  broken (`no field or member function named 'print' in 'mem.Allocator'`,
  `no field named 'debug' in enum 'builtin.OptimizeMode'`); never "fix" that
  back to 0.16 names. Find a 0.17 compiler with `which -a zig` and in versioned
  install directories, and run it by absolute path or `PATH=<dir>:$PATH`.
- **0.17.0 and 0.17.1:** the language and LLVM 22.1.8 are the same, but 0.17.1
  fixes miscompilations, changes a few std signatures, and changes two
  behaviors silently: ending a `std.http` request that sent a body now reads
  its unread answer to the end, and `-femit-llvm-bc` is now optimized. Build
  and test with the pinned patch release; [toolchain](references/toolchain.md)
  lists what 0.17.1 fixed and still breaks.
- Never upgrade, relink, or replace a shared `zig`. Install a missing release
  next to the others, or ask, and say which checks did not run on it.

## Working method

Before editing, map the contract: ownership, borrowing, lifetimes, allocation,
errors, external bounds, thread ownership, and build-mode assumptions. Make
invalid states hard to express with enums, tagged unions, optionals, and named
error sets. Keep allocation, blocking I/O, mutation, and ownership transfer
visible in signatures or doc comments. Make the smallest coherent change, and do
not widen a shared contract for one caller. These are correctness issues, not
style:

- Every allocation has one owner and a cleanup path on success and failure.
- No pointer or slice outlives its storage or survives a mutation that can
  reallocate it.
- External lengths, offsets, counts, recursion, retries, queues, and captured
  output are validated and bounded before arithmetic, allocation, or slicing.
- Assertions and `catch unreachable` guard program-owned invariants only;
  malformed external data gets normal error handling in every build mode.
- Integer conversions and arithmetic have stated range and overflow reasoning.
- Shared mutable state has an owner and a synchronization policy, and
  cancellation or shutdown leaves no thread or resource behind.
- Public contracts state ownership and do not expose `anyerror`, `anytype`, or
  internal mutable storage by accident.

## Changes that compile but change behavior

A clean build proves none of these. Check every one during a migration.

1. **`@hasDecl` only sees `pub` declarations**, even in the same file, so a
   probe of a private one silently turns a feature off. Make it `pub`.
2. **`std.mem.containsAtLeastScalar(T, list, element, minimum)`** swapped its
   last two parameters (0.16: `minimum, element`); old `u8` calls compile and
   answer wrongly. Slice `containsAtLeast` keeps `(haystack, count, needle)`.
3. **`@bitCast` was redefined.** Array and vector casts concatenate logical bit
   representations (endian-agnostic). `extern struct`/`extern union` operands
   are rejected; pun through `@as(*align(1) const T, @ptrCast(&value))`. A cast
   to an enum safety-checks the tag.
4. **`@tagName(builtin.optimize)`** yields `debug`, `safe`, `fast`, `small`;
   map it when a user sees the label.
5. **`std.mem.eql` and `findDiff` on floats** no longer treat a slice as equal
   to itself (NaN is not equal to NaN).
6. **`std.array_list.Managed`** (and so `std.json.Array`) has a required
   `pointer_stability` field: use `.init(gpa)` or `.fromOwnedSlice(gpa, items)`.

## Removed: these no longer compile

| 0.16 | 0.17 |
|---|---|
| `[1]T{v} ** n`, `"ab" ** n` | `const a: [n]T = @splat(v);`; repeated strings need a comptime helper ([language](references/language.md)) |
| `errdefer \|err\| ...` | Split the function and handle the error in the caller |
| `void{}`, `i0` | `{}`, `u0` |
| `@cImport` | The translate-c package ([build system](references/build-system.md)) |
| `opt == .ReleaseSafe` and the other old tags in `==` or `!=` | `.debug`, `.safe`, `.fast`, `.small` |
| `std.heap.StackFallbackAllocator`, `stackFallback` | `std.heap.BufferFirstAllocator.init(buffer, fallback)` |
| `@typeInfo(T).@"struct".fields` | `.field_names`, `.field_types`, `.field_attrs`, `.decl_names` |
| `b.build_root`, `if (b.args) \|a\| run.addArgs(a)` | `b.root` (a `Cache.Path`), `run.addPassthruArgs()` |

The full list, with `std.ascii`, bit sets, packed ints, and ZON, is in [std](references/std.md).

## Deprecated: still compiles, do not write it

| Deprecated | Use |
|---|---|
| `std.fmt.allocPrint(gpa, f, a)` | `gpa.print(f, a)` (same error set) |
| `std.fmt.bufPrint`, `bufPrintSentinel`, `BufPrintError` | `std.mem.print`, `std.mem.printSentinel`, `std.mem.PrintError` |
| `std.mem.indexOf*`, `lastIndexOf*` | `std.mem.find`, `findScalar`, `findAny`, `findPos`, `findLast`, `findScalarLast`, `findLastAny` |
| `std.mem.copyForwards(T, d, s)`, `copyBackwards` | `@memmove(d[0..s.len], s)`; `@memmove` requires equal lengths |
| anything in `std.fs` | `std.Io.Dir.path`, `std.Io.Dir.max_path_bytes`, `std.Io.Dir.max_name_bytes` |
| `path.resolve`, `path.relative` | `std.Io.Dir.path.resolveAlloc`, `relativeAlloc` |
| `@import("builtin").os`, `.cpu`, `.abi`, `.object_format` | `builtin.target.os`, `.target.cpu`, `.target.abi`, `.target.ofmt` |
| `builtin.mode`, `std.debug.runtime_safety` | `builtin.optimize`, `builtin.optimize.runtimeSafety()` |
| `std.builtin`, `std.lang.OptimizeMode` | `std.lang`, `std.lang.Optimize` |
| `@intFromEnum`, `@enumFromInt` | `@backingInt`, `@fromBackingInt` (`zig fmt` rewrites them) |
| `std.ArrayListUnmanaged`, `*ArrayHashMapUnmanaged`, `*BitSet*` | `std.ArrayList`, `std.array_hash_map.String`/`Auto`/`Custom`, `std.bit_set.Integer`/`Array`/`Static`/`Dynamic` |
| `list.getLast()`, `getLastOrNull()` | `list.last().?`, `list.last()` |
| `std.heap.DebugAllocator` (deprecated) | `std.heap.SafeAllocator` |
| `std.unicode.utf8Decode` | Validate with `utf8ByteSequenceLength`, then `utf8Decode2/3/4` |
| `std.meta.fieldNames`, `fieldInfo`, `fieldTypes` | `@typeInfo` |
| Run `addArtifactArg`, `addFileArg`, `addPrefixed*Arg`, ... | `addArtifactArg2(x, .{ .prefix = "-p" })`, `addFileArg2`, ... |
| `b.addTranslateC` | The translate-c package |

Most rows forward to their replacement, so the rename cannot change behavior.
Three can: `copyForwards` (lengths), `utf8Decode` (validation), and
`DebugAllocator`, which is not an alias of `SafeAllocator`. Rarer deprecations
are in [std](references/std.md).

## Entry point, I/O, and allocators

```zig
pub fn main(init: std.process.Init) !void {
    const greeting = try init.gpa.print("hello, {s}", .{"zig"});
    defer init.gpa.free(greeting);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("{s}\n", .{greeting});
    try stdout.interface.flush();
}
```

- `init.gpa` is a `std.heap.SafeAllocator` in Debug and ReleaseSafe builds and
  reports leaks when `main` returns, without changing the exit code. Other
  builds get `std.heap.c_allocator` when linking libc and `smp_allocator`
  otherwise. Do not hand-build that switch.
- `init.io` is a `std.Io.Threaded`: pass it down instead of creating another.
  `init.arena` lives until exit; `init.environ_map` and `init.minimal.args`
  hold the environment and arguments. `pub fn main() !void` gets neither.
- Pick allocators by lifetime: `std.testing.allocator` in tests, `SafeAllocator`
  for leak checks (never in production: it never reuses memory), an
  `ArenaAllocator` per request or batch, `FixedBufferAllocator` for bounded
  scratch, and `std.heap.smp_allocator` for shared concurrent use.
- `std.Io.Evented` does not compile on 0.17.0 or 0.17.1; use `std.Io.Threaded`.
- `std.ArrayList(T)` starts as `.empty` and takes the allocator per call.
  Growth can move storage: take interior pointers after reserving capacity.
- Reading `undefined` is illegal behavior. Narrow with `std.math.cast`; use
  `@intCast` only after the range is proven. Locks, `Child.Term`, and
  cancellation are in [io-concurrency-security](references/io-concurrency-security.md).

## Writing, migrating, and reviewing

**New code:** use only the right-hand columns above, and before reporting it
done, require zero removed and zero deprecated findings from the scanner:

```sh
python3 <this skill>/scripts/check_deprecated.py <files or directories>
```

**Migrating 0.16 code:**

1. Read [toolchain](references/toolchain.md) first if CI, release targets, or
   OS minimums change.
2. Apply the mechanical renames, then let `zig fmt` (0.17) rewrite
   `@intFromEnum` and `@enumFromInt`:

   ```sh
   python3 <this skill>/scripts/migrate.py --write <files or directories>
   zig fmt <files or directories>
   ```

   [`scripts/migrate.py`](scripts/migrate.py) only makes exact forwarding
   renames, never edits strings or comments, prints a `NOTE` for each site that
   needs judgment, and without `--write` only reports.
3. Zig analyzes lazily: build every artifact the project ships and run the
   full test suite.
4. Run `check_deprecated.py --review`, replace what remains, and read every
   review hotspot against the six behavior changes above. Rewrite each
   `copyForwards` site by hand, trimming the destination to `s.len`.
5. Add a test for each silent change you fix, so a later merge cannot undo it,
   and report anything left deprecated on purpose.

**Merging an upgraded `main` into a 0.16 branch:** merge, do not rebase. Take
`main`'s side where a conflict differs only in 0.16 spellings; keep the branch's
behavior changes, written the 0.17 way. Then run steps 2 to 4 on the result.

**Reviewing:** run the scanner on the changed files, and treat a new
`@hasDecl` probe, `containsAtLeastScalar` call, or `@bitCast` of an array,
extern struct, or enum as a question. Rank memory safety, illegal behavior,
races, and leaks first, then contracts, then maintainability, then measured
speed or size. Correctness findings block; design alternatives are
considerations with their tradeoff.

## Verification gate

Use the repository's commands first; otherwise run `zig fmt --check` on the
project's Zig paths, `zig build`, and `zig build test` with the pinned compiler.
Add only what the claim needs: a fuzz target when parsing or untrusted bytes
changed, Debug and ReleaseSafe when safety checks could matter, a cross-compile
for portability, ReleaseFast or ReleaseSmall for their speed or size, and the
built executable for runtime claims. Say what could not run.

## References

Load one only when the task needs more than this file:

- [types-memory-errors](references/types-memory-errors.md): data models,
  allocators, lifetimes, error sets, arithmetic, casts, generics, state machines.
- [api-maintainability](references/api-maintainability.md): public APIs, module
  boundaries, naming, documentation, refactors.
- [io-concurrency-security](references/io-concurrency-security.md): `std.Io`,
  files, sockets, subprocesses, paths, threads, locks, atomics, external input.
- [testing-build-size](references/testing-build-size.md): tests, fuzzing, build
  modes, dependencies, performance, binary size.
- [language](references/language.md): 0.17 casts, builtins, comptime,
  reflection, and removed syntax, with before and after code.
- [std](references/std.md): exact 0.17 signatures, allocators, containers, ZON,
  rare deprecations.
- [build-system](references/build-system.md): `build.zig`, `build.zig.zon`,
  packages, translate-c, editor tooling.
- [toolchain](references/toolchain.md): installing a Zig next to another, CI,
  targets, OS minimums, what 0.17.1 fixed and still breaks, port gotchas.
- [examples.zig](references/examples.zig): compile-checked snippets; `zig test
  references/examples.zig` passes on 0.17.0 and 0.17.1.
