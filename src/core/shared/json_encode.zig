//! Drop-in replacements for `std.json.Stringify.value`, `valueAlloc`, and
//! `Stringify.write`.
//!
//! `std.json` generates a whole writer for every type it writes, and each call
//! inlines that writer's punctuation and safety checks, so every struct,
//! slice, optional, and call site carries its own copy of the writing logic.
//! Here each type is described once at compile time, as a table of fields,
//! offsets, and child types, and one shared function walks that table at run
//! time. Scalars, optionals, slices, and unions keep a small per-type helper,
//! so number formatting, enum names, and memory layout follow `std.json`
//! exactly.
//!
//! For the same value and options, the output is byte for byte what
//! `std.json` writes. The tests below check that against `std.json` itself.
//! Types with a `jsonStringify` method still write through that method, and
//! the few shapes without byte-addressable fields (packed structs and
//! vectors) write through `std.json`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Writer = std.Io.Writer;

const Error = Writer.Error;

/// Same contract as `std.json.Stringify.value`.
pub fn value(v: anytype, options: Stringify.Options, writer: *Writer) Error!void {
    const T = @TypeOf(v);
    if (comptime isComptimeOnly(T)) return Stringify.value(v, options, writer);
    const coerced: Coerced(T) = v;
    return writeDocument(describe(Coerced(T)), @ptrCast(&coerced), options, writer);
}

/// Same contract as `std.json.Stringify.valueAlloc`. Caller owns the returned
/// memory.
pub fn valueAlloc(gpa: Allocator, v: anytype, options: Stringify.Options) error{OutOfMemory}![]u8 {
    const T = @TypeOf(v);
    if (comptime isComptimeOnly(T)) return Stringify.valueAlloc(gpa, v, options);
    const coerced: Coerced(T) = v;
    return allocDocument(gpa, describe(Coerced(T)), @ptrCast(&coerced), options);
}

/// Same contract as `std.json.Stringify.write`, for a `jsonStringify` method
/// or a document written piece by piece.
pub fn write(stringify: *Stringify, v: anytype) Error!void {
    const T = @TypeOf(v);
    if (comptime isComptimeOnly(T)) return stringify.write(v);
    const coerced: Coerced(T) = v;
    return writeValue(stringify, describe(Coerced(T)), @ptrCast(&coerced));
}

/// A pointer to a byte array, such as a string literal, is written as the
/// `[]const u8` slice it coerces to, as `std.json` writes it, so every
/// literal length shares one description.
fn Coerced(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => return T,
    };
    if (info.size != .one) return T;
    return switch (@typeInfo(info.child)) {
        .array => |array| if (array.child == u8) []const u8 else T,
        else => T,
    };
}

/// Values that exist only at compile time have no address to describe, so
/// `std.json` writes them directly. Each is a single token.
fn isComptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .enum_literal, .null => true,
        else => false,
    };
}

fn writeDocument(desc: *const Desc, ptr: *const anyopaque, options: Stringify.Options, writer: *Writer) Error!void {
    var stringify: Stringify = .{ .writer = writer, .options = options };
    return writeValue(&stringify, desc, ptr);
}

