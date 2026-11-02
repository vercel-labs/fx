//! Drop-in replacements for `std.json.parseFromSlice`, `parseFromSliceLeaky`,
//! and `innerParse` with a `*std.json.Scanner` source.
//!
//! `std.json` generates a whole parser for every type it parses into, so each
//! struct, slice, and optional carries its own copy of the parsing logic.
//! Here each type is described once at compile time, as a table of fields,
//! offsets, defaults, and child types, and one shared function walks that
//! table at run time. Scalars, optionals, slices, and unions keep a small
//! per-type helper, so number parsing, enum names, and memory layout follow
//! `std.json` exactly.
//!
//! For the same input and options, every document `std.json` accepts parses
//! to the same value, and every document it rejects fails with the same
//! error. The tests below check that against `std.json` itself. Types with a
//! `jsonParse` method still parse through that method, and the few shapes
//! without byte-addressable fields (tuples, packed structs, sentinel arrays
//! and slices) parse through `std.json`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const json = std.json;
const Scanner = json.Scanner;
const Token = json.Token;

const Error = json.ParseError(Scanner);

/// Same contract as `std.json.parseFromSlice`.
pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    s: []const u8,
    options: json.ParseOptions,
) Error!json.Parsed(T) {
    var scanner = Scanner.initCompleteInput(allocator, s);
    defer scanner.deinit();

    var parsed: json.Parsed(T) = .{
        .arena = try allocator.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = .init(allocator);
    errdefer parsed.arena.deinit();

    parsed.value = try parseFromScannerLeaky(T, parsed.arena.allocator(), &scanner, options);
    return parsed;
}

/// Same contract as `std.json.parseFromSliceLeaky`.
pub fn parseFromSliceLeaky(
    comptime T: type,
    allocator: Allocator,
    s: []const u8,
    options: json.ParseOptions,
) Error!T {
    var scanner = Scanner.initCompleteInput(allocator, s);
    defer scanner.deinit();

    return parseFromScannerLeaky(T, allocator, &scanner, options);
}

fn parseFromScannerLeaky(
    comptime T: type,
    allocator: Allocator,
    scanner: *Scanner,
    options: json.ParseOptions,
) Error!T {
    std.debug.assert(scanner.is_end_of_input);
    var resolved = options;
    if (resolved.max_value_len == null) resolved.max_value_len = scanner.input.len;
    if (resolved.allocate == null) resolved.allocate = .alloc_if_needed;

    const value = try innerParse(T, allocator, scanner, resolved);

    std.debug.assert(.end_of_document == try scanner.next());
    return value;
}

/// Same contract as `std.json.innerParse` with a `*std.json.Scanner` source:
/// `options` must have no null fields, as in a `jsonParse` method.
pub fn innerParse(
    comptime T: type,
    allocator: Allocator,
    source: *Scanner,
    options: json.ParseOptions,
) Error!T {
    var value: T = undefined;
    try parseInto(allocator, source, &options, describe(T), @ptrCast(&value));
    return value;
}

/// Field-presence bits for one object; structs with more fields are rejected
/// at compile time.
const max_fields = 256;

/// A duplicate field under `.use_first` parses into this much stack before
/// falling back to the allocator, as `std.json` parses it into a temporary.
const scratch_bytes = 256;

const ParseScalar = *const fn (slice: []const u8, out: *anyopaque) Error!void;
const ParseCustom = *const fn (Allocator, *Scanner, json.ParseOptions, *anyopaque) Error!void;
const SetSlice = *const fn (out: *anyopaque, ptr: [*]u8, len: usize) void;

const Desc = union(enum) {
    boolean,
    /// Integers, floats, and enums: a number or string token.
    scalar: ParseScalar,
    optional: Optional,
    object: Object,
    slice: Sequence,
    array: Sequence,
    one: Sequence,
    tagged: Tagged,
    /// A type with its own `jsonParse` method.
    custom: ParseCustom,
};

const ParseChild = *const fn (Allocator, *Scanner, *const json.ParseOptions, *const Desc, *anyopaque) Error!void;

const Optional = struct {
    child: *const Desc,
    set_null: *const fn (out: *anyopaque) void,
    /// Parses the payload into a temporary and stores it as present.
    /// Marking a pointer-like optional present before its payload exists
    /// would leave its null state undefined.
    parse_some: ParseChild,
};

/// The tables are read-only data that holds pointers, so they cost binary
/// size next to the code they replace: a field takes 24 bytes, and a struct's
/// field names share one string.
const Object = struct {
    fields: []const Field,
    names: [*]const u8,
};

const Field = struct {
    desc: *const Desc,
    default: ?*const anyopaque,
    layout: FieldLayout,

    fn name(field: *const Field, names: [*]const u8) []const u8 {
        return names[field.layout.name_offset..][0..field.layout.name_len];
    }

    fn alignment(field: *const Field) Alignment {
        return @fromBackingInt(field.layout.align_log2);
    }
};

const FieldLayout = packed struct(u64) {
    offset: u20,
    size: u20,
    name_offset: u12,
    name_len: u8,
    align_log2: u4,
};

/// Whether a struct fits `FieldLayout`; one that does not parses through
/// `std.json`.
fn fitsFieldLayout(comptime T: type) bool {
    const info = @typeInfo(T).@"struct";
    var names_len: usize = 0;
    for (info.field_names, info.field_types) |name, FieldType| {
        if (@offsetOf(T, name) >= 1 << 20 or @sizeOf(FieldType) >= 1 << 20) return false;
        if (name.len >= 1 << 8 or names_len >= 1 << 12) return false;
        if (@backingInt(Alignment.of(FieldType)) >= 1 << 4) return false;
        names_len += name.len;
    }
    return info.field_names.len <= max_fields;
}

const Sequence = struct {
    child: *const Desc,
    /// Stores the slice or pointer; unused for arrays.
    set: SetSlice = undefined,
    elem_size: u32,
    shape: SequenceShape,

    fn alignment(seq: Sequence) Alignment {
        // `Alignment` is narrower than the field on 32-bit targets.
        return @fromBackingInt(@intCast(seq.shape.align_log2));
    }
};

const SequenceShape = packed struct(u32) {
    /// Element count, for arrays.
    len: u24 = 0,
    align_log2: u6,
    /// The child is `u8`, so a JSON string is also accepted.
    bytes: bool = false,
    /// A `[]u8` slice, whose string form is always copied.
    mutable: bool = false,
};

/// Whether a child type fits `Sequence`; one that does not parses through
/// `std.json`.
fn fitsSequence(comptime Child: type, comptime len: usize) bool {
    return @sizeOf(Child) < 1 << 32 and len < 1 << 24;
}

const Tagged = struct {
    variants: []const Variant,
    /// Sets the active field and returns its payload.
    init: *const fn (out: *anyopaque, index: usize) *anyopaque,
};

const Variant = struct {
    name: []const u8,
    /// Null for a `void` payload, which parses from `{}`.
    desc: ?*const Desc,
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
    switch (@typeInfo(T)) {
        .bool => return .boolean,
        .int => return .{ .scalar = Helpers(T).parseInt },
        .float => return .{ .scalar = Helpers(T).parseFloat },
        .optional => |info| return .{ .optional = .{
            .child = describe(info.child),
            .set_null = Helpers(T).setNull,
            .parse_some = Helpers(T).parseSome,
        } },
        .@"enum" => {
            if (std.meta.hasFn(T, "jsonParse")) return .{ .custom = Helpers(T).parseCustom };
            return .{ .scalar = Helpers(T).parseEnum };
        },
        .@"union" => |info| {
            if (std.meta.hasFn(T, "jsonParse")) return .{ .custom = Helpers(T).parseCustom };
            if (info.tag_type == null) @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");
            const variants = comptime variants: {
                var list: [info.field_names.len]Variant = undefined;
                for (info.field_names, info.field_types, 0..) |name, FieldType, i| {
                    list[i] = .{ .name = name, .desc = if (FieldType == void) null else describe(FieldType) };
                }
                const final = list;
                break :variants &final;
            };
            return .{ .tagged = .{ .variants = variants, .init = Helpers(T).initVariant } };
        },
        .@"struct" => |info| {
            // Tuples and packed structs, whose fields have no byte offsets,
            // parse through `std.json` itself.
            if (info.is_tuple) return .{ .custom = Helpers(T).parseWithStd };
            if (std.meta.hasFn(T, "jsonParse")) return .{ .custom = Helpers(T).parseCustom };
            if (info.layout == .@"packed" or !fitsFieldLayout(T)) return .{ .custom = Helpers(T).parseWithStd };
            const object = comptime object: {
                var list: [info.field_names.len]Field = undefined;
                var names: []const u8 = "";
                for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, i| {
                    if (attrs.@"comptime") @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ name);
                    list[i] = .{
                        .desc = describe(FieldType),
                        .default = attrs.default_value_ptr,
                        .layout = .{
                            .offset = @offsetOf(T, name),
                            .size = @sizeOf(FieldType),
                            .name_offset = names.len,
                            .name_len = name.len,
                            .align_log2 = @backingInt(Alignment.of(FieldType)),
                        },
                    };
                    names = names ++ name;
                }
                const final_fields = list;
                const final_names = names[0..names.len].*;
                break :object Object{ .fields = &final_fields, .names = &final_names };
            };
            return .{ .object = object };
        },
        .array => |info| {
            if (info.sentinel_ptr != null or !fitsSequence(info.child, info.len)) return .{ .custom = Helpers(T).parseWithStd };
            return .{ .array = .{
                .child = describe(info.child),
                .elem_size = @sizeOf(info.child),
                .shape = .{
                    .len = info.len,
                    .align_log2 = @backingInt(Alignment.of(info.child)),
                    .bytes = info.child == u8,
                },
            } };
        },
        .pointer => |info| {
            if (@sizeOf(info.child) == 0) @compileError("json_decode does not parse pointers to zero-size types: " ++ @typeName(T));
            if (!fitsSequence(info.child, 0)) return .{ .custom = Helpers(T).parseWithStd };
            switch (info.size) {
                .one => return .{ .one = .{
                    .child = describe(info.child),
                    .set = Helpers(T).setOne,
                    .elem_size = @sizeOf(info.child),
                    .shape = .{ .align_log2 = @backingInt(Alignment.of(info.child)) },
                } },
                .slice => {
                    if (info.sentinel_ptr != null) return .{ .custom = Helpers(T).parseWithStd };
                    return .{ .slice = .{
                        .child = describe(info.child),
                        .set = Helpers(T).setSlice,
                        .elem_size = @sizeOf(info.child),
                        .shape = .{
                            .align_log2 = @backingInt(Alignment.of(info.child)),
                            .bytes = info.child == u8,
                            .mutable = !info.attrs.@"const",
                        },
                    } };
                },
                else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
            }
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
}

/// The only code generated per type: each helper converts between the
/// type-erased pointer and `T`.
fn Helpers(comptime T: type) type {
    return struct {
        fn parseInt(slice: []const u8, out: *anyopaque) Error!void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = try sliceToInt(T, slice);
        }

        fn parseFloat(slice: []const u8, out: *anyopaque) Error!void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = try std.fmt.parseFloat(T, slice);
        }

        fn parseEnum(slice: []const u8, out: *anyopaque) Error!void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = try sliceToEnum(T, slice);
        }

        fn parseCustom(allocator: Allocator, source: *Scanner, options: json.ParseOptions, out: *anyopaque) Error!void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = try T.jsonParse(allocator, source, options);
        }

        fn parseWithStd(allocator: Allocator, source: *Scanner, options: json.ParseOptions, out: *anyopaque) Error!void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = try json.innerParse(T, allocator, source, options);
        }

        fn setNull(out: *anyopaque) void {
            const value: *T = @ptrCast(@alignCast(out));
            value.* = null;
        }

        fn parseSome(
            allocator: Allocator,
            source: *Scanner,
            options: *const json.ParseOptions,
            child: *const Desc,
            out: *anyopaque,
        ) Error!void {
            var payload: @typeInfo(T).optional.child = undefined;
            try parseInto(allocator, source, options, child, @ptrCast(&payload));
            const value: *T = @ptrCast(@alignCast(out));
            value.* = payload;
        }

        fn setSlice(out: *anyopaque, ptr: [*]u8, len: usize) void {
            const Elem = @typeInfo(T).pointer.child;
            const value: *T = @ptrCast(@alignCast(out));
            const items: [*]Elem = @ptrCast(@alignCast(ptr));
            value.* = items[0..len];
        }

        fn setOne(out: *anyopaque, ptr: [*]u8, len: usize) void {
            std.debug.assert(len == 1);
            const value: *T = @ptrCast(@alignCast(out));
            value.* = @ptrCast(@alignCast(ptr));
        }

        fn initVariant(out: *anyopaque, index: usize) *anyopaque {
            const info = @typeInfo(T).@"union";
            const value: *T = @ptrCast(@alignCast(out));
            switch (index) {
                inline 0...info.field_names.len - 1 => |i| {
                    const name = info.field_names[i];
                    if (info.field_types[i] == void) {
                        value.* = @unionInit(T, name, {});
                        return out;
                    }
                    value.* = @unionInit(T, name, undefined);
                    return @ptrCast(&@field(value.*, name));
                },
                else => unreachable,
            }
        }
    };
}

