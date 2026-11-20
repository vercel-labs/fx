# Zig 0.17 standard library

Read this for any std API question the core table does not answer. "Removed"
means a compile error on 0.17; "deprecated" still compiles and is scheduled for
removal (several say "after 0.18.0"). Signatures were checked in the 0.17.0
and 0.17.1 source. The few std APIs that 0.17.1 changed, such as
`http.Reader.side` and `HashMap.removeByPtr`, are listed in toolchain.md under
"Zig 0.17.1".

## Formatting

| Old | 0.17 |
|---|---|
| `std.fmt.allocPrint(gpa, f, args)` | `gpa.print(f, args)` returning `Allocator.Error![]u8` |
| `std.fmt.allocPrintSentinel(gpa, f, args, s)` | `gpa.printSentinel(f, args, s)` |
| `std.fmt.bufPrint(buf, f, args)` | `std.mem.print(buf, f, args)` returning `std.mem.PrintError![]u8` (`error.NoSpaceLeft`) |
| `std.fmt.bufPrintSentinel(buf, f, args, s)` | `std.mem.printSentinel(buf, f, args, s)` |
| `std.fmt.BufPrintError` | `std.mem.PrintError` |

The deprecated functions are one-line forwards, so the rewrite cannot change
behavior. `{q}` now passes UTF-8 through unescaped, and `{qf}` double-quote
escapes the output of a `format()` method.

## Searching, copying, and comparing (`std.mem`)

All `indexOf*` names are aliases of `find*`:

| Deprecated | Use |
|---|---|
| `indexOf`, `indexOfPos` | `find`, `findPos` |
| `indexOfScalar`, `indexOfScalarPos` | `findScalar`, `findScalarPos` |
| `indexOfAny`, `indexOfAnyPos`, `indexOfNone` | `findAny`, `findAnyPos`, `findNone` |
| `lastIndexOf`, `lastIndexOfScalar` | `findLast`, `findScalarLast` |
| `lastIndexOfAny`, `lastIndexOfNone`, `lastIndexOfLinear` | `findLastAny`, `findLastNone`, `findLastLinear` |
| `indexOfDiff`, `indexOfSentinel`, `indexOfMin`, `indexOfMinMax` | `findDiff`, `findSentinel`, `findMin`, `findMinMax` |
| `copyForwards(T, dest, src)`, `copyBackwards` | `@memmove(dest[0..src.len], src)` |
| `byteSwapAllFields`, `byteSwapAllFieldsAligned` | `byteSwap`, `byteSwapAligned` |

Removed: `readPackedIntNative`/`Foreign` (use `readPackedInt`),
`writePackedIntNative`/`Foreign` (use `writePackedInt`), and
`containsAtLeastScalar2`, whose order `containsAtLeastScalar(T, list, element,
minimum)` now uses.

`copyForwards` copied `src.len` elements into a destination at least that long.
`@memmove` asserts equal lengths, so `@memmove(items[start..], items[end..])`
panics in safe builds. Write `@memmove(items[start .. items.len - (end - start)],
items[end..])`, or trim with `[0..src.len]`.

`std.mem.eql` and `findDiff` no longer short-circuit when both slices are the
same memory and the element type is a float.

## Allocators

- `std.heap.DebugAllocator`, `DebugAllocatorConfig`, and `std.heap.Check` are
  deprecated. `DebugAllocator` is the older implementation, not an alias, so
  switching changes behavior. Use `std.heap.SafeAllocator`: thread-safe,
  reports every leak, panics or faults on mismatched or double frees, and never
  reuses memory (keep it out of production). `main(init: std.process.Init)`
  already gets one as `init.gpa` in Debug and ReleaseSafe builds:

  ```zig
  var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
  const gpa = safe.allocator();
  defer std.debug.assert(safe.deinit() == 0); // deinit returns the leak count
  ```
- `std.heap.StackFallbackAllocator` and `std.heap.stackFallback` are removed.
  `std.heap.BufferFirstAllocator` takes the buffer as an argument:

  ```zig
  var stack_buf: [256]u8 = undefined;
  var first: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
  const allocator = first.allocator();
  ```
- `std.heap.memory_pool.AlignedManaged` and `ExtraManaged` are removed; use
  `Aligned` and `Extra`.
- Default `.{}` initialization is deprecated for `std.HashMapUnmanaged`,
  `std.array_hash_map.Custom`, and `std.enums.EnumMap` (use `.empty`) and for
  `std.heap.ArenaAllocator.State` (use `.init`).

## Containers

| Deprecated or removed | Use |
|---|---|
| `std.ArrayListUnmanaged`, `std.ArrayListAligned*` | `std.ArrayList`, `std.array_list.Aligned` |
| `std.array_list.Managed`, `AlignedManaged` | `std.ArrayList` with the allocator passed per call |
| `std.StringArrayHashMapUnmanaged`, `std.AutoArrayHashMapUnmanaged`, `std.ArrayHashMapUnmanaged`, `std.array_hash_map.ArrayHashMap` | `std.array_hash_map.String`, `.Auto`, `.Custom` |
| `std.bit_set.IntegerBitSet`, `ArrayBitSet`, `StaticBitSet`/`std.StaticBitSet` | `std.bit_set.Integer`, `Array`, `Static` |
| `std.DynamicBitSetUnmanaged` | `std.bit_set.Dynamic` (same methods, including `initEmpty(gpa, n)`) |
| `std.DynamicBitSet`, `std.bit_set.DynamicManaged` | `std.bit_set.Dynamic` |
| Integer/Array bit sets and `EnumSet`: `initEmpty()`, `initFull()` (removed) | `.empty`, `.full` |
| `list.getLastOrNull()`, `list.getLast()` | `list.last()`, `list.last().?`; new `list.lastPtr()` returns `?*T` |
| `std.DoublyLinkedList.pop` | `popLast` |

