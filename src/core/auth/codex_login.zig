const std = @import("std");
const codex_oauth = @import("codex_oauth.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const login_timeout_ns: u64 = 15 * std.time.ns_per_min;
const poll_slice_ms: u64 = 100;

pub const Error = error{
    DeviceCodeUnavailable,
    InvalidDeviceCodeResponse,
    InvalidAuthorizationGrant,
    InvalidTokenExchange,
    LoginTimedOut,
    AccessDenied,
    HomeNotSet,
};

pub const DeviceCode = struct {
    verification_url: []u8,
    user_code: []u8,
    device_auth_id: []u8,
    interval_ns: u64,

    pub fn deinit(self: *DeviceCode, alloc: Allocator) void {
        alloc.free(self.verification_url);
        alloc.free(self.user_code);
        secret.zeroAndFree(alloc, self.device_auth_id);
        self.* = undefined;
    }
};

pub const AuthorizationGrant = struct {
    authorization_code: []u8,
    code_verifier: []u8,
    code_challenge: []u8,

    pub fn deinit(self: *AuthorizationGrant, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.authorization_code);
        secret.zeroAndFree(alloc, self.code_verifier);
        alloc.free(self.code_challenge);
        self.* = undefined;
    }
};

pub const PollResult = union(enum) {
    pending,
    success: AuthorizationGrant,
};

pub fn requestDeviceCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !DeviceCode {
    const client_id = codex_oauth.oauth_client_id;
    const url = try std.fmt.allocPrint(alloc, "{s}/api/accounts/deviceauth/usercode", .{codex_oauth.issuer()});
    defer alloc.free(url);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(client_id, .{}, &payload.writer);
    try payload.writer.writeByte('}');

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = payload.written(),
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        if (response.status == .not_found) return Error.DeviceCodeUnavailable;
        return Error.InvalidDeviceCodeResponse;
    }
    return parseDeviceCode(alloc, response.body);
}

pub fn parseDeviceCode(alloc: Allocator, bytes: []const u8) !DeviceCode {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.InvalidDeviceCodeResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidDeviceCodeResponse;
    const object = parsed.value.object;
    const device_auth_id = objectString(object, "device_auth_id") orelse
        return Error.InvalidDeviceCodeResponse;
    const user_code = objectString(object, "user_code") orelse
        objectString(object, "usercode") orelse
        return Error.InvalidDeviceCodeResponse;
    if (device_auth_id.len == 0 or user_code.len == 0) return Error.InvalidDeviceCodeResponse;
    const interval_s = objectIntervalSeconds(object);

    const verification_url = try std.fmt.allocPrint(alloc, "{s}/codex/device", .{codex_oauth.issuer()});
    errdefer alloc.free(verification_url);
    return .{
        .verification_url = verification_url,
        .user_code = try alloc.dupe(u8, user_code),
        .device_auth_id = try alloc.dupe(u8, device_auth_id),
        .interval_ns = interval_s * std.time.ns_per_s,
    };
}

pub fn pollAuthorizationGrant(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    device: DeviceCode,
    cancel_flag: ?*std.atomic.Value(bool),
) !PollResult {
    const url = try std.fmt.allocPrint(alloc, "{s}/api/accounts/deviceauth/token", .{codex_oauth.issuer()});
    defer alloc.free(url);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"device_auth_id\":");
    try std.json.Stringify.value(device.device_auth_id, .{}, &payload.writer);
    try payload.writer.writeAll(",\"user_code\":");
    try std.json.Stringify.value(device.user_code, .{}, &payload.writer);
    try payload.writer.writeByte('}');

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = payload.written(),
        .cancel_flag = cancel_flag,
    });
    defer response.deinit(alloc);
    if (response.disposition == .accepted) {
        return .{ .success = try parseAuthorizationGrant(alloc, response.body) };
    }
    if (isPendingStatus(response.status)) return .pending;
    if (response.status == .unauthorized) return Error.AccessDenied;
    return Error.InvalidAuthorizationGrant;
}

