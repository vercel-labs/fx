const std = @import("std");
const otel = @import("opentelemetry-sdk");
const hooks = @import("../../core/hooks/hooks.zig");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const QueueCapacity = 4;
const DefaultTimeoutMs: u64 = 10_000;

pub const State = struct {
    alloc: Allocator = std.heap.c_allocator,
    env: ?std.process.Environ.Map = null,
    sdk_config: ?*otel.config.Configuration = null,
    transport_config: ?*otel.otlp.ConfigOptions = null,
    exporter: ?*otel.trace.OTLPExporter = null,
    processor: ?*otel.trace.BatchingProcessor = null,
    provider: ?*otel.trace.TracerProvider = null,
    tracer: ?*otel.api.trace.TracerImpl = null,
    prng: std.Random.DefaultPrng = .init(0),

    pub fn configure(self: *State) !void {
        self.deinit();
        if (std.ascii.eqlIgnoreCase(io_mod.getenv("OTEL_SDK_DISABLED") orelse "", "true")) return;
        const endpoint = io_mod.getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") orelse
            io_mod.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") orelse return;
        if (endpoint.len == 0) return;

        self.env = try io_mod.cloneEnvironMap(self.alloc);
        const env = &self.env.?;
        if (env.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") == null) {
            const traces_endpoint = try genericTracesEndpoint(self.alloc, endpoint);
            defer self.alloc.free(traces_endpoint);
            try env.put("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", traces_endpoint);
        }
        if (env.get("OTEL_SERVICE_NAME") == null or env.get("OTEL_SERVICE_NAME").?.len == 0)
            try env.put("OTEL_SERVICE_NAME", "fx");
        try preferSignalValue(env, "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "OTEL_EXPORTER_OTLP_PROTOCOL");
        try preferSignalValue(env, "OTEL_EXPORTER_OTLP_TRACES_COMPRESSION", "OTEL_EXPORTER_OTLP_COMPRESSION");

        self.sdk_config = try otel.config.Configuration.init(self.alloc, io_mod.getIo(), env);
        otel.config.Configuration.set(self.sdk_config.?);
        self.transport_config = try otel.otlp.ConfigOptions.init(self.alloc, env);
        self.transport_config.?.headers = env.get("OTEL_EXPORTER_OTLP_TRACES_HEADERS") orelse
            env.get("OTEL_EXPORTER_OTLP_HEADERS");
        const timeout_ms = try exporterTimeoutMs(env);
        self.transport_config.?.timeout_sec = std.math.divCeil(u64, timeout_ms, std.time.ms_per_s) catch unreachable;

        self.exporter = try otel.trace.OTLPExporter.init(self.alloc, io_mod.getIo(), self.transport_config.?);
        self.processor = try otel.trace.BatchingProcessor.init(
            self.alloc,
            io_mod.getIo(),
            self.exporter.?.asSpanExporter(),
            .{
                .max_queue_size = QueueCapacity,
                .scheduled_delay_millis = 100,
                .export_timeout_millis = timeout_ms,
                .max_export_batch_size = 1,
            },
        );
        var seed: u64 = undefined;
        io_mod.getIo().random(std.mem.asBytes(&seed));
        self.prng = .init(seed);
        self.provider = try otel.trace.TracerProvider.init(
            self.alloc,
            io_mod.getIo(),
            .{ .Random = otel.trace.RandomIDGenerator.init(self.prng.random()) },
        );
        try self.provider.?.addSpanProcessor(self.processor.?.asSpanProcessor());
        self.tracer = try self.provider.?.getTracer(.{ .name = "fx" });
    }

    pub fn shutdown(self: *State) void {
        if (self.provider) |provider| {
            provider.shutdown();
            self.provider = null;
            self.tracer = null;
        }
        if (self.processor) |processor| {
            processor.deinit();
            self.processor = null;
        }
    }

    pub fn deinit(self: *State) void {
        self.shutdown();
        if (self.exporter) |exporter| exporter.deinit();
        if (self.transport_config) |config| config.deinit();
        if (self.sdk_config) |config| config.deinit();
        if (self.env) |*env| env.deinit();
        self.exporter = null;
        self.transport_config = null;
        self.sdk_config = null;
        self.env = null;
    }

    pub fn enabled(self: *const State) bool {
        return self.tracer != null;
    }
};

fn preferSignalValue(env: *std.process.Environ.Map, signal_key: []const u8, generic_key: []const u8) !void {
    if (env.get(signal_key)) |value| try env.put(generic_key, value);
}

fn genericTracesEndpoint(allocator: Allocator, endpoint: []const u8) ![]u8 {
    const suffix_start = std.mem.findAny(u8, endpoint, "?#") orelse endpoint.len;
    const base = std.mem.trimEnd(u8, endpoint[0..suffix_start], "/");
    return std.fmt.allocPrint(allocator, "{s}/v1/traces{s}", .{ base, endpoint[suffix_start..] });
}

fn exporterTimeoutMs(env: *const std.process.Environ.Map) !u64 {
    const raw = env.get("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT") orelse
        env.get("OTEL_EXPORTER_OTLP_TIMEOUT") orelse return DefaultTimeoutMs;
    const value = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidTimeout;
    if (value == 0) return error.InvalidTimeout;
    return value;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(app: *App) !void {
            app.otel.configure() catch |err| {
                debug_trace.logf("otel", "exporter disabled during configuration error={s}", .{@errorName(err)});
                app.otel.deinit();
                return;
            };
            if (!app.otel.enabled()) return;
            errdefer app.otel.deinit();
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.otel.turn",
                .ctx = &app.otel,
                .run = postTurnEnd,
            });
        }

        fn postTurnEnd(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            const state: *State = @ptrCast(@alignCast(raw));
            recordTurn(state, input) catch |err| {
                debug_trace.logf("otel", "trace dropped error={s}", .{@errorName(err)});
            };
        }
    };
}

