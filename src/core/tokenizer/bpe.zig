const std = @import("std");
const normalize = @import("normalize.zig");
const unicode = @import("unicode.zig");
const utf = @import("utf.zig");

const Allocator = std.mem.Allocator;
const max_rank: u32 = std.math.maxInt(u32);
const heap = std.heap.c_allocator;

pub const Splitter = enum { o200k, cl100k, deepseek, kimi, qwen, glm5 };

const Part = struct { start: usize, rank: u32 };

pub const RankTable = struct {
    pairs: []u32,
    short: std.AutoHashMap(u128, u32),
    long: std.StringHashMap(u32),
    max_token_len: usize,

    fn parse(compressed: []const u8) RankTable {
        const raw = decompress(compressed);
        var p: []const u8 = raw;
        if (!std.mem.eql(u8, p[0..6], "UTOK1\n")) unreachable;
        p = p[6..];
        const entry_count = readU32(&p);
        const pairs = heap.alloc(u32, 65536) catch unreachable;
        @memset(pairs, max_rank);
        var short = std.AutoHashMap(u128, u32).init(heap);
        short.ensureTotalCapacity(entry_count) catch unreachable;
        var long = std.StringHashMap(u32).init(heap);
        long.ensureTotalCapacity(entry_count / 16) catch unreachable;
        var max_len: usize = 0;
        var token_rank: u32 = 0;
        while (token_rank < entry_count) : (token_rank += 1) {
            const len = readVarint(&p);
            if (len != 0) {
                const key = p[0..len];
                if (len == 2) {
                    pairs[(@as(usize, key[0]) << 8) | key[1]] = token_rank;
                } else if (pack(key)) |packed_value| {
                    short.put(packed_value, token_rank) catch unreachable;
                } else {
                    long.put(key, token_rank) catch unreachable;
                }
                max_len = @max(max_len, len);
                p = p[len..];
            }
        }
        if (p.len != 0) unreachable;
        return .{ .pairs = pairs, .short = short, .long = long, .max_token_len = max_len };
    }

    fn rank(self: *const RankTable, piece: []const u8) ?u32 {
        if (piece.len == 2) {
            const value = self.pairs[(@as(usize, piece[0]) << 8) | piece[1]];
            return if (value != max_rank) value else null;
        }
        if (pack(piece)) |packed_value| return self.short.get(packed_value);
        return self.long.get(piece);
    }

    fn countPiece(self: *const RankTable, piece: []const u8) u32 {
        if (piece.len == 0) return 0;
        if (self.rank(piece) != null) return 1;
        var parts: std.ArrayList(Part) = .empty;
        defer parts.deinit(heap);
        parts.ensureTotalCapacity(heap, piece.len + 1) catch unreachable;
        var min_rank: struct { rank: u32, index: usize } = .{ .rank = max_rank, .index = std.math.maxInt(usize) };
        var i: usize = 0;
        while (i + 1 < piece.len) : (i += 1) {
            const pair_rank = self.rank(piece[i .. i + 2]) orelse max_rank;
            if (pair_rank < min_rank.rank) min_rank = .{ .rank = pair_rank, .index = i };
            parts.append(heap, .{ .start = i, .rank = pair_rank }) catch unreachable;
        }
        parts.append(heap, .{ .start = piece.len - 1, .rank = max_rank }) catch unreachable;
        parts.append(heap, .{ .start = piece.len, .rank = max_rank }) catch unreachable;
        while (min_rank.rank != max_rank) {
            const at = min_rank.index;
            if (at > 0) parts.items[at - 1].rank = self.mergeRank(piece, parts.items, at - 1);
            parts.items[at].rank = self.mergeRank(piece, parts.items, at);
            _ = parts.orderedRemove(at + 1);
            min_rank = .{ .rank = max_rank, .index = std.math.maxInt(usize) };
            i = 0;
            while (i + 1 < parts.items.len) : (i += 1) {
                if (parts.items[i].rank < min_rank.rank) min_rank = .{ .rank = parts.items[i].rank, .index = i };
            }
        }
        return @intCast(parts.items.len - 1);
    }

    fn mergeRank(self: *const RankTable, piece: []const u8, parts: []const Part, index: usize) u32 {
        if (index + 3 >= parts.len) return max_rank;
        return self.rank(piece[parts[index].start..parts[index + 3].start]) orelse max_rank;
    }
};

fn decompress(compressed: []const u8) []u8 {
    var out: std.Io.Writer.Allocating = .init(heap);
    var input: std.Io.Reader = .fixed(compressed);
    var stream: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    _ = stream.reader.streamRemaining(&out.writer) catch unreachable;
    return out.toOwnedSlice() catch unreachable;
}

