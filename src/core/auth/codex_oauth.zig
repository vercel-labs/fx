const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const auth_file_env = "FX_CODEX_AUTH_FILE";
pub const token_url_env = "FX_CODEX_TOKEN_URL";
pub const oauth_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const default_token_url = "https://auth.openai.com/oauth/token";
pub const issuer_env = "FX_CODEX_ISSUER";
pub const default_issuer = "https://auth.openai.com";
pub const refresh_early_seconds: i64 = 5 * 60;
const max_auth_file_bytes: usize = 256 * 1024;
const personal_access_token_prefix = "at-";
const jwt_payload_max_bytes: usize = 8 * 1024;

pub const Loaded = struct {
    access_token: []u8,
    account_id: ?[]u8 = null,
    refresh_after_ms: ?i64 = null,
    refreshable: bool = true,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        if (self.account_id) |account_id| alloc.free(account_id);
        self.* = undefined;
    }
};

pub const StoredTokens = struct {
    id_token: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    account_id: []const u8,
};

pub fn sourceExists(alloc: Allocator) !bool {
    if (comptime host_target.is_wasm) return false;
    var loaded = (try loadStored(alloc)) orelse return false;
    loaded.deinit(alloc);
    return true;
}

pub fn loadStored(alloc: Allocator) !?Loaded {
    if (comptime host_target.is_wasm) return null;
    const path = (try resolveAuthFilePath(alloc)) orelse return null;
    defer alloc.free(path);
    return loadFromPath(alloc, path);
}

pub fn load(alloc: Allocator, transport: oauth_transport.Provider) !?Loaded {
    if (comptime host_target.is_wasm) return null;
    const path = (try resolveAuthFilePath(alloc)) orelse return null;
    defer alloc.free(path);
    var loaded = (try loadFromPath(alloc, path)) orelse return null;
    errdefer loaded.deinit(alloc);
    if (!loaded.refreshable) return loaded;
    if (!needsRefresh(loaded.refresh_after_ms, io_mod.milliTimestamp())) return loaded;
    loaded.deinit(alloc);
    return refreshAtPath(alloc, transport, path);
}

pub fn refresh(alloc: Allocator, transport: oauth_transport.Provider) !?Loaded {
    if (comptime host_target.is_wasm) return null;
    const path = (try resolveAuthFilePath(alloc)) orelse return null;
    defer alloc.free(path);
    return refreshAtPath(alloc, transport, path);
}

pub fn resolveAuthFilePath(alloc: Allocator) !?[]u8 {
    if (nonEmptyEnv(auth_file_env)) |path| return try alloc.dupe(u8, path);
    if (nonEmptyEnv("CODEX_HOME")) |home| {
        return try std.fs.path.join(alloc, &.{ home, "auth.json" });
    }
    const home = nonEmptyEnv("HOME") orelse nonEmptyEnv("USERPROFILE") orelse return null;
    return try std.fs.path.join(alloc, &.{ home, ".codex", "auth.json" });
}

pub fn tokenUrl() []const u8 {
    return nonEmptyEnv(token_url_env) orelse default_token_url;
}

pub fn issuer() []const u8 {
    const value = nonEmptyEnv(issuer_env) orelse return default_issuer;
    return std.mem.trimEnd(u8, value, "/");
}

pub fn persistTokens(alloc: Allocator, tokens: StoredTokens) !void {
    if (comptime host_target.is_wasm) return error.CodexAuthUnavailable;
    const path = (try resolveAuthFilePath(alloc)) orelse return error.HomeNotSet;
    defer alloc.free(path);
    try ensureAuthFileParent(path);
    const existing = readAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| secret.zeroAndFree(alloc, bytes);
    try writeRefreshedDocument(alloc, path, existing orelse "{}", tokens);
}

pub fn copyAccountId(id_token: []const u8, buf: []u8) ?[]const u8 {
    return jwtAccountId(id_token, buf);
}

pub const LogoutResult = struct {
    session_deleted: bool = false,
    local_durability_failed: bool = false,
    remote_revocation_failed: bool = false,
};