fn allocDocument(gpa: Allocator, desc: *const Desc, ptr: *const anyopaque, options: Stringify.Options) error{OutOfMemory}![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeDocument(desc, ptr, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const WriteLeaf = *const fn (stringify: *Stringify, ptr: *const anyopaque) Error!void;

const Desc = union(enum) {
    /// Scalars, types with their own `jsonStringify`, and shapes this file
    /// does not walk, written by `std.json` through a per-type helper.
    leaf: WriteLeaf,
    optional: Optional,
    /// `*T`, written as the `T` it points to.
    pointer: *const Desc,
    slice: Sequence,
    array: Sequence,
    object: Object,
    /// A tuple, written as an array of its fields.
    tuple: Object,
    tagged: Tagged,
    /// A `comptime` struct field, whose value the struct does not store.
    constant: Constant,
};

const Optional = struct {
    child: *const Desc,
    /// The payload, or null when the optional is null.
    payload: *const fn (ptr: *const anyopaque) ?*const anyopaque,
};

/// The tables are read-only data that holds pointers, so they cost binary
/// size next to the code they replace: a field takes 16 bytes, and a struct's
/// field names share one string.
const Object = struct {
    fields: []const Field,
    names: [*]const u8,
};

const Field = struct {
    desc: *const Desc,
    layout: FieldLayout,

    fn name(field: *const Field, names: [*]const u8) []const u8 {
        return names[field.layout.name_offset..][0..field.layout.name_len];
    }
};

const FieldLayout = packed struct(u64) {
    offset: u32,
    name_offset: u24,
    name_len: u8,
};

/// Whether a struct fits `FieldLayout`; one that does not writes through
/// `std.json`.
fn fitsFieldLayout(comptime T: type) bool {
    const info = @typeInfo(T).@"struct";
    var names_len: usize = 0;
    for (info.field_names) |name| {
        if (name.len >= 1 << 8 or names_len >= 1 << 24) return false;
        names_len += name.len;
    }
    return @sizeOf(T) < 1 << 32;
}

const Sequence = struct {
    child: *const Desc,
    /// Reads a slice's items; unused for arrays.
    items: *const fn (ptr: *const anyopaque) Items = undefined,
    elem_size: u32,
    shape: SequenceShape,
};

const SequenceShape = packed struct(u32) {
    /// Element count, for arrays.
    len: u31 = 0,
    /// The elements are `u8`, which `std.json` writes as a string when they
    /// are valid UTF-8.
    bytes: bool,
};

const Items = struct {
    ptr: [*]const u8,
    len: usize,
};

/// Whether a child type fits `Sequence`; one that does not writes through
/// `std.json`.
fn fitsSequence(comptime Child: type, comptime len: usize) bool {
    return @sizeOf(Child) < 1 << 32 and len < 1 << 31;
}

const Tagged = struct {
    variants: []const Variant,
    /// The active field's index and payload.
    active: *const fn (ptr: *const anyopaque) Active,
};

const Variant = struct {
    name: []const u8,
    /// Null for a `void` payload, which `std.json` writes as `{}`.
    desc: ?*const Desc,
};

const Active = struct {
    index: usize,
    payload: *const anyopaque,
};

const Constant = struct {
    desc: *const Desc,
    ptr: *const anyopaque,
};

fn describe(comptime T: type) *const Desc {
    return &Described(T).desc;
}

fn Described(comptime T: type) type {
    return struct {
        const desc: Desc = build(T);
    };
}

fn build(comptime T: type) Desc {
    const leaf: Desc = .{ .leaf = Helpers(T).writeLeaf };
    switch (@typeInfo(T)) {
        .optional => |info| return .{ .optional = .{
            .child = describe(info.child),
            .payload = Helpers(T).payload,
        } },
        .@"union" => |info| {
            if (std.meta.hasFn(T, "jsonStringify") or info.tag_type == null) return leaf;
            const variants = comptime variants: {
                var list: [info.field_names.len]Variant = undefined;
                for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
                    list[i] = .{ .name = name, .desc = if (FieldType == void) null else describe(FieldType) };
                }
                const final = list;
                break :variants &final;
            };
            return .{ .tagged = .{ .variants = variants, .active = Helpers(T).active } };
        },
        .@"struct" => |info| {
            // Packed structs, whose fields have no byte offsets, write
            // through `std.json` itself.
            if (std.meta.hasFn(T, "jsonStringify")) return leaf;
            if (info.layout == .@"packed" or !fitsFieldLayout(T)) return leaf;
            const object = comptime object: {
                var count: usize = 0;
                for (info.field_types) |FieldType| {
                    if (FieldType != void) count += 1;
                }
                var list: [count]Field = undefined;
                var names: []const u8 = "";
                var i: usize = 0;
                for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, index| {
                    // `std.json` leaves out `void` fields.
                    if (FieldType == void) continue;
                    // A tuple's fields have no names in JSON.
                    const json_name = if (info.is_tuple) "" else name;
                    list[i] = .{
                        .desc = if (attrs.@"comptime") &ComptimeField(T, index).desc else describe(FieldType),
                        .layout = .{
                            .offset = if (attrs.@"comptime") 0 else @offsetOf(T, name),
                            .name_offset = names.len,
                            .name_len = json_name.len,
                        },
                    };
                    names = names ++ json_name;
                    i += 1;
                }
                const final_fields = list;
                const final_names = names[0..names.len].*;
                break :object Object{ .fields = &final_fields, .names = &final_names };
            };
            return if (info.is_tuple) .{ .tuple = object } else .{ .object = object };
        },
        .array => |info| {
            if (!fitsSequence(info.child, info.len)) return leaf;
            return .{ .array = .{
                .child = describe(info.child),
                .elem_size = @sizeOf(info.child),
                .shape = .{ .len = info.len, .bytes = info.child == u8 },
            } };
        },
        .pointer => |info| switch (info.size) {
            // `std.json` writes `*[N]T` as a slice, which is the array the
            // pointer points to.
            .one => return .{ .pointer = describe(info.child) },
            .slice, .many => {
                // A many-item pointer without a sentinel has no length, and
                // `std.json` rejects it.
                if (info.size == .many and info.sentinel() == null) return leaf;
                if (!fitsSequence(info.child, 0)) return leaf;
                return .{ .slice = .{
                    .child = describe(info.child),
                    .items = Helpers(T).items,
                    .elem_size = @sizeOf(info.child),
                    .shape = .{ .bytes = info.child == u8 },
                } };
            },
            .c => return leaf,
        },
        // Booleans, numbers, enums, errors, vectors, and every type
        // `std.json` rejects.
        else => return leaf,
    }
}

/// A `comptime` field of `T`: its value lives in the type, not the struct.
fn ComptimeField(comptime T: type, comptime index: usize) type {
    const info = @typeInfo(T).@"struct";
    const FieldType = info.field_types[index];
    const default: *const FieldType = @ptrCast(@alignCast(info.field_attrs[index].default_value_ptr.?));
    return struct {
        const desc: Desc = .{ .constant = if (isComptimeOnly(FieldType))
            .{ .desc = &comptime_only, .ptr = @ptrCast(&comptime_only) }
        else
            .{ .desc = describe(Coerced(FieldType)), .ptr = @ptrCast(&coerced) } };

        const coerced: Coerced(FieldType) = default.*;

        /// A value that exists only at compile time, such as an integer
        /// literal, has no address, so this helper writes it directly.
        const comptime_only: Desc = .{ .leaf = writeComptimeOnly };

        fn writeComptimeOnly(stringify: *Stringify, _: *const anyopaque) Error!void {
            return stringify.write(default.*);
        }
    };
}

/// The only code generated per type: each helper converts the type-erased
/// pointer back to `T`.
fn Helpers(comptime T: type) type {
    return struct {
        fn writeLeaf(stringify: *Stringify, ptr: *const anyopaque) Error!void {
            const v: *const T = @ptrCast(@alignCast(ptr));
            return stringify.write(v.*);
        }

        fn payload(ptr: *const anyopaque) ?*const anyopaque {
            const v: *const T = @ptrCast(@alignCast(ptr));
            if (v.*) |*some| return @ptrCast(some);
            return null;
        }

        fn items(ptr: *const anyopaque) Items {
            const v: *const T = @ptrCast(@alignCast(ptr));
            const slice = if (@typeInfo(T).pointer.size == .many) std.mem.span(v.*) else v.*;
            return .{ .ptr = @ptrCast(slice.ptr), .len = slice.len };
        }

        fn active(ptr: *const anyopaque) Active {
            const info = @typeInfo(T).@"union";
            const v: *const T = @ptrCast(@alignCast(ptr));
            inline for (info.field_names, 0..) |name, index| {
                if (v.* == @field(info.tag_type.?, name)) {
                    return .{ .index = index, .payload = @ptrCast(&@field(v.*, name)) };
                }
            }
            unreachable;
        }
    };
}

fn writeValue(stringify: *Stringify, desc: *const Desc, ptr: *const anyopaque) Error!void {
    switch (desc.*) {
        .leaf => |leaf| return leaf(stringify, ptr),
        .optional => |optional| {
            const some = optional.payload(ptr) orelse return stringify.write(null);
            return writeValue(stringify, optional.child, some);
        },
        .pointer => |child| {
            const target: *const *const anyopaque = @ptrCast(@alignCast(ptr));
            return writeValue(stringify, child, target.*);
        },
        .slice => |seq| {
            const items = seq.items(ptr);
            return writeItems(stringify, seq, items.ptr, items.len);
        },
        .array => |seq| return writeItems(stringify, seq, @ptrCast(ptr), seq.shape.len),
        .object => |object| return writeFields(stringify, object, @ptrCast(ptr), false),
        .tuple => |object| return writeFields(stringify, object, @ptrCast(ptr), true),
        .tagged => |tagged| return writeTagged(stringify, tagged, ptr),
        .constant => |constant| return writeValue(stringify, constant.desc, constant.ptr),
    }
}

fn writeItems(stringify: *Stringify, seq: Sequence, items: [*]const u8, len: usize) Error!void {
    // `std.json` checks the bytes for UTF-8 and honors
    // `emit_strings_as_arrays` itself.
    if (seq.shape.bytes) return stringify.write(items[0..len]);
    try stringify.beginArray();
    for (0..len) |i| try writeValue(stringify, seq.child, @ptrCast(items + i * seq.elem_size));
    try stringify.endArray();
}

fn writeFields(stringify: *Stringify, object: Object, base: [*]const u8, tuple: bool) Error!void {
    if (tuple) try stringify.beginArray() else try stringify.beginObject();
    for (object.fields) |*field| {
        var desc = field.desc;
        var ptr: *const anyopaque = @ptrCast(base + field.layout.offset);
        if (desc.* == .constant) {
            ptr = desc.constant.ptr;
            desc = desc.constant.desc;
        }
        // `std.json` leaves a null optional out of a tuple too.
        if (!stringify.options.emit_null_optional_fields and desc.* == .optional) {
            if (desc.optional.payload(ptr) == null) continue;
        }
        if (!tuple) try stringify.objectField(field.name(object.names));
        try writeValue(stringify, desc, ptr);
    }
    if (tuple) try stringify.endArray() else try stringify.endObject();
}

fn writeTagged(stringify: *Stringify, tagged: Tagged, ptr: *const anyopaque) Error!void {
    const active = tagged.active(ptr);
    const variant = tagged.variants[active.index];
    try stringify.beginObject();
    try stringify.objectField(variant.name);
    if (variant.desc) |desc| {
        try writeValue(stringify, desc, active.payload);
    } else {
        try stringify.beginObject();
        try stringify.endObject();
    }
    try stringify.endObject();
}

// Every test writes the same value through `std.json` and through this file
// and expects the same bytes, under each set of options.

const testing = std.testing;

const test_options = [_]Stringify.Options{
    .{},
    .{ .whitespace = .indent_2 },
    .{ .whitespace = .indent_tab },
    .{ .emit_null_optional_fields = false },
    .{ .emit_strings_as_arrays = true },
    .{ .escape_unicode = true },
    .{ .emit_nonportable_numbers_as_strings = true, .whitespace = .indent_1, .emit_null_optional_fields = false },
};

fn expectSame(v: anytype) !void {
    for (test_options) |options| {
        const expected = try Stringify.valueAlloc(testing.allocator, v, options);
        defer testing.allocator.free(expected);
        const actual = try valueAlloc(testing.allocator, v, options);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);

        var buffer: [16384]u8 = undefined;
        var fixed: Writer = .fixed(&buffer);
        try value(v, options, &fixed);
        try testing.expectEqualStrings(expected, fixed.buffered());
    }
}