fn parseInto(
    allocator: Allocator,
    source: *Scanner,
    options: *const json.ParseOptions,
    desc: *const Desc,
    out: *anyopaque,
) Error!void {
    switch (desc.*) {
        .boolean => {
            const value: *bool = @ptrCast(out);
            value.* = switch (try source.next()) {
                .true => true,
                .false => false,
                else => return error.UnexpectedToken,
            };
        },
        .scalar => |parse| {
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            defer freeAllocated(allocator, token);
            const slice = switch (token) {
                inline .number, .allocated_number, .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            try parse(slice, out);
        },
        .optional => |optional| switch (try source.peekNextTokenType()) {
            .null => {
                _ = try source.next();
                optional.set_null(out);
            },
            else => try optional.parse_some(allocator, source, options, optional.child, out),
        },
        .object => |object| try parseObject(allocator, source, options, object, @ptrCast(out)),
        .slice => |seq| try parseSlice(allocator, source, options, seq, out),
        .array => |seq| try parseArray(allocator, source, options, seq, @ptrCast(out)),
        .one => |seq| {
            const item = allocator.rawAlloc(seq.elem_size, seq.alignment(), @returnAddress()) orelse return error.OutOfMemory;
            try parseInto(allocator, source, options, seq.child, item);
            seq.set(out, item, 1);
        },
        .tagged => |tagged| try parseTagged(allocator, source, options, tagged, out),
        .custom => |parse| try parse(allocator, source, options.*, out),
    }
}

fn parseObject(
    allocator: Allocator,
    source: *Scanner,
    options: *const json.ParseOptions,
    object: Object,
    base: [*]u8,
) Error!void {
    const fields = object.fields;
    if (.object_begin != try source.next()) return error.UnexpectedToken;

    var seen: std.bit_set.Static(max_fields) = .empty;
    while (true) {
        var name_token: ?Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const field_name = switch (name_token.?) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => break,
            else => return error.UnexpectedToken,
        };

        for (fields, 0..) |*field, i| {
            if (!std.mem.eql(u8, field.name(object.names), field_name)) continue;
            // Free the name before parsing the value, as `std.json` does.
            freeAllocated(allocator, name_token.?);
            name_token = null;
            if (seen.isSet(i)) switch (options.duplicate_field_behavior) {
                .use_first => {
                    // Parse and ignore the redundant value, keeping type checks.
                    var scratch: [scratch_bytes]u8 align(16) = undefined;
                    const size = field.layout.size;
                    const into: *anyopaque = if (size <= scratch.len and field.alignment().toByteUnits() <= 16)
                        &scratch
                    else
                        allocator.rawAlloc(size, field.alignment(), @returnAddress()) orelse return error.OutOfMemory;
                    try parseInto(allocator, source, options, field.desc, into);
                    break;
                },
                .@"error" => return error.DuplicateField,
                .use_last => {},
            };
            try parseInto(allocator, source, options, field.desc, base + field.layout.offset);
            seen.set(i);
            break;
        } else {
            freeAllocated(allocator, name_token.?);
            if (options.ignore_unknown_fields) {
                try source.skipValue();
            } else {
                return error.UnknownField;
            }
        }
    }

    for (fields, 0..) |*field, i| {
        if (seen.isSet(i)) continue;
        const default = field.default orelse return error.MissingField;
        const bytes: [*]const u8 = @ptrCast(default);
        const size = field.layout.size;
        @memcpy((base + field.layout.offset)[0..size], bytes[0..size]);
    }
}

