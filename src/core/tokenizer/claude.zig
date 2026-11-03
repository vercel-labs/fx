const std = @import("std");
const normalize = @import("normalize.zig");
const unicode = @import("unicode.zig");
const utf = @import("utf.zig");

const Allocator = std.mem.Allocator;
const heap = std.heap.c_allocator;
const BOW: u8 = 0x01;
const EOW: u8 = 0x02;
const SHIFT: u8 = 0x04;
const CAPS: u8 = 0x05;
const NON_SEPARATOR: u21 = 0x0e3a;

pub const Family = enum { v3, v47, v5, v5_sonnet };

const Class = enum { wordy, hard, digit, punct, space, stray_mark };
const Run = struct { cls: Class, start: usize, end: usize };
const CaseForm = enum { literal, shift, shift_keep_dotted, caps };
const FrameParams = struct {
    message_overhead: u32,
    fold_quotes: bool,
    allcaps_min: ?usize,
    frame_bow: bool,
    ladder: bool,
};

const Edge = struct { parent: u32, byte: u8, child: u32 };
const State = struct { edge_start: u32, fail: u32, dict: u32, edge_count: u16, out_len: u16 };

const PieceMatcher = struct {
    states: []State,
    edge_bytes: []u8,
    edge_targets: []u32,
    root_goto: [256]u32,

    fn goto(self: *const PieceMatcher, state: u32, byte: u8) ?u32 {
        const st = self.states[state];
        const start = st.edge_start;
        const end = start + st.edge_count;
        var i = start;
        while (i < end) : (i += 1) {
            if (self.edge_bytes[i] == byte) return self.edge_targets[i];
            if (self.edge_bytes[i] > byte) break;
        }
        return null;
    }

    fn advance(self: *const PieceMatcher, state: u32, byte: u8) u32 {
        var at = state;
        while (true) {
            if (at == 0) return self.root_goto[byte];
            if (self.goto(at, byte)) |next| return next;
            at = self.states[at].fail;
        }
    }

    fn minTile(self: *const PieceMatcher, text: []const u8, core: *const VocabCore) u32 {
        if (text.len == 0) return 0;
        const best = heap.alloc(u32, text.len + 1) catch unreachable;
        defer heap.free(best);
        @memset(best, 0);
        var state: u32 = 0;
        var end: usize = 1;
        while (end <= text.len) : (end += 1) {
            state = self.advance(state, text[end - 1]);
            if (end != text.len and isContinuation(text[end])) continue;
            var start = end - 1;
            while (start > 0 and isContinuation(text[start])) start -= 1;
            const single = end - start;
            var cost: u32 = std.math.maxInt(u32);
            var spelled = false;
            var at = state;
            while (true) {
                const len = self.states[at].out_len;
                at = self.states[at].dict;
                if (len != 0) {
                    if (len <= end) cost = @min(cost, best[end - len] + 1);
                    spelled = spelled or len == single;
                }
                if (at == 0) break;
            }
            if (!spelled) cost = @min(cost, best[start] + core.uncoveredCost(text[start..end]));
            best[end] = cost;
        }
        return best[text.len];
    }
};

