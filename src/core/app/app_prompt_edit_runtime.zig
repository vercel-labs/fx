//! Private native-editor exchange. The caller owns composer and submission state.
const std = @import("std");
const builtin = @import("builtin");
const agents = @import("../agents/agents.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const lifecycle = @import("app_lifecycle.zig");
const Allocator = std.mem.Allocator;
const document_name = "prompt.md";

/// Borrows seed and owner. Returns caller-owned prompt text, or null on
/// cancellation/empty input. Never changes the composer or submits a turn.
fn edit(comptime App: type, app: *App, owner: *agents.Agent, seed: []const u8) !?[]u8 {
    if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.EditorUnavailable;
    try checkArchive(owner);
    var editor = try parseEditor(app.alloc, selectedEditor(io_mod.getenv("VISUAL"), io_mod.getenv("EDITOR")) orelse return error.EditorNotConfigured);
    defer editor.deinit(app.alloc);
    const argv = try app.alloc.alloc([]const u8, editor.tokens.len + 1);
    defer app.alloc.free(argv);
    for (editor.tokens, 0..) |token, i| argv[i] = token.value;

    var scratch = try Scratch.create(app.alloc);
    defer scratch.deinit();
    const absolute_dir = try io_mod.dirRealpathAlloc(app.alloc, scratch.dir, ".");
    defer app.alloc.free(absolute_dir);
    const absolute_file = try std.Io.Dir.path.join(app.alloc, &.{ absolute_dir, document_name });
    defer app.alloc.free(absolute_file);
    argv[editor.tokens.len] = absolute_file;
    const markers = Markers.fresh();
    {
        var file = try scratch.dir.createFile(io_mod.getIo(), document_name, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        defer file.close(io_mod.getIo());
        var buffer: [8192]u8 = undefined;
        var writer = file.writer(io_mod.getIo(), &buffer);
        try writeDocument(&writer.interface, owner, app.alloc, seed, &markers);
        try writer.interface.flush();
    }
    // Scan what was actually written: a stored message or seed must not be
    // mistaken for a second expected boundary, even before the editor runs.
    _ = try readDocument(app.alloc, scratch.dir, &markers, 0, false);
    const term = lifecycle.runExternalInteractive(&app.terminal, &app.shell, &app.metrics, App.footer_rows, argv, scratch.dir) catch |err| switch (err) {
        error.EditorInterrupted => return null,
        else => return err,
    };
    switch (term) {
        .exited => |code| if (code != 0) return error.EditorFailed,
        else => return error.EditorFailed,
    }
    return readDocument(app.alloc, scratch.dir, &markers, App.input_limits.composer_bytes, true);
}

/// One main-thread request. The original invocation stays in the live composer.
pub const Request = struct { owner: *agents.Agent, seed: []u8, suffix_discarded: bool = false };

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn request(app: *App, seed: []const u8) !void {
            const owner = agents.screenAgentOf(app);
            if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) {
                return notice(app, "The external editor is unavailable on this host.");
            }
            if (owner.role != .instance) return notice(app, "/edit is unavailable on a subagent screen.");
            if (owner.pending_images.items.len != 0 or app.input_runtime.entities.skill_tokens.items.len != 0 or app.input_runtime.entities.image_tokens.items.len != 0) return notice(app, "/edit does not support image attachments or bound skills. Remove them before editing.");
            if (app.prompt_edit_request != null) return;
            if (!hostQuiet(app)) return notice(app, "/edit needs an idle host. Finish pending work before editing.");
            app.prompt_edit_request = .{ .owner = owner, .seed = try app.alloc.dupe(u8, seed) };
            app.shell.render_requests.request(.footer);
        }

        pub fn run(app: *App, max_prompt_history: usize) !void {
            if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return;
            const request_value = app.prompt_edit_request orelse return;
            // Clear before ordinary admission; no callbacks or fact collection
            // run between releasing the editor holds and that admission.
            defer {
                app.alloc.free(request_value.seed);
                app.prompt_edit_request = null;
                app.shell.render_requests.request(.footer);
            }
            if (request_value.owner != agents.screenAgentOf(app)) return notice(app, "/edit target changed; nothing was sent.");
            if (app.prompt_edit_request.?.suffix_discarded) try notice(app, "Input that arrived right after /edit was ignored.");
            if (!hostQuiet(app)) return notice(app, "/edit needs an idle host. Finish pending work before editing.");
            var held: usize = 0;
            defer releaseHolds(app, held);
            if (!app.main_agent.worker.tryHoldTurnStart()) return notice(app, "/edit needs an idle host.");
            held = 1;
            for (app.child_agents.items) |child| {
                if (!child.agent.worker.tryHoldTurnStart()) return notice(app, "/edit needs an idle host.");
                held += 1;
            }
            // quiet() accounts for direct subagent execution before it starts;
            // handoffs count reports before a tree becomes quiet. Together with
            // every root worker held, there is no producer left to start work.
            if (!hostQuiet(app)) return notice(app, "/edit needs an idle host.");
            defer app.program_status.invalidate();
            const text = edit(App, app, request_value.owner, request_value.seed) catch |err| {
                var buffer: [192]u8 = undefined;
                const body = switch (err) {
                    error.EditorNotConfigured => "Set VISUAL or EDITOR to a foreground editor (use its wait option for GUI editors), then retry /edit.",
                    error.HistoryDamaged, error.HistoryUnavailable => "/edit cannot export the complete saved history. Nothing was sent; the invocation is preserved.",
                    error.EditorRequiresAbsoluteExecutable => "Use an absolute editor executable path, or a command found on PATH, then retry /edit.",
                    error.EditorTerminalRestoreFailed, error.EditorWaitFailed => return err,
                    else => std.mem.print(&buffer, "External editor failed ({s}); nothing was sent. Your /edit invocation is preserved.", .{@errorName(err)}) catch "External editor failed; nothing was sent.",
                };
                return notice(app, body);
            };
            defer if (text) |owned| app.alloc.free(owned);
            releaseHolds(app, held);
            held = 0;
            app.program_status.invalidate();
            if (text) |prompt| {
                _ = @import("input_submit_runtime.zig").SubmitRuntime(App).submitLiteral(app, request_value.owner, prompt, max_prompt_history) catch |err| {
                    // Prepared replacement preserves the invocation on OOM;
                    // later failures leave the edited prompt in the composer.
                    var buffer: [160]u8 = undefined;
                    try notice(app, std.mem.print(&buffer, "Edited prompt was not sent ({s}); the draft is still in the composer.", .{@errorName(err)}) catch "Edited prompt was not sent; the draft is still in the composer.");
                    return;
                };
            } else try notice(app, "Editor cancelled or prompt empty; nothing was sent.");
        }

        fn releaseHolds(app: *App, held: usize) void {
            if (held == 0) return;
            for (app.child_agents.items[0 .. held - 1]) |child| child.agent.worker.releaseTurnStartHold();
            app.main_agent.worker.releaseTurnStartHold();
        }

        fn agentQuiet(agent: *agents.Agent) bool {
            if (agent.submission.pending != null or agent.submission.launch_prompt != null or agent.submission.compaction_pending or agent.stream.active or agent.worker.isProcessing() or agent.worker.queuedPromptCount() != 0 or agent.worker.hasPendingEvents() or agent.worker.contextCompactionStatus() != .idle or agent.approval_prompt.isActive() or agent.question_prompt.isActive()) return false;
            const saved = &agent.session_persistence;
            if (saved.pending_live_session_policy != null or saved.pending_live_session_wait != null or saved.pending_request_resume != null or saved.pending_cancelled_command != null) return false;
            if (saved.subagent_host) |host| if (!host.quiet()) return false;
            if (agent.child_run) |*run_state| if (run_state.inFlight()) return false;
            return true;
        }

        fn hostQuiet(app: *App) bool {
            if (app.pacer.hasPending() or app.main_screen.pacer.hasPending() or app.shell.sessionScrollbackHandoffPending() or app.terminal.alternate_screen_owner != .none or app.auth.picker_active or app.auth.prompt_credential_refresh_task != null or app.auth.providerPreparationPending() or app.auth.startupCredentialPending()) return false;
            if (!agentQuiet(&app.main_agent)) return false;
            for (app.child_agents.items) |child| if (!agentQuiet(&child.agent) or child.screen.pacer.hasPending()) return false;
            app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_handoffs.mutex.unlock(io_mod.getIo());
            return app.child_handoffs.posts.items.len == 0 and app.child_handoffs.reports.items.len == 0;
        }

        fn notice(app: *App, body: []const u8) !void {
            try app.writeDomainNotice(.{ .topic = "edit", .tone = .neutral, .body = body }, true);
        }
    };
}