pub fn revokeRefreshToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    refresh_token: []const u8,
) !void {
    var request_body: std.Io.Writer.Allocating = .init(alloc);
    defer request_body.deinit();
    try request_body.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(oauth_client_id, .{}, &request_body.writer);
    try request_body.writer.writeAll(",\"token\":");
    try std.json.Stringify.value(refresh_token, .{}, &request_body.writer);
    try request_body.writer.writeAll(",\"token_type_hint\":\"refresh_token\"}");

    var response = transport.execute(alloc, .{
        .method = .post_json,
        .url = tokenUrl(),
        .payload = request_body.written(),
    }) catch return;
    defer response.deinit(alloc);
}

pub fn clearStoredTokens(alloc: Allocator) !LogoutResult {
    if (comptime host_target.is_wasm) return error.CodexAuthUnavailable;
    const path = (try resolveAuthFilePath(alloc)) orelse return error.HomeNotSet;
    defer alloc.free(path);

    const existing = readAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer secret.zeroAndFree(alloc, existing);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, existing, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexAuthFile,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexAuthFile;
    if (parsed.value.object.get("tokens") == null) return .{};

    _ = parsed.value.object.orderedRemove("tokens");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &out.writer);
    io_mod.writeFileAtomic(alloc, path, out.written()) catch return .{
        .local_durability_failed = true,
    };
    return .{ .session_deleted = true };
}