fn parseSlice(
    allocator: Allocator,
    source: *Scanner,
    options: *const json.ParseOptions,
    seq: Sequence,
    out: *anyopaque,
) Error!void {
    switch (try source.peekNextTokenType()) {
        .array_begin => {
            _ = try source.next();
            var list: RawList = .{ .elem_size = seq.elem_size, .alignment = seq.alignment() };
            while (true) {
                switch (try source.peekNextTokenType()) {
                    .array_end => {
                        _ = try source.next();
                        break;
                    },
                    else => {},
                }
                const item = try list.addOne(allocator);
                try parseInto(allocator, source, options, seq.child, item);
            }
            const items = try list.toOwnedSlice(allocator);
            seq.set(out, items.ptr, list.len);
        },
        .string => {
            if (!seq.shape.bytes) return error.UnexpectedToken;
            // A mutable slice always gets its own copy.
            const when: json.AllocWhen = if (seq.shape.mutable) .alloc_always else options.allocate.?;
            const slice = switch (try source.nextAllocMax(allocator, when, options.max_value_len.?)) {
                inline .string, .allocated_string => |slice| slice,
                else => unreachable,
            };
            seq.set(out, @constCast(slice.ptr), slice.len);
        },
        else => return error.UnexpectedToken,
    }
}

