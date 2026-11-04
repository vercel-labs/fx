//! Deep copies and frees of values that own what they point to.
//!
//! fx copies and frees much of its state by hand, one pair of functions per
//! type, and every pair repeats the same steps: duplicate each slice, copy its
//! elements, undo the copies made so far when one fails, and free them all
//! again. Here each type is described once at compile time, and one shared
//! function walks the description to copy or free any value.
//!
//! A value owns every slice and optional payload it reaches and copies
//! everything else bit for bit. A struct names fields that a copy leaves out,
//! such as a pointer borrowed for one action, in `pub const copy_omits`: a copy
//! resets them to their defaults, and freeing skips them. Any other pointer,
//! such as a single-item pointer, `*anyopaque`, or a function pointer, is a
//! compile error, because its type does not say who owns it; copy such a type
//! by hand.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Error = Allocator.Error;

/// Returns a copy of `value` that owns new copies of every slice it reaches.
/// The caller owns the copy and releases it with `free`. On error, nothing
/// the copy allocated is left behind.
pub fn dupe(comptime T: type, alloc: Allocator, value: T) Error!T {
    if (comptime describe(T).* == .plain) return value;
    var copy: T = undefined;
    try dupeInto(alloc, describe(T), @ptrCast(&copy), @ptrCast(&value), @sizeOf(T));
    return copy;
}

/// `dupe` for a slice, returning mutable elements as `Allocator.dupe` does.
/// The caller owns the copy and releases it with `free`.
pub fn dupeSlice(comptime Elem: type, alloc: Allocator, items: []const Elem) Error![]Elem {
    // A copy only reads its source, so viewing the source as mutable is safe.
    return dupe([]Elem, alloc, @constCast(items));
}

/// Frees everything a value from `dupe` owns.
pub fn free(comptime T: type, alloc: Allocator, value: T) void {
    if (comptime describe(T).* == .plain) return;
    // Freeing only reads the value.
    freeAt(alloc, describe(T), @ptrCast(@constCast(&value)));
}

const Desc = union(enum) {
    /// Owns nothing: copied bit for bit, nothing to free.
    plain,
    /// A `[]u8` or `[]const u8`, the most common owned field, copied and freed
    /// as `Allocator.dupe` and `Allocator.free` do without a call per type.
    bytes,
    /// An optional `bytes`.
    optional_bytes,
    optional: Optional,
    slice: Slice,
    object: Object,
    tagged: Tagged,
};

const Optional = struct {
    child: *const Desc,
    /// The payload, or null when the optional is null.
    payload: *const fn (ptr: *anyopaque) ?*anyopaque,
};

const Slice = struct {
    /// Null when the elements own nothing, so copying the block copies them.
    child: ?*const Desc,
    /// Reads the slice at `ptr`; given a block, also points the slice at it.
    access: *const fn (ptr: *anyopaque, block: ?[*]u8) Items,
    elem_size: usize,
    alignment: std.mem.Alignment,

    fn at(slice: Slice, block: [*]u8, index: usize) *anyopaque {
        return @ptrCast(block + index * slice.elem_size);
    }
};

const Items = struct {
    ptr: [*]u8,
    len: usize,
};

const Object = struct {
    /// The fields that own something, in declaration order.
    fields: []const Field,
    /// The fields named in `copy_omits`.
    omits: []const Omit,
};

const Field = struct {
    desc: *const Desc,
    offset: usize,
};

const Omit = struct {
    offset: usize,
    default: []const u8,
};

const Tagged = struct {
    /// Indexed by `active`; null for a payload that owns nothing.
    variants: [*]const ?*const Desc,
    active: *const fn (ptr: *anyopaque) Active,
};

const Active = struct {
    index: usize,
    payload: *anyopaque,
};

fn describe(comptime T: type) *const Desc {
    return &Described(T).desc;
}

fn Described(comptime T: type) type {
    return struct {
        const desc: Desc = build(T);
    };
}

/// Whether a value of `T` reaches no pointer, so a bit copy is a full copy.
fn ownsNothing(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => false,
        .optional => |info| ownsNothing(info.child),
        .array => |info| ownsNothing(info.child),
        .@"struct" => |info| {
            if (@hasDecl(T, "copy_omits")) return false;
            for (info.field_types, info.field_attrs) |FieldType, attrs| {
                if (!attrs.@"comptime" and !ownsNothing(FieldType)) return false;
            }
            return true;
        },
        .@"union" => |info| {
            for (info.field_types) |FieldType| {
                if (!ownsNothing(FieldType)) return false;
            }
            return true;
        },
        else => true,
    };
}