pub fn loadStoredRefreshToken(alloc: Allocator) !?[]u8 {
    if (comptime host_target.is_wasm) return null;
    const path = (try resolveAuthFilePath(alloc)) orelse return null;
    defer alloc.free(path);
    const bytes = readAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer secret.zeroAndFree(alloc, bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tokens = storedTokensFromDocument(parsed.value.object) orelse return null;
    if (tokens.refresh_token.len == 0) return null;
    return try alloc.dupe(u8, tokens.refresh_token);
}

pub fn parseLoaded(alloc: Allocator, bytes: []const u8) !?Loaded {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexAuthFile,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexAuthFile;
    return loadedFromDocument(alloc, parsed.value.object);
}

pub fn applyRefreshResponse(current: StoredTokens, response: std.json.ObjectMap) !StoredTokens {
    const access = objectString(response, "access_token") orelse current.access_token;
    const refresh_token = objectString(response, "refresh_token") orelse current.refresh_token;
    const id_token = objectString(response, "id_token") orelse current.id_token;
    if (access.len == 0 or refresh_token.len == 0) return error.InvalidCodexRefreshResponse;

    var jwt_buf: [jwt_payload_max_bytes]u8 = undefined;
    if (jwtAccountId(id_token, &jwt_buf)) |next_account| {
        if (next_account.len > 0 and current.account_id.len > 0 and
            !std.mem.eql(u8, current.account_id, next_account))
        {
            return error.CodexAccountChanged;
        }
    }

    return .{
        .id_token = id_token,
        .access_token = access,
        .refresh_token = refresh_token,
        .account_id = current.account_id,
    };
}

pub fn jwtExpirationUnix(jwt: []const u8) ?i64 {
    var buf: [jwt_payload_max_bytes]u8 = undefined;
    const payload = decodeJwtPayload(jwt, &buf) orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const exp = parsed.value.object.get("exp") orelse return null;
    return switch (exp) {
        .integer => |value| value,
        else => null,
    };
}

fn loadFromPath(alloc: Allocator, path: []const u8) !?Loaded {
    const bytes = readAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("auth", "codex auth load failed step=read err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer secret.zeroAndFree(alloc, bytes);

    return parseLoaded(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("auth", "codex auth load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

fn refreshAtPath(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    path: []const u8,
) !?Loaded {
    const bytes = readAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer secret.zeroAndFree(alloc, bytes);

    var document = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexAuthFile,
    };
    defer document.deinit();
    if (document.value != .object) return error.InvalidCodexAuthFile;

    const current = storedTokensFromDocument(document.value.object) orelse return error.InvalidCodexAuthFile;
    if (current.refresh_token.len == 0) return error.CodexRefreshUnavailable;

    var request_body: std.Io.Writer.Allocating = .init(alloc);
    defer request_body.deinit();
    try request_body.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(oauth_client_id, .{}, &request_body.writer);
    try request_body.writer.writeAll(",\"grant_type\":\"refresh_token\",\"refresh_token\":");
    try std.json.Stringify.value(current.refresh_token, .{}, &request_body.writer);
    try request_body.writer.writeByte('}');

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = tokenUrl(),
        .payload = request_body.written(),
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.CodexRefreshRejected;

    var refreshed_json = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexRefreshResponse,
    };
    defer refreshed_json.deinit();
    if (refreshed_json.value != .object) return error.InvalidCodexRefreshResponse;

    const refreshed = try applyRefreshResponse(current, refreshed_json.value.object);
    try writeRefreshedDocument(alloc, path, bytes, refreshed);
    return try takeLoaded(alloc, refreshed.access_token, refreshed.account_id, true);
}

fn loadedFromDocument(alloc: Allocator, object: std.json.ObjectMap) !?Loaded {
    if (personalAccessToken(object)) |token| {
        if (!std.mem.startsWith(u8, token, personal_access_token_prefix)) return error.InvalidCodexAuthFile;
        return try takeLoaded(alloc, token, objectString(object, "account_id"), false);
    }

    var jwt_buf: [jwt_payload_max_bytes]u8 = undefined;
    const tokens = storedTokensFromDocumentWithJwt(object, &jwt_buf) orelse return null;
    return try takeLoaded(alloc, tokens.access_token, tokens.account_id, true);
}

fn storedTokensFromDocument(object: std.json.ObjectMap) ?StoredTokens {
    if (objectString(object, "auth_mode")) |mode| {
        if (!std.ascii.eqlIgnoreCase(mode, "chatgpt")) return null;
    }
    const tokens_value = object.get("tokens") orelse return null;
    if (tokens_value != .object) return null;
    const tokens = tokens_value.object;
    const access = objectString(tokens, "access_token") orelse return null;
    const refresh_token = objectString(tokens, "refresh_token") orelse return null;
    const id_token = objectString(tokens, "id_token") orelse "";
    const account_id = objectString(tokens, "account_id") orelse return null;
    if (access.len == 0 or refresh_token.len == 0 or account_id.len == 0) return null;
    return .{
        .id_token = id_token,
        .access_token = access,
        .refresh_token = refresh_token,
        .account_id = account_id,
    };
}

fn storedTokensFromDocumentWithJwt(object: std.json.ObjectMap, jwt_buf: []u8) ?StoredTokens {
    if (objectString(object, "auth_mode")) |mode| {
        if (!std.ascii.eqlIgnoreCase(mode, "chatgpt")) return null;
    }
    const tokens_value = object.get("tokens") orelse return null;
    if (tokens_value != .object) return null;
    const tokens = tokens_value.object;
    const access = objectString(tokens, "access_token") orelse return null;
    const refresh_token = objectString(tokens, "refresh_token") orelse return null;
    const id_token = objectString(tokens, "id_token") orelse "";
    if (access.len == 0 or refresh_token.len == 0) return null;

    const account_id = objectString(tokens, "account_id") orelse jwtAccountId(id_token, jwt_buf) orelse "";
    if (account_id.len == 0) return null;
    return .{
        .id_token = id_token,
        .access_token = access,
        .refresh_token = refresh_token,
        .account_id = account_id,
    };
}

fn personalAccessToken(object: std.json.ObjectMap) ?[]const u8 {
    const selected = if (objectString(object, "auth_mode")) |mode|
        std.mem.eql(u8, mode, "personalAccessToken")
    else
        object.get("personal_access_token") != null;
    if (!selected) return null;
    return objectString(object, "personal_access_token");
}

fn takeLoaded(
    alloc: Allocator,
    access_token: []const u8,
    account_id: ?[]const u8,
    refreshable: bool,
) !Loaded {
    const token = try alloc.dupe(u8, access_token);
    errdefer secret.zeroAndFree(alloc, token);
    const owned_account = if (account_id) |value|
        if (value.len > 0) try alloc.dupe(u8, value) else null
    else
        null;
    const refresh_after_ms = if (refreshable)
        if (jwtExpirationUnix(access_token)) |exp|
            (exp - refresh_early_seconds) * std.time.ms_per_s
        else
            io_mod.milliTimestamp()
    else
        null;
    return .{
        .access_token = token,
        .account_id = owned_account,
        .refresh_after_ms = refresh_after_ms,
        .refreshable = refreshable,
    };
}

fn needsRefresh(refresh_after_ms: ?i64, now_ms: i64) bool {
    const deadline = refresh_after_ms orelse return false;
    return deadline <= now_ms;
}

fn writeRefreshedDocument(
    alloc: Allocator,
    path: []const u8,
    original_bytes: []const u8,
    tokens: StoredTokens,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena_alloc,
        original_bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexAuthFile,
    };
    if (root != .object) return error.InvalidCodexAuthFile;

    try root.object.put(arena_alloc, try arena_alloc.dupe(u8, "auth_mode"), .{
        .string = try arena_alloc.dupe(u8, "chatgpt"),
    });
    const stamp = try rfc3339UtcAlloc(arena_alloc, @divFloor(io_mod.milliTimestamp(), 1000));
    try root.object.put(arena_alloc, try arena_alloc.dupe(u8, "last_refresh"), .{
        .string = stamp,
    });

    var token_object: std.json.ObjectMap = if (root.object.get("tokens")) |value|
        if (value == .object) value.object else .empty
    else
        .empty;
    try token_object.put(arena_alloc, try arena_alloc.dupe(u8, "id_token"), .{
        .string = try arena_alloc.dupe(u8, tokens.id_token),
    });
    try token_object.put(arena_alloc, try arena_alloc.dupe(u8, "access_token"), .{
        .string = try arena_alloc.dupe(u8, tokens.access_token),
    });
    try token_object.put(arena_alloc, try arena_alloc.dupe(u8, "refresh_token"), .{
        .string = try arena_alloc.dupe(u8, tokens.refresh_token),
    });
    try token_object.put(arena_alloc, try arena_alloc.dupe(u8, "account_id"), .{
        .string = try arena_alloc.dupe(u8, tokens.account_id),
    });
    try root.object.put(arena_alloc, try arena_alloc.dupe(u8, "tokens"), .{ .object = token_object });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer);
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

fn ensureAuthFileParent(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidCodexAuthPath;
    if (std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent, .{})) |*dir| {
        dir.close(io_mod.getIo());
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    std.Io.Dir.createDirAbsolute(io_mod.getIo(), parent, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn readAuthFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .mode = .read_only,
    });
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn jwtAccountId(jwt: []const u8, buf: []u8) ?[]const u8 {
    // ChatGPT id_token payloads are ~1KiB. `buf` is only the account-id output.
    var payload_buf: [jwt_payload_max_bytes]u8 = undefined;
    const payload = decodeJwtPayload(jwt, &payload_buf) orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const nested = parsed.value.object.get("https://api.openai.com/auth") orelse return null;
    if (nested != .object) return null;
    const account = objectString(nested.object, "chatgpt_account_id") orelse return null;
    if (account.len == 0 or account.len > buf.len) return null;
    @memcpy(buf[0..account.len], account);
    return buf[0..account.len];
}

fn decodeJwtPayload(jwt: []const u8, buf: []u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return null;
    const payload = parts.next() orelse return null;
    if (payload.len == 0 or parts.next() == null or parts.next() != null) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return null;
    if (size > buf.len) return null;
    decoder.decode(buf[0..size], payload) catch return null;
    return buf[0..size];
}

fn rfc3339UtcAlloc(alloc: Allocator, timestamp_s: i64) ![]u8 {
    const days = @divFloor(timestamp_s, 86_400);
    var seconds = @mod(timestamp_s, 86_400);
    if (seconds < 0) seconds += 86_400;
    const hour: u6 = @intCast(@divFloor(seconds, 3_600));
    const minute: u6 = @intCast(@divFloor(@mod(seconds, 3_600), 60));
    const second: u6 = @intCast(@mod(seconds, 60));
    const civil = civilFromDays(days);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        civil.year,
        civil.month,
        civil.day,
        hour,
        minute,
        second,
    });
}