pub fn parseAuthorizationGrant(alloc: Allocator, bytes: []const u8) !AuthorizationGrant {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.InvalidAuthorizationGrant,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidAuthorizationGrant;
    const object = parsed.value.object;
    const authorization_code = objectString(object, "authorization_code") orelse
        return Error.InvalidAuthorizationGrant;
    const code_verifier = objectString(object, "code_verifier") orelse
        return Error.InvalidAuthorizationGrant;
    const code_challenge = objectString(object, "code_challenge") orelse "";
    if (authorization_code.len == 0 or code_verifier.len == 0) return Error.InvalidAuthorizationGrant;
    return .{
        .authorization_code = try alloc.dupe(u8, authorization_code),
        .code_verifier = try alloc.dupe(u8, code_verifier),
        .code_challenge = try alloc.dupe(u8, code_challenge),
    };
}

pub fn exchangeAuthorizationGrant(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    grant: AuthorizationGrant,
) !codex_oauth.StoredTokens {
    const redirect_uri = try std.fmt.allocPrint(
        alloc,
        "{s}/deviceauth/callback",
        .{codex_oauth.issuer()},
    );
    defer alloc.free(redirect_uri);

    var form: FormBody = .{};
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try form.append(&writer.writer, "grant_type", "authorization_code");
    try form.append(&writer.writer, "code", grant.authorization_code);
    try form.append(&writer.writer, "redirect_uri", redirect_uri);
    try form.append(&writer.writer, "client_id", codex_oauth.oauth_client_id);
    try form.append(&writer.writer, "code_verifier", grant.code_verifier);

    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = codex_oauth.tokenUrl(),
        .payload = writer.written(),
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return Error.InvalidTokenExchange;
    return parseExchangedTokens(alloc, response.body);
}

pub fn parseExchangedTokens(alloc: Allocator, bytes: []const u8) !codex_oauth.StoredTokens {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.InvalidTokenExchange,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidTokenExchange;
    const object = parsed.value.object;
    const id_token = objectString(object, "id_token") orelse return Error.InvalidTokenExchange;
    const access_token = objectString(object, "access_token") orelse return Error.InvalidTokenExchange;
    const refresh_token = objectString(object, "refresh_token") orelse return Error.InvalidTokenExchange;
    if (id_token.len == 0 or access_token.len == 0 or refresh_token.len == 0) {
        return Error.InvalidTokenExchange;
    }

    var account_buf: [256]u8 = undefined;
    const account_id = objectString(object, "account_id") orelse
        codex_oauth.copyAccountId(id_token, &account_buf) orelse
        return Error.InvalidTokenExchange;

    return .{
        .id_token = try alloc.dupe(u8, id_token),
        .access_token = try alloc.dupe(u8, access_token),
        .refresh_token = try alloc.dupe(u8, refresh_token),
        .account_id = try alloc.dupe(u8, account_id),
    };
}

pub fn completeLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    device: DeviceCode,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const deadline_ns = started.raw.nanoseconds + login_timeout_ns;
    while (true) {
        if (cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (now.raw.nanoseconds >= deadline_ns) return Error.LoginTimedOut;

        switch (try pollAuthorizationGrant(alloc, transport, device, cancel_flag)) {
            .pending => {},
            .success => |grant_value| {
                var grant = grant_value;
                defer grant.deinit(alloc);
                const tokens = try exchangeAuthorizationGrant(alloc, transport, grant);
                defer {
                    secret.zeroAndFree(alloc, @constCast(tokens.id_token));
                    secret.zeroAndFree(alloc, @constCast(tokens.access_token));
                    secret.zeroAndFree(alloc, @constCast(tokens.refresh_token));
                    alloc.free(tokens.account_id);
                }
                try codex_oauth.persistTokens(alloc, tokens);
                return;
            },
        }

        const now_ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake).raw.nanoseconds;
        if (now_ns >= deadline_ns) return Error.LoginTimedOut;
        const remaining_ns: u64 = @intCast(deadline_ns - now_ns);
        const wait_ns: u64 = if (device.interval_ns == 0) 0 else @min(device.interval_ns, remaining_ns);
        try sleepCancellable(wait_ns, cancel_flag);
    }
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var device = try requestDeviceCode(alloc, transport);
    defer device.deinit(alloc);

    try writeStdout("Open ");
    try writeStdout(device.verification_url);
    try writeStdout("\nCode: ");
    try writeStdout(device.user_code);
    try writeStdout("\n\nThe code expires in 15 minutes. Continue only if you started this login in fx.\n\n");

    _ = url_opener.open(alloc, device.verification_url) catch false;
    try writeStdout("Waiting for authorization...\n");
    try completeLogin(alloc, transport, device, null);
    try writeStdout("Signed in to ChatGPT Codex.\n");
}