/// Refuses known missing saved turns before any editor or export I/O.
pub fn checkArchive(owner: anytype) !void {
    if (owner.session_persistence.shutdown_failure != null or owner.session_persistence.degraded_warning_emitted) return error.HistoryUnavailable;
    if (owner.session_persistence.v2 == null and owner.session.historyLen() != 0) return error.HistoryUnavailable;
}

fn selectedEditor(visual: ?[]const u8, editor: ?[]const u8) ?[]const u8 {
    if (visual) |value| if (std.mem.trim(u8, value, " \t\r\n").len != 0) return value;
    if (editor) |value| if (std.mem.trim(u8, value, " \t\r\n").len != 0) return value;
    return null;
}

fn parseEditor(alloc: Allocator, command: []const u8) !command_lex.Argv {
    var result = try command_lex.tokenize_argv(alloc, command);
    errdefer result.deinit(alloc);
    if (result.tokens.len == 0 or result.tokens[0].value.len == 0) return error.EditorNotConfigured;
    if (command_lex.unsafe_compound_indicator(command)) return error.EditorShellSyntax;
    for (result.tokens) |token| {
        // Quoted/escaped punctuation is an ordinary argument. Only raw lexer
        // operators are forbidden; nothing here is evaluated by a shell.
        if (!token.quoted and std.mem.eql(u8, token.raw, token.value)) {
            if (command_lex.redirection_kind(token.value) != null or
                std.mem.eql(u8, token.value, "|") or std.mem.eql(u8, token.value, "&") or
                std.mem.eql(u8, token.value, "&&") or std.mem.eql(u8, token.value, "||")) return error.EditorShellSyntax;
        }
    }
    const exe = result.tokens[0].value;
    if (std.mem.findScalar(u8, exe, '/') != null and !std.Io.Dir.path.isAbsolute(exe)) return error.EditorRequiresAbsoluteExecutable;
    return result;
}