fn millisecondsToNanoseconds(value: i64) u64 {
    return @intCast(@as(i128, @max(value, 0)) * std.time.ns_per_ms);
}

fn recordTurn(state: *State, input: hooks.PostTurnEndInput) !void {
    const tracer = state.tracer orelse return;
    const now_ms = io_mod.milliTimestamp();
    const reported_start_ms = if (input.turn_summary) |summary| summary.started_at_ms else now_ms;
    const reported_end_ms = if (input.turn_summary) |summary| summary.completed_at_ms else now_ms;
    const start_ms = if (reported_start_ms > 0) reported_start_ms else now_ms;
    const end_ms = if (reported_end_ms >= start_ms) reported_end_ms else start_ms;

    const attributes = try otel.Attributes.from(state.alloc, .{
        "fx.turn.scope",   @tagName(input.invocation.scope.kind),
        "fx.turn.outcome", @tagName(input.outcome),
    });
    defer if (attributes) |values| state.alloc.free(values);

    var span = try tracer.startSpan(state.alloc, "fx.turn", .{
        .kind = .Internal,
        .attributes = attributes,
        .start_timestamp = millisecondsToNanoseconds(start_ms),
    });
    defer span.deinit();
    if (input.provider_disposition) |disposition| {
        try span.setAttribute("fx.turn.provider_disposition", .{ .string = @tagName(disposition) });
    }
    if (input.outcome == .failed) {
        try span.setAttribute("error.type", .{ .string = "fx.turn.failed" });
        span.setStatus(otel.api.trace.Status.error_with_description(""));
    }
    span.end(millisecondsToNanoseconds(end_ms));
    state.provider.?.onSpanEnd(span);
}

test "OTLP exporter is opt-in" {
    var state = State{ .alloc = std.testing.allocator };
    defer state.deinit();
    try std.testing.expect(!state.enabled());
}

test "OTLP timeout honors signal precedence" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("OTEL_EXPORTER_OTLP_TIMEOUT", "9000");
    try env.put("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT", "125");
    try std.testing.expectEqual(@as(u64, 125), try exporterTimeoutMs(&env));
}

test "generic OTLP endpoint inserts the traces path before its query" {
    const endpoint = try genericTracesEndpoint(std.testing.allocator, "https://collector.example/root/?tenant=a");
    defer std.testing.allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://collector.example/root/v1/traces?tenant=a", endpoint);
}