fn build(comptime T: type) Desc {
    if (ownsNothing(T)) return .plain;
    if (isBytes(T)) return .bytes;
    switch (@typeInfo(T)) {
        .optional => |info| return if (isBytes(info.child)) .optional_bytes else .{ .optional = .{
            .child = describe(info.child),
            .payload = OptionalHelpers(T).payload,
        } },
        .pointer => |info| {
            if (info.size != .slice) @compileError("owned_copy cannot tell who owns " ++ @typeName(T) ++ "; name the field in copy_omits or copy the type by hand");
            if (info.sentinel_ptr != null) @compileError("owned_copy does not copy sentinel slices: " ++ @typeName(T));
            const child = describe(info.child);
            return .{ .slice = .{
                .child = if (child.* == .plain) null else child,
                .access = SliceHelpers(T).access,
                .elem_size = @sizeOf(info.child),
                .alignment = .of(info.child),
            } };
        },
        .@"struct" => |info| {
            const omitted: []const []const u8 = if (@hasDecl(T, "copy_omits")) &T.copy_omits else &.{};
            const object = comptime object: {
                for (omitted) |name| {
                    if (!@hasField(T, name)) @compileError(@typeName(T) ++ ".copy_omits names no field " ++ name);
                }
                var fields: []const Field = &.{};
                var omits: []const Omit = &.{};
                for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
                    if (attrs.@"comptime") continue;
                    if (isOmitted(omitted, name)) {
                        const default = attrs.default_value_ptr orelse
                            @compileError(@typeName(T) ++ "." ++ name ++ " is in copy_omits but has no default");
                        const bytes: *const [@sizeOf(FieldType)]u8 = @ptrCast(default);
                        omits = omits ++ [_]Omit{.{ .offset = @offsetOf(T, name), .default = bytes }};
                    } else if (!ownsNothing(FieldType)) {
                        fields = fields ++ [_]Field{.{ .desc = describe(FieldType), .offset = @offsetOf(T, name) }};
                    }
                }
                break :object Object{ .fields = fields, .omits = omits };
            };
            return .{ .object = object };
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("owned_copy does not copy untagged unions: " ++ @typeName(T));
            const variants = comptime variants: {
                var list: [info.field_types.len]?*const Desc = undefined;
                for (info.field_types, 0..) |FieldType, i| {
                    list[i] = if (ownsNothing(FieldType)) null else describe(FieldType);
                }
                const final = list;
                break :variants &final;
            };
            return .{ .tagged = .{ .variants = variants, .active = UnionHelpers(T).active } };
        },
        .array => @compileError("owned_copy does not copy arrays of owned values: " ++ @typeName(T)),
        else => @compileError("owned_copy cannot copy " ++ @typeName(T)),
    }
}

fn isBytes(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => return false,
    };
    return info.size == .slice and info.child == u8 and info.sentinel_ptr == null and
        !info.attrs.@"volatile" and !info.attrs.@"allowzero" and
        (info.attrs.@"addrspace" orelse .generic) == .generic and info.attrs.@"align" == null;
}

