# Testing, Build Modes, Dependencies, and Binary Size

Read this reference when adding tests, fuzzing, choosing an optimization mode, preparing
production builds, changing dependencies, or investigating performance or binary size.

## Test the contracts that can fail

- Colocate unit tests with the declarations they cover when that matches the repository's
  test layout. Ensure the selected test root imports those files; unreachable test blocks
  are silently absent from the run.
- Use `std.testing.allocator` for allocations whose leaks should fail the test. Exercise
  fallible setup with `std.testing.checkAllAllocationFailures` or
  `std.testing.FailingAllocator` when cleanup logic is non-trivial. A hand-written
  `FailingAllocator` lets resizes succeed by default, and `std.testing.allocator` may
  grow in place on one run and not the next, so set `.resize_fail_index = 0` or back
  the sweep with an allocator that refuses in-place resize. 0.17.1's
  `checkAllAllocationFailures` already fails every resize; 0.17.0's does not.
- Cover boundaries and invalid values, not only representative success cases: empty,
  maximum accepted, one beyond maximum, truncation, malformed tags, overflow, duplicate
  values, and cancellation.
- Prefer `expectEqualStrings` and `expectEqualSlices` when they produce more useful diffs
  than a boolean assertion.
- Test public behavior instead of copying private implementation steps into the test.
- Use declaration-named tests (`test declaration_name { ... }`) as doctests when a public
  API benefits from a compiled usage example.
- Add integration or end-to-end coverage when initialization, I/O, subprocesses,
  terminals, threads, or packaging determine behavior that unit tests cannot reproduce.

## Fuzzing

- Define a real fuzz target with `std.testing.fuzz`; the callback should accept arbitrary
  bytes, impose realistic bounds, and assert invariants rather than one expected output.
- Good targets include parsers, decoders, protocol state machines, path handling, and
  functions that turn external lengths into allocation or slicing decisions.
- Preserve minimal regressions discovered by fuzzing as ordinary deterministic tests.
- Run the fuzz command supported by the repository and pinned Zig version. In a compatible
  Zig 0.17 build graph this is commonly `zig build test --fuzz`, but the project may expose
  a dedicated step.
- Fuzzing supplements structured boundary and error tests; it does not replace them.

## Build modes

- **Debug:** favors diagnostics and safety checks with little optimization. Use it during
  development and for allocator diagnostics.
- **ReleaseSafe:** optimizes while retaining safety checks. It is a strong default for
  reliability-sensitive production applications.
- **ReleaseFast:** prioritizes speed and disables runtime safety checks. Use it when
  benchmarks justify the trade and tests/fuzzing cover the affected invariants.
- **ReleaseSmall:** prioritizes code size and also disables runtime safety checks. Measure
  it separately; it is not simply a smaller ReleaseSafe.

Libraries should not dictate the consumer's optimization mode. Applications should pick
a mode based on failure cost and measured requirements. Do not use a safety-enabled panic
as external-input validation because that validation disappears as a reliable guard in
safety-disabled modes.

## Verification strategy

- Follow repository instructions before generic commands. A sensible fallback is to
  format-check project-owned Zig paths, run `zig build`, and run `zig build test`.
- Test Debug and ReleaseSafe when optimization or safety checks could expose different
  behavior. Test ReleaseFast or ReleaseSmall when those are proposed for distribution.
- Cross-compile every target for which portability is claimed. Run on representative
  targets where ABI, terminal, filesystem, or process behavior matters.
- Exercise the freshly built artifact through the changed path. A unit test does not prove
  that the composition root, runtime initialization, or packaging works.
- Report commands and results precisely. If an environment prevents a check, state which
  behavior remains unverified.

## Binary-size work

- Establish a reproducible baseline: same Zig version, target, CPU features, optimization
  mode, feature flags, linkage, stripping, and measurement tool.
- Separate file size from loaded/code/data size. Debug symbols, unwind data, initialized
  globals, embedded assets, and machine code require different remedies.
- Inspect sections and symbols with suitable platform tools before changing source. Rank
  contributors by size rather than guessing from line count.
- Watch generic and comptime instantiations. `anytype`, large inline functions, and
  generated lookup data can duplicate code or constants across call sites.
- Avoid forced inlining unless measurement proves it helps the real objective. Smaller
  source does not guarantee a smaller binary.
- Large initialized globals occupy file space; zero-initialized storage may live in a
  non-file-backed section. Confirm section placement instead of assuming.
- Use stable sorting, richer formatting, Unicode tables, compression formats, and similar
  features only when their semantics are required—but do not remove behavior merely to
  meet a size target.
- Track binary size in CI only when the project has a real budget. Use a threshold that
  catches meaningful regressions without failing on toolchain noise.

## Performance work

- Benchmark before optimizing and use representative workloads.
- Distinguish startup latency, steady-state throughput, tail latency, peak memory, and
  binary size; improving one can worsen another.
- Keep a correctness reference or differential test when replacing clear code with a
  specialized fast path.
- Re-run benchmarks after compiler upgrades because Zig and LLVM code generation changes.

## Dependencies and toolchain

- Pin the Zig version used by development and CI. Version-sensitive code should be tested
  against that exact compiler.
- Review dependencies for source, license, maintenance, transitive build cost, platform
  support, and binary impact. Avoid both casual addition and categorical bans.
- Keep `build.zig.zon` hashes and declared versions intentional. Review build scripts as
  executable code.
- Re-evaluate size, startup, and cross-target behavior when a dependency or compiler
  version changes.