fn parseArray(
    allocator: Allocator,
    source: *Scanner,
    options: *const json.ParseOptions,
    seq: Sequence,
    base: [*]u8,
) Error!void {
    switch (try source.peekNextTokenType()) {
        .array_begin => {
            std.debug.assert(.array_begin == try source.next());
            for (0..seq.shape.len) |i| {
                try parseInto(allocator, source, options, seq.child, base + i * seq.elem_size);
            }
            if (.array_end != try source.next()) return error.UnexpectedToken;
        },
        .string => {
            if (!seq.shape.bytes) return error.UnexpectedToken;
            // Fixed-length string.
            const len = seq.shape.len;
            var i: usize = 0;
            while (true) {
                switch (try source.next()) {
                    .string => |slice| {
                        if (i + slice.len != len) return error.LengthMismatch;
                        @memcpy(base[i..][0..slice.len], slice);
                        break;
                    },
                    .partial_string => |slice| {
                        if (i + slice.len > len) return error.LengthMismatch;
                        @memcpy(base[i..][0..slice.len], slice);
                        i += slice.len;
                    },
                    inline .partial_string_escaped_1,
                    .partial_string_escaped_2,
                    .partial_string_escaped_3,
                    .partial_string_escaped_4,
                    => |arr| {
                        if (i + arr.len > len) return error.LengthMismatch;
                        @memcpy(base[i..][0..arr.len], arr[0..]);
                        i += arr.len;
                    },
                    else => unreachable,
                }
            }
        },
        else => return error.UnexpectedToken,
    }
}