const TestColor = enum(u8) { red, green, blue = 7 };
const TestOpenColor = enum(u8) { red, green, _ };

const TestInner = struct {
    a: i32,
    b: ?f64 = null,
    color: TestColor = .red,
};

const TestChoice = union(enum) {
    none: void,
    num: u16,
    text: []const u8,
    inner: TestInner,
    nested: ?*const TestChoice,
};

/// Writes through its own method, which calls back into this file.
const TestCustom = struct {
    doubled: i64,

    pub fn jsonStringify(self: TestCustom, jw: *Stringify) Error!void {
        try jw.beginObject();
        try jw.objectField("half");
        try write(jw, @divTrunc(self.doubled, 2));
        try jw.objectField("inner");
        try write(jw, TestInner{ .a = 1, .b = 0.5 });
        try jw.endObject();
    }
};

const TestFlags = packed struct(u8) {
    read: bool = false,
    write: bool = true,
    rest: u6 = 3,
};

const TestExtern = extern struct {
    x: u16 = 1,
    y: u64 = 2,
};

/// A recursive type, whose description refers to itself.
const TestTree = struct {
    name: []const u8,
    children: []const TestTree = &.{},
    parent: ?*const TestTree = null,
};

const TestDoc = struct {
    id: u64,
    name: []const u8,
    flag: bool = false,
    ratio: f32 = 1.5,
    exact: f64 = 0.1,
    small: i8 = -1,
    wide: i128 = std.math.minInt(i128),
    huge: u64 = std.math.maxInt(u64),
    items: []const TestInner = &.{},
    tags: []const []const u8 = &.{},
    fixed: [3]u8 = .{ 1, 2, 3 },
    code: [4]u8 = "abcd".*,
    maybe: ?TestInner = null,
    boxed: ?*const TestInner = null,
    choice: TestChoice = .none,
    bytes: []u8 = &.{},
    nested: []const []const i64 = &.{},
    custom: ?TestCustom = null,
    pair: [2]TestColor = .{ .red, .blue },
    open: TestOpenColor = @fromBackingInt(@intCast(9)),
    note: ?[]const u8 = null,
    double: ??u8 = @as(?u8, null),
    flags: TestFlags = .{},
    point: struct { i32, ?bool } = .{ 0, null },
    zstr: [:0]const u8 = "z",
    cstr: [*:0]const u8 = "c",
    nothing: void = {},
    ext: TestExtern = .{},
    failure: anyerror = error.OutOfMemory,
    vec: @Vector(2, u8) = @splat('A'),
    dynamic: std.json.Value = .null,
    empty: struct {} = .{},
    zeros: []const struct {} = &.{ .{}, .{} },
};