const Markers = struct {
    begin: [57]u8,
    end: [55]u8,

    fn fresh() Markers {
        var bytes: [16]u8 = undefined;
        io_mod.getIo().random(&bytes);
        return fromNonce(std.fmt.bytesToHex(bytes, .lower));
    }

    fn fromNonce(nonce: [32]u8) Markers {
        var result: Markers = undefined;
        _ = std.mem.print(&result.begin, "<!-- fx:prompt:begin:{s} -->", .{nonce}) catch unreachable;
        _ = std.mem.print(&result.end, "<!-- fx:prompt:end:{s} -->", .{nonce}) catch unreachable;
        return result;
    }
};

fn writeDocument(writer: *std.Io.Writer, owner: *agents.Agent, alloc: Allocator, seed: []const u8, markers: *const Markers) !void {
    try writer.print("# Your prompt\n\n{s}\n", .{markers.begin});
    // Normalize the seed before adding the framing LF, so a trailing lone CR
    // cannot absorb that extra LF and lose a user-authored newline.
    var start: usize = 0;
    var i: usize = 0;
    while (i < seed.len) : (i += 1) {
        if (seed[i] != '\r') continue;
        try writer.writeAll(seed[start..i]);
        try writer.writeAll("\n");
        if (i + 1 < seed.len and seed[i + 1] == '\n') i += 1;
        start = i + 1;
    }
    try writer.writeAll(seed[start..]);
    try writer.print("\n{s}\n\n# Conversation history (reference only)\n", .{markers.end});
    var visitor: TurnWriter = .{ .writer = writer };
    if (owner.session_persistence.v2) |session| try session.visitHistoryChecked(alloc, &visitor);
}

const TurnWriter = struct {
    writer: *std.Io.Writer,
    count: usize = 0,

    pub fn append(self: *TurnWriter, turn: types.HistoryTurn) !void {
        switch (turn) {
            .compacted_summary => return error.HistoryUnavailable,
            .assistant => |entry| {
                try self.open(entry.user);
                try self.execution(entry.execution);
                try self.writer.print("\n### Assistant (final)\n{s}\n", .{entry.assistant});
            },
            .interrupted => |entry| {
                try self.open(entry.user);
                try self.execution(entry.execution);
                if (entry.assistant) |text| try self.writer.print("\n### Assistant (interrupted)\n{s}\n", .{text});
                if (entry.tool_call) |call| {
                    try self.writer.writeAll("\n### Interrupted tool call\n");
                    try self.writeCall(call);
                }
                for (entry.completed_tool_names) |name| try self.writer.print("Completed tool: {s}\n", .{name});
                if (entry.cancelled_command) |command| {
                    if (command.command_artifact_handle) |handle| try self.writer.print("Command artifact: {s}\n", .{handle});
                    if (command.output_replay) |replay| try self.writeReplay(replay);
                }
                try self.writer.print("\nTurn interrupted: {s}; origin: {s}; process exited: {}\n", .{ @tagName(entry.terminal_reason), @tagName(entry.cancellation_origin), entry.stopped_by_exit });
            },
        }
    }

    fn open(self: *TurnWriter, user: types.UserTurn) !void {
        self.count += 1;
        try self.writer.print("\n## Turn {d}\n\n### Opening message ({s})\n{s}\n", .{ self.count, @tagName(user.author), user.text });
        for (user.images) |image| {
            try self.writer.print("Image {d}: {s} ({s})\n", .{ image.id, image.path, image.media_type });
            if (image.blob_path) |path| try self.writer.print("Image blob: {s}\n", .{path});
            if (image.snapshot_path) |path| try self.writer.print("Image snapshot: {s}\n", .{path});
            if (image.snapshot_sha256) |digest| try self.writer.print("Image digest: {s}\n", .{digest});
            if (image.source_ref) |ref| try self.writer.print("Image reference: {s}\n", .{ref});
        }
    }

    fn execution(self: *TurnWriter, memory: types.ExecutionMemory) !void {
        var note: usize = 0;
        var steering: usize = 0;
        for (0..memory.tool_steps.len + 1) |boundary| {
            while (note < memory.context_notes.len and memory.context_notes[note].after_tool_step_count == boundary) : (note += 1) {
                const item = memory.context_notes[note];
                try self.writer.print("\n### Context note\n{s}\n", .{item.text});
                for (item.sources) |source| try self.writer.print("Source: {s} (stamp {d})\n", .{ source.path, source.stamp });
            }
            while (steering < memory.steering.len and memory.steering[steering].after_tool_step_count == boundary) : (steering += 1) {
                const item = memory.steering[steering];
                if (item.assistant_prefix) |text| try self.writer.print("\n### Assistant\n{s}\n", .{text});
                try self.writer.print("\n### User steering\n{s}\n", .{item.text});
            }
            if (boundary == memory.tool_steps.len) break;
            const step = memory.tool_steps[boundary];
            if (step.assistant) |text| try self.writer.print("\n### Assistant\n{s}\n", .{text});
            for (step.tool_calls) |call| try self.writeCall(call);
            for (step.tool_results) |result| {
                try self.writer.print("\n### Tool result: {s} ({s}, {s})\n{s}\n", .{ result.tool_name, result.tool_call_id, @tagName(result.status), result.output });
                if (result.preview) |preview| try self.writer.print("Stored preview:\n{s}\n", .{preview});
                if (result.output_handle) |handle| try self.writer.print("Output handle: {s}\n", .{handle});
                if (result.tool_image_handle) |handle| try self.writer.print("Tool image handle: {s}\n", .{handle});
                try self.writer.print("Output bytes: {d}; stored bytes: {d}; truncated: {}\n", .{ result.output_bytes, result.stored_output_bytes, result.truncated });
                if (result.committed_file_presentation) |file| {
                    try self.writer.print("File change: {s} ({s})\n", .{ file.path, @tagName(file.kind) });
                    if (file.content_handle) |handle| try self.writer.print("File content handle: {s}\n", .{handle});
                }
                if (result.command_output_replay) |replay| try self.writeReplay(replay);
                for (result.tool_images) |image| {
                    try self.writer.print("Tool image: {s}\n", .{image.mime_type});
                    if (image.source_ref) |ref| try self.writer.print("Image reference: {s}\n", .{ref});
                    if (image.name) |name| try self.writer.print("Image digest: {s}\n", .{name});
                }
                for (result.permission_feedback) |feedback| try self.writer.print("\n### Permission feedback\n{s}\n", .{feedback});
            }
        }
        // Out-of-order or impossible boundaries cannot be presented as a
        // complete chronological transcript.
        if (note != memory.context_notes.len or steering != memory.steering.len) return error.HistoryDamaged;
    }

    fn writeCall(self: *TurnWriter, value: types.ToolCall) !void {
        try self.writer.print("\n### Tool call: {s} ({s})\n{s}\n", .{ value.name, value.id, value.arguments_json });
        if (value.provider_result) |result| try self.writer.print("Provider tool result:\n{s}\n", .{result});
    }

    fn writeReplay(self: *TurnWriter, value: types.CommandOutputReplay) !void {
        switch (value) {
            .available => |saved| try self.writer.print("Command replay: {s} ({d} bytes)\n", .{ saved.handle, saved.framed_bytes }),
            .unavailable => try self.writer.writeAll("Command replay: unavailable\n"),
        }
    }
};