fn parseTagged(
    allocator: Allocator,
    source: *Scanner,
    options: *const json.ParseOptions,
    tagged: Tagged,
    out: *anyopaque,
) Error!void {
    if (.object_begin != try source.next()) return error.UnexpectedToken;

    var name_token: ?Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    const field_name = switch (name_token.?) {
        inline .string, .allocated_string => |slice| slice,
        else => return error.UnexpectedToken,
    };

    for (tagged.variants, 0..) |variant, i| {
        if (!std.mem.eql(u8, variant.name, field_name)) continue;
        freeAllocated(allocator, name_token.?);
        name_token = null;
        const payload = tagged.init(out, i);
        if (variant.desc) |desc| {
            try parseInto(allocator, source, options, desc, payload);
        } else {
            // A `void` payload parses from `{}`.
            if (.object_begin != try source.next()) return error.UnexpectedToken;
            if (.object_end != try source.next()) return error.UnexpectedToken;
        }
        break;
    } else {
        return error.UnknownField;
    }

    if (.object_end != try source.next()) return error.UnexpectedToken;
}

/// A growable list of `elem_size`-byte items with a run-time alignment.
const RawList = struct {
    elem_size: usize,
    alignment: Alignment,
    items: [*]u8 = undefined,
    len: usize = 0,
    capacity: usize = 0,

    fn addOne(list: *RawList, allocator: Allocator) Allocator.Error!*anyopaque {
        if (list.len == list.capacity) {
            const capacity = list.capacity +| list.capacity / 2 +| 8;
            const bytes = std.math.mul(usize, capacity, list.elem_size) catch return error.OutOfMemory;
            const grown = allocator.rawAlloc(bytes, list.alignment, @returnAddress()) orelse return error.OutOfMemory;
            if (list.capacity != 0) {
                @memcpy(grown[0 .. list.len * list.elem_size], list.items[0 .. list.len * list.elem_size]);
                allocator.rawFree(list.items[0 .. list.capacity * list.elem_size], list.alignment, @returnAddress());
            }
            list.items = grown;
            list.capacity = capacity;
        }
        const item = list.items + list.len * list.elem_size;
        list.len += 1;
        return item;
    }

    /// Returns exactly `len` items; an empty list returns an empty slice.
    fn toOwnedSlice(list: *RawList, allocator: Allocator) Allocator.Error![]u8 {
        const len = list.len * list.elem_size;
        if (list.capacity == 0) {
            const empty: [*]u8 = @ptrFromInt(list.alignment.toByteUnits());
            return empty[0..0];
        }
        const old = list.items[0 .. list.capacity * list.elem_size];
        if (allocator.rawRemap(old, list.alignment, len, @returnAddress())) |items| {
            return items[0..len];
        }
        const items = allocator.rawAlloc(len, list.alignment, @returnAddress()) orelse return error.OutOfMemory;
        @memcpy(items[0..len], list.items[0..len]);
        allocator.rawFree(old, list.alignment, @returnAddress());
        return items[0..len];
    }
};