fn readU32(p: *[]const u8) u32 {
    const bytes = p.*[0..4];
    p.* = p.*[4..];
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readVarint(p: *[]const u8) usize {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = p.*[0];
        p.* = p.*[1..];
        const part: u64 = byte & 0x7f;
        if (shift == 63 and part > 1) unreachable;
        value |= part << shift;
        if (byte & 0x80 == 0) return @intCast(value);
        if (shift == 63) unreachable;
        shift += 7;
    }
}

fn pack(key: []const u8) ?u128 {
    if (key.len > 15) return null;
    var value: u128 = @as(u128, key.len) << 120;
    for (key, 0..) |byte, index| value |= @as(u128, byte) << @intCast(index * 8);
    return value;
}

const TableSlot = struct {
    lock: std.atomic.Mutex = .unlocked,
    value: ?*RankTable = null,
};
var o200k_slot = TableSlot{};
var cl100k_slot = TableSlot{};
var qwen_slot = TableSlot{};
var deepseek_slot = TableSlot{};
var kimi_slot = TableSlot{};
var glm_slot = TableSlot{};

fn table(slot: *TableSlot, compressed: []const u8) *const RankTable {
    if (slot.value) |value| return value;
    while (!slot.lock.tryLock()) std.atomic.spinLoopHint();
    defer slot.lock.unlock();
    if (slot.value == null) {
        const value = heap.create(RankTable) catch unreachable;
        value.* = RankTable.parse(compressed);
        slot.value = value;
    }
    return slot.value.?;
}

const o200k_data = @embedFile("data/o200k_base.bin.zst");
const cl100k_data = @embedFile("data/cl100k_base.bin.zst");
const qwen_data = @embedFile("data/qwen3.bin.zst");
const deepseek_data = @embedFile("data/deepseek3.bin.zst");
const kimi_data = @embedFile("data/kimi_k2.bin.zst");
const glm_data = @embedFile("data/glm5.bin.zst");

fn getTable(splitter: Splitter) *const RankTable {
    return switch (splitter) {
        .o200k => table(&o200k_slot, o200k_data),
        .cl100k => table(&cl100k_slot, cl100k_data),
        .qwen => table(&qwen_slot, qwen_data),
        .deepseek => table(&deepseek_slot, deepseek_data),
        .kimi => table(&kimi_slot, kimi_data),
        .glm5 => table(&glm_slot, glm_data),
    };
}

pub fn count(text: []const u8, splitter: Splitter, nfc: bool) usize {
    if (nfc) {
        const normalized = normalize.nfc(heap, text) catch unreachable;
        defer heap.free(normalized);
        return countScanned(normalized, splitter);
    }
    return countScanned(text, splitter);
}

fn countScanned(text: []const u8, splitter: Splitter) usize {
    const rank_table = getTable(splitter);
    var total: u64 = 0;
    if (splitter == .deepseek) return countDeepSeek(text, rank_table);
    var pos: usize = 0;
    while (pos < text.len) {
        const end = nextPiece(text, pos, splitter);
        total += rank_table.countPiece(text[pos..end]);
        pos = end;
    }
    return @intCast(@min(total, std.math.maxInt(usize)));
}

fn decodedAt(text: []const u8, pos: usize) ?utf.Decoded {
    if (pos >= text.len) return null;
    return utf.decode(text, pos);
}

fn contractionEnd(text: []const u8, pos: usize) usize {
    const first = decodedAt(text, pos) orelse return pos;
    if (first.codepoint != '\'') return pos;
    const second = decodedAt(text, pos + first.len) orelse return pos;
    const one = pos + first.len + second.len;
    return switch (second.codepoint) {
        's', 'S', 0x17f, 't', 'T', 'm', 'M', 'd', 'D' => one,
        'r', 'R' => if (decodedAt(text, one)) |next| if (next.codepoint == 'e' or next.codepoint == 'E') one + next.len else pos else pos,
        'v', 'V' => if (decodedAt(text, one)) |next| if (next.codepoint == 'e' or next.codepoint == 'E') one + next.len else pos else pos,
        'l', 'L' => if (decodedAt(text, one)) |next| if (next.codepoint == 'l' or next.codepoint == 'L') one + next.len else pos else pos,
        else => pos,
    };
}

fn digitsEnd(text: []const u8, pos: usize) ?usize {
    var i = pos;
    var count_digits: usize = 0;
    while (count_digits < 3) : (count_digits += 1) {
        const d = decodedAt(text, i) orelse break;
        if (!unicode.isNumber(d.codepoint)) break;
        i += d.len;
    }
    return if (i > pos) i else null;
}