test "structs, slices, optionals, and unions match std.json" {
    const inner: TestInner = .{ .a = -5, .b = 2.25, .color = .blue };
    var mutable_bytes = "mutable".*;
    try expectSame(TestDoc{ .id = 1, .name = "plain" });
    try expectSame(TestDoc{
        .id = 2,
        .name = "h\u{e9}llo \"quoted\"\n\x01 \u{1f600}",
        .flag = true,
        .ratio = std.math.nan(f32),
        .exact = std.math.inf(f64),
        .items = &.{ inner, .{ .a = 3 } },
        .tags = &.{ "x", "", "\xff\xfe not utf-8" },
        .code = "\xe9\xe9\xe9\xe9".*,
        .maybe = inner,
        .boxed = &inner,
        .choice = .{ .inner = inner },
        .bytes = &mutable_bytes,
        .nested = &.{ &.{}, &.{ 1, -2 }, &.{9007199254740993} },
        .custom = .{ .doubled = 84 },
        .open = .green,
        .note = "note",
        .double = @as(?u8, 7),
        .point = .{ -1, true },
        .dynamic = .{ .string = "dynamic" },
    });
    try expectSame(TestDoc{ .id = 3, .name = "double null", .double = null, .choice = .{ .text = "t" } });
    const leaf_choice: TestChoice = .{ .num = 65535 };
    try expectSame(TestChoice{ .nested = &leaf_choice });
    try expectSame(TestChoice{ .nested = null });
}