// A bounded line-prefix scanner. Non-marker lines can be arbitrarily long:
// only their first marker-sized prefix is buffered, even in the reference.
const Scanner = struct {
    markers: *const Markers,
    alloc: Allocator,
    limit: usize,
    retain: bool,
    prompt: std.ArrayList(u8) = .empty,
    state: enum { before, prompt, reference } = .before,
    prefix: [58]u8 = undefined,
    prefix_len: usize = 0,
    ordinary: bool = false,
    last_cr: bool = false,
    prompt_last: ?u8 = null,

    fn deinit(self: *Scanner) void {
        self.prompt.deinit(self.alloc);
    }

    fn append(self: *Scanner, bytes: []const u8) !void {
        if (self.state != .prompt or bytes.len == 0) return;
        self.prompt_last = bytes[bytes.len - 1];
        if (!self.retain) return;
        // One extra byte is reserved for the mandatory framing LF.
        if (bytes.len > (self.limit +| 1) -| self.prompt.items.len) return error.PromptTooLarge;
        try self.prompt.appendSlice(self.alloc, bytes);
    }

    fn feed(self: *Scanner, bytes: []const u8) !void {
        for (bytes) |byte| {
            if (byte == '\n' and self.last_cr) {
                self.last_cr = false;
                continue;
            }
            self.last_cr = byte == '\r';
            const normalized = if (byte == '\r') '\n' else byte;
            if (normalized == '\n') {
                try self.line(true);
            } else if (self.ordinary) {
                try self.append(&.{normalized});
            } else {
                self.prefix[self.prefix_len] = normalized;
                self.prefix_len += 1;
                const prefix = self.prefix[0..self.prefix_len];
                if (!std.mem.startsWith(u8, &self.markers.begin, prefix) and !std.mem.startsWith(u8, &self.markers.end, prefix)) {
                    self.ordinary = true;
                    try self.append(prefix);
                    self.prefix_len = 0;
                }
            }
        }
    }

    fn line(self: *Scanner, newline: bool) !void {
        const prefix = self.prefix[0..self.prefix_len];
        if (!self.ordinary and std.mem.eql(u8, prefix, &self.markers.begin)) {
            if (self.state != .before or !newline) return error.InvalidPromptFraming;
            self.state = .prompt;
        } else if (!self.ordinary and std.mem.eql(u8, prefix, &self.markers.end)) {
            if (self.state != .prompt or self.prompt_last != '\n') return error.InvalidPromptFraming;
            self.state = .reference;
            if (self.retain) self.prompt.items.len -= 1;
        } else {
            if (!self.ordinary) try self.append(prefix);
            if (newline) try self.append("\n");
        }
        self.prefix_len = 0;
        self.ordinary = false;
    }

    fn finish(self: *Scanner) !?[]u8 {
        if (self.prefix_len != 0 or self.ordinary) try self.line(false);
        if (self.state != .reference) return error.InvalidPromptFraming;
        if (!self.retain) return null;
        if (self.prompt.items.len > self.limit) return error.PromptTooLarge;
        if (std.mem.findScalar(u8, self.prompt.items, 0) != null) return error.PromptContainsNul;
        if (!std.unicode.utf8ValidateSlice(self.prompt.items)) return error.PromptInvalidUtf8;
        if (std.mem.trim(u8, self.prompt.items, " \t\r\n").len == 0) return null;
        return try self.prompt.toOwnedSlice(self.alloc);
    }
};

fn readDocument(alloc: Allocator, dir: std.Io.Dir, markers: *const Markers, limit: usize, retain: bool) !?[]u8 {
    var file = try io_mod.openExistingRegularFile(dir, document_name, .read_only);
    defer file.close(io_mod.getIo());
    if ((try file.stat(io_mod.getIo())).nlink != 1 or try descriptorUid(file.handle) != std.c.geteuid()) return error.EditorFileUnsafe;
    var scanner: Scanner = .{ .markers = markers, .alloc = alloc, .limit = limit, .retain = retain };
    defer scanner.deinit();
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io_mod.getIo(), &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        try scanner.feed(buffer[0..count]);
    }
    return scanner.finish();
}