fn punctEnd(text: []const u8, pos: usize, trailing_slash: bool) ?usize {
    var i = pos;
    if (decodedAt(text, pos)) |first| {
        if (first.codepoint == ' ') i += first.len;
    }
    const start = i;
    while (decodedAt(text, i)) |d| {
        if (unicode.isWhitespace(d.codepoint) or unicode.isLetter(d.codepoint) or unicode.isNumber(d.codepoint)) break;
        i += d.len;
    }
    if (i == start) return null;
    while (decodedAt(text, i)) |d| {
        if (d.codepoint == '\r' or d.codepoint == '\n' or (trailing_slash and d.codepoint == '/')) i += d.len else break;
    }
    return i;
}

fn wsEnd(text: []const u8, pos: usize) ?usize {
    var i = pos;
    var last_nl_end: ?usize = null;
    var last_len: usize = 0;
    var count_cp: usize = 0;
    while (decodedAt(text, i)) |d| {
        if (!unicode.isWhitespace(d.codepoint)) break;
        i += d.len;
        if (d.codepoint == '\r' or d.codepoint == '\n') last_nl_end = i;
        last_len = d.len;
        count_cp += 1;
    }
    if (count_cp == 0) return null;
    if (last_nl_end) |end| return end;
    if (i == text.len) return i;
    return if (count_cp > 1) i - last_len else i;
}

fn nextPiece(text: []const u8, pos: usize, splitter: Splitter) usize {
    return switch (splitter) {
        .cl100k => nextCl100k(text, pos),
        .o200k => nextO200k(text, pos),
        .qwen => nextQwen(text, pos),
        .kimi => nextKimi(text, pos),
        .glm5 => nextCl100k(text, pos),
        .deepseek => unreachable,
    };
}

fn fallbackEnd(text: []const u8, pos: usize) usize {
    if (decodedAt(text, pos)) |d| return pos + d.len;
    return pos + 1;
}

fn nextCl100k(text: []const u8, pos: usize) usize {
    const contraction = contractionEnd(text, pos);
    if (contraction > pos) return contraction;
    if (wordCl100k(text, pos)) |end| return end;
    if (digitsEnd(text, pos)) |end| return end;
    if (punctEnd(text, pos, false)) |end| return end;
    if (wsEnd(text, pos)) |end| return end;
    return fallbackEnd(text, pos);
}

fn wordCl100k(text: []const u8, pos: usize) ?usize {
    const first = decodedAt(text, pos) orelse return null;
    const start = if (first.codepoint != '\r' and first.codepoint != '\n' and !unicode.isLetter(first.codepoint) and !unicode.isNumber(first.codepoint)) pos + first.len else pos;
    var i = start;
    while (decodedAt(text, i)) |d| {
        if (!unicode.isLetter(d.codepoint)) break;
        i += d.len;
    }
    return if (i > start) i else null;
}

fn nextO200k(text: []const u8, pos: usize) usize {
    if (wordO200k(text, pos)) |end| return contractionEnd(text, end);
    if (digitsEnd(text, pos)) |end| return end;
    if (punctEnd(text, pos, true)) |end| return end;
    if (wsEnd(text, pos)) |end| return end;
    return fallbackEnd(text, pos);
}

fn wordO200k(text: []const u8, pos: usize) ?usize {
    const first = decodedAt(text, pos) orelse return null;
    const prefix: ?usize = if (first.codepoint != '\r' and first.codepoint != '\n' and !unicode.isLetter(first.codepoint) and !unicode.isNumber(first.codepoint)) pos + first.len else null;
    if (prefix) |p| {
        if (body1(text, p)) |end| return end;
    }
    if (body1(text, pos)) |end| return end;
    if (prefix) |p| {
        if (body2(text, p)) |end| return end;
    }
    return body2(text, pos);
}

fn inUpperSet(cp: u21) bool {
    return if (cp < 0x80) std.ascii.isUpper(@intCast(cp)) else unicode.isUpper(cp) or unicode.isModifierLetter(cp) or unicode.isOtherLetter(cp) or unicode.isMark(cp);
}
fn inLowerSet(cp: u21) bool {
    return if (cp < 0x80) std.ascii.isLower(@intCast(cp)) else unicode.isLower(cp) or unicode.isModifierLetter(cp) or unicode.isOtherLetter(cp) or unicode.isMark(cp);
}