fn isOmitted(comptime omitted: []const []const u8, comptime name: []const u8) bool {
    for (omitted) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// The only code generated per type: each helper converts the type-erased
/// pointer back to `T`.
fn OptionalHelpers(comptime T: type) type {
    return struct {
        fn payload(ptr: *anyopaque) ?*anyopaque {
            const value: *T = @ptrCast(@alignCast(ptr));
            if (value.*) |*some| return @ptrCast(some);
            return null;
        }
    };
}

fn SliceHelpers(comptime T: type) type {
    const Elem = @typeInfo(T).pointer.child;
    return struct {
        fn access(ptr: *anyopaque, block: ?[*]u8) Items {
            const value: *T = @ptrCast(@alignCast(ptr));
            const items: Items = .{ .ptr = @ptrCast(@constCast(value.ptr)), .len = value.len };
            if (block) |new| value.* = @as([*]Elem, @ptrCast(@alignCast(new)))[0..value.len];
            return items;
        }
    };
}

fn UnionHelpers(comptime T: type) type {
    const info = @typeInfo(T).@"union";
    return struct {
        fn active(ptr: *anyopaque) Active {
            const value: *T = @ptrCast(@alignCast(ptr));
            inline for (info.field_names, 0..) |name, index| {
                if (value.* == @field(info.tag_type.?, name)) {
                    return .{ .index = index, .payload = @ptrCast(&@field(value.*, name)) };
                }
            }
            unreachable;
        }
    };
}

/// Copies the `size`-byte value at `source` to `dest`, then gives `dest` its own
/// copy of every part it owns. Shared by every type, so callers only pass
/// pointers.
noinline fn dupeInto(alloc: Allocator, desc: *const Desc, dest: *anyopaque, source: *const anyopaque, size: usize) Error!void {
    @memcpy(@as([*]u8, @ptrCast(dest))[0..size], @as([*]const u8, @ptrCast(source))[0..size]);
    return dupeInPlace(alloc, desc, dest);
}

/// Replaces every owned part of the value at `ptr`, which starts as a bit copy
/// of the source, with a new copy. On error, frees the copies it made, and the
/// value is left for the caller to discard.
fn dupeInPlace(alloc: Allocator, desc: *const Desc, ptr: *anyopaque) Error!void {
    switch (desc.*) {
        .plain, .bytes, .optional_bytes => try dupeLeaf(alloc, desc, ptr),
        .optional => |optional| {
            if (optional.payload(ptr)) |some| try dupeInPlace(alloc, optional.child, some);
        },
        .slice => |slice| {
            const items = slice.access(ptr, null);
            const bytes = items.len * slice.elem_size;
            if (bytes == 0) {
                // An empty copy points where `Allocator.dupe` would point it.
                _ = slice.access(ptr, @ptrFromInt(slice.alignment.backward(std.math.maxInt(usize))));
                return;
            }
            const block = alloc.rawAlloc(bytes, slice.alignment, @returnAddress()) orelse return error.OutOfMemory;
            @memcpy(block[0..bytes], items.ptr[0..bytes]);
            _ = slice.access(ptr, block);
            const child = slice.child orelse return;
            for (0..items.len) |index| {
                dupeLeaf(alloc, child, slice.at(block, index)) catch |err| {
                    for (0..index) |copied| freeAt(alloc, child, slice.at(block, copied));
                    freeBlock(alloc, slice.alignment, block[0..bytes]);
                    return err;
                };
            }
        },
        .object => |object| {
            const base: [*]u8 = @ptrCast(ptr);
            for (object.omits) |omit| @memcpy(base[omit.offset..][0..omit.default.len], omit.default);
            for (object.fields, 0..) |field, index| {
                dupeLeaf(alloc, field.desc, @ptrCast(base + field.offset)) catch |err| {
                    for (object.fields[0..index]) |copied| freeAt(alloc, copied.desc, @ptrCast(base + copied.offset));
                    return err;
                };
            }
        },
        .tagged => |tagged| {
            const active = tagged.active(ptr);
            if (tagged.variants[active.index]) |child| try dupeInPlace(alloc, child, active.payload);
        },
    }
}

fn freeAt(alloc: Allocator, desc: *const Desc, ptr: *anyopaque) void {
    switch (desc.*) {
        .plain, .bytes, .optional_bytes => freeLeaf(alloc, desc, ptr),
        .optional => |optional| {
            if (optional.payload(ptr)) |some| freeAt(alloc, optional.child, some);
        },
        .slice => |slice| {
            const items = slice.access(ptr, null);
            if (slice.child) |child| {
                for (0..items.len) |index| freeLeaf(alloc, child, slice.at(items.ptr, index));
            }
            const bytes = items.len * slice.elem_size;
            if (bytes != 0) freeBlock(alloc, slice.alignment, items.ptr[0..bytes]);
        },
        .object => |object| {
            const base: [*]u8 = @ptrCast(ptr);
            for (object.fields) |field| freeLeaf(alloc, field.desc, @ptrCast(base + field.offset));
        },
        .tagged => |tagged| {
            const active = tagged.active(ptr);
            if (tagged.variants[active.index]) |child| freeAt(alloc, child, active.payload);
        },
    }
}

/// Copies one owned value. Strings, most of what fx owns, are copied here
/// without a call; anything else goes through `dupeInPlace`.
inline fn dupeLeaf(alloc: Allocator, desc: *const Desc, ptr: *anyopaque) Error!void {
    switch (desc.*) {
        .plain => {},
        .bytes => {
            const value: *[]const u8 = @ptrCast(@alignCast(ptr));
            value.* = try alloc.dupe(u8, value.*);
        },
        .optional_bytes => {
            const value: *?[]const u8 = @ptrCast(@alignCast(ptr));
            if (value.*) |bytes| value.* = try alloc.dupe(u8, bytes);
        },
        else => try dupeInPlace(alloc, desc, ptr),
    }
}

/// Frees one owned value, the counterpart of `dupeLeaf`.
inline fn freeLeaf(alloc: Allocator, desc: *const Desc, ptr: *anyopaque) void {
    switch (desc.*) {
        .plain => {},
        .bytes => alloc.free(@as(*const []const u8, @ptrCast(@alignCast(ptr))).*),
        .optional_bytes => {
            if (@as(*const ?[]const u8, @ptrCast(@alignCast(ptr))).*) |bytes| alloc.free(bytes);
        },
        else => freeAt(alloc, desc, ptr),
    }
}

/// Frees a block as `Allocator.free` does.
fn freeBlock(alloc: Allocator, alignment: std.mem.Alignment, block: []u8) void {
    @memset(block, undefined);
    alloc.rawFree(block, alignment, @returnAddress());
}

const testing = std.testing;
const testing_allocator = @import("testing_allocator.zig");

const TestKind = enum { first, second };

const TestLeaf = struct {
    path: []const u8,
    stamp: u64 = 0,
    tags: []const []const u8 = &.{},
};

const TestChoice = union(enum) {
    none: void,
    code: i32,
    text: []u8,
    leaf: TestLeaf,
};

const TestBorrowed = struct { label: []const u8 };

const TestDoc = struct {
    name: []const u8,
    kind: TestKind = .first,
    fixed: [4]u8 = "abcd".*,
    note: ?[]u8 = null,
    leaves: []TestLeaf = &.{},
    maybe: ?TestLeaf = null,
    choice: TestChoice = .none,
    choices: []const TestChoice = &.{},
    lines: [][]u8 = &.{},
    count: usize = 0,
    /// A pointer the source borrows; copies leave it out.
    borrowed: ?*const TestBorrowed = null,

    pub const copy_omits = [_][]const u8{"borrowed"};
};

fn testDoc(note: []u8, lines: [][]u8, text: []u8, borrowed: *const TestBorrowed) TestDoc {
    const Static = struct {
        var leaves = [_]TestLeaf{
            .{ .path = "a.zig", .stamp = 1, .tags = &.{ "x", "" } },
            .{ .path = "", .stamp = 2 },
        };
    };
    return .{
        .name = "doc",
        .kind = .second,
        .note = note,
        .leaves = &Static.leaves,
        .maybe = .{ .path = "maybe.zig", .tags = &.{"m"} },
        .choice = .{ .text = text },
        .choices = &.{ .none, .{ .code = 7 }, .{ .leaf = .{ .path = "inner" } } },
        .lines = lines,
        .count = 3,
        .borrowed = borrowed,
    };
}

test "a copy equals its source, shares none of its slices, and leaves out copy_omits" {
    var note = "note".*;
    var line_a = "line a".*;
    var line_b = "".*;
    var lines = [_][]u8{ &line_a, &line_b };
    var text = "text".*;
    const borrowed: TestBorrowed = .{ .label = "borrowed" };
    const source = testDoc(&note, &lines, &text, &borrowed);

    const copy = try dupe(TestDoc, testing.allocator, source);
    defer free(TestDoc, testing.allocator, copy);

    try testing.expectEqual(null, copy.borrowed);
    var expected = source;
    expected.borrowed = null;
    try testing.expectEqualDeep(expected, copy);

    try testing.expect(copy.name.ptr != source.name.ptr);
    try testing.expect(copy.note.?.ptr != source.note.?.ptr);
    try testing.expect(copy.leaves.ptr != source.leaves.ptr);
    try testing.expect(copy.leaves[0].path.ptr != source.leaves[0].path.ptr);
    try testing.expect(copy.leaves[0].tags.ptr != source.leaves[0].tags.ptr);
    try testing.expect(copy.leaves[0].tags[0].ptr != source.leaves[0].tags[0].ptr);
    try testing.expect(copy.maybe.?.path.ptr != source.maybe.?.path.ptr);
    try testing.expect(copy.choice.text.ptr != source.choice.text.ptr);
    try testing.expect(copy.choices[2].leaf.path.ptr != source.choices[2].leaf.path.ptr);
    try testing.expect(copy.lines[0].ptr != source.lines[0].ptr);
}

test "values that own nothing are copied as they are" {
    try testing.expectEqual(@as(u32, 5), try dupe(u32, testing.allocator, 5));
    const plain: struct { a: u8, b: TestKind, c: ?[3]u8 } = .{ .a = 1, .b = .second, .c = "xyz".* };
    try testing.expectEqualDeep(plain, try dupe(@TypeOf(plain), testing.allocator, plain));
    free(@TypeOf(plain), testing.allocator, plain);
    try testing.expect(describe(TestKind).* == .plain);
    try testing.expect(describe(TestDoc).* == .object);
    try testing.expect(describe([]const u8).* == .bytes);
    try testing.expect(describe(?[]u8).* == .optional_bytes);
    try testing.expect(describe([][]u8).* == .slice);
}

fn dupeThenFree(alloc: Allocator, source: TestDoc) !void {
    const copy = try dupe(TestDoc, alloc, source);
    free(TestDoc, alloc, copy);
}

test "a copy that runs out of memory at any allocation leaves nothing behind" {
    var note = "note".*;
    var line_a = "line a".*;
    var line_b = "b".*;
    var lines = [_][]u8{ &line_a, &line_b };
    var text = "text".*;
    const borrowed: TestBorrowed = .{ .label = "borrowed" };
    try testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        dupeThenFree,
        .{testDoc(&note, &lines, &text, &borrowed)},
    );
}