fn descriptorUid(fd: std.posix.fd_t) !std.posix.uid_t {
    if (comptime builtin.target.os.tag == .linux) {
        const linux = std.os.linux;
        while (true) {
            var stat: linux.Statx = std.mem.zeroes(linux.Statx);
            switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stat))) {
                .SUCCESS => return stat.uid,
                .INTR => continue,
                else => return error.EditorFileUnsafe,
            }
        }
    } else if (comptime builtin.target.os.tag == .macos) {
        var native: std.c.Stat = undefined;
        while (true) {
            switch (std.c.errno(std.c.fstat(fd, &native))) {
                .SUCCESS => return native.uid,
                .INTR => continue,
                else => return error.EditorFileUnsafe,
            }
        }
    } else return error.EditorUnavailable;
}

fn withinPath(path: []const u8, parent: []const u8) bool {
    return std.mem.eql(u8, path, parent) or
        (std.mem.startsWith(u8, path, parent) and path.len > parent.len and
            (std.mem.endsWith(u8, parent, "/") or path[parent.len] == '/'));
}

fn checkTempRoot(kind: std.Io.File.Kind, uid: std.posix.uid_t, own_uid: std.posix.uid_t, mode: std.posix.mode_t) !void {
    if (kind != .directory) return error.EditorTempRootUnsafe;
    if (uid != own_uid and !(uid == 0 and mode & 0o1000 != 0)) return error.EditorTempRootUnsafe;
    // A writable shared root needs sticky deletion protection even when its
    // owner happens to be the caller, or another user could replace the child.
    if (mode & 0o022 != 0 and mode & 0o1000 == 0) return error.EditorTempRootUnsafe;
}

// The editor resolves an absolute filename, not just our held descriptor.
// Walk from / so a writable untrusted ancestor cannot redirect that filename.
fn openTrustedTempRoot(canonical: []const u8) !std.Io.Dir {
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), "/", .{ .iterate = true });
    errdefer dir.close(io_mod.getIo());
    var parts = std.mem.tokenizeScalar(u8, canonical, '/');
    while (parts.next()) |part| {
        var next = try dir.openDir(io_mod.getIo(), part, .{ .follow_symlinks = false, .iterate = true });
        const safe = blk: {
            const stat = next.stat(io_mod.getIo()) catch break :blk false;
            const uid = descriptorUid(next.handle) catch break :blk false;
            break :blk (uid == 0 or uid == std.c.geteuid()) and
                (stat.permissions.toMode() & 0o022 == 0 or stat.permissions.toMode() & 0o1000 != 0);
        };
        if (!safe) {
            next.close(io_mod.getIo());
            return error.EditorTempRootUnsafe;
        }
        dir.close(io_mod.getIo());
        dir = next;
    }
    return dir;
}

const Scratch = struct {
    root: std.Io.Dir,
    dir: std.Io.Dir,
    name: [40]u8,

    fn create(alloc: Allocator) !Scratch {
        const configured = io_mod.getenv("TMPDIR") orelse "/tmp";
        const path = if (configured.len == 0) "/tmp" else configured;
        if (!std.Io.Dir.path.isAbsolute(path)) return error.EditorTempRootUnsafe;
        const canonical = try io_mod.realpathAlloc(alloc, path);
        defer alloc.free(canonical);
        const workspace = try io_mod.realpathAlloc(alloc, ".");
        defer alloc.free(workspace);
        if (withinPath(canonical, workspace)) return error.EditorTempRootInWorkspace;
        var root = try openTrustedTempRoot(canonical);
        errdefer root.close(io_mod.getIo());
        const stat = try root.stat(io_mod.getIo());
        const uid = try descriptorUid(root.handle);
        try checkTempRoot(stat.kind, uid, std.c.geteuid(), stat.permissions.toMode());
        var random: [16]u8 = undefined;
        io_mod.getIo().random(&random);
        var name: [40]u8 = undefined;
        _ = try std.mem.print(&name, "fx-edit-{s}", .{std.fmt.bytesToHex(random, .lower)});
        // Never adopt an existing name, even after an improbable collision.
        try root.createDir(io_mod.getIo(), &name, .fromMode(0o700));
        errdefer root.deleteDir(io_mod.getIo(), &name) catch {};
        var dir = try root.openDir(io_mod.getIo(), &name, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io_mod.getIo());
        const private = try dir.stat(io_mod.getIo());
        if (private.kind != .directory or private.permissions.toMode() & 0o777 != 0o700 or try descriptorUid(dir.handle) != std.c.geteuid()) return error.EditorTempRootUnsafe;
        return .{ .root = root, .dir = dir, .name = name };
    }

    fn deinit(self: *Scratch) void {
        // deleteTree opens directories no-follow and unlinks symlinks rather
        // than visiting their targets, including editor-created backups.
        var iterator = self.dir.iterate();
        while (iterator.next(io_mod.getIo()) catch null) |entry| self.dir.deleteTree(io_mod.getIo(), entry.name) catch {};
        self.dir.close(io_mod.getIo());
        self.root.deleteDir(io_mod.getIo(), &self.name) catch {};
        self.root.close(io_mod.getIo());
    }
};