test "scalars, strings, and pointers at the top level match std.json" {
    try expectSame(true);
    try expectSame(@as(u8, 200));
    try expectSame(@as(i64, std.math.minInt(i64)));
    try expectSame(@as(u128, std.math.maxInt(u128)));
    try expectSame(@as(f32, -0.0));
    try expectSame(@as(f64, 1e300));
    try expectSame(@as([]const u8, "string"));
    try expectSame("literal");
    try expectSame(@as([]const u8, "\xc3"));
    try expectSame(@as([:0]const u8, "sentinel"));
    try expectSame(@as([*:0]const u8, "many"));
    try expectSame([_]u16{ 1, 2, 3 });
    try expectSame(&[_]TestColor{ .green, .blue });
    try expectSame(@as([]const ?u8, &.{ null, 1 }));
    try expectSame(@as(?u8, null));
    try expectSame(TestColor.blue);
    try expectSame(@as(TestOpenColor, @fromBackingInt(@intCast(200))));
    try expectSame(error.NotFound);
    try expectSame(TestFlags{});
    try expectSame(.{ @as(u8, 1), "tuple" });
    try expectSame(42);
    try expectSame(1.5);
    try expectSame(.literal);
    try expectSame(null);
    try expectSame(TestCustom{ .doubled = -6 });
    const leaf: TestTree = .{ .name = "leaf" };
    const root: TestTree = .{ .name = "root", .children = &.{ leaf, .{ .name = "second", .children = &.{leaf} } } };
    try expectSame(root);
    try expectSame(TestTree{ .name = "child", .parent = &root });
}