const Builder = struct {
    terminal: std.ArrayList(bool) = .empty,
    depth: std.ArrayList(u32) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    path: std.ArrayList(u32) = .empty,

    fn init(piece_count: usize) Builder {
        var b: Builder = .{};
        b.terminal.append(heap, false) catch unreachable;
        b.depth.append(heap, 0) catch unreachable;
        b.path.append(heap, 0) catch unreachable;
        b.edges.ensureTotalCapacity(heap, piece_count * 2) catch unreachable;
        return b;
    }

    fn pushPiece(self: *Builder, shared: usize, suffix: []const u8) void {
        self.path.shrinkRetainingCapacity(shared + 1);
        var at = self.path.items[self.path.items.len - 1];
        for (suffix) |byte| {
            const child: u32 = @intCast(self.terminal.items.len);
            self.terminal.append(heap, false) catch unreachable;
            self.depth.append(heap, self.depth.items[at] + 1) catch unreachable;
            self.edges.append(heap, .{ .parent = at, .byte = byte, .child = child }) catch unreachable;
            self.path.append(heap, child) catch unreachable;
            at = child;
        }
        self.terminal.items[at] = true;
    }

    fn finish(self: *Builder) PieceMatcher {
        const node_count = self.terminal.items.len;
        const offsets = heap.alloc(u32, node_count + 1) catch unreachable;
        defer heap.free(offsets);
        @memset(offsets, 0);
        for (self.edges.items) |edge| offsets[edge.parent + 1] += 1;
        var i: usize = 0;
        while (i < node_count) : (i += 1) offsets[i + 1] += offsets[i];
        const edge_bytes = heap.alloc(u8, self.edges.items.len) catch unreachable;
        const edge_targets = heap.alloc(u32, self.edges.items.len) catch unreachable;
        const cursor = heap.alloc(u32, node_count) catch unreachable;
        defer heap.free(cursor);
        @memcpy(cursor, offsets[0..node_count]);
        for (self.edges.items) |edge| {
            const at = cursor[edge.parent];
            cursor[edge.parent] += 1;
            edge_bytes[at] = edge.byte;
            edge_targets[at] = edge.child;
        }
        const states = heap.alloc(State, node_count) catch unreachable;
        for (0..node_count) |index| {
            states[index] = .{ .edge_start = offsets[index], .edge_count = @intCast(offsets[index + 1] - offsets[index]), .fail = 0, .dict = 0, .out_len = 0 };
            sortEdges(edge_bytes, edge_targets, offsets[index], offsets[index + 1]);
        }
        var result = PieceMatcher{ .states = states, .edge_bytes = edge_bytes, .edge_targets = edge_targets, .root_goto = @splat(0) };
        const queue = std.ArrayList(u32).empty;
        var bfs: std.ArrayList(u32) = queue;
        defer bfs.deinit(heap);
        const root_end = offsets[1];
        for (offsets[0]..root_end) |edge_index| {
            const child = edge_targets[edge_index];
            result.root_goto[edge_bytes[edge_index]] = child;
            bfs.append(heap, child) catch unreachable;
        }
        var head: usize = 0;
        while (head < bfs.items.len) : (head += 1) {
            const node = bfs.items[head];
            const fail = result.states[node].fail;
            result.states[node].out_len = if (self.terminal.items[node]) @intCast(self.depth.items[node]) else 0;
            result.states[node].dict = if (result.states[fail].out_len != 0) fail else result.states[fail].dict;
            const start = result.states[node].edge_start;
            const end = start + result.states[node].edge_count;
            for (start..end) |edge_index| {
                const child = edge_targets[edge_index];
                result.states[child].fail = result.advance(fail, edge_bytes[edge_index]);
                bfs.append(heap, child) catch unreachable;
            }
        }
        self.terminal.deinit(heap);
        self.depth.deinit(heap);
        self.edges.deinit(heap);
        self.path.deinit(heap);
        return result;
    }
};

fn sortEdges(bytes: []u8, targets: []u32, start: u32, end: u32) void {
    var i = start + 1;
    while (i < end) : (i += 1) {
        const byte = bytes[i];
        const target = targets[i];
        var j = i;
        while (j > start and bytes[j - 1] > byte) : (j -= 1) {
            bytes[j] = bytes[j - 1];
            targets[j] = targets[j - 1];
        }
        bytes[j] = byte;
        targets[j] = target;
    }
}

fn orderU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}
fn orderU21(a: u21, b: u21) std.math.Order {
    return std.math.order(a, b);
}

const ByteFloor = struct {
    tokens: []u64,
    max_len: usize,

    fn costBytes(self: *const ByteFloor, bytes: []const u8) u32 {
        var best: [5]u32 = @splat(std.math.maxInt(u32));
        best[0] = 0;
        for (1..bytes.len + 1) |i| {
            const begin = if (i > self.max_len) i - self.max_len else 0;
            for (begin..i) |j| {
                if (best[j] == std.math.maxInt(u32)) continue;
                const valid = i - j == 1 or std.sort.binarySearch(u64, self.tokens, packBytes(bytes[j..i]), orderU64) != null;
                if (valid) best[i] = @min(best[i], best[j] + 1);
            }
        }
        return best[bytes.len];
    }

    fn costChar(self: *const ByteFloor, cp: u21) u32 {
        var bytes: [4]u8 = undefined;
        const n = utf.encode(cp, &bytes);
        return self.costBytes(bytes[0..n]);
    }
};