fn freeAllocated(allocator: Allocator, token: Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| allocator.free(slice),
        else => {},
    }
}

// The two converters below repeat `std.json`'s private helpers so numbers and
// enum tags parse exactly as they do there.

fn sliceToInt(comptime T: type, slice: []const u8) !T {
    if (json.isNumberFormattedLikeAnInteger(slice))
        return std.fmt.parseInt(T, slice, 10);
    // Try to coerce a float to an integer.
    const float = try std.fmt.parseFloat(f128, slice);
    if (@round(float) != float) return error.InvalidNumber;
    if (float > @as(f128, @floatFromInt(std.math.maxInt(T))) or float < @as(f128, @floatFromInt(std.math.minInt(T)))) return error.Overflow;
    return @as(T, @intCast(@as(i128, @intFromFloat(float))));
}

fn sliceToEnum(comptime T: type, slice: []const u8) !T {
    // Check for a named value.
    if (std.meta.stringToEnum(T, slice)) |value| return value;
    // Check for a numeric value.
    if (!json.isNumberFormattedLikeAnInteger(slice)) return error.InvalidEnumTag;
    const n = std.fmt.parseInt(@typeInfo(T).@"enum".tag_type, slice, 10) catch return error.InvalidEnumTag;
    return std.enums.fromInt(T, n) orelse return error.InvalidEnumTag;
}

// Tests: every case runs through both `std.json` and this module, which must
// agree on the value or on the error.

const testing = std.testing;

const TestColor = enum(u8) { red, green, blue = 7 };

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
};

/// Parses through its own method, which calls back into `std.json`.
const TestCustom = struct {
    doubled: i64,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !TestCustom {
        const raw = try json.innerParse(i64, allocator, source, options);
        return .{ .doubled = raw * 2 };
    }
};

const TestDoc = struct {
    id: u64,
    name: []const u8,
    flag: bool = false,
    ratio: f32 = 1.5,
    small: i8 = -1,
    wide: i128 = 0,
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
    note: ?[]const u8 = null,
    inner_note: ?TestNoted = null,
    flags: TestFlags = .{},
    point: struct { i32, ?bool } = .{ 0, null },
    zstr: [:0]const u8 = "",
};

const TestFlags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    rest: u6 = 0,
};

/// An optional slice, whose null state lives in its pointer, at a nonzero
/// offset inside an optional struct.
const TestNoted = struct {
    first: bool = false,
    second: bool = false,
    text: ?[]const u8 = null,
};