fn testMarkers() Markers {
    return Markers.fromNonce(@splat('a'));
}

fn scanTest(alloc: Allocator, prompt: []const u8, reference: []const u8, limit: usize) !?[]u8 {
    const markers = testMarkers();
    var scanner: Scanner = .{ .markers = &markers, .alloc = alloc, .limit = limit, .retain = true };
    defer scanner.deinit();
    try scanner.feed(&markers.begin);
    try scanner.feed("\n");
    try scanner.feed(prompt);
    try scanner.feed("\n");
    try scanner.feed(&markers.end);
    try scanner.feed("\n");
    try scanner.feed(reference);
    return scanner.finish();
}

test "prompt editor readback normalizes newlines and preserves nonframing whitespace" {
    const alloc = std.testing.allocator;
    const result = (try scanTest(alloc, " \r\n你好\rworld\n\n ", "reference", 100)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings(" \n你好\nworld\n\n ", result);
    try std.testing.expectEqual(@as(?[]u8, null), try scanTest(alloc, " \t\r\n", "", 100));
    try std.testing.expectEqual(@as(?[]u8, null), try scanTest(alloc, "", "", 0));
}

test "prompt editor cap UTF8 NUL and unlimited reference" {
    const alloc = std.testing.allocator;
    const exact = (try scanTest(alloc, "1234", "", 4)).?;
    defer alloc.free(exact);
    try std.testing.expectEqualStrings("1234", exact);
    try std.testing.expectError(error.PromptTooLarge, scanTest(alloc, "12345", "", 4));
    try std.testing.expectError(error.PromptContainsNul, scanTest(alloc, "a\x00b", "", 10));
    try std.testing.expectError(error.PromptInvalidUtf8, scanTest(alloc, "\xff", "", 10));
    const markers = testMarkers();
    var scanner: Scanner = .{ .markers = &markers, .alloc = alloc, .limit = 1, .retain = true };
    defer scanner.deinit();
    try scanner.feed(&markers.begin);
    try scanner.feed("\nx\n");
    try scanner.feed(&markers.end);
    try scanner.feed("\n");
    const chunk: [8192]u8 = @splat('z');
    for (0..100) |_| try scanner.feed(&chunk);
    try scanner.feed("\n");
    try scanner.feed(&markers.begin);
    // A marker is recognized only when its exact line terminates.
    try std.testing.expectError(error.InvalidPromptFraming, scanner.feed("\n"));
}

test "prompt editor rejects missing reversed duplicate and nonline boundaries" {
    const alloc = std.testing.allocator;
    const markers = testMarkers();
    var missing: Scanner = .{ .markers = &markers, .alloc = alloc, .limit = 100, .retain = true };
    defer missing.deinit();
    try missing.feed("no boundaries");
    try std.testing.expectError(error.InvalidPromptFraming, missing.finish());
    var reversed: Scanner = .{ .markers = &markers, .alloc = alloc, .limit = 100, .retain = true };
    defer reversed.deinit();
    try reversed.feed(&markers.end);
    try std.testing.expectError(error.InvalidPromptFraming, reversed.feed("\n"));
    try std.testing.expectError(error.InvalidPromptFraming, scanTest(alloc, "x", &markers.end, 100));
    const result = (try scanTest(alloc, "# Heading\n```\nordinary text", "", 100)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("# Heading\n```\nordinary text", result);
}

test "prompt editor argv selection quoting operators and executable policy" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqualStrings("bad '", selectedEditor("bad '", "vi").?);
    try std.testing.expectEqualStrings("vi", selectedEditor(" \t", "vi").?);
    var argv = try parseEditor(alloc, "'/usr/bin/an editor' --wait 'a; b' '>'");
    defer argv.deinit(alloc);
    try std.testing.expectEqualStrings("/usr/bin/an editor", argv.tokens[0].value);
    try std.testing.expectEqualStrings("a; b", argv.tokens[2].value);
    for ([_][]const u8{ "vi | cat", "vi >out", "vi && cat", "vi; cat", "vi $(cat)", "vi `cat`" }) |command| {
        try std.testing.expectError(error.EditorShellSyntax, parseEditor(alloc, command));
    }
    try std.testing.expectError(error.UnbalancedQuote, parseEditor(alloc, "vi '"));
    try std.testing.expectError(error.EditorRequiresAbsoluteExecutable, parseEditor(alloc, "./vi --wait"));
}

test "prompt editor allocation failures release scanner and editor arguments" {
    const Exercise = struct {
        fn run(alloc: Allocator) !void {
            var argv = try parseEditor(alloc, "vi --wait 'a b'");
            defer argv.deinit(alloc);
            const text = (try scanTest(alloc, "some text\r\nwith Unicode λ", "reference", 100)).?;
            defer alloc.free(text);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Exercise.run, .{});
}

test "prompt editor turn writer preserves tool boundary chronology and author" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var writer: TurnWriter = .{ .writer = &output.writer };
    var notes = [_]types.PersistedContextNote{ .{ .text = @constCast("note-zero"), .after_tool_step_count = 0 }, .{ .text = @constCast("note-one"), .after_tool_step_count = 1 } };
    var steering = [_]types.PersistedSteering{ .{ .text = @constCast("steer-zero"), .assistant_prefix = @constCast("prefix-zero"), .after_tool_step_count = 0 }, .{ .text = @constCast("steer-one"), .after_tool_step_count = 1 } };
    var calls = [_]types.ToolCall{.{ .id = "call-one", .name = "read_file", .arguments_json = "{\"path\":\"x\"}" }};
    var results = [_]types.PersistedToolResult{.{ .tool_call_id = @constCast("call-one"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast("result-one"), .preview = @constCast("preview-one"), .output_handle = @constCast("handle-one"), .output_bytes = 20, .stored_output_bytes = 10, .truncated = true }};
    var steps = [_]types.ToolExecutionStep{.{ .assistant = @constCast("intermediate-one"), .tool_calls = &calls, .tool_results = &results }};
    var runtime_context = [_][]u8{@constCast("never-export-runtime-system")};
    try writer.append(.{ .assistant = .{ .user = .{ .text = @constCast("opening"), .author = .parent }, .assistant = @constCast("final-one"), .execution = .{ .context_notes = &notes, .steering = &steering, .tool_steps = &steps, .runtime_context = &runtime_context } } });
    const text = output.written();
    var at: usize = 0;
    for ([_][]const u8{ "(parent)", "opening", "note-zero", "prefix-zero", "steer-zero", "intermediate-one", "Tool call:", "result-one", "preview-one", "handle-one", "note-one", "steer-one", "final-one" }) |needle| {
        at = (std.mem.findPos(u8, text, at, needle) orelse return error.MissingChronologicalEntry) + needle.len;
    }
    try std.testing.expect(std.mem.find(u8, text, "never-export-runtime-system") == null);
    try writer.append(.{ .interrupted = .{ .user = .{ .text = @constCast("interrupted-opening") }, .assistant = @constCast("partial"), .terminal_reason = .failed, .stopped_by_exit = true } });
    try std.testing.expect(std.mem.find(u8, output.written(), "Turn interrupted: failed") != null);
}

test "prompt editor readback rejects unsafe descriptors and permits atomic save" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = io_mod.getIo();
    const markers = testMarkers();
    var file = try tmp.dir.createFile(io, "replacement", .{ .permissions = .fromMode(0o644) });
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("{s}\nx\n{s}\n", .{ markers.begin, markers.end });
    try writer.interface.flush();
    file.close(io);
    try tmp.dir.rename("replacement", tmp.dir, document_name, io);
    const text = (try readDocument(std.testing.allocator, tmp.dir, &markers, 1, true)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("x", text);
    try tmp.dir.hardLink(document_name, tmp.dir, "duplicate", io, .{});
    try std.testing.expectError(error.DurablePathUnsafe, readDocument(std.testing.allocator, tmp.dir, &markers, 1, true));
    try tmp.dir.deleteFile(io, "duplicate");
    try tmp.dir.deleteFile(io, document_name);
    try tmp.dir.symLink(io, "other", document_name, .{});
    try std.testing.expectError(error.DurablePathUnsafe, readDocument(std.testing.allocator, tmp.dir, &markers, 1, true));
}

test "prompt editor refuses incomplete archive before native handoff" {
    const App = struct {
        alloc: Allocator,
        terminal: @import("../../ui/shell_runtime.zig").TerminalState = .{},
        shell: @import("../../ui/transcript/runtime.zig").TranscriptRuntime = .{},
        metrics: types.Metrics = .{},
        pub const footer_rows: u16 = 4;
        pub const input_limits = .{ .composer_bytes = 1024 };
    };
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    app.* = .{ .alloc = std.testing.allocator };
    const owner = try std.testing.allocator.create(agents.Agent);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{};
    try checkArchive(owner);
    try owner.session.agent.history.append(std.testing.allocator, .{ .assistant = .{ .user = .{ .text = @constCast("borrowed") }, .assistant = @constCast("answer") } });
    defer owner.session.agent.history.deinit(std.testing.allocator);
    try std.testing.expectError(error.HistoryUnavailable, checkArchive(owner));
    owner.session_persistence.degraded_warning_emitted = true;
    try std.testing.expectError(error.HistoryUnavailable, edit(App, app, owner, "seed"));
}

test "prompt editor temporary root policy and workspace boundary" {
    try checkTempRoot(.directory, 1000, 1000, 0o700);
    try checkTempRoot(.directory, 0, 1000, 0o1777);
    try std.testing.expectError(error.EditorTempRootUnsafe, checkTempRoot(.directory, 2000, 1000, 0o1700));
    try std.testing.expectError(error.EditorTempRootUnsafe, checkTempRoot(.directory, 1000, 1000, 0o777));
    try std.testing.expectError(error.EditorTempRootUnsafe, checkTempRoot(.file, 1000, 1000, 0o700));
    try std.testing.expect(withinPath("/workspace/tmp", "/workspace"));
    try std.testing.expect(withinPath("/workspace", "/workspace"));
    try std.testing.expect(withinPath("/tmp", "/"));
    try std.testing.expect(!withinPath("/workspace-other", "/workspace"));
}

test "prompt editor scratch is private random and cleanup never follows links" {
    var scratch = try Scratch.create(std.testing.allocator);
    var second = try Scratch.create(std.testing.allocator);
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, &scratch.name, &second.name));
    const stat = try scratch.dir.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    var sentinel = try second.dir.createFile(io_mod.getIo(), "sentinel", .{});
    sentinel.close(io_mod.getIo());
    const target = try io_mod.dirRealpathAlloc(std.testing.allocator, second.dir, ".");
    defer std.testing.allocator.free(target);
    try scratch.dir.symLink(io_mod.getIo(), target, "editor-backup", .{});
    try scratch.dir.createDir(io_mod.getIo(), "extras", .fromMode(0o700));
    const name = scratch.name;
    scratch.deinit();
    try std.testing.expectError(error.FileNotFound, second.root.statFile(io_mod.getIo(), &name, .{ .follow_symlinks = false }));
    _ = try second.dir.statFile(io_mod.getIo(), "sentinel", .{});
}