fn isPendingStatus(status: ?std.http.Status) bool {
    return status == .forbidden or status == .not_found;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn objectIntervalSeconds(object: std.json.ObjectMap) u64 {
    const value = object.get("interval") orelse return 5;
    return switch (value) {
        .integer => |integer| if (integer < 0) 0 else @intCast(integer),
        .string => |text| std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t"), 10) catch 5,
        else => 5,
    };
}

const FormBody = struct {
    first: bool = true,

    fn append(self: *FormBody, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (!self.first) try writer.writeAll("&");
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeAll("=");
        try percentEncode(writer, value);
    }
};

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn sleepCancellable(wait_ns: u64, cancel_flag: ?*std.atomic.Value(bool)) !void {
    if (wait_ns == 0) return;
    var remaining = wait_ns;
    const slice_ns = poll_slice_ms * std.time.ns_per_ms;
    while (remaining > 0) {
        if (cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        const slice = @min(remaining, slice_ns);
        io_mod.sleep(slice);
        remaining -= slice;
    }
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

const ScriptedTransport = struct {
    responses: []const ScriptedResponse,
    index: usize = 0,
    last_url: []const u8 = "",
    last_payload: []const u8 = "",
    last_method: ?oauth_transport.Method = null,

    const ScriptedResponse = struct {
        disposition: oauth_transport.Disposition,
        status: std.http.Status,
        body: []const u8,
    };

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.last_url = request.url;
        self.last_payload = request.payload orelse "";
        self.last_method = request.method;
        if (self.index >= self.responses.len) return error.UnexpectedOAuthRequest;
        const next = self.responses[self.index];
        self.index += 1;
        return .{
            .disposition = next.disposition,
            .status = next.status,
            .body = try alloc.dupe(u8, next.body),
        };
    }

    fn provider(self: *@This()) oauth_transport.Provider {
        return .{
            .context = self,
            .execute_fn = execute,
        };
    }
};

test "parseDeviceCode accepts string intervals and usercode aliases" {
    const alloc = std.testing.allocator;
    var device = try parseDeviceCode(
        alloc,
        "{\"device_auth_id\":\"auth-1\",\"usercode\":\"ABCD-1234\",\"interval\":\"2\"}",
    );
    defer device.deinit(alloc);
    try std.testing.expectEqualStrings("auth-1", device.device_auth_id);
    try std.testing.expectEqualStrings("ABCD-1234", device.user_code);
    try std.testing.expectEqual(@as(u64, 2 * std.time.ns_per_s), device.interval_ns);
    try std.testing.expect(std.mem.endsWith(u8, device.verification_url, "/codex/device"));
}

test "device-code poll treats 403 as pending then exchanges the grant" {
    const alloc = std.testing.allocator;
    var pending = ScriptedTransport{
        .responses = &.{
            .{ .disposition = .rejected, .status = .forbidden, .body = "pending" },
        },
    };
    var device = try parseDeviceCode(
        alloc,
        "{\"device_auth_id\":\"auth-1\",\"user_code\":\"CODE\",\"interval\":0}",
    );
    defer device.deinit(alloc);
    try std.testing.expectEqual(
        std.meta.Tag(PollResult).pending,
        std.meta.activeTag(try pollAuthorizationGrant(
            alloc,
            pending.provider(),
            device,
            null,
        )),
    );

    var ready = ScriptedTransport{
        .responses = &.{
            .{
                .disposition = .accepted,
                .status = .ok,
                .body = "{\"authorization_code\":\"abc\",\"code_verifier\":\"verifier\",\"code_challenge\":\"challenge\"}",
            },
        },
    };
    var grant = switch (try pollAuthorizationGrant(alloc, ready.provider(), device, null)) {
        .pending => return error.TestExpectedGrant,
        .success => |value| value,
    };
    defer grant.deinit(alloc);
    try std.testing.expectEqualStrings("abc", grant.authorization_code);
    try std.testing.expectEqualStrings("verifier", grant.code_verifier);
}

test "parseExchangedTokens extracts account id from a realistic ChatGPT JWT" {
    const alloc = std.testing.allocator;
    const jwt = try encodePaddedJwt(alloc, "acct_login_real", 900);
    defer alloc.free(jwt);
    const token_json = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh-login\"}}",
        .{ jwt, jwt },
    );
    defer alloc.free(token_json);

    const tokens = try parseExchangedTokens(alloc, token_json);
    defer {
        secret.zeroAndFree(alloc, @constCast(tokens.id_token));
        secret.zeroAndFree(alloc, @constCast(tokens.access_token));
        secret.zeroAndFree(alloc, @constCast(tokens.refresh_token));
        alloc.free(tokens.account_id);
    }
    try std.testing.expectEqualStrings("acct_login_real", tokens.account_id);
}

test "token exchange posts the Codex device-callback form and persists ChatGPT tokens" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const auth_path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(auth_path);

    const encoder = std.base64.url_safe_no_pad.Encoder;
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_login\"}}";
    const encoded_len = encoder.calcSize(payload.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, payload);
    const jwt = try std.fmt.allocPrint(alloc, "e30.{s}.sig", .{encoded});
    defer alloc.free(jwt);
    const token_json = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh-login\"}}",
        .{ jwt, jwt },
    );
    defer alloc.free(token_json);

    var env = try TestEnv.install(alloc, &.{
        .{ codex_oauth.auth_file_env, auth_path },
        .{ codex_oauth.issuer_env, "https://auth.openai.com" },
    });
    defer env.deinit();

    var grant = AuthorizationGrant{
        .authorization_code = try alloc.dupe(u8, "abc"),
        .code_verifier = try alloc.dupe(u8, "verifier"),
        .code_challenge = try alloc.dupe(u8, "challenge"),
    };
    defer grant.deinit(alloc);

    var transport = ScriptedTransport{
        .responses = &.{
            .{ .disposition = .accepted, .status = .ok, .body = token_json },
        },
    };
    const tokens = try exchangeAuthorizationGrant(alloc, transport.provider(), grant);
    defer {
        secret.zeroAndFree(alloc, @constCast(tokens.id_token));
        secret.zeroAndFree(alloc, @constCast(tokens.access_token));
        secret.zeroAndFree(alloc, @constCast(tokens.refresh_token));
        alloc.free(tokens.account_id);
    }
    try std.testing.expectEqualStrings("acct_login", tokens.account_id);
    try std.testing.expect(transport.last_method == .post_form);
    try std.testing.expect(std.mem.find(u8, transport.last_payload, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.find(u8, transport.last_payload, "redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback") != null);

    try codex_oauth.persistTokens(alloc, tokens);
    var loaded = (try codex_oauth.loadStored(alloc)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("acct_login", loaded.account_id.?);
    try std.testing.expectEqualStrings(jwt, loaded.access_token);
}

test "completeLogin walks pending poll then token exchange" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const auth_path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(auth_path);

    const encoder = std.base64.url_safe_no_pad.Encoder;
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_done\"}}";
    const encoded_len = encoder.calcSize(payload.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, payload);
    const jwt = try std.fmt.allocPrint(alloc, "e30.{s}.sig", .{encoded});
    defer alloc.free(jwt);
    const token_json = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh-done\"}}",
        .{ jwt, jwt },
    );
    defer alloc.free(token_json);

    var env = try TestEnv.install(alloc, &.{
        .{ codex_oauth.auth_file_env, auth_path },
    });
    defer env.deinit();

    var device = try parseDeviceCode(
        alloc,
        "{\"device_auth_id\":\"auth-1\",\"user_code\":\"CODE\",\"interval\":0}",
    );
    defer device.deinit(alloc);

    var transport = ScriptedTransport{
        .responses = &.{
            .{ .disposition = .rejected, .status = .forbidden, .body = "wait" },
            .{
                .disposition = .accepted,
                .status = .ok,
                .body = "{\"authorization_code\":\"abc\",\"code_verifier\":\"verifier\",\"code_challenge\":\"challenge\"}",
            },
            .{ .disposition = .accepted, .status = .ok, .body = token_json },
        },
    };
    try completeLogin(alloc, transport.provider(), device, null);
    try std.testing.expectEqual(@as(usize, 3), transport.index);
    var loaded = (try codex_oauth.loadStored(alloc)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("acct_done", loaded.account_id.?);
}

var stable_login_test_environ: ?*std.process.Environ.Map = null;

fn stableLoginTestEnviron() !*const std.process.Environ.Map {
    if (stable_login_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_login_test_environ = map;
    return map;
}

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

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const [2][]const u8) !*TestEnv {
        _ = try stableLoginTestEnviron();
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
        if (stable_login_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};