const VocabCore = struct {
    message_overhead: u32,
    fold_quotes: bool,
    allcaps_min: ?usize,
    vocab: PieceMatcher,
    unit_pieces: []u21,
    newline_ladder: []u32,
    floor: ByteFloor,

    fn parse(blob: []const u8) VocabCore {
        var cursor = Cursor{ .data = blob, .pos = 0 };
        if (!std.mem.eql(u8, cursor.take(4), "CTOK") or cursor.byte() != 2) unreachable;
        const fold_quotes = cursor.byte() & 1 != 0;
        const message_overhead = cursor.byte();
        const allcaps_min = switch (cursor.byte()) {
            0 => null,
            else => |n| @as(?usize, n),
        };
        const byte_token_count = cursor.word16();
        const piece_count = cursor.word32();
        var floor_tokens: std.ArrayList(u64) = .empty;
        floor_tokens.ensureTotalCapacity(heap, byte_token_count + 512) catch unreachable;
        var max_len: usize = 1;
        for (0..byte_token_count) |_| {
            const len = cursor.byte();
            if (len == 0 or len > 4) unreachable;
            max_len = @max(max_len, len);
            floor_tokens.append(heap, packBytes(cursor.take(len))) catch unreachable;
        }
        var builder = Builder.init(piece_count);
        var unit_pieces: std.ArrayList(u21) = .empty;
        var newline_ladder: std.ArrayList(u32) = .empty;
        var scratch: std.ArrayList(u8) = .empty;
        scratch.ensureTotalCapacity(heap, 64) catch unreachable;
        for (0..piece_count) |_| {
            const shared = cursor.varint();
            const suffix_len = cursor.varint();
            if (shared > scratch.items.len) unreachable;
            scratch.shrinkRetainingCapacity(shared);
            scratch.appendSlice(heap, cursor.take(suffix_len)) catch unreachable;
            builder.pushPiece(shared, scratch.items[shared..]);
            if (allBytes(scratch.items, '\n')) newline_ladder.append(heap, @intCast(scratch.items.len)) catch unreachable;
            if (scratch.items.len == 1 and isMarker(scratch.items[0])) continue;
            const decoded = utf.decode(scratch.items, 0);
            var encoded: [4]u8 = undefined;
            const encoded_len = utf.encode(decoded.codepoint, &encoded);
            if (scratch.items.len == encoded_len) {
                unit_pieces.append(heap, decoded.codepoint) catch unreachable;
                max_len = @max(max_len, scratch.items.len);
                floor_tokens.append(heap, packBytes(scratch.items)) catch unreachable;
            }
        }
        if (cursor.pos != blob.len) unreachable;
        std.sort.heap(u64, floor_tokens.items, {}, std.sort.asc(u64));
        std.sort.heap(u21, unit_pieces.items, {}, std.sort.asc(u21));
        std.sort.heap(u32, newline_ladder.items, {}, std.sort.asc(u32));
        return .{ .message_overhead = message_overhead, .fold_quotes = fold_quotes, .allcaps_min = allcaps_min, .vocab = builder.finish(), .unit_pieces = unit_pieces.toOwnedSlice(heap) catch unreachable, .newline_ladder = newline_ladder.toOwnedSlice(heap) catch unreachable, .floor = .{ .tokens = floor_tokens.toOwnedSlice(heap) catch unreachable, .max_len = max_len } };
    }

    fn uncoveredCost(self: *const VocabCore, bytes: []const u8) u32 {
        if (bytes.len == 1 and isMarker(bytes[0])) return 1;
        const cp = utf.decode(bytes, 0).codepoint;
        if (std.sort.binarySearch(u21, self.unit_pieces, cp, orderU21) != null) return 1;
        return self.floor.costChar(cp);
    }

    fn tileCost(self: *const VocabCore, stream: []const u8) u32 {
        return self.vocab.minTile(stream, self);
    }

    fn ladderTailCost(self: *const VocabCore, n_tail: usize, appended: usize) u32 {
        if (n_tail == 0) return 0;
        const m = n_tail + appended;
        const best = heap.alloc(u32, m + 1) catch unreachable;
        defer heap.free(best);
        best[0] = 0;
        for (1..m + 1) |end| {
            var cost = best[end - 1] + 1;
            for (self.newline_ladder) |length| {
                const len: usize = length;
                if (len > end) break;
                cost = @min(cost, best[end - len] + 1);
            }
            best[end] = cost;
        }
        return best[m] - 1;
    }
};