fn body1(text: []const u8, pos: usize) ?usize {
    var i = pos;
    var last_shared: ?usize = null;
    while (decodedAt(text, i)) |d| {
        if (!inUpperSet(d.codepoint)) break;
        if (inLowerSet(d.codepoint)) last_shared = i + d.len;
        i += d.len;
    }
    if (decodedAt(text, i)) |d| {
        if (inLowerSet(d.codepoint)) {
            var j = i + d.len;
            while (decodedAt(text, j)) |next| {
                if (!inLowerSet(next.codepoint)) break;
                j += next.len;
            }
            return j;
        }
    }
    return last_shared;
}

fn body2(text: []const u8, pos: usize) ?usize {
    var i = pos;
    while (decodedAt(text, i)) |d| {
        if (!inUpperSet(d.codepoint)) break;
        i += d.len;
    }
    if (i == pos) return null;
    while (decodedAt(text, i)) |d| {
        if (!inLowerSet(d.codepoint)) break;
        i += d.len;
    }
    return i;
}

fn nextQwen(text: []const u8, pos: usize) usize {
    const contraction = contractionEnd(text, pos);
    if (contraction > pos) return contraction;
    if (wordQwen(text, pos)) |end| return end;
    if (decodedAt(text, pos)) |d| {
        if (unicode.isNumber(d.codepoint)) return pos + d.len;
        if (punctQwen(text, pos)) |end| return end;
        if (wsEnd(text, pos)) |end| return end;
        return pos + d.len;
    }
    return pos + 1;
}

fn lmRunEnd(text: []const u8, pos: usize) usize {
    var i = pos;
    while (decodedAt(text, i)) |d| {
        if (!unicode.isLetter(d.codepoint) and !unicode.isMark(d.codepoint)) break;
        i += d.len;
    }
    return i;
}
fn wordQwen(text: []const u8, pos: usize) ?usize {
    const first = decodedAt(text, pos) orelse return null;
    if (first.codepoint != '\r' and first.codepoint != '\n' and !unicode.isLetter(first.codepoint) and !unicode.isNumber(first.codepoint)) {
        const end = lmRunEnd(text, pos + first.len);
        if (end > pos + first.len) return end;
        return if (unicode.isMark(first.codepoint)) pos + first.len else null;
    }
    const end = lmRunEnd(text, pos);
    return if (end > pos) end else null;
}
fn punctQwen(text: []const u8, pos: usize) ?usize {
    const first = decodedAt(text, pos) orelse return null;
    const start = if (first.codepoint == ' ') pos + first.len else pos;
    var i = start;
    while (decodedAt(text, i)) |d| {
        if (unicode.isWhitespace(d.codepoint) or unicode.isLetter(d.codepoint) or unicode.isMark(d.codepoint) or unicode.isNumber(d.codepoint)) break;
        i += d.len;
    }
    if (i == start) return null;
    while (decodedAt(text, i)) |d| {
        if (d.codepoint != '\r' and d.codepoint != '\n') break;
        i += d.len;
    }
    return i;
}

fn inKimiA(cp: u21) bool {
    return !unicode.isHan(cp) and inUpperSet(cp);
}
fn inKimiB(cp: u21) bool {
    return !unicode.isHan(cp) and inLowerSet(cp);
}
fn coreLower(text: []const u8, pos: usize) ?usize {
    var i = pos;
    var last_b: ?usize = null;
    while (decodedAt(text, i)) |d| {
        if (!inKimiA(d.codepoint)) break;
        i += d.len;
        if (inKimiB(d.codepoint)) last_b = i;
    }
    var end = i;
    while (decodedAt(text, end)) |d| {
        if (!inKimiB(d.codepoint)) break;
        end += d.len;
    }
    if (end > i) return contractionEnd(text, end);
    return if (last_b) |at| contractionEnd(text, at) else null;
}
fn coreUpper(text: []const u8, pos: usize) ?usize {
    var i = pos;
    while (decodedAt(text, i)) |d| {
        if (!inKimiA(d.codepoint)) break;
        i += d.len;
    }
    if (i == pos) return null;
    var end = i;
    while (decodedAt(text, end)) |d| {
        if (!inKimiB(d.codepoint)) break;
        end += d.len;
    }
    return contractionEnd(text, end);
}
fn nextKimi(text: []const u8, pos: usize) usize {
    const first = decodedAt(text, pos) orelse return pos + 1;
    if (unicode.isHan(first.codepoint)) {
        var i = pos + first.len;
        while (decodedAt(text, i)) |d| {
            if (!unicode.isHan(d.codepoint)) break;
            i += d.len;
        }
        return i;
    }
    const prefix = first.codepoint != '\r' and first.codepoint != '\n' and !unicode.isLetter(first.codepoint) and !unicode.isNumber(first.codepoint);
    if (prefix) if (coreLower(text, pos + first.len)) |end| return end;
    if (coreLower(text, pos)) |end| return end;
    if (prefix) if (coreUpper(text, pos + first.len)) |end| return end;
    if (coreUpper(text, pos)) |end| return end;
    if (digitsEnd(text, pos)) |end| return end;
    if (punctEnd(text, pos, false)) |end| return end;
    if (wsEnd(text, pos)) |end| return end;
    return pos + first.len;
}