test "anonymous struct literals with comptime fields match std.json" {
    var id: u32 = 7;
    _ = &id;
    const text: []const u8 = "runtime";
    try expectSame(.{ .jsonrpc = "2.0", .id = id, .result = .{ .text = text, .count = 3 } });
    try expectSame(.{ .kind = .literal, .missing = null, .ratio = 0.5, .big = 9007199254740993, .flag = false });
    try expectSame(.{ .maybe = @as(?u8, null), .present = @as(?u8, 1), .list = .{ 1, "two" } });
    try expectSame(.{});
}

test "write fits into a document written piece by piece" {
    for (test_options) |options| {
        var expected: Writer.Allocating = .init(testing.allocator);
        defer expected.deinit();
        var actual: Writer.Allocating = .init(testing.allocator);
        defer actual.deinit();
        var by_std: Stringify = .{ .writer = &expected.writer, .options = options };
        var by_this: Stringify = .{ .writer = &actual.writer, .options = options };
        const inner: TestInner = .{ .a = 2, .b = null };
        try by_std.beginArray();
        try by_this.beginArray();
        try by_std.write(inner);
        try write(&by_this, inner);
        try by_std.write(@as([]const u8, "s"));
        try write(&by_this, @as([]const u8, "s"));
        try by_std.write(TestChoice.none);
        try write(&by_this, TestChoice.none);
        try by_std.endArray();
        try by_this.endArray();
        try testing.expectEqualStrings(expected.written(), actual.written());
    }
}

test "valueAlloc reports allocation failure and a full writer reports WriteFailed" {
    const doc: TestDoc = .{ .id = 4, .name = "a name long enough to need more than one allocation" };
    try testing.expectError(error.OutOfMemory, valueAlloc(testing.failing_allocator, doc, .{}));
    var buffer: [16]u8 = undefined;
    var fixed: Writer = .fixed(&buffer);
    try testing.expectError(error.WriteFailed, value(doc, .{}, &fixed));
}

test "table entries stay small" {
    try testing.expectEqual(16, @sizeOf(Field));
    try testing.expectEqual(24, @sizeOf(Sequence));
    try testing.expect(@sizeOf(Desc) <= 32);
}