test "prompt editor scans generated export for marker collisions without retaining text" {
    const markers = testMarkers();
    var scanner: Scanner = .{ .markers = &markers, .alloc = std.testing.allocator, .limit = 0, .retain = false };
    defer scanner.deinit();
    try scanner.feed(&markers.begin);
    try scanner.feed("\nseed\n");
    try scanner.feed(&markers.end);
    try scanner.feed("\nlarge reference\n");
    try scanner.feed(&markers.end);
    try std.testing.expectError(error.InvalidPromptFraming, scanner.feed("\n"));
    try std.testing.expectEqual(@as(usize, 0), scanner.prompt.capacity);
}

test "prompt editor export preserves trailing seed newline and streams empty session" {
    const owner = try std.testing.allocator.create(agents.Agent);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const markers = testMarkers();
    try writeDocument(&output.writer, owner, std.testing.allocator, "seed\r", &markers);
    var scanner: Scanner = .{ .markers = &markers, .alloc = std.testing.allocator, .limit = 100, .retain = true };
    defer scanner.deinit();
    try scanner.feed(output.written());
    const text = (try scanner.finish()).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("seed\n", text);
}

test "prompt editor refuses pending admission transitions and hidden agent work before taking the draft" {
    const Busy = struct {
        pending: bool = false,
        pub fn hasPending(self: *const @This()) bool {
            return self.pending;
        }
    };
    const App = struct {
        alloc: Allocator = std.testing.allocator,
        main_agent: agents.Agent = .{},
        input_runtime: @import("../input/runtime.zig").Runtime = .{},
        prompt_edit_request: ?Request = null,
        pacer: Busy = .{},
        main_screen: struct { pacer: Busy = .{} } = .{},
        child_agents: std.ArrayList(*struct { agent: agents.Agent = .{}, screen: struct { pacer: Busy = .{} } = .{} }) = .empty,
        child_handoffs: struct {
            mutex: std.Io.Mutex = .init,
            posts: std.ArrayList(u8) = .empty,
            reports: std.ArrayList(u8) = .empty,
        } = .{},
        terminal: struct { alternate_screen_owner: enum { none, catalog_menu } = .none } = .{},
        shell: struct {
            render_requests: @import("../../ui/render_request.zig").RenderRequestState = .{},
            pub fn sessionScrollbackHandoffPending(_: *const @This()) bool {
                return false;
            }
        } = .{},
        auth: struct {
            picker_active: bool = false,
            prompt_credential_refresh_task: ?u8 = null,
            pub fn providerPreparationPending(_: *const @This()) bool {
                return false;
            }
            pub fn startupCredentialPending(_: *const @This()) bool {
                return false;
            }
        } = .{},
        notices: usize = 0,
        pub fn agent(self: *@This()) *agents.Agent {
            return &self.main_agent;
        }
        pub fn writeDomainNotice(self: *@This(), _: types.SemanticNotice, _: bool) !void {
            self.notices += 1;
        }
    };
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    app.* = .{};
    defer app.input_runtime.deinit(app.alloc);
    const invocation = "/edit retain draft";
    try app.input_runtime.textReplacementState().replace(app.alloc, invocation);
    for (0..11) |condition| {
        app.main_agent = .{};
        app.auth.picker_active = false;
        app.auth.prompt_credential_refresh_task = null;
        app.pacer.pending = false;
        switch (condition) {
            0 => app.main_agent.role = .subagent,
            1 => app.main_agent.submission.launch_prompt = @constCast("launch"),
            2 => app.main_agent.submission.compaction_pending = true,
            3 => app.main_agent.stream.active = true,
            4 => app.main_agent.worker.worker_processing = true,
            5 => app.main_agent.session_persistence.pending_live_session_policy = .carry_forward,
            6 => app.main_agent.session_persistence.pending_live_session_wait = .{ .geometry = 1 },
            7 => app.main_agent.question_prompt.active = true,
            8 => app.auth.picker_active = true,
            9 => app.auth.prompt_credential_refresh_task = 1,
            10 => app.pacer.pending = true,
            else => unreachable,
        }
        try Runtime(App).request(app, "retain draft");
        try std.testing.expect(app.prompt_edit_request == null);
        try std.testing.expectEqualStrings(invocation, app.input_runtime.edit_state.input.items);
    }
    app.main_agent = .{};
    app.pacer.pending = false;
    for (std.enums.values(@import("submission_state.zig").PendingPhase)) |phase| {
        app.main_agent.submission.pending = .{
            .draft = .{ .turn_id = 1, .prompt = @constCast("pending"), .images = &.{}, .skill_display_spans = &.{} },
            .phase = phase,
        };
        try Runtime(App).request(app, "retain draft");
        try std.testing.expect(app.prompt_edit_request == null);
        try std.testing.expectEqualStrings(invocation, app.input_runtime.edit_state.input.items);
    }
    app.main_agent.submission.pending = null;
    try Runtime(App).request(app, "retain draft");
    defer app.alloc.free(app.prompt_edit_request.?.seed);
    try std.testing.expectEqualStrings("retain draft", app.prompt_edit_request.?.seed);
    try std.testing.expectEqual(@as(usize, 16), app.notices);
}