fn countDeepSeek(text: []const u8, rank_table: *const RankTable) usize {
    const result = countDeepStage(text, rank_table, 0);
    return @intCast(@min(result, std.math.maxInt(usize)));
}
fn countDeepStage(text: []const u8, rank_table: *const RankTable, stage: u2) u64 {
    if (stage == 3) return rank_table.countPiece(text);
    var total: u64 = 0;
    var gap: usize = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = switch (stage) {
            0 => digitsEnd(text, pos),
            1 => cjkEnd(text, pos),
            2 => mainEnd(text, pos),
            else => unreachable,
        };
        if (end) |matched| {
            if (pos > gap) total += countDeepStage(text[gap..pos], rank_table, stage + 1);
            total += countDeepStage(text[pos..matched], rank_table, stage + 1);
            pos = matched;
            gap = matched;
        } else pos += fallbackEnd(text, pos) - pos;
    }
    if (gap < text.len) total += countDeepStage(text[gap..], rank_table, stage + 1);
    return total;
}
fn cjkCodepoint(cp: u21) bool {
    return (cp >= 0x3040 and cp <= 0x30ff) or (cp >= 0x4e00 and cp <= 0x9fa5);
}
fn cjkEnd(text: []const u8, pos: usize) ?usize {
    var i = pos;
    while (decodedAt(text, i)) |d| {
        if (!cjkCodepoint(d.codepoint)) break;
        i += d.len;
    }
    return if (i > pos) i else null;
}
fn isPs(cp: u21) bool {
    const group = unicode.generalCategoryGroup(cp);
    return group == .punctuation or group == .symbol;
}
fn mainEnd(text: []const u8, pos: usize) ?usize {
    const first = decodedAt(text, pos) orelse return null;
    if (first.codepoint < 0x80 and std.ascii.isPunctuation(@intCast(first.codepoint))) {
        var i = pos + first.len;
        while (decodedAt(text, i)) |d| {
            if (d.codepoint >= 0x80 or !std.ascii.isAlphabetic(@intCast(d.codepoint))) break;
            i += d.len;
        }
        if (i > pos + first.len) return i;
    }
    if (unicode.isLetter(first.codepoint) or unicode.isMark(first.codepoint)) return lmRunEnd(text, pos + first.len);
    if (first.codepoint != '\r' and first.codepoint != '\n' and !isPs(first.codepoint)) {
        if (decodedAt(text, pos + first.len)) |second| {
            if (unicode.isLetter(second.codepoint) or unicode.isMark(second.codepoint)) return lmRunEnd(text, pos + first.len + second.len);
        }
    }
    if (psEnd(text, pos)) |end| return end;
    return wsEnd(text, pos);
}
fn psEnd(text: []const u8, pos: usize) ?usize {
    var i = pos;
    if (decodedAt(text, pos)) |d| {
        if (d.codepoint == ' ') i += d.len;
    }
    const start = i;
    while (decodedAt(text, i)) |d| {
        if (!isPs(d.codepoint)) break;
        i += d.len;
    }
    if (i == start) return null;
    while (decodedAt(text, i)) |d| {
        if (d.codepoint != '\r' and d.codepoint != '\n') break;
        i += d.len;
    }
    return i;
}

// The native implementation initializes each vocabulary on first use. A
// process-wide immutable table shares the parsed rank map across requests.
const Slot = struct { lock: std.atomic.Mutex = .unlocked, value: ?*RankTable = null };

pub fn countO200k(text: []const u8) usize {
    return count(text, .o200k, false);
}
pub fn countCl100k(text: []const u8) usize {
    return count(text, .cl100k, false);
}
pub fn countQwen3(text: []const u8) usize {
    return count(text, .qwen, true);
}
pub fn countDeepseek(text: []const u8) usize {
    return count(text, .deepseek, false);
}
pub fn countKimi(text: []const u8) usize {
    return count(text, .kimi, false);
}
pub fn countGlm5(text: []const u8) usize {
    return count(text, .glm5, false);
}
