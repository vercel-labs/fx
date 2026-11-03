//! Observed model performance used by the native model hub.
//!
//! A tracker belongs to one host runtime.  Native frontends give it their
//! profile allocator and profile root; hosted runtimes can leave the profile
//! root unset and still collect in-memory observations without touching the
//! process user's HOME.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;
const max_models = 128;
const max_model_bytes = 256;
const persisted_max_bytes = 128 * 1024;

pub const Metrics = struct {
    mru_index: ?usize = null,
    ttft_ms: ?u32 = null,
    tokens_per_second: ?f64 = null,
    requests: u64 = 0,
};

const Slot = struct {
    key: [max_model_bytes]u8 = undefined,
    key_len: usize = 0,
    first_output_total_ms: u64 = 0,
    first_output_samples: u64 = 0,
    output_tokens: u64 = 0,
    generation_ms: u64 = 0,
    requests: u64 = 0,
    last_used: u64 = 0,
};

const PersistedMetric = struct {
    model: []const u8,
    first_output_total_ms: u64,
    first_output_samples: u64,
    output_tokens: u64,
    generation_ms: u64,
    requests: u64,
    last_used: u64,
};

const PersistedFile = struct {
    version: u8,
    metrics: []PersistedMetric,
};

/// Per-host observed usage and performance state. The tracker owns `path`
/// when a profile root is supplied. A null root is intentional for hosted SDK
/// and test runtimes: no implicit HOME access or process-global state occurs.
pub const State = struct {
    allocator: Allocator,
    path: ?[]u8 = null,
    mutex: std.Io.Mutex = .init,
    slots: [max_models]Slot = @splat(.{}),
    next_use: u64 = 0,
    loaded: bool = false,

    pub fn init(allocator: Allocator, profile_root: ?[]const u8) State {
        var state: State = .{ .allocator = allocator };
        if (profile_root) |root| {
            state.path = profile_paths.modelPerformancePath(allocator, root) catch null;
        }
        return state;
    }

    pub fn deinit(self: *State) void {
        if (self.path) |path| self.allocator.free(path);
        self.path = null;
    }

    fn findLocked(self: *State, model: []const u8) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.key_len == model.len and std.mem.eql(u8, slot.key[0..slot.key_len], model)) return slot;
        }
        return null;
    }

    fn getOrCreateLocked(self: *State, model: []const u8) ?*Slot {
        if (self.findLocked(model)) |slot| return slot;
        if (model.len == 0 or model.len > max_model_bytes) return null;
        for (&self.slots) |*slot| {
            if (slot.key_len == 0) {
                @memcpy(slot.key[0..model.len], model);
                slot.key_len = model.len;
                return slot;
            }
        }
        // Keep the observed table bounded: evict the least recently used entry.
        var victim: *Slot = &self.slots[0];
        for (self.slots[1..]) |*slot| {
            if (slot.last_used < victim.last_used) victim = slot;
        }
        victim.* = .{};
        @memcpy(victim.key[0..model.len], model);
        victim.key_len = model.len;
        return victim;
    }

    /// Re-reads the profile file so a frontend host sees metrics written by
    /// its detached supervisor since the last hub open. Hosted/no-profile
    /// states remain in-memory and are deliberately not reset.
    pub fn reload(self: *State) void {
        if (self.path == null) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.slots = @splat(.{});
        self.next_use = 0;
        self.loaded = false;
        self.loadLocked();
    }

    fn loadLocked(self: *State) void {
        if (self.loaded) return;
        self.loaded = true;
        const path = self.path orelse return;
        var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch return;
        defer file.close(io_mod.getIo());
        const stat = file.stat(io_mod.getIo()) catch return;
        if (stat.kind != .file or stat.size > persisted_max_bytes) return;
        const bytes = io_mod.readFileToEnd(self.allocator, &file, persisted_max_bytes) catch return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(PersistedFile, self.allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value.version != 1) return;
        for (parsed.value.metrics) |raw| {
            if (raw.model.len == 0 or raw.model.len > max_model_bytes) continue;
            const slot = self.getOrCreateLocked(raw.model) orelse continue;
            @memcpy(slot.key[0..raw.model.len], raw.model);
            slot.key_len = raw.model.len;
            slot.first_output_total_ms = raw.first_output_total_ms;
            slot.first_output_samples = raw.first_output_samples;
            slot.output_tokens = raw.output_tokens;
            slot.generation_ms = raw.generation_ms;
            slot.requests = raw.requests;
            slot.last_used = raw.last_used;
            self.next_use = @max(self.next_use, raw.last_used);
        }
    }

    /// Writes a bounded snapshot after a mutation. Persisted model keys are
    /// duplicated before the JSON writer runs; they never point at a loop copy
    /// of `Slot` or any other temporary storage.
    fn persist(self: *State) void {
        const path = self.path orelse return;
        var text: ?[]u8 = null;
        {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            self.loadLocked();
            var metrics: std.ArrayList(PersistedMetric) = .empty;
            defer {
                for (metrics.items) |metric| self.allocator.free(metric.model);
                metrics.deinit(self.allocator);
            }
            for (self.slots) |slot| {
                if (slot.key_len == 0) continue;
                const key = self.allocator.dupe(u8, slot.key[0..slot.key_len]) catch return;
                metrics.append(self.allocator, .{
                    .model = key,
                    .first_output_total_ms = slot.first_output_total_ms,
                    .first_output_samples = slot.first_output_samples,
                    .output_tokens = slot.output_tokens,
                    .generation_ms = slot.generation_ms,
                    .requests = slot.requests,
                    .last_used = slot.last_used,
                }) catch {
                    self.allocator.free(key);
                    return;
                };
            }
            var output: std.Io.Writer.Allocating = .init(self.allocator);
            defer output.deinit();
            std.json.Stringify.value(PersistedFile{ .version = 1, .metrics = metrics.items }, .{}, &output.writer) catch return;
            text = self.allocator.dupe(u8, output.written()) catch return;
        }
        defer self.allocator.free(text.?);
        io_mod.writeFileAtomic(self.allocator, path, text.?) catch {};
    }

    /// Called when the first non-empty streamed output arrives.
    pub fn recordFirstOutput(self: *State, model: []const u8, started_at_ms: i64, output_at_ms: i64) void {
        if (output_at_ms <= started_at_ms) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.loadLocked();
        const slot = self.getOrCreateLocked(model) orelse {
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        slot.first_output_total_ms +|= @intCast(@min(output_at_ms - started_at_ms, std.math.maxInt(u32)));
        slot.first_output_samples +|= 1;
        self.mutex.unlock(io_mod.getIo());
        // TTFT is part of the durable observed metric, not merely a live
        // stream hint; persist it so a detached frontend can reload it.
        self.persist();
    }

    /// Records a model selection in the durable MRU order.
    pub fn recordUsage(self: *State, model: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.loadLocked();
        const slot = self.getOrCreateLocked(model) orelse {
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        self.next_use +|= 1;
        slot.last_used = self.next_use;
        self.mutex.unlock(io_mod.getIo());
        self.persist();
    }

    /// Called once per completed provider request. Failed requests do not
    /// pollute throughput, but a successful request still updates MRU.
    pub fn recordCompletion(self: *State, model: []const u8, duration_ms: i64, output_tokens: u32, status: u16) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.loadLocked();
        const slot = self.getOrCreateLocked(model) orelse {
            self.mutex.unlock(io_mod.getIo());
            return;
        };
        self.next_use +|= 1;
        slot.last_used = self.next_use;
        if (status >= 200 and status < 300) {
            slot.requests +|= 1;
            if (output_tokens > 0 and duration_ms > 0) {
                slot.output_tokens +|= output_tokens;
                slot.generation_ms +|= @intCast(duration_ms);
            }
        }
        self.mutex.unlock(io_mod.getIo());
        self.persist();
    }

    pub fn snapshot(self: *State, model: []const u8) Metrics {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.loadLocked();
        const slot = self.findLocked(model) orelse return .{};
        var rank: usize = 0;
        if (slot.last_used > 0) for (self.slots) |other| {
            if (other.key_len > 0 and other.last_used > slot.last_used) rank += 1;
        };
        return .{
            .mru_index = if (slot.last_used > 0) rank else null,
            .ttft_ms = if (slot.first_output_samples > 0) @intCast(slot.first_output_total_ms / slot.first_output_samples) else null,
            .tokens_per_second = if (slot.generation_ms > 0 and slot.output_tokens > 0)
                @as(f64, @floatFromInt(slot.output_tokens)) * 1000.0 / @as(f64, @floatFromInt(slot.generation_ms))
            else
                null,
            .requests = slot.requests,
        };
    }

    pub fn reset(self: *State) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.slots = @splat(.{});
        self.next_use = 0;
        // A reset is process-local (used by tests and explicit session reset);
        // do not rehydrate the old profile file on the next read in this state.
        self.loaded = true;
    }
};