const Cursor = struct {
    data: []const u8,
    pos: usize,
    fn take(self: *Cursor, len: usize) []const u8 {
        const result = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return result;
    }
    fn byte(self: *Cursor) u8 {
        return self.take(1)[0];
    }
    fn word16(self: *Cursor) u16 {
        return std.mem.readInt(u16, self.take(2)[0..2], .little);
    }
    fn word32(self: *Cursor) u32 {
        return std.mem.readInt(u32, self.take(4)[0..4], .little);
    }
    fn varint(self: *Cursor) usize {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = self.byte();
            const part: u64 = b & 0x7f;
            if (shift == 63 and part > 1) unreachable;
            value |= part << shift;
            if (b & 0x80 == 0) return @intCast(value);
            if (shift == 63) unreachable;
            shift += 7;
        }
    }
};

fn decompress(compressed: []const u8) []u8 {
    var out: std.Io.Writer.Allocating = .init(heap);
    var input: std.Io.Reader = .fixed(compressed);
    var stream: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    _ = stream.reader.streamRemaining(&out.writer) catch unreachable;
    return out.toOwnedSlice() catch unreachable;
}
fn packBytes(bytes: []const u8) u64 {
    var result: u64 = 1;
    for (bytes) |byte| result = (result << 8) | byte;
    return result;
}
fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}
fn isMarker(byte: u8) bool {
    return byte >= 1 and byte <= 5;
}
fn allBytes(bytes: []const u8, wanted: u8) bool {
    for (bytes) |byte| if (byte != wanted) return false;
    return true;
}

const CoreSlot = struct { lock: std.atomic.Mutex = .unlocked, value: ?*VocabCore = null };
var v3_slot = CoreSlot{};
var v47_slot = CoreSlot{};
const v3_data = @embedFile("data/ctok_v3.bin.zst");
const v47_data = @embedFile("data/ctok_v4_7.bin.zst");
fn getCore(slot: *CoreSlot, data: []const u8) *const VocabCore {
    if (slot.value) |value| return value;
    while (!slot.lock.tryLock()) std.atomic.spinLoopHint();
    defer slot.lock.unlock();
    if (slot.value == null) {
        const value = heap.create(VocabCore) catch unreachable;
        value.* = VocabCore.parse(decompress(data));
        slot.value = value;
    }
    return slot.value.?;
}

fn coreFor(family: Family) *const VocabCore {
    return switch (family) {
        .v3 => getCore(&v3_slot, v3_data),
        .v47, .v5, .v5_sonnet => getCore(&v47_slot, v47_data),
    };
}
fn params(core: *const VocabCore, family: Family) FrameParams {
    var result = FrameParams{ .message_overhead = core.message_overhead, .fold_quotes = core.fold_quotes, .allcaps_min = core.allcaps_min, .frame_bow = true, .ladder = true };
    if (family == .v5 or family == .v5_sonnet) {
        result.message_overhead = 6;
        result.frame_bow = false;
        result.ladder = family == .v5_sonnet;
    }
    return result;
}
fn appendedNewlines(family: Family) usize {
    return if (family == .v5_sonnet) 0 else 2;
}

pub fn count(text: []const u8, family: Family) usize {
    const core = coreFor(family);
    const p = params(core, family);
    const head_space = text.len != 0 and utf.decode(text, 0).codepoint == ' ';
    const normalized = normalizeClaude(text, p.fold_quotes);
    defer heap.free(normalized);
    if (p.ladder) {
        var n_tail: usize = 0;
        var i = normalized.len;
        while (i > 0 and normalized[i - 1] == '\n') : (i -= 1) n_tail += 1;
        const stream = streamNorm(normalized, p, head_space);
        defer heap.free(stream);
        const tail = core.ladderTailCost(n_tail, appendedNewlines(family));
        if (stream.len == 0) return tail;
        return @intCast(core.tileCost(stream) + tail);
    }
    const stream = streamNorm(trimEndWs(normalized), p, head_space);
    defer heap.free(stream);
    if (stream.len == 0) return 0;
    return @intCast(core.tileCost(stream));
}