const test_documents = [_][]const u8{
    // Valid documents.
    \\{"id":1,"name":"a"}
    ,
    \\{"id":18446744073709551615,"name":"max","flag":true,"ratio":0.25,"small":-128,"wide":-170141183460469231731687303715884105728}
    ,
    \\{"name":"order","id":2,"items":[{"a":1},{"a":-2,"b":3.5,"color":"green"},{"a":3,"color":7}]}
    ,
    \\{"id":3,"name":"tags","tags":["x","","y\n\u00e9\ud83d\ude00"],"nested":[[],[1,2],[-3]]}
    ,
    \\{"id":4,"name":"fixed","fixed":[9,8,7],"code":"wxyz","pair":["blue",0]}
    ,
    \\{"id":5,"name":"escaped code","code":"\u00e9\u00e9"}
    ,
    \\{"id":6,"name":"opt","maybe":{"a":5},"boxed":{"a":6,"b":null},"choice":{"inner":{"a":7}}}
    ,
    \\{"id":7,"name":"choices","choice":{"none":{}}}
    ,
    \\{"id":8,"name":"choice num","choice":{"num":"65535"}}
    ,
    \\{"id":9,"name":"choice text","choice":{"text":"hi"},"bytes":"mutable\tcopy"}
    ,
    \\{"id":10,"name":"bytes as array","bytes":[104,105],"custom":21}
    ,
    \\{"id":"11","name":"numbers as strings","small":"12","ratio":"2.5"}
    ,
    \\{"id":1.2e1,"name":"float ints","small":-1.0e2,"wide":3.0}
    ,
    \\{"id":13,"name":"maybe null","maybe":null,"boxed":null,"custom":null}
    ,
    \\  {"id":14,"name":"whitespace"}  
    ,
    \\{"id":15,"name":"enum numbers","items":[{"a":0,"color":"7"},{"a":0,"color":1}]}
    ,
    \\{"id":16,"name":"notes","note":"n","inner_note":{"first":true,"text":"t"}}
    ,
    \\{"id":17,"name":"std shapes","flags":{"write":true,"rest":3},"point":[-4,true],"zstr":"z"}
    ,
    // Invalid documents.
    "",
    "null",
    "[]",
    "{}",
    \\{"name":"missing id"}
    ,
    \\{"id":1}
    ,
    \\{"id":1,"name":"a","extra":{"deep":[1,{"x":null}]}}
    ,
    \\{"id":1,"name":"a","id":2}
    ,
    \\{"id":1,"name":"a","maybe":{"a":1},"maybe":{"a":2}}
    ,
    \\{"id":1,"name":"a","maybe":{"a":1},"maybe":{"a":"bad"}}
    ,
    \\{"id":-1,"name":"negative unsigned"}
    ,
    \\{"id":18446744073709551616,"name":"overflow"}
    ,
    \\{"id":1,"name":"a","small":128}
    ,
    \\{"id":1,"name":"a","small":-129.0}
    ,
    \\{"id":1.5,"name":"fraction"}
    ,
    \\{"id":1e400,"name":"huge"}
    ,
    \\{"id":"x","name":"word"}
    ,
    \\{"id":"1_000","name":"underscore"}
    ,
    \\{"id":"+5","name":"plus"}
    ,
    \\{"id":"0x10","name":"hex"}
    ,
    \\{"id":1,"name":"a","ratio":"nan?"}
    ,
    \\{"id":1,"name":"a","ratio":true}
    ,
    \\{"id":1,"name":"a","flag":1}
    ,
    \\{"id":1,"name":"a","flag":"true"}
    ,
    \\{"id":1,"name":7}
    ,
    \\{"id":1,"name":null}
    ,
    \\{"id":1,"name":"a","items":[{"a":1,"color":"purple"}]}
    ,
    \\{"id":1,"name":"a","items":[{"a":1,"color":3}]}
    ,
    \\{"id":1,"name":"a","items":[{"a":1,"color":"07"}]}
    ,
    \\{"id":1,"name":"a","items":{"a":1}}
    ,
    \\{"id":1,"name":"a","fixed":[1,2]}
    ,
    \\{"id":1,"name":"a","fixed":[1,2,3,4]}
    ,
    \\{"id":1,"name":"a","fixed":"abc"}
    ,
    \\{"id":1,"name":"a","code":"abc"}
    ,
    \\{"id":1,"name":"a","code":"abcde"}
    ,
    \\{"id":1,"name":"a","code":"\u00e9\u00e9\u00e9"}
    ,
    \\{"id":1,"name":"a","code":[1,2,3,4]}
    ,
    \\{"id":1,"name":"a","tags":"x"}
    ,
    \\{"id":1,"name":"a","nested":[[1],["x"]]}
    ,
    \\{"id":1,"name":"a","choice":{}}
    ,
    \\{"id":1,"name":"a","choice":{"none":null}}
    ,
    \\{"id":1,"name":"a","choice":{"none":{"x":1}}}
    ,
    \\{"id":1,"name":"a","choice":{"num":1,"text":"x"}}
    ,
    \\{"id":1,"name":"a","choice":{"other":1}}
    ,
    \\{"id":1,"name":"a","choice":"none"}
    ,
    \\{"id":1,"name":"a","custom":"x"}
    ,
    \\{"id":1,"name":"a","pair":["red"]}
    ,
    \\{"id":1,"name":"a"} trailing
    ,
    \\{"id":1,"name":"a"}{}
    ,
    \\{"id":1,"name":"a",}
    ,
    \\{"id":1,"name":"a"
    ,
    \\{"id":1 "name":"a"}
    ,
    \\{"id":01,"name":"a"}
    ,
    \\{id:1}
    ,
    \\{"id":1,"name":"\x"}
    ,
    \\{"id":1,"name":"\ud800"}
};

const test_options = [_]json.ParseOptions{
    .{},
    .{ .ignore_unknown_fields = true },
    .{ .duplicate_field_behavior = .use_first },
    .{ .duplicate_field_behavior = .use_last, .ignore_unknown_fields = true },
    .{ .allocate = .alloc_always },
    .{ .max_value_len = 3 },
};

fn expectSameParse(comptime T: type, input: []const u8, options: json.ParseOptions) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const expected = json.parseFromSliceLeaky(T, arena, input, options);
    const actual = parseFromSliceLeaky(T, arena, input, options);
    // On a mismatch, `std.testing` reports both outcomes.
    if (expected) |expected_value| {
        const actual_value = actual catch |err| {
            return testing.expectEqual(@as(anyerror!void, {}), @as(anyerror!void, err));
        };
        try testing.expectEqualDeep(expected_value, actual_value);
    } else |expected_err| {
        if (actual) |_| {
            return testing.expectEqual(@as(anyerror!void, expected_err), @as(anyerror!void, {}));
        } else |actual_err| {
            try testing.expectEqual(@as(anyerror, expected_err), @as(anyerror, actual_err));
        }
    }
}

