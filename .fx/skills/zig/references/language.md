# Zig 0.17 language changes

Read this when a change touches syntax, builtins, casts, comptime, or
reflection. Every example compiles and passes on 0.17.0 and 0.17.1, which
share the language. 0.17.1 only tightens the parser to the grammar: a doc
comment before `...` in a parameter list is now an error.

## Removed syntax and types

### Array multiplication `**`

`a ** n` is gone. Fill arrays with `@splat`:

```zig
const zeros: [8]u8 = @splat(0);
const rule: [40]u8 = @splat('-');      // use &rule where a slice is needed
```

Repeated strings need a comptime helper. The function must be `inline` and
return a `comptime` block, because a runtime-callable function cannot return a
value from inside `comptime { ... }`:

```zig
inline fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count:0]u8 {
    return comptime blk: {
        var bytes: [text.len * count:0]u8 = @splat(0);
        for (0..count) |i| @memcpy(bytes[i * text.len ..][0..text.len], text);
        const final = bytes;
        break :blk &final;
    };
}
```

`++` concatenation still works.

### `errdefer` capture

`errdefer |err| ...` no longer parses. Split the function so the caller sees
the error:

```zig
fn processOneTarget(job: Job) void {
    processOneTargetFallible(job) catch |err| std.debug.panic("panic: {s}", .{@errorName(err)});
}
fn processOneTargetFallible(job: Job) !void { ... }
```

### Smaller removals

- `void{}` is invalid; write `{}`.
- `i0` is not a type; `u0` replaces it.
- `std.lang.GlobalLinkage` lost `internal` (do not `@export` the symbol) and
  `link_once` (use `weak`).
- `@cImport`, `@cInclude`, `@cDefine`, and `@cUndef` are gone. Use the
  translate-c package described in build-system.md.

## Changed semantics

### `@hasDecl` sees only `pub` declarations

0.16 also found non-`pub` declarations in the same file. 0.17 behaves the same
everywhere:

```zig
const Foo = struct {
    bar: i32,
    const baz = 1;
    pub var quux = "xxx";
};
// @hasDecl(Foo, "bar") == false  (field, not a declaration)
// @hasDecl(Foo, "baz") == false  (true on 0.16)
// @hasDecl(Foo, "quux") == true
```

Duck typing such as `if (@hasDecl(App, "clipboard")) app.clipboard()` turns a
feature off with no error when the declaration is private. Search every
`@hasDecl` target and make the real and fake implementations declare it `pub`.

### `@bitCast`

It reinterprets the logical bit representation. Types with one are `void`,
`bool`, runtime integers and floats, `enum(T)`, `packed struct(T)`,
`packed union(T)`, and arrays or vectors of those. Arrays and vectors
concatenate their elements' bits in index order, independent of endianness.
Integer-to-integer and integer-to-packed casts are unchanged.

`extern struct` and `extern union` operands are now compile errors. Pun through
a pointer instead:

```zig
const TwoBytes = extern struct { b0: u8, b1: u8 };
const bytes: TwoBytes = .{ .b0 = 0x12, .b1 = 0xAB };
const int_ptr: *align(1) const u16 = @ptrCast(&bytes);
// int_ptr.* == 0xAB12 on little-endian targets
```

Casts involving arrays or vectors can change results on big-endian targets
without a compile error, so test any such cast you keep. A `@bitCast` to an
enum now safety-checks the tag value.

### Enum and bitpack integers: `@backingInt` and `@fromBackingInt`

`@intFromEnum` and `@enumFromInt` are deprecated; `zig fmt` rewrites them.

- `@backingInt(x)` works on every enum, on bitpacks with an explicit backing
  integer, and on tagged unions (it returns the active tag's integer).
- `@fromBackingInt(int)` infers its result type and requires exactly the
  backing integer type, so narrow first: `@fromBackingInt(@intCast(index))`.
- `std.meta.BackingInt(T)` names the result type.
- An empty enum must use `noreturn` as its backing type.

```zig
const Level = enum(u8) { low = 1, high = 2 };
const b = @backingInt(Level.high);               // 2, type u8
const wide: usize = 1;
const level: Level = @fromBackingInt(@intCast(wide));
```

### Type reflection is struct-of-arrays

`@typeInfo` returns `std.lang.Type`. Structs and unions expose parallel slices:

```zig
const info = @typeInfo(S).@"struct";
inline for (info.field_names, info.field_types) |name, T| { ... }
// also: info.field_attrs, info.decl_names
```

The old `fields` array is gone. `std.meta.fieldNames`, `fieldInfo`, and
`fieldTypes` are deprecated in favor of this.

## Additions

- **`@divCeil(numerator, denominator)`** rounds toward positive infinity:
  `@divCeil(5, 3) == 2`, `@divCeil(-5, 3) == -1`. The caller guarantees a
  nonzero denominator and no overflow. Both operands need one type, so cast a
  `usize` constant with `@as(u64, c)` when the other side is `u64`.
- **Comptime-length slices** dereference to arrays and coerce to array
  pointers:

  ```zig
  const slice: []const u16 = &.{ 1, 2, 3 };
  const array: [3]u16 = slice.*;
  const array_ptr: *const [3]u16 = slice;
  ```
- **`@SpirvType`** declares SPIR-V images, samplers, sampled images, and
  runtime arrays. It is a compile error on other targets.

## New guidance in the 0.17 language reference

- **Slicing by length:** write `s[a..][0..n]` instead of `s[a .. a + n]`. When
  `n` is comptime-known the result is `*[n]T` rather than `[]T`, which is
  usually safer. That type change can alter generic consumers (for example
  `std.json` serializes the two differently), so change existing call sites
  deliberately, not with a blind rewrite.
- **`inline` is not a hint.** It restricts the compiler and can cost size,
  compile time, and speed. Use `@branchHint` to hint; keep `inline` for required
  comptime propagation, guaranteed frames, or backend workarounds.
- Containers are called namespaces; "container level" and "static local"
  variables are now "namespace level" and "locally scoped global" variables.
- Builtin signatures name `std.lang` types (`std.lang.Type`,
  `std.lang.SourceLocation`, `std.lang.CallModifier`, `std.lang.VaList`).
- The grammar in `grammar.peg` now matches the parser and is fuzzed against it.
  This does not change valid programs.