fn normalizeClaude(text: []const u8, fold_quotes: bool) []u8 {
    const canonical = normalize.nfc(heap, text) catch unreachable;
    defer heap.free(canonical);
    var cps: std.ArrayList(u21) = .empty;
    forCodepoints(canonical, &cps, fold_quotes);
    return cpsToUtf8(cps.items);
}
fn forCodepoints(text: []const u8, out: *std.ArrayList(u21), fold_quotes: bool) void {
    var pos: usize = 0;
    while (pos < text.len) {
        const d = utf.decode(text, pos);
        pos += @max(d.len, 1);
        const cp = d.codepoint;
        if (cp >= 1 and cp <= 8 or cp >= 0x0b and cp <= 0x1f or cp >= 0x7f and cp <= 0x9f or cp >= 0xe000 and cp <= 0xf8ff) continue;
        if (cp == 0) {
            out.append(heap, ' ') catch unreachable;
            continue;
        }
        if (cp == 0x0e32 and out.items.len != 0 and out.items[out.items.len - 1] == 0x0e4d) {
            _ = out.pop();
            out.append(heap, 0x0e33) catch unreachable;
            continue;
        }
        const folded = if (fold_quotes) foldQuote(cp) else cp;
        out.append(heap, if (isFunnySpace(folded)) ' ' else folded) catch unreachable;
    }
}
fn cpsToUtf8(cps: []const u21) []u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cps) |cp| {
        var bytes: [4]u8 = undefined;
        const n = utf.encode(cp, &bytes);
        out.appendSlice(heap, bytes[0..n]) catch unreachable;
    }
    return out.toOwnedSlice(heap) catch unreachable;
}
fn foldQuote(cp: u21) u21 {
    return switch (cp) {
        0x2018, 0x2019 => '\'',
        0x201c, 0x201d => '"',
        else => cp,
    };
}
fn isFunnySpace(cp: u21) bool {
    return cp == 0xa0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029 or cp == 0x202f or cp == 0x205f or (cp >= 0x2000 and cp <= 0x200a);
}
fn trimEndWs(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0) {
        const start = previousStart(text, end);
        const cp = utf.decode(text, start).codepoint;
        if (cp != ' ' and cp != '\t' and cp != '\n' and cp != '\r' and cp != 0x0b and cp != 0x0c) break;
        end = start;
    }
    return text[0..end];
}
fn previousStart(text: []const u8, end: usize) usize {
    var start = end - 1;
    while (start > 0 and isContinuation(text[start])) start -= 1;
    return start;
}

fn classify(cp: u21) Class {
    if (cp < 0x80) return switch (cp) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => .space,
        '0'...'9' => .digit,
        'A'...'Z', 'a'...'z' => .wordy,
        0x21...0x2f, 0x3a...0x40, 0x5b...0x60, 0x7b...0x7e => .punct,
        else => .hard,
    };
    if (unicode.isHan(cp) or (cp >= 0xac00 and cp <= 0xd7a3)) return .hard;
    if (isSeparator(cp)) return .hard;
    if (cp == 0x1c89 or cp == 0x1c8a or cp == 0xa7cb or cp == 0x264) return .wordy;
    if (unicode.generalCategoryGroup(cp) == .separator) return .space;
    if (isSymbolLetter(cp)) return .wordy;
    if (isDigit(cp)) return .digit;
    if (cp < 0x80 and (unicode.isPunctuation(cp) or unicode.isSymbol(cp)) or isPunctSym(cp)) return .punct;
    if (cp >= 0xfe00 and cp <= 0xfe0f) return .hard;
    if (cp == 0x0cf3) return .wordy;
    const group = unicode.generalCategoryGroup(cp);
    if ((group == .letter or group == .mark) and !isHardCp(cp)) return .wordy;
    return .hard;
}
fn isSeparator(cp: u21) bool {
    return cp != NON_SEPARATOR and (unicode.isCombining9(cp) or (cp >= 0x0300 and cp <= 0x0344) or (cp >= 0x0346 and cp <= 0x0362) or (cp >= 0x0483 and cp <= 0x0489));
}
fn isDigit(cp: u21) bool {
    return unicode.isNumber(cp) and (cp < 0x80 or (cp >= 0x660 and cp <= 0x669) or (cp >= 0x6f0 and cp <= 0x6f9));
}
fn isHardCp(cp: u21) bool {
    return cp >= 0x10000 or (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0x3400 and cp <= 0x4dbf) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xac00 and cp <= 0xd7a3) or cp == 0x3005 or cp == 0x3006 or (cp >= 0x6dd and cp <= 0x6e0) or (cp >= 0x6e9 and cp <= 0x6ec);
}
fn isSymbolLetter(cp: u21) bool {
    return (cp >= 0x16ee and cp <= 0x16f0) or (cp >= 0x2160 and cp <= 0x2188) or (cp >= 0x24b6 and cp <= 0x24e9) or (cp >= 0xa6e6 and cp <= 0xa6ef);
}
fn isPunctSym(cp: u21) bool {
    return switch (cp) {
        0x2014, 0xbb, 0xab, 0x2022, 0xb0, 0x201e, 0x2013, 0x2212, 0xa3, 0xa7, 0x20ac, 0x2026, 0x221a, 0x2192, 0xff08, 0x2116, 0x2020, 0x2504, 0x2502, 0xf0d, 0xb7, 0x2500, 0x2550, 0x2588, 0x0e3a => true,
        else => false,
    };
}
fn isStrayMark(cp: u21) bool {
    if (cp < 0x80 or cp == 0x0711 or (cp >= 0x0730 and cp <= 0x073f)) return false;
    return unicode.combiningClass(cp) != 0 and !isSeparator(cp);
}