test "every document parses to the same value or error as std.json" {
    for (test_options) |options| {
        for (test_documents) |input| try expectSameParse(TestDoc, input, options);
    }
}

test "scalars, slices, and unions at the top level match std.json" {
    const inputs = [_][]const u8{ "5", "-5", "5.0", "\"5\"", "true", "null", "[1,2]", "\"text\"", "{\"num\":3}", "[]", "\"red\"", "2" };
    for (inputs) |input| {
        try expectSameParse(u8, input, .{});
        try expectSameParse(?i64, input, .{});
        try expectSameParse(f64, input, .{});
        try expectSameParse(bool, input, .{});
        try expectSameParse([]const u8, input, .{});
        try expectSameParse([]const ?u16, input, .{});
        try expectSameParse(TestChoice, input, .{});
        try expectSameParse(TestColor, input, .{});
        try expectSameParse([2]i8, input, .{});
        try expectSameParse(*const u32, input, .{});
    }
}

test "mutated documents parse to the same value or error as std.json" {
    var prng: std.Random.DefaultPrng = .init(0x6a736f6e);
    const random = prng.random();
    const alphabet = "{}[]\",:-.0123456789eEabnrtlu\\ ";
    var buf: [512]u8 = undefined;
    for (0..4000) |_| {
        const seed = test_documents[random.uintLessThan(usize, 18)];
        var len = @min(seed.len, buf.len - 8);
        @memcpy(buf[0..len], seed[0..len]);
        for (0..random.uintLessThan(usize, 3) + 1) |_| {
            const at = random.uintLessThan(usize, len + 1);
            switch (random.uintLessThan(u8, 3)) {
                0 => if (at < len) {
                    @memmove(buf[at .. len - 1], buf[at + 1 .. len]);
                    len -= 1;
                },
                1 => {
                    @memmove(buf[at + 1 .. len + 1], buf[at..len]);
                    buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                    len += 1;
                },
                else => if (at < len) {
                    buf[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                },
            }
        }
        const options = test_options[random.uintLessThan(usize, test_options.len)];
        try expectSameParse(TestDoc, buf[0..len], options);
    }
}

test "parseFromSlice frees everything on success and on failure" {
    const ok = try parseFromSlice(TestDoc, testing.allocator, test_documents[2], .{});
    defer ok.deinit();
    try testing.expectEqual(@as(usize, 3), ok.value.items.len);
    try testing.expectEqual(TestColor.green, ok.value.items[1].color);

    try testing.expectError(error.MissingField, parseFromSlice(TestDoc, testing.allocator, "{\"id\":1}", .{}));
    try testing.expectError(error.UnexpectedToken, parseFromSlice(TestDoc, testing.allocator, "{\"id\":1,\"name\":\"a\",\"items\":[{\"a\":1},7]}", .{}));
}

test "table entries stay small" {
    // Each field and type costs read-only data in the binary.
    try testing.expectEqual(@as(usize, 24), @sizeOf(Field));
    try testing.expect(@sizeOf(Desc) <= 32);
}