const CivilDate = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days: i64) CivilDate {
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day: u8 = @intCast(day_of_year - @divFloor(153 * month_prime + 2, 5) + 1);
    const month: u8 = @intCast(if (month_prime < 10) month_prime + 3 else month_prime - 9);
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

var stable_codex_test_environ: ?*std.process.Environ.Map = null;

fn stableCodexTestEnviron() !*const std.process.Environ.Map {
    if (stable_codex_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_codex_test_environ = map;
    return map;
}

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const [2][]const u8) !*TestEnv {
        _ = try stableCodexTestEnviron();
        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        if (stable_codex_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn encodeJwt(alloc: Allocator, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded_len = encoder.calcSize(payload.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(alloc, "e30.{s}.sig", .{encoded});
}

fn encodePaddedJwt(alloc: Allocator, account_id: []const u8, pad_len: usize) ![]u8 {
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":");
    try std.json.Stringify.value(account_id, .{}, &payload.writer);
    try payload.writer.writeAll("},\"pad\":\"");
    var index: usize = 0;
    while (index < pad_len) : (index += 1) try payload.writer.writeByte('x');
    try payload.writer.writeAll("\"}");
    return encodeJwt(alloc, payload.written());
}

const FakeTransportState = struct {
    body: []const u8,
    disposition: oauth_transport.Disposition,
    calls: usize = 0,

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        _ = request;
        return .{
            .disposition = self.disposition,
            .body = try alloc.dupe(u8, self.body),
        };
    }
};

test "auth file path prefers FX_CODEX_AUTH_FILE then CODEX_HOME then ~/.codex" {
    const alloc = std.testing.allocator;

    var explicit = try TestEnv.install(alloc, &.{
        .{ auth_file_env, "/tmp/custom-auth.json" },
        .{ "CODEX_HOME", "/tmp/codex-home" },
        .{ "HOME", "/tmp/home" },
    });
    defer explicit.deinit();
    const explicit_path = (try resolveAuthFilePath(alloc)).?;
    defer alloc.free(explicit_path);
    try std.testing.expectEqualStrings("/tmp/custom-auth.json", explicit_path);

    var home = try TestEnv.install(alloc, &.{
        .{ "CODEX_HOME", "/tmp/codex-home" },
        .{ "HOME", "/tmp/home" },
    });
    defer home.deinit();
    const home_path = (try resolveAuthFilePath(alloc)).?;
    defer alloc.free(home_path);
    try std.testing.expectEqualStrings("/tmp/codex-home/auth.json", home_path);

    var fallback = try TestEnv.install(alloc, &.{.{ "HOME", "/tmp/home" }});
    defer fallback.deinit();
    const fallback_path = (try resolveAuthFilePath(alloc)).?;
    defer alloc.free(fallback_path);
    try std.testing.expectEqualStrings("/tmp/home/.codex/auth.json", fallback_path);
}

test "copyAccountId extracts chatgpt_account_id from a ChatGPT JWT larger than 256 bytes" {
    const alloc = std.testing.allocator;
    const jwt = try encodePaddedJwt(alloc, "acct_real", 900);
    defer alloc.free(jwt);

    var tiny: [256]u8 = undefined;
    const account = copyAccountId(jwt, &tiny) orelse return error.TestExpectedAccountId;
    try std.testing.expectEqualStrings("acct_real", account);
}

test "parseLoaded reads ChatGPT tokens and JWT expiry" {
    const alloc = std.testing.allocator;
    const jwt = try encodeJwt(alloc, "{\"exp\":1700000000,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_1\"}}");
    defer alloc.free(jwt);
    const document = try std.fmt.allocPrint(alloc,
        \\{{"auth_mode":"chatgpt","tokens":{{"id_token":"{s}","access_token":"{s}","refresh_token":"refresh","account_id":"acct_1"}}}}
    , .{ jwt, jwt });
    defer alloc.free(document);

    var loaded = (try parseLoaded(alloc, document)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(jwt, loaded.access_token);
    try std.testing.expectEqualStrings("acct_1", loaded.account_id.?);
    try std.testing.expect(loaded.refreshable);
    try std.testing.expectEqual(@as(i64, (1_700_000_000 - refresh_early_seconds) * 1000), loaded.refresh_after_ms.?);
}

test "applyRefreshResponse rotates tokens and rejects account changes" {
    const alloc = std.testing.allocator;
    const next = try encodeJwt(alloc, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_1\"}}");
    defer alloc.free(next);
    const changed = try encodeJwt(alloc, "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_2\"}}");
    defer alloc.free(changed);

    const current = StoredTokens{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct_1",
    };

    const rotated_json = try std.fmt.allocPrint(
        alloc,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"new-refresh\",\"id_token\":\"{s}\"}}",
        .{ next, next },
    );
    defer alloc.free(rotated_json);
    var rotated = try std.json.parseFromSlice(std.json.Value, alloc, rotated_json, .{});
    defer rotated.deinit();
    const applied = try applyRefreshResponse(current, rotated.value.object);
    try std.testing.expectEqualStrings(next, applied.access_token);
    try std.testing.expectEqualStrings("new-refresh", applied.refresh_token);
    try std.testing.expectEqualStrings("acct_1", applied.account_id);

    const swapped_json = try std.fmt.allocPrint(
        alloc,
        "{{\"access_token\":\"{s}\",\"id_token\":\"{s}\"}}",
        .{ changed, changed },
    );
    defer alloc.free(swapped_json);
    var swapped = try std.json.parseFromSlice(std.json.Value, alloc, swapped_json, .{});
    defer swapped.deinit();
    try std.testing.expectError(error.CodexAccountChanged, applyRefreshResponse(current, swapped.value.object));
}

test "load refreshes an expired ChatGPT auth.json through the OAuth transport" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const auth_path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(auth_path);

    const expired = try encodeJwt(alloc, "{\"exp\":1,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_1\"}}");
    defer alloc.free(expired);
    const fresh = try encodeJwt(alloc, "{\"exp\":4000000000,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_1\"}}");
    defer alloc.free(fresh);
    const seed = try std.fmt.allocPrint(alloc,
        \\{{"auth_mode":"chatgpt","extra":1,"tokens":{{"id_token":"{s}","access_token":"{s}","refresh_token":"refresh-1","account_id":"acct_1"}}}}
    , .{ expired, expired });
    defer alloc.free(seed);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "auth.json", .data = seed });

    var env = try TestEnv.install(alloc, &.{.{ auth_file_env, auth_path }});
    defer env.deinit();

    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh-2\",\"id_token\":\"{s}\"}}",
        .{ fresh, fresh },
    );
    defer alloc.free(response);
    var transport_state = FakeTransportState{ .body = response, .disposition = .accepted };
    const transport = oauth_transport.Provider{
        .context = &transport_state,
        .execute_fn = FakeTransportState.execute,
    };

    var loaded = (try load(alloc, transport)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(fresh, loaded.access_token);
    try std.testing.expectEqualStrings("acct_1", loaded.account_id.?);
    try std.testing.expectEqual(@as(usize, 1), transport_state.calls);

    var rewritten_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), auth_path, .{ .mode = .read_only });
    defer rewritten_file.close(io_mod.getIo());
    const rewritten = try io_mod.readFileToEnd(alloc, &rewritten_file, max_auth_file_bytes);
    defer alloc.free(rewritten);
    try std.testing.expect(std.mem.find(u8, rewritten, "refresh-2") != null);
    try std.testing.expect(std.mem.find(u8, rewritten, "\"extra\": 1") != null or std.mem.find(u8, rewritten, "\"extra\":1") != null);
    try std.testing.expect(std.mem.find(u8, rewritten, "\"auth_mode\": \"chatgpt\"") != null or std.mem.find(u8, rewritten, "\"auth_mode\":\"chatgpt\"") != null);
}