fn splitRuns(text: []const u8) []Run {
    var runs: std.ArrayList(Run) = .empty;
    var pos: usize = 0;
    var start: usize = 0;
    var cls: ?Class = null;
    while (pos < text.len) {
        const d = utf.decode(text, pos);
        const next = pos + @max(d.len, 1);
        var current = classify(d.codepoint);
        if (current == .wordy and isStrayMark(d.codepoint)) current = .stray_mark;
        if (cls == null) cls = current else if (cls.? == .stray_mark and current == .wordy and isStrayMark(d.codepoint)) {} else if (current == cls.?) {} else if (current == .wordy and cls.? != .wordy and isStrayMark(d.codepoint)) {
            pushRun(&runs, text, cls.?, start, pos);
            start = pos;
            cls = .stray_mark;
        } else {
            pushRun(&runs, text, cls.?, start, pos);
            start = pos;
            cls = current;
        }
        pos = next;
    }
    if (cls) |value| pushRun(&runs, text, value, start, text.len);
    return runs.toOwnedSlice(heap) catch unreachable;
}
fn pushRun(runs: *std.ArrayList(Run), text: []const u8, cls: Class, start: usize, end: usize) void {
    if (start == end) return;
    if (cls != .hard) {
        runs.append(heap, .{ .cls = cls, .start = start, .end = end }) catch unreachable;
        return;
    }
    var pos = start;
    const first = utf.decode(text, pos).codepoint;
    var kind = hardKind(first);
    pos += utf.decode(text, pos).len;
    var sub_start = start;
    while (pos < end) {
        const d = utf.decode(text, pos);
        if (d.codepoint >= 0xfe00 and d.codepoint <= 0xfe0f or hardKind(d.codepoint) == kind) {
            pos += d.len;
            continue;
        }
        runs.append(heap, .{ .cls = .hard, .start = sub_start, .end = pos }) catch unreachable;
        sub_start = pos;
        kind = hardKind(d.codepoint);
        pos += d.len;
    }
    runs.append(heap, .{ .cls = .hard, .start = sub_start, .end = end }) catch unreachable;
}
const HardKind = enum { punct, number, letter };
fn hardKind(cp: u21) HardKind {
    if (unicode.isHan(cp)) return .letter;
    if (marksLikePunct(cp)) return .punct;
    if (digitBorder(cp)) return .number;
    return .letter;
}
fn marksLikePunct(cp: u21) bool {
    if (cp < 0x80) return classify(cp) == .punct;
    if (unicode.isHan(cp) or cp >= 0x10000) return false;
    if (isSeparator(cp)) return true;
    return switch (unicode.generalCategoryGroup(cp)) {
        .punctuation => !(cp >= 0x3001 and cp <= 0x303f),
        .symbol => true,
        .other => unicode.isFormat(cp) or unicode.isUnassigned(cp),
        else => false,
    };
}
fn digitBorder(cp: u21) bool {
    return cp < 0x10000 and unicode.isNumber(cp) and !((cp >= 0x30 and cp <= 0x39));
}
fn isDigitRun(body: []const u8) bool {
    if (body.len == 0) return false;
    var pos: usize = 0;
    var category: ?bool = null;
    while (pos < body.len) {
        const d = utf.decode(body, pos);
        if (!isDigit(d.codepoint)) return false;
        const decimal = d.codepoint < 0x80;
        if (category == null) category = decimal else if (category.? != decimal) return false;
        pos += d.len;
    }
    return true;
}
fn hardBow(body: []const u8) bool {
    const cp = utf.decode(body, 0).codepoint;
    return cp >= 0xfe00 and cp <= 0xfe0f or marksLikePunct(cp);
}
fn hardEow(body: []const u8) bool {
    var pos: usize = 0;
    while (pos < body.len) {
        const d = utf.decode(body, pos);
        if (pos + d.len == body.len) return d.codepoint >= 0xfe00 and d.codepoint <= 0xfe0f or marksLikePunct(d.codepoint);
        pos += d.len;
    }
    return false;
}
fn opensWord(text: []const u8, runs: []const Run, i: usize) bool {
    const r = runs[i];
    return r.end - r.start == 1 and text[r.start] == '\'' and i + 1 < runs.len and (runs[i + 1].cls == .wordy or runs[i + 1].cls == .stray_mark);
}
fn takesRightBorder(text: []const u8, run: Run) bool {
    const body = text[run.start..run.end];
    return run.cls == .punct or hardEow(body) or ((run.cls == .digit or run.cls == .hard) and isDigitRun(body) and digitEow(body));
}
fn digitBow(body: []const u8) bool {
    return isDigitRun(body) and digitBorder(utf.decode(body, 0).codepoint);
}
fn digitEow(body: []const u8) bool {
    var pos: usize = 0;
    var last: u21 = 0;
    while (pos < body.len) {
        const d = utf.decode(body, pos);
        last = d.codepoint;
        pos += d.len;
    }
    return isDigitRun(body) and digitBorder(last);
}
fn contractionSeam(text: []const u8, runs: []const Run, i: usize) bool {
    if (i == 0) return false;
    const r = runs[i];
    if (!(r.end - r.start == 1 or r.end - r.start == 2) or !isContractionSuffix(text[r.start..r.end])) return false;
    const prev = runs[i - 1];
    if (prev.cls != .punct or prev.end - prev.start != 1 or text[prev.start] != '\'') return false;
    return i < 2 or takesRightBorder(text, runs[i - 2]);
}
fn isContractionSuffix(body: []const u8) bool {
    return std.mem.eql(u8, body, "s") or std.mem.eql(u8, body, "t") or std.mem.eql(u8, body, "d") or std.mem.eql(u8, body, "m") or std.mem.eql(u8, body, "ll") or std.mem.eql(u8, body, "re") or std.mem.eql(u8, body, "ve");
}