`std.array_list.Managed` (and `std.json.Array`, which is one) has a new required
`pointer_stability: std.debug.SafetyLock` field that catches pointer
invalidation. Construct it with `.init(gpa)` or `.fromOwnedSlice(gpa, items)`,
never with a struct literal. `ArrayHashMap.setKey` no longer recomputes the
whole index.

## Target and build mode

| Deprecated | Use |
|---|---|
| `std.builtin` | `std.lang` (`std.lang.Type`, `AtomicOrder`, `CallModifier`, ...) |
| `@import("builtin").os`, `.cpu`, `.abi`, `.object_format` (removed in 0.18) | `.target.os`, `.target.cpu`, `.target.abi`, `.target.ofmt` |
| `@import("builtin").mode`, `std.lang.OptimizeMode` | `@import("builtin").optimize`, `std.lang.Optimize` |
| tags `.Debug`, `.ReleaseSafe`, `.ReleaseFast`, `.ReleaseSmall` | `.debug`, `.safe`, `.fast`, `.small` |
| `std.debug.runtime_safety` | `@import("builtin").optimize.runtimeSafety()` |
| `Target.isAARCH64`, `isRISCV`, `isMIPS*`, `isPowerPC*`, `isSPARC`, `isSpirV`, `isLoongArch` | `isAarch64`, `isRiscv`, `isMips*`, `isPowerpc*`, `isSparc`, `isSpirv`, `isLoongarch` |
| `Target.isBSD` | check the specific OS tags |
| `Target.linuxTriple`, `hurdTuple`, and their `Simple` forms | `std.zig.target.linuxTriple`, ... |

The old optimize tags still exist as deprecated declarations, but `==` and `!=`
cannot use them, so `optimize == .ReleaseSafe` is a compile error.
`std.Target.parseCpuModel` returns an optional instead of an error.

## Files, paths, and I/O

- Everything left in `std.fs` is deprecated. `std.fs.path` is `std.Io.Dir.path`;
  `std.fs.max_path_bytes` and `max_name_bytes` are `std.Io.Dir.max_path_bytes`
  and `max_name_bytes`; `std.fs.base64_*` is `std.base64.url_safe`.
- `path.resolve` and `path.relative` (and their `Posix`/`Windows` forms) are
  aliases of `resolveAlloc(gpa, paths)` and
  `relativeAlloc(gpa, cwd, environ_map, from, to)`. Appending variants were
  added.
- `std.Io.Reader.readAlloc` is `readAllocAll(reader, gpa, len)`; the old name
  goes away after 0.17.
- `std.Io.net` `sendMany` is deprecated; call `sendManyTimeout` with `.none`.
- `std.Io.Semaphore.waitTimeout` is new.
- `std.tar.pipeToFileSystem` and `PipeOptions` are `extract` and
  `ExtractOptions`.
- On Darwin, `Dir.renamePreserve` now calls `renameatx_np` with exclusive mode,
  so it can move directories (0.16 hard-linked and could not). It treats
  `ENOTEMPTY`, `EISDIR`, and `EINVAL` as programmer bugs: `errnoBug` panics in
  Debug builds and returns `error.Unexpected` in release builds.

## Text

- `std.unicode.utf8Decode` and `wtf8Decode` are deprecated. The fixed-length
  decoders assert that the lead byte matches the length, so validate first:

  ```zig
  fn decodeOne(sequence: []const u8) error{InvalidUtf8}!u21 {
      if (sequence.len == 0) return error.InvalidUtf8;
      const len = std.unicode.utf8ByteSequenceLength(sequence[0]) catch return error.InvalidUtf8;
      if (len != sequence.len) return error.InvalidUtf8;
      return switch (len) {
          1 => sequence[0],
          2 => std.unicode.utf8Decode2(sequence[0..2].*) catch error.InvalidUtf8,
          3 => std.unicode.utf8Decode3(sequence[0..3].*) catch error.InvalidUtf8,
          4 => std.unicode.utf8Decode4(sequence[0..4].*) catch error.InvalidUtf8,
          else => unreachable,
      };
  }
  ```
- `std.ascii.indexOfIgnoreCase`, `indexOfIgnoreCasePos`, and
  `indexOfIgnoreCasePosLinear` are removed; use `findIgnoreCase*`.

## Networking and URIs

`Uri` no longer validates host names. `Uri.getHost(&buf)` is replaced by
`std.Io.net.HostName.fromUri(uri, &buf)`, which validates and has a different
error set. `Uri.getHostAlloc` is removed.

## ZON

`std.zon.parse.fromSlice` takes one struct and allocates results and
diagnostics from an arena:

```zig
var diag: std.zon.parse.Diagnostics = undefined;
const cfg = try std.zon.parse.fromSlice(Config, .{
    .gpa = gpa,
    .arena = arena,
    .source = source,
    .diagnostics = &diag,
});
// on error.ParseZon: diag.fatal("input.zon")
```

`fromSliceAlloc` became `fromSlice`, the old `fromSlice` became
`fromSliceNoAlloc`, and the other `from*` functions follow the same scheme. New
`updateFrom*` functions overwrite only the fields a ZON source sets, which suits
layered configuration.

## Other

- `std.meta.fieldInfo`, `fieldNames`, `fieldTypes`: use `@typeInfo`.
- `std.gpu` is renamed `std.spirv`, with new image sampling helpers.
- `std.debug.SafetyLock` gained `lockShared` and `unlockShared`.
- `std.zig.allocPrintCmd` and `std.testing.parent_dir_path` are deprecated.
- `f128` `@exp` and `@exp2` are implemented; `hash.crc` was audited.