fn caseForm(span: []const u8, allcaps_min: ?usize, head_mark: bool) CaseForm {
    if (head_mark) return .literal;
    if (std.unicode.utf8ValidateSlice(span) and span.len == std.unicode.utf8CountCodepoints(span) catch span.len) {
        var any_upper = false;
        var any_lower = false;
        var upper_after = false;
        for (span, 0..) |b, i| {
            if (b >= 'A' and b <= 'Z') {
                any_upper = true;
                upper_after = upper_after or i > 0;
            } else if (b >= 'a' and b <= 'z') any_lower = true;
        }
        if (allcaps_min) |min| if (span.len >= min and any_upper and !any_lower) return .caps;
        if (any_upper and !upper_after and span[0] >= 'A' and span[0] <= 'Z') return .shift;
        return .literal;
    }
    var pos: usize = 0;
    var first: u21 = 0;
    var cp_count: usize = 0;
    var any_upper = false;
    var any_lower = false;
    while (pos < span.len) {
        const d = utf.decode(span, pos);
        if (cp_count == 0) first = d.codepoint;
        if (unicode.isUpper(d.codepoint)) any_upper = true;
        if (unicode.isLower(d.codepoint)) any_lower = true;
        cp_count += 1;
        pos += d.len;
    }
    if (allcaps_min) |min| if (cp_count >= min and any_upper and !any_lower) return .caps;
    if (unicode.isUpper(first) and !any_upper) return .shift;
    return if (any_upper and !any_lower) .shift else .literal;
}
fn emitCaseBody(span: []const u8, form: CaseForm, out: *std.ArrayList(u8)) void {
    if (form == .literal) {
        out.appendSlice(heap, span) catch unreachable;
        return;
    }
    var pos: usize = 0;
    while (pos < span.len) {
        const d = utf.decode(span, pos);
        if (form == .shift_keep_dotted and pos > 0 and d.codepoint == 0x130) {
            out.appendSlice(heap, span[pos .. pos + d.len]) catch unreachable;
        } else if (unicode.lowerBytes(d.codepoint)) |lower| {
            for (lower) |byte| out.append(heap, byte) catch unreachable;
        } else if (d.codepoint < 0x80 and d.codepoint >= 'A' and d.codepoint <= 'Z') {
            out.append(heap, @as(u8, @intCast(d.codepoint + ('a' - 'A')))) catch unreachable;
        } else out.appendSlice(heap, span[pos .. pos + d.len]) catch unreachable;
        pos += d.len;
    }
}

fn streamNorm(text: []const u8, p: FrameParams, raw_head_space: bool) []u8 {
    var s = text;
    if (p.ladder) {
        while (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    }
    if (p.frame_bow and raw_head_space and s.len > 0 and s[0] == ' ' and (s.len < 2 or s[1] != ' ')) s = s[1..];
    const runs = splitRuns(s);
    defer heap.free(runs);
    if (runs.len == 0) {
        var empty = std.ArrayList(u8).empty;
        if (p.frame_bow) empty.append(heap, BOW) catch unreachable;
        return empty.toOwnedSlice(heap) catch unreachable;
    }
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(heap, s.len + s.len / 2 + 16) catch unreachable;
    var guard: usize = 0;
    const first = runs[0];
    const first_body = s[first.start..first.end];
    const head_quote = opensWord(s, runs, 0);
    const has_own_bow = !head_quote and (first.cls == .wordy or first.cls == .punct or first.cls == .stray_mark or hardBow(first_body) or ((first.cls == .digit or first.cls == .hard) and digitBow(first_body)) or (first.cls == .space and s[first.start] == ' '));
    if (!has_own_bow and p.frame_bow) out.append(heap, if (head_quote) ' ' else BOW) catch unreachable;
    for (runs, 0..) |r, i| {
        const body = s[r.start..r.end];
        switch (r.cls) {
            .wordy => {
                const fused = i > 0 and runs[i - 1].cls == .stray_mark;
                const form = caseForm(body, p.allcaps_min, fused);
                if (form == .shift or form == .shift_keep_dotted) out.append(heap, SHIFT) catch unreachable else if (form == .caps) out.append(heap, CAPS) catch unreachable;
                if (!fused and !contractionSeam(s, runs, i)) pushBow(&out, &guard);
                emitCaseBody(body, form, &out);
                out.append(heap, EOW) catch unreachable;
            },
            .stray_mark => {
                pushBow(&out, &guard);
                out.appendSlice(heap, body) catch unreachable;
                const follows = i + 1 < runs.len and runs[i + 1].cls == .wordy;
                if (!follows) out.append(heap, EOW) catch unreachable;
            },
            else => {
                const borders_left = bordersSpace(s, runs, i, -1);
                const borders_right = bordersSpace(s, runs, i, 1);
                if ((r.cls == .punct or hardBow(body)) and borders_left and !opensWord(s, runs, i)) pushBow(&out, &guard);
                out.appendSlice(heap, body) catch unreachable;
                if ((r.cls == .punct or hardEow(body)) and borders_right) out.append(heap, EOW) catch unreachable;
            },
        }
    }
    return out.toOwnedSlice(heap) catch unreachable;
}
fn bordersSpace(text: []const u8, runs: []const Run, i: usize, side: isize) bool {
    const at = @as(isize, @intCast(i)) + side;
    if (at < 0) return true;
    if (@as(usize, @intCast(at)) >= runs.len) return false;
    const r = runs[@intCast(at)];
    if (r.cls != .space) return false;
    return if (side < 0) text[r.end - 1] == ' ' else text[r.start] == ' ' and (r.end - r.start < 2 or text[r.start + 1] != ' ');
}
fn pushBow(out: *std.ArrayList(u8), guard: *usize) void {
    var case_at = out.items.len;
    while (case_at >= 1 and (out.items[case_at - 1] == SHIFT or out.items[case_at - 1] == CAPS)) case_at -= 1;
    const seam = case_at >= 3 and out.items[case_at - 1] == ' ' and out.items[case_at - 2] == EOW and previousStart(out.items, case_at - 2) >= guard.*;
    if (seam) {
        const tail_len = out.items.len - case_at;
        if (tail_len != 0) @memmove(out.items[case_at - 1 .. case_at - 1 + tail_len], out.items[case_at..]);
        out.items = out.items[0 .. out.items.len - 1];
    }
    out.append(heap, BOW) catch unreachable;
    if (seam) guard.* = out.items.len;
}
