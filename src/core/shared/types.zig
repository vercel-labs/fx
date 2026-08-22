const std = @import("std");
const text_utils = @import("text_utils.zig");

pub const Layout = struct {
    rows: u16,
    cols: u16,
    content_bottom: u16,
    divider_top_row: u16,
    input_row: u16,
    divider_bottom_row: u16,
    hint_row: u16,
};

pub const Metrics = struct {
    ansi_bytes: usize = 0,
    full_redraws: usize = 0,
    debounced_resizes: usize = 0,
    footer_line_updates: usize = 0,
    stream_chunks: usize = 0,
};

pub const NoticeTone = enum {
    information,
    success,
    warning,
    @"error",
    cancelled,
    // Renders in the neutral body color so the line reads like a normal response.
    neutral,
};

pub const NoticeVisibility = enum {
    compact_and_full,
    full_only,
};

pub const SemanticNotice = struct {
    topic: []const u8,
    tone: NoticeTone,
    body: []const u8,
    visibility: NoticeVisibility = .compact_and_full,
};

/// Returns a duplicate with owned topic and body bytes. The caller frees it
/// with `freeSemanticNotice` using the same allocator.
pub fn dupeSemanticNotice(alloc: std.mem.Allocator, notice: SemanticNotice) std.mem.Allocator.Error!SemanticNotice {
    const topic = try alloc.dupe(u8, notice.topic);
    errdefer alloc.free(topic);
    return .{
        .topic = topic,
        .tone = notice.tone,
        .body = try alloc.dupe(u8, notice.body),
        .visibility = notice.visibility,
    };
}

pub fn freeSemanticNotice(alloc: std.mem.Allocator, notice: SemanticNotice) void {
    alloc.free(notice.topic);
    alloc.free(notice.body);
}

/// Converts legacy context-notice text into a semantic notice body while
/// preserving line structure. The caller owns the returned bytes.
pub fn renderContextNoticeBody(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    var needs_separator = false;
    while (lines.next()) |line| {
        if (needs_separator) try body.writer.writeByte('\n');
        needs_separator = true;
        if (std.mem.eql(u8, line, "[context]")) continue;
        const legacy_prefix = "[context] ";
        try body.writer.writeAll(if (std.mem.startsWith(u8, line, legacy_prefix)) line[legacy_prefix.len..] else line);
    }
    return body.toOwnedSlice();
}

test "context notice body drops legacy markers from every line" {
    const body = try renderContextNoticeBody(
        std.testing.allocator,
        "[context] first\n[context] second\nalready semantic\n[context]\n",
    );
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("first\nsecond\nalready semantic\n\n", body);
}

pub const CredentialSource = enum {
    vercel_oidc_token,
    ai_gateway_api_key,
    fx_login,
    stored_key,
    chatgpt_subscription,
    grok_subscription,
    claude_subscription,
};

pub fn parseCredentialSource(text: []const u8) ?CredentialSource {
    return std.meta.stringToEnum(CredentialSource, text);
}

test "credential source round trips through its persisted name" {
    for (std.meta.tags(CredentialSource)) |source| {
        try std.testing.expectEqual(source, parseCredentialSource(@tagName(source)).?);
    }
    try std.testing.expect(parseCredentialSource("keychain") == null);
}

pub const TurnPresentationOutcome = enum {
    completed,
    interrupted,
    failed,
    paused,
};

pub const TurnFinished = struct {
    turn_id: u64,
    outcome: TurnPresentationOutcome,
};

pub const ToolLifecycleId = struct {
    turn_id: u64,
    call_id: []const u8,
};

pub const ToolPresentationGroupId = struct {
    turn_id: u64,
    anchor_step_id: u64,
};

pub const ToolOutcomeKind = enum {
    completed,
    denied,
    cancelled,
    failed,
    deferred,
};

pub const ToolOutcome = struct {
    kind: ToolOutcomeKind,
    summary: []const u8,
};

pub const ToolLifecycleEvent = union(enum) {
    provisional: struct {
        id: ToolLifecycleId,
        presentation_group_id: ?ToolPresentationGroupId = null,
        tool_name: ?[]const u8,
        activity_kind: ToolActivityKind,
    },
    authoritative_started: struct {
        id: ToolLifecycleId,
        presentation_group_id: ?ToolPresentationGroupId = null,
        reconciles_provisional_call_id: ?[]const u8,
        tool_name: []const u8,
        activity_kind: ToolActivityKind,
        arguments_json: ?[]const u8 = null,
        place_after_current_transcript: bool = false,
    },
    progress: struct {
        id: ToolLifecycleId,
        text: []const u8,
    },
    terminal: struct {
        id: ToolLifecycleId,
        outcome: ToolOutcome,
        result: ?[]const u8 = null,
        result_memory: ?ToolResultMemory = null,
        command_artifact_handle: ?[]const u8 = null,
    },
    turn_finished: TurnFinished,
};

pub const StreamState = struct {
    active: bool = false,
    chunks: usize = 0,
    read_count: usize = 0,
    list_count: usize = 0,
    write_count: usize = 0,
    edit_count: usize = 0,
    open_count: usize = 0,
    command_count: usize = 0,
    subagent_count: usize = 0,
    token_progress: TurnTokenProgress = .{},
    last_activity_kind: ?ToolActivityKind = null,
    /// When the turn started; 0 hides the Thinking elapsed counter and its
    /// wall-clock blink. Monotonic for the whole turn: tool boundaries never
    /// reset it.
    turn_started_ms: i64 = 0,
    /// When fx started waiting on user input (approval or question); 0 means
    /// not waiting. While set, the Thinking clock freezes at this instant;
    /// on resume the wait is excluded by shifting turn_started_ms forward.
    waiting_since_ms: i64 = 0,
    /// Assistant text reached the transcript in the current stretch: the
    /// status row stays with the response instead of flipping back to Thinking
    /// whenever the pacer catches up. A tool start opens the next stretch.
    assistant_text_started: bool = false,
    /// The model is streaming tool arguments that open no status row of their
    /// own, so the turn is producing output the transcript cannot show yet.
    /// Cleared as soon as assistant text resumes or the tool itself starts.
    composing_tool_payload: bool = false,
};

pub const RouteRecoveryUnsafeReason = enum {
    assistant_output,
    tool_start,
};

pub const RouteRecoveryStatusTone = enum {
    warning,
    success,
    danger,
};

pub const ModelRecoveryCause = enum {
    network_interrupted,
    response_interrupted,
    provider_unavailable,
    rate_limited,
    system_resumed,
    authentication,
    request_limit_reached,
};

pub const ModelRecoveryAction = enum {
    retrying_request,
    continuing_response,
    regenerating_tool,
    continuing_after_tool,
    reconciling_tool,
    waiting_for_connectivity,
    paused,
};

pub const ModelRecoveryRequiredAction = enum {
    none,
    continue_later,
    inspect_uncertain_tool,
    change_request,
};

pub const ModelFailureDiagnostic = struct {
    pub const max_bytes: usize = 256;

    bytes: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    len: u16 = 0,

    pub fn defaultTextForCause(cause: ModelRecoveryCause) []const u8 {
        return switch (cause) {
            .network_interrupted => "NetworkInterrupted",
            .response_interrupted => "StreamInterrupted",
            .provider_unavailable => "provider_error",
            .rate_limited => "HTTP 429",
            .system_resumed => "SystemResumed",
            .authentication => "AuthenticationExpired",
            .request_limit_reached => "ProviderRequestLimitReached",
        };
    }

    pub fn forCause(cause: ModelRecoveryCause) ModelFailureDiagnostic {
        return init(defaultTextForCause(cause));
    }

    pub fn init(text: []const u8) ModelFailureDiagnostic {
        var diagnostic: ModelFailureDiagnostic = .{};
        if (text.len <= max_bytes) {
            @memcpy(diagnostic.bytes[0..text.len], text);
            diagnostic.len = @intCast(text.len);
            return diagnostic;
        }

        const marker = "...";
        const prefix = text_utils.utf8PrefixByBytes(text, max_bytes - marker.len);
        @memcpy(diagnostic.bytes[0..prefix.len], prefix);
        @memcpy(diagnostic.bytes[prefix.len .. prefix.len + marker.len], marker);
        diagnostic.len = @intCast(prefix.len + marker.len);
        return diagnostic;
    }

    pub fn view(self: *const ModelFailureDiagnostic) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const RouteRecoveryStatus = struct {
    pub const label_max_bytes: usize = 512;

    pub const Kind = enum {
        auto_retry,
        auto_recovered,
        manual_retry_without_fast,
        manual_recovered_without_fast,
        terminal_provider_error,
        unsafe_assistant_output,
        unsafe_tool_start,
        content_filter,
    };

    kind: Kind,
    failed_attempt: usize = 0,
    succeeded_attempt: usize = 0,
    attempt_limit: usize = 0,
    cause: ?ModelRecoveryCause = null,
    action: ?ModelRecoveryAction = null,
    required_action: ModelRecoveryRequiredAction = .none,
    delay_seconds: u64 = 0,
    diagnostic: ?ModelFailureDiagnostic = null,

    pub fn tone(self: RouteRecoveryStatus) RouteRecoveryStatusTone {
        return switch (self.kind) {
            .auto_recovered,
            .manual_recovered_without_fast,
            => .success,
            .terminal_provider_error,
            .unsafe_assistant_output,
            .unsafe_tool_start,
            .content_filter,
            => .danger,
            .auto_retry,
            .manual_retry_without_fast,
            => .warning,
        };
    }

    pub fn isRecovered(self: RouteRecoveryStatus) bool {
        return switch (self.kind) {
            .auto_recovered,
            .manual_recovered_without_fast,
            => true,
            else => false,
        };
    }

    pub fn reportedAttempt(self: RouteRecoveryStatus) usize {
        if (self.isRecovered() and self.succeeded_attempt != 0) {
            return self.succeeded_attempt;
        }
        return self.failed_attempt;
    }

    pub fn label(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        return switch (self.kind) {
            .auto_retry => self.recoveryLabel(buf),
            .auto_recovered => std.fmt.bufPrint(
                buf,
                "✓ recovered · succeeded on attempt {d}/{d}",
                .{ self.succeeded_attempt, self.attempt_limit },
            ) catch "✓ recovered",
            .manual_retry_without_fast => self.manualRetryLabel(buf),
            .manual_recovered_without_fast => "✓ recovered · Fast disabled",
            .terminal_provider_error => self.pausedLabel(buf),
            .unsafe_assistant_output => self.fixedFailureLabel(
                buf,
                "Response interrupted",
                "partial output preserved",
            ),
            .unsafe_tool_start => self.fixedFailureLabel(
                buf,
                "Tool state needs review",
                "context preserved",
            ),
            .content_filter => self.fixedFailureLabel(buf, "blocked", "content filter"),
        };
    }

    fn manualRetryLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        if (self.diagnostic) |diagnostic| {
            return std.fmt.bufPrint(
                buf,
                "⚠ Provider route unavailable · {s} · continuing without Fast",
                .{diagnostic.view()},
            ) catch "⚠ Provider route unavailable · continuing without Fast";
        }
        return "⚠ Provider route unavailable · continuing without Fast";
    }

    fn fixedFailureLabel(
        self: RouteRecoveryStatus,
        buf: []u8,
        cause: []const u8,
        action: []const u8,
    ) []const u8 {
        if (self.diagnostic) |diagnostic| {
            return std.fmt.bufPrint(
                buf,
                "⚠ {s} · {s} · {s}",
                .{ cause, diagnostic.view(), action },
            ) catch "⚠ Model response failed";
        }
        return std.fmt.bufPrint(buf, "⚠ {s} · {s}", .{ cause, action }) catch "⚠ Model response failed";
    }

    fn recoveryLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        const cause = switch (self.cause orelse .provider_unavailable) {
            .network_interrupted => "Network interrupted",
            .response_interrupted => "Response ended early",
            .provider_unavailable => "Provider unavailable",
            .rate_limited => "Rate limited",
            .system_resumed => "Mac woke from sleep",
            .authentication => "Authentication refreshed",
            .request_limit_reached => "Provider request limit reached",
        };
        const action = switch (self.action orelse .retrying_request) {
            .retrying_request => "retrying request",
            .continuing_response => "continuing response",
            .regenerating_tool => "regenerating unstarted tool",
            .continuing_after_tool => "continuing after confirmed tool",
            .reconciling_tool => "checking uncertain tool state",
            .waiting_for_connectivity => "waiting for connection",
            .paused => "recovery paused",
        };
        if (self.delay_seconds > 0) {
            if (self.diagnostic) |diagnostic| {
                return std.fmt.bufPrint(
                    buf,
                    "⚠ {s} · {s} · {s} in {d}s · attempt {d}/{d}",
                    .{ cause, diagnostic.view(), action, self.delay_seconds, self.failed_attempt, self.attempt_limit },
                ) catch "⚠ Recovering model response";
            }
            return std.fmt.bufPrint(
                buf,
                "⚠ {s} · {s} in {d}s · attempt {d}/{d}",
                .{ cause, action, self.delay_seconds, self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Recovering model response";
        }
        if (self.diagnostic) |diagnostic| {
            return std.fmt.bufPrint(
                buf,
                "⚠ {s} · {s} · {s} · attempt {d}/{d}",
                .{ cause, diagnostic.view(), action, self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Recovering model response";
        }
        return std.fmt.bufPrint(
            buf,
            "⚠ {s} · {s} · attempt {d}/{d}",
            .{ cause, action, self.failed_attempt, self.attempt_limit },
        ) catch "⚠ Recovering model response";
    }

    fn pausedLabel(self: RouteRecoveryStatus, buf: []u8) []const u8 {
        const cause = self.cause orelse return self.pausedCauseLabel(buf, "Provider unavailable");
        if (cause == .rate_limited and self.failed_attempt < self.attempt_limit) {
            if (self.diagnostic) |diagnostic| {
                return std.fmt.bufPrint(
                    buf,
                    "⚠ Rate limited · {s} · server requested a longer wait · recovery paused · attempt {d}/{d}",
                    .{ diagnostic.view(), self.failed_attempt, self.attempt_limit },
                ) catch "⚠ Rate limited · recovery paused";
            }
            return std.fmt.bufPrint(
                buf,
                "⚠ Rate limited · server requested a longer wait · recovery paused · attempt {d}/{d}",
                .{ self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Rate limited · recovery paused";
        }
        if (cause == .system_resumed and self.failed_attempt < self.attempt_limit) {
            if (self.diagnostic) |diagnostic| {
                return std.fmt.bufPrint(
                    buf,
                    "⚠ Mac woke from sleep · {s} · connection still unavailable · recovery paused · attempt {d}/{d}",
                    .{ diagnostic.view(), self.failed_attempt, self.attempt_limit },
                ) catch "⚠ Connection unavailable · recovery paused";
            }
            return std.fmt.bufPrint(
                buf,
                "⚠ Mac woke from sleep · connection still unavailable · recovery paused · attempt {d}/{d}",
                .{ self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Connection unavailable · recovery paused";
        }
        if (cause == .request_limit_reached) {
            if (self.diagnostic) |diagnostic| {
                return std.fmt.bufPrint(
                    buf,
                    "⚠ Response paused · {s} · {d}/{d} provider-request safety limit reached",
                    .{ diagnostic.view(), self.failed_attempt, self.attempt_limit },
                ) catch "⚠ Response paused · provider-request safety limit reached";
            }
            return std.fmt.bufPrint(
                buf,
                "⚠ Response paused · {d}/{d} provider-request safety limit reached",
                .{ self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Response paused · provider-request safety limit reached";
        }
        const name = switch (cause) {
            .network_interrupted => "Network interrupted",
            .response_interrupted => "Response ended early",
            .provider_unavailable => "Provider unavailable",
            .rate_limited => "Rate limited",
            .system_resumed => "Mac woke from sleep",
            .authentication => "Authentication expired",
            .request_limit_reached => unreachable,
        };
        return self.pausedCauseLabel(buf, name);
    }

    fn pausedCauseLabel(
        self: RouteRecoveryStatus,
        buf: []u8,
        name: []const u8,
    ) []const u8 {
        if (self.diagnostic) |diagnostic| {
            return std.fmt.bufPrint(
                buf,
                "⚠ {s} · {s} · recovery paused after {d}/{d} attempts",
                .{ name, diagnostic.view(), self.failed_attempt, self.attempt_limit },
            ) catch "⚠ Model response recovery paused";
        }
        return std.fmt.bufPrint(
            buf,
            "⚠ {s} · recovery paused after {d}/{d} attempts",
            .{ name, self.failed_attempt, self.attempt_limit },
        ) catch "⚠ Model response recovery paused";
    }
};

test "route recovery reports the attempt owned by its state" {
    try std.testing.expectEqual(@as(usize, 3), (RouteRecoveryStatus{
        .kind = .auto_retry,
        .failed_attempt = 3,
        .attempt_limit = 10,
    }).reportedAttempt());
    try std.testing.expectEqual(@as(usize, 4), (RouteRecoveryStatus{
        .kind = .auto_recovered,
        .failed_attempt = 3,
        .succeeded_attempt = 4,
        .attempt_limit = 10,
    }).reportedAttempt());
}

test "route recovery label includes a value-owned diagnostic" {
    var status = RouteRecoveryStatus{
        .kind = .auto_retry,
        .failed_attempt = 4,
        .attempt_limit = 10,
        .cause = .provider_unavailable,
        .action = .retrying_request,
        .delay_seconds = 4,
        .diagnostic = ModelFailureDiagnostic.init(
            "HTTP 503 · no_available_providers: No providers are currently available",
        ),
    };
    const copied = status;
    status.diagnostic = null;

    var label_buf: [RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "⚠ Provider unavailable · HTTP 503 · no_available_providers: No providers are currently available · retrying request in 4s · attempt 4/10",
        copied.label(&label_buf),
    );
}

test "model failure diagnostic truncation is bounded and utf8 safe" {
    const long = "provider_error: " ++ ("é" ** 200);
    const diagnostic = ModelFailureDiagnostic.init(long);

    try std.testing.expect(diagnostic.view().len <= ModelFailureDiagnostic.max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(diagnostic.view()));
    try std.testing.expect(std.mem.endsWith(u8, diagnostic.view(), "..."));
}

pub const ChatRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const FinalToolIdentity = enum {
    valid,
    absent,
    empty,
    wrong_type,
};

pub const ToolExecutionProvenance = enum {
    fx_local,
    provider_executed,
};

pub const ProviderResultIdentityFailure = enum {
    absent,
    empty,
    wrong_type,
    unmatched,
    ambiguous,
    missing_result,
    incomplete_streamed_input,
    invalid_tool_input,
    conflicting_tool_name,
    malformed_provider_executed,
    provenance_contradiction,
    malformed_preliminary,
    duplicate_result,
};

pub const ToolArgumentIntegrity = enum {
    valid,
    malformed_json,

    pub fn classifySerialized(
        alloc: std.mem.Allocator,
        serialized: []const u8,
    ) std.mem.Allocator.Error!ToolArgumentIntegrity {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .malformed_json,
        };
        defer parsed.deinit();
        return .valid;
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    argument_integrity: ToolArgumentIntegrity = .valid,
    provisional_id: ?[]const u8 = null,
    provider_result: ?[]const u8 = null,
    final_identity: FinalToolIdentity = .valid,
    provenance: ToolExecutionProvenance = .fx_local,
};

pub const WebSearchProgress = union(enum) {
    query_started: []const u8,
    results_received: struct {
        query: []const u8,
        result_count: usize,
    },
};

pub const WebSearchCompletion = struct {
    searches: u32,
    duration_ms: u64,
};

pub const WebFetchProgress = union(enum) {
    fetching: []const u8,
    converting: []const u8,
};

pub const WebFetchArtifactState = enum {
    none,
    stored,
    unavailable,
};

pub const WebFetchCompletion = struct {
    pub const max_url_len: usize = 192;

    url_buf: [max_url_len]u8 = [_]u8{0} ** max_url_len,
    url_len: u8 = 0,
    bytes: u64 = 0,
    status: u16 = 0,
    duration_ms: u64 = 0,
    cache_hit: bool = false,
    artifact_state: WebFetchArtifactState = .none,

    pub fn setUrl(self: *WebFetchCompletion, url_value: []const u8) void {
        const n = @min(url_value.len, max_url_len);
        if (n > 0) @memcpy(self.url_buf[0..n], url_value[0..n]);
        self.url_len = @intCast(n);
    }

    pub fn url(self: *const WebFetchCompletion) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

pub const PersistedToolStatus = enum {
    success,
    failure,
};

pub const FileEvidenceAction = enum {
    read,
    write,
    edit,
    delete,
    rename,
    copy,
    search,
    list,
    unknown,
};

pub const CommittedFilePresentationKind = enum {
    added,
    edited,
};

pub const CommittedFilePresentationLineKind = enum {
    context,
    addition,
    deletion,
    elision,
    notice,
};

pub const CommittedFilePresentationLine = struct {
    kind: CommittedFilePresentationLineKind,
    old_line: ?u32 = null,
    new_line: ?u32 = null,
    text: []const u8,
};

pub const CommittedFilePresentation = struct {
    path: []const u8,
    kind: CommittedFilePresentationKind,
    lines: []const CommittedFilePresentationLine,
    additions: usize,
    deletions: usize,
    truncated: bool,
    previous_content: ?[]const u8 = null,
    after_content: ?[]const u8 = null,
    lifecycle_id: ?ToolLifecycleId = null,
};

pub const PersistedToolResult = struct {
    tool_call_id: []u8,
    tool_name: []u8,
    status: PersistedToolStatus,
    output: []u8,
    output_handle: ?[]u8 = null,
    preview: ?[]u8 = null,
    output_bytes: usize,
    stored_output_bytes: usize,
    truncated: bool = false,
    provider_native: bool = false,
    created_at_ms: i64 = 0,
    permission_feedback: [][]u8 = &.{},
    committed_file_presentation: ?CommittedFilePresentation = null,
    command_output_replay: ?CommandOutputReplay = null,
    command_process_presentation: ?CommandProcessPresentation = null,
};

pub const CommandOutputReplayDescriptor = struct {
    handle: []const u8,
    framed_bytes: usize,
};

pub const CommandOutputReplay = union(enum) {
    available: CommandOutputReplayDescriptor,
    unavailable,
};

pub const CancelledCommandPresentation = struct {
    output_replay: ?CommandOutputReplay = null,
    command_artifact_handle: ?[]const u8 = null,
};

pub const CommandProcessPresentation = union(enum) {
    exit_code: i64,
    signal: u32,
};

pub const deferred_tool_result_output = "Not executed";
pub const context_deferred_tool_result_output = "Scoped project instructions were added before execution. Review them and reissue this tool call if it is still appropriate.";
pub const context_deferred_tool_status_label = "Context updated";

pub fn isContextDeferredToolResult(result: PersistedToolResult) bool {
    return result.status == .failure and
        std.mem.eql(u8, result.output, context_deferred_tool_result_output);
}

pub fn isDeferredToolResult(result: PersistedToolResult) bool {
    return result.status == .failure and
        (std.mem.eql(u8, result.output, deferred_tool_result_output) or
            std.mem.eql(u8, result.output, context_deferred_tool_result_output));
}

test "persisted deferred tool result classifier is exact" {
    var result = PersistedToolResult{
        .tool_call_id = @constCast("call_deferred"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast(deferred_tool_result_output),
        .output_bytes = deferred_tool_result_output.len,
        .stored_output_bytes = deferred_tool_result_output.len,
    };

    try std.testing.expect(isDeferredToolResult(result));
    try std.testing.expect(!isContextDeferredToolResult(result));

    result.status = .success;
    try std.testing.expect(!isDeferredToolResult(result));
    try std.testing.expect(!isContextDeferredToolResult(result));

    result.status = .failure;
    result.output = @constCast("Not executed\n");
    try std.testing.expect(!isDeferredToolResult(result));

    result.output = @constCast("not executed");
    try std.testing.expect(!isDeferredToolResult(result));

    result.output = @constCast("tool failed");
    try std.testing.expect(!isDeferredToolResult(result));

    result.output = @constCast(context_deferred_tool_result_output);
    try std.testing.expect(isDeferredToolResult(result));
    try std.testing.expect(isContextDeferredToolResult(result));
}

pub const ToolResultMemory = struct {
    output_handle: ?[]const u8 = null,
    preview: ?[]const u8 = null,
    output_bytes: usize = 0,
    stored_output_bytes: usize = 0,
    truncated: bool = false,
    model_view_covers_full_file: ?bool = null,
    committed_file_presentation: ?CommittedFilePresentation = null,
    command_output_replay: ?CommandOutputReplay = null,
    command_process_presentation: ?CommandProcessPresentation = null,
};

pub const ToolExecutionStep = struct {
    assistant: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},
    tool_results: []PersistedToolResult = &.{},
};

pub const FileEvidence = struct {
    path: []u8,
    new_path: ?[]u8 = null,
    tool_call_id: []u8,
    tool_name: []u8,
    action: FileEvidenceAction = .unknown,
    status: PersistedToolStatus = .success,
    model_view_covers_full_file: bool = false,
    stale: bool = false,
};

pub const ExecutionMemory = struct {
    tool_steps: []ToolExecutionStep = &.{},
    files: []FileEvidence = &.{},

    pub fn isEmpty(self: ExecutionMemory) bool {
        return self.tool_steps.len == 0 and self.files.len == 0;
    }
};

pub const ImageAttachment = struct {
    id: usize = 0,
    path: []u8,
    media_type: []u8,
    snapshot_path: ?[]u8 = null,
    snapshot_sha256: ?[]u8 = null,
};

pub const UserTurn = struct {
    text: []u8,
    images: []ImageAttachment = &.{},
    /// Durable join key for manager-owned child work. This is metadata only;
    /// model projections continue to use `text` and `images` exclusively.
    work_id: ?[]u8 = null,
};

pub const ChatCachePolicy = enum {
    default,
    no_cache,
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: ?[]const u8 = null,
    images: []const ImageAttachment = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    /// Provider-owned opaque response items needed only for stateless within-turn continuation.
    /// The value is a validated JSON array and is never sent across provider routes.
    provider_state_json: ?[]const u8 = null,
    tool_result_status: ?PersistedToolStatus = null,
    tool_result_memory: ?ToolResultMemory = null,
    permission_feedback: bool = false,
    cache_policy: ChatCachePolicy = .default,
};

pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
};

/// Exact usage metadata returned by a completed Gateway stream. `model` is
/// owned by the completion carrying this value.
pub const GatewayBilling = struct {
    created_at_ms: i64,
    model: []const u8,
    total_cost: f64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64,
};

/// Absolute per-turn token totals. Input covers only user-submitted prompt text
/// and stays estimated; output may become exact from provider usage.
pub const TurnTokenProgress = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    input_exact: bool = true,
    output_exact: bool = true,
};

pub const ToolUsage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    web_search_requests: u32 = 0,
};

pub const TurnSummary = struct {
    thinking_duration_ms: u64 = 0,
    turn_duration_ms: u64 = 0,
    token_progress: TurnTokenProgress = .{},
};

pub const ProviderFinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    provider_error,
    other,

    pub fn parse_unified(raw: []const u8) ?ProviderFinishReason {
        if (std.mem.eql(u8, raw, "stop")) return .stop;
        if (std.mem.eql(u8, raw, "length")) return .length;
        if (std.mem.eql(u8, raw, "content-filter")) return .content_filter;
        if (std.mem.eql(u8, raw, "tool-calls")) return .tool_calls;
        if (std.mem.eql(u8, raw, "error")) return .provider_error;
        if (std.mem.eql(u8, raw, "other")) return .other;
        return null;
    }

    pub fn parse_legacy(raw: []const u8) ?ProviderFinishReason {
        if (std.mem.eql(u8, raw, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
        return parse_unified(raw);
    }

    pub fn label(self: ProviderFinishReason) []const u8 {
        return switch (self) {
            .stop => "stop",
            .length => "length",
            .content_filter => "content-filter",
            .tool_calls => "tool-calls",
            .provider_error => "error",
            .other => "other",
        };
    }
};

pub const GatewayCompletion = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    generation_id: ?[]const u8 = null,
    billing: ?GatewayBilling = null,
    /// Gateway generation or resolved-model metadata was malformed or conflicting.
    generation_metadata_invalid: bool = false,
    /// An earlier delivery may have billed outside this generation identity.
    delivery_ambiguous: bool = false,
    provider_result_identity_failure: ?ProviderResultIdentityFailure = null,
    provider_failure_detail: ?[]const u8 = null,
    /// Provider-owned opaque response items for the next stateless request in this turn.
    provider_state_json: ?[]const u8 = null,
    finish_reason: ?ProviderFinishReason = null,
    usage: Usage = .{},
};

pub fn parseGatewayTimestamp(text: []const u8) error{InvalidGatewayTimestamp}!i64 {
    if (text.len < 20 or
        text[4] != '-' or
        text[7] != '-' or
        text[10] != 'T' or
        text[13] != ':' or
        text[16] != ':')
    {
        return error.InvalidGatewayTimestamp;
    }
    const year = try parseTimestampDigits(text[0..4]);
    const month = try parseTimestampDigits(text[5..7]);
    const day = try parseTimestampDigits(text[8..10]);
    const hour = try parseTimestampDigits(text[11..13]);
    const minute = try parseTimestampDigits(text[14..16]);
    const second = try parseTimestampDigits(text[17..19]);
    if (year < 1970 or
        month < 1 or
        month > 12 or
        day < 1 or
        day > daysInMonth(year, month) or
        hour > 23 or
        minute > 59 or
        second > 59)
    {
        return error.InvalidGatewayTimestamp;
    }

    var cursor: usize = 19;
    var fractional_ms: i64 = 0;
    if (cursor < text.len and text[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        const fraction = text[fraction_start..cursor];
        if (fraction.len == 0 or fraction.len > 9) {
            return error.InvalidGatewayTimestamp;
        }
        const digits = @min(fraction.len, 3);
        fractional_ms = @intCast(try parseTimestampDigits(fraction[0..digits]));
        if (digits == 1) fractional_ms *= 100;
        if (digits == 2) fractional_ms *= 10;
    }
    if (cursor + 1 != text.len or text[cursor] != 'Z') {
        return error.InvalidGatewayTimestamp;
    }

    const days = daysFromCivil(year, month, day);
    if (days < 0) return error.InvalidGatewayTimestamp;
    const seconds = std.math.add(
        i64,
        std.math.mul(i64, days, std.time.s_per_day) catch
            return error.InvalidGatewayTimestamp,
        @as(i64, @intCast(hour * std.time.s_per_hour +
            minute * std.time.s_per_min +
            second)),
    ) catch return error.InvalidGatewayTimestamp;
    return std.math.add(
        i64,
        std.math.mul(i64, seconds, std.time.ms_per_s) catch
            return error.InvalidGatewayTimestamp,
        fractional_ms,
    ) catch return error.InvalidGatewayTimestamp;
}

fn parseTimestampDigits(text: []const u8) error{InvalidGatewayTimestamp}!u32 {
    if (text.len == 0) return error.InvalidGatewayTimestamp;
    var result: u32 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidGatewayTimestamp;
        result = std.math.mul(u32, result, 10) catch
            return error.InvalidGatewayTimestamp;
        result = std.math.add(u32, result, byte - '0') catch
            return error.InvalidGatewayTimestamp;
    }
    return result;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        else => 0,
    };
}

fn daysFromCivil(year_value: u32, month_value: u32, day_value: u32) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value;
    const day: i64 = day_value;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub fn validGatewayGenerationId(id: []const u8) bool {
    if (id.len != 30 or !std.mem.startsWith(u8, id, "gen_")) return false;
    for (id[4..]) |char| switch (char) {
        '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => {},
        else => return false,
    };
    return true;
}

test "Gateway timestamps parse UTC fractions strictly" {
    try std.testing.expectEqual(
        @as(i64, 1_775_045_467_000),
        try parseGatewayTimestamp("2026-04-01T12:11:07Z"),
    );
    try std.testing.expectEqual(
        @as(i64, 1_775_045_467_123),
        try parseGatewayTimestamp("2026-04-01T12:11:07.123456Z"),
    );
    try std.testing.expectError(
        error.InvalidGatewayTimestamp,
        parseGatewayTimestamp("2026-02-30T12:11:07Z"),
    );
    try std.testing.expectError(
        error.InvalidGatewayTimestamp,
        parseGatewayTimestamp("2026-04-01T12:11:07+00:00"),
    );
}

test "Gateway timestamp parser handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzGatewayTimestamp, .{
        .corpus = &.{
            "",
            "2026-04-01T12:11:07Z",
            "2026-04-01T12:11:07.123456789Z",
        },
    });
}

fn fuzzGatewayTimestamp(_: void, smith: *std.testing.Smith) !void {
    var buffer: [128]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    _ = parseGatewayTimestamp(buffer[0..len]) catch return;
}

/// Team identifiers reach the gateway as a query value, so reject anything that
/// would need percent-encoding rather than build a malformed URL. Accepts both
/// the `team_` id form and the slug form.
pub fn validGatewayTeam(team: []const u8) bool {
    if (team.len == 0 or team.len > 128) return false;
    for (team) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

pub const ProviderCompletionDisposition = enum {
    completed,
    length_limited,
    interrupted,
    provider_failure,
    invalid_completion,
};

pub fn allToolCallsProviderExecuted(tool_calls: []const ToolCall) bool {
    if (tool_calls.len == 0) return false;
    for (tool_calls) |call| {
        if (call.provenance != .provider_executed) return false;
    }
    return true;
}

pub fn classifyProviderCompletion(completion: GatewayCompletion) ProviderCompletionDisposition {
    const finish_reason = completion.finish_reason orelse return .interrupted;
    return switch (finish_reason) {
        .provider_error, .content_filter => .provider_failure,
        .length => .length_limited,
        .tool_calls => if (completion.tool_calls.len > 0) .completed else .invalid_completion,
        .stop => if (completion.tool_calls.len == 0 or allToolCallsProviderExecuted(completion.tool_calls)) .completed else .invalid_completion,
        .other => if (completion.tool_calls.len == 0) .completed else .invalid_completion,
    };
}

test "provider completion disposition classifies finish reason and tool presence" {
    const call = ToolCall{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{}",
    };
    const cases = [_]struct {
        finish_reason: ?ProviderFinishReason,
        has_tool_calls: bool,
        expected: ProviderCompletionDisposition,
    }{
        .{ .finish_reason = null, .has_tool_calls = false, .expected = .interrupted },
        .{ .finish_reason = null, .has_tool_calls = true, .expected = .interrupted },
        .{ .finish_reason = .provider_error, .has_tool_calls = false, .expected = .provider_failure },
        .{ .finish_reason = .provider_error, .has_tool_calls = true, .expected = .provider_failure },
        .{ .finish_reason = .content_filter, .has_tool_calls = false, .expected = .provider_failure },
        .{ .finish_reason = .content_filter, .has_tool_calls = true, .expected = .provider_failure },
        .{ .finish_reason = .length, .has_tool_calls = false, .expected = .length_limited },
        .{ .finish_reason = .length, .has_tool_calls = true, .expected = .length_limited },
        .{ .finish_reason = .tool_calls, .has_tool_calls = true, .expected = .completed },
        .{ .finish_reason = .tool_calls, .has_tool_calls = false, .expected = .invalid_completion },
        .{ .finish_reason = .stop, .has_tool_calls = true, .expected = .invalid_completion },
        .{ .finish_reason = .other, .has_tool_calls = true, .expected = .invalid_completion },
        .{ .finish_reason = .stop, .has_tool_calls = false, .expected = .completed },
        .{ .finish_reason = .other, .has_tool_calls = false, .expected = .completed },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            classifyProviderCompletion(.{
                .finish_reason = case.finish_reason,
                .tool_calls = if (case.has_tool_calls) &.{call} else &.{},
            }),
        );
    }
}

test "provider completion disposition allows terminal provider-executed tool calls" {
    const provider_call = ToolCall{
        .id = "provider_search",
        .name = "perplexity_search",
        .arguments_json = "{}",
        .provider_result = "{\"results\":[]}",
        .provenance = .provider_executed,
    };
    const local_call = ToolCall{
        .id = "local_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    };
    const mixed_calls = [_]ToolCall{ provider_call, local_call };

    try std.testing.expectEqual(
        ProviderCompletionDisposition.completed,
        classifyProviderCompletion(.{
            .finish_reason = .stop,
            .tool_calls = &.{provider_call},
        }),
    );
    try std.testing.expectEqual(
        ProviderCompletionDisposition.invalid_completion,
        classifyProviderCompletion(.{
            .finish_reason = .stop,
            .tool_calls = &.{local_call},
        }),
    );
    try std.testing.expectEqual(
        ProviderCompletionDisposition.invalid_completion,
        classifyProviderCompletion(.{
            .finish_reason = .stop,
            .tool_calls = &mixed_calls,
        }),
    );
    try std.testing.expectEqual(
        ProviderCompletionDisposition.invalid_completion,
        classifyProviderCompletion(.{
            .finish_reason = .other,
            .tool_calls = &.{provider_call},
        }),
    );
}

test "ProviderFinishReason accepts only the canonical provider domain" {
    const cases = [_]struct {
        raw: []const u8,
        reason: ProviderFinishReason,
    }{
        .{ .raw = "stop", .reason = .stop },
        .{ .raw = "length", .reason = .length },
        .{ .raw = "content-filter", .reason = .content_filter },
        .{ .raw = "tool-calls", .reason = .tool_calls },
        .{ .raw = "error", .reason = .provider_error },
        .{ .raw = "other", .reason = .other },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.reason, ProviderFinishReason.parse_unified(case.raw).?);
        try std.testing.expectEqualStrings(case.raw, case.reason.label());
    }
    try std.testing.expect(ProviderFinishReason.parse_unified("") == null);
    try std.testing.expect(ProviderFinishReason.parse_unified("future-reason") == null);
    try std.testing.expectEqual(ProviderFinishReason.tool_calls, ProviderFinishReason.parse_legacy("tool_calls").?);
    try std.testing.expectEqual(ProviderFinishReason.content_filter, ProviderFinishReason.parse_legacy("content_filter").?);
}

pub const AuthoritativeToolAdmission = union(enum) {
    admitted,
    reject_malformed_identity: FinalToolIdentity,
    reject_malformed_provider_result: ProviderResultIdentityFailure,
    reject_malformed_provider_arguments,
    reject_duplicate_identity,
};

pub fn authoritativeToolAdmission(completion: GatewayCompletion) AuthoritativeToolAdmission {
    if (completion.provider_result_identity_failure) |failure| {
        return .{ .reject_malformed_provider_result = failure };
    }

    for (completion.tool_calls) |call| {
        const final_identity = if (call.final_identity == .valid and call.id.len == 0)
            FinalToolIdentity.empty
        else
            call.final_identity;
        if (final_identity != .valid) {
            return if (call.provenance == .provider_executed)
                .{ .reject_malformed_provider_result = switch (final_identity) {
                    .absent => .absent,
                    .empty => .empty,
                    .wrong_type => .wrong_type,
                    .valid => unreachable,
                } }
            else
                .{ .reject_malformed_identity = final_identity };
        }
    }

    for (completion.tool_calls, 0..) |call, i| {
        for (completion.tool_calls[0..i]) |prior| {
            if (std.mem.eql(u8, prior.id, call.id)) return .reject_duplicate_identity;
        }
    }

    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and
            call.argument_integrity == .malformed_json)
        {
            return .reject_malformed_provider_arguments;
        }
    }

    for (completion.tool_calls) |call| {
        if (call.provenance == .provider_executed and call.provider_result == null) {
            return .{ .reject_malformed_provider_result = .missing_result };
        }
    }

    return .admitted;
}

test "authoritative tool admission rejects duplicate final ids across provenance" {
    const local_calls = [_]ToolCall{
        .{ .id = "duplicate_1", .name = "read_file", .arguments_json = "{\"path\":\"a\"}" },
        .{ .id = "duplicate_1", .name = "read_file", .arguments_json = "{\"path\":\"b\"}" },
    };
    const provider_calls = [_]ToolCall{
        .{
            .id = "duplicate_1",
            .name = "parallel_search",
            .arguments_json = "{}",
            .provider_result = "{\"results\":[]}",
            .provenance = .provider_executed,
        },
        .{
            .id = "duplicate_1",
            .name = "parallel_search",
            .arguments_json = "{}",
            .provider_result = "{\"results\":[]}",
            .provenance = .provider_executed,
        },
    };
    const mixed_calls = [_]ToolCall{
        .{
            .id = "duplicate_1",
            .name = "parallel_search",
            .arguments_json = "{}",
            .provider_result = "{\"results\":[]}",
            .provenance = .provider_executed,
        },
        .{ .id = "duplicate_1", .name = "read_file", .arguments_json = "{\"path\":\"a\"}" },
    };
    const cases = [_][]const ToolCall{
        &local_calls,
        &provider_calls,
        &mixed_calls,
    };

    for (cases) |calls| {
        switch (authoritativeToolAdmission(.{ .tool_calls = calls })) {
            .reject_duplicate_identity => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "authoritative tool admission rejects malformed provider arguments but admits local recovery" {
    const local_call = ToolCall{
        .id = "local_1",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    };
    try std.testing.expectEqual(
        AuthoritativeToolAdmission.admitted,
        authoritativeToolAdmission(.{ .tool_calls = &.{local_call} }),
    );

    const provider_call = ToolCall{
        .id = "provider_1",
        .name = "parallel_search",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
        .provider_result = "{\"results\":[]}",
        .provenance = .provider_executed,
    };
    try std.testing.expectEqual(
        AuthoritativeToolAdmission.reject_malformed_provider_arguments,
        authoritativeToolAdmission(.{ .tool_calls = &.{provider_call} }),
    );
}

pub const ConversationLanguage = struct {
    pub const max_len: usize = 24;

    bytes: [max_len]u8 = [_]u8{0} ** max_len,
    len: u8 = 0,

    pub fn default() ConversationLanguage {
        return literal("und");
    }

    pub fn literal(comptime tag: []const u8) ConversationLanguage {
        if (tag.len == 0 or tag.len > max_len) @compileError("invalid conversation language literal");

        var value: ConversationLanguage = .{};
        value.len = @intCast(tag.len);
        @memcpy(value.bytes[0..tag.len], tag);
        return value;
    }

    pub fn fromSlice(tag: []const u8) !ConversationLanguage {
        const trimmed = std.mem.trim(u8, tag, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_len) return error.InvalidConversationLanguage;

        var value: ConversationLanguage = .{};
        value.len = @intCast(trimmed.len);
        @memcpy(value.bytes[0..trimmed.len], trimmed);
        return value;
    }

    pub fn view(self: *const ConversationLanguage) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const AssistantHistoryTurn = struct {
    user: UserTurn,
    assistant: []u8,
    execution: ExecutionMemory = .{},
};

pub const StableBackgroundRecordId = [16]u8;

pub const BackgroundCommandHistoryTurn = struct {
    user: UserTurn,
    assistant: ?[]u8 = null,
    execution: ExecutionMemory = .{},
    log_path: []u8,
    expect_url: bool,
    url: ?[]u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
};

pub const InterruptedTerminalReason = enum {
    cancelled,
    failed,
};

pub const InterruptedHistoryTurn = struct {
    user: UserTurn,
    assistant: ?[]u8 = null,
    tool_call: ?ToolCall = null,
    completed_tool_names: [][]u8 = &.{},
    execution: ExecutionMemory = .{},
    cancelled_command: ?CancelledCommandPresentation = null,
    terminal_reason: InterruptedTerminalReason = .cancelled,
};

pub const CompactedSummaryHistoryTurn = struct {
    summary: []u8,
    removed_turn_count: usize,
    compaction_count: usize,
    /// Legacy compacted root text retained for storage compatibility. It is
    /// model context only and never permission authority.
    root_user_messages: [][]u8 = &.{},
    /// Legacy completeness marker retained for storage compatibility.
    root_user_messages_complete: bool = true,
    /// Legacy compacted feedback retained for storage compatibility. It is not
    /// permission authority.
    permission_feedback: [][]u8 = &.{},
    /// Legacy completeness marker retained for storage compatibility.
    permission_feedback_complete: bool = true,
};

pub const HistoryTurn = union(enum) {
    compacted_summary: CompactedSummaryHistoryTurn,
    assistant: AssistantHistoryTurn,
    background_command: BackgroundCommandHistoryTurn,
    interrupted: InterruptedHistoryTurn,
};

pub const FinishedPromptProjection = enum {
    history_default,
    assistant_text,
};

pub const SnapshotFileOwnership = struct {
    ctx: *anyopaque,
    retain_fn: *const fn (*anyopaque) void,
    release_fn: *const fn (*anyopaque) void,
    transfer_fn: *const fn (*anyopaque) void,

    pub fn retain(self: SnapshotFileOwnership) void {
        self.retain_fn(self.ctx);
    }

    pub fn release(self: SnapshotFileOwnership) void {
        self.release_fn(self.ctx);
    }

    pub fn transfer(self: SnapshotFileOwnership) void {
        self.transfer_fn(self.ctx);
    }
};

pub const FinishedPrompt = struct {
    turn: HistoryTurn,
    summary: ?TurnSummary = null,
    terminal_projection: FinishedPromptProjection = .history_default,
    terminal_outcome: ?TurnPresentationOutcome = null,
    snapshot_file_ownership: ?SnapshotFileOwnership = null,
};

pub const PermissionMode = enum {
    ask,
    auto,
    yolo,
};

pub const RuleDecision = enum {
    none,
    allow,
    ask,
    deny,
};

pub const ContentHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const ToolChoice = enum {
    auto,
    none,
    required,

    pub fn label(self: ToolChoice) []const u8 {
        return @tagName(self);
    }

    pub fn parse(raw: []const u8) ?ToolChoice {
        if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(raw, "none")) return .none;
        return null;
    }
};

pub const ReasoningEffort = union(enum) {
    auto,
    named: Name,

    pub const max_name_bytes = 64;
    pub const max_options = 16;

    pub const Name = struct {
        bytes: [max_name_bytes]u8,
        len: u8,

        fn parse(raw: []const u8) ?Name {
            if (raw.len == 0 or raw.len > max_name_bytes) return null;
            for (raw) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return null;
            }

            var name = Name{
                .bytes = [_]u8{0} ** max_name_bytes,
                .len = @intCast(raw.len),
            };
            @memcpy(name.bytes[0..raw.len], raw);
            return name;
        }

        fn literal(comptime raw: []const u8) Name {
            const parsed = comptime Name.parse(raw);
            if (parsed) |name| return name;
            @compileError("invalid reasoning effort literal: " ++ raw);
        }

        fn view(self: *const Name) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    pub fn literal(comptime raw: []const u8) ReasoningEffort {
        return .{ .named = Name.literal(raw) };
    }

    pub fn label(self: *const ReasoningEffort) []const u8 {
        return switch (self.*) {
            .auto => "auto",
            .named => |*name| name.view(),
        };
    }

    pub fn displayLabel(self: *const ReasoningEffort) []const u8 {
        return switch (self.*) {
            .auto => "default",
            .named => self.label(),
        };
    }

    pub fn gatewayValue(self: *const ReasoningEffort) ?[]const u8 {
        return switch (self.*) {
            .auto => null,
            .named => self.label(),
        };
    }

    pub fn parse(raw: []const u8) ?ReasoningEffort {
        if (std.ascii.eqlIgnoreCase(raw, "auto") or
            std.ascii.eqlIgnoreCase(raw, "adaptive") or
            std.ascii.eqlIgnoreCase(raw, "default")) return .auto;
        return .{ .named = Name.parse(raw) orelse return null };
    }

    pub fn parseDisplayLabel(raw: []const u8) ?ReasoningEffort {
        return parse(raw);
    }

    pub fn eql(a: ReasoningEffort, b: ReasoningEffort) bool {
        return switch (a) {
            .auto => b == .auto,
            .named => |a_name| switch (b) {
                .auto => false,
                .named => |b_name| std.mem.eql(u8, a_name.view(), b_name.view()),
            },
        };
    }

    pub fn isDefault(self: ReasoningEffort) bool {
        return self == .auto;
    }
};

pub const ToolPermissionDenialReason = enum {
    user_denied,
    auto_denied,
    policy_denied,
    permission_required,
};

pub const ToolPermissionDecision = enum {
    once,
    always,
    deny,
    policy_denied,
    permission_required,

    pub fn isDenied(self: ToolPermissionDecision) bool {
        return switch (self) {
            .deny, .policy_denied, .permission_required => true,
            .once, .always => false,
        };
    }

    pub fn denialReason(self: ToolPermissionDecision) ?ToolPermissionDenialReason {
        return switch (self) {
            .deny => .user_denied,
            .policy_denied => .policy_denied,
            .permission_required => .permission_required,
            .once, .always => null,
        };
    }
};

pub const PermissionGrant = struct {
    tool_name: []u8,
    target_path: []u8,
};

pub const PermissionAction = enum {
    allow,
    ask,
    deny,
};

pub const PermissionRule = struct {
    permission: []u8,
    pattern: []u8,
    action: PermissionAction,
};

pub const PermissionRuleSet = struct {
    rules: []PermissionRule = &.{},

    pub fn deinit(self: *PermissionRuleSet, alloc: std.mem.Allocator) void {
        freePermissionRuleSlice(alloc, self.rules);
        self.* = .{};
    }
};

pub const ToolActivityKind = enum {
    read,
    list,
    write,
    edit,
    open,
    command,
    subagent,
    ask,
};

pub const QuestionOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const QuestionBatchEntry = struct {
    question: []const u8,
    options: []const QuestionOption,
};

/// One persisted answer from an interactive question batch. The strings are
/// borrowed from the short-lived arena that decodes the completed tool result.
pub const QuestionAnswer = struct {
    question: []const u8,
    answer: []const u8,
};

pub const ResolveMode = enum {
    existing,
    create,
};

pub fn freeHistoryTurn(alloc: std.mem.Allocator, turn: HistoryTurn) void {
    switch (turn) {
        .compacted_summary => |entry| {
            alloc.free(entry.summary);
            freeCompletedToolNames(alloc, entry.root_user_messages);
            freePermissionFeedback(alloc, entry.permission_feedback);
        },
        .assistant => |entry| {
            freeUserTurn(alloc, entry.user);
            alloc.free(entry.assistant);
            freeExecutionMemory(alloc, entry.execution);
        },
        .background_command => |entry| {
            freeUserTurn(alloc, entry.user);
            if (entry.assistant) |assistant| alloc.free(assistant);
            freeExecutionMemory(alloc, entry.execution);
            alloc.free(entry.log_path);
            if (entry.url) |url| alloc.free(url);
        },
        .interrupted => |entry| {
            freeUserTurn(alloc, entry.user);
            if (entry.assistant) |assistant| alloc.free(assistant);
            if (entry.tool_call) |tool_call| freeToolCall(alloc, tool_call);
            freeCompletedToolNames(alloc, entry.completed_tool_names);
            freeExecutionMemory(alloc, entry.execution);
            if (entry.cancelled_command) |presentation| {
                freeCancelledCommandPresentation(alloc, presentation);
            }
        },
    }
}

pub fn freeHistoryTurnSlice(alloc: std.mem.Allocator, turns: []HistoryTurn) void {
    for (turns) |turn| {
        freeHistoryTurn(alloc, turn);
    }
    alloc.free(turns);
}

pub fn freeFinishedPrompt(alloc: std.mem.Allocator, finished: FinishedPrompt) void {
    freeHistoryTurn(alloc, finished.turn);
    if (finished.snapshot_file_ownership) |ownership| ownership.release();
}

pub fn dupeHistoryTurn(alloc: std.mem.Allocator, turn: HistoryTurn) !HistoryTurn {
    return switch (turn) {
        .compacted_summary => |entry| blk: {
            const summary = try alloc.dupe(u8, entry.summary);
            errdefer alloc.free(summary);
            const root_user_messages = try dupeCompletedToolNames(
                alloc,
                entry.root_user_messages,
            );
            errdefer freeCompletedToolNames(alloc, root_user_messages);
            const permission_feedback = try dupePermissionFeedback(
                alloc,
                entry.permission_feedback,
            );
            break :blk .{ .compacted_summary = .{
                .summary = summary,
                .removed_turn_count = entry.removed_turn_count,
                .compaction_count = entry.compaction_count,
                .root_user_messages = root_user_messages,
                .root_user_messages_complete = entry.root_user_messages_complete,
                .permission_feedback = permission_feedback,
                .permission_feedback_complete = entry.permission_feedback_complete,
            } };
        },
        .assistant => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = try alloc.dupe(u8, entry.assistant);
            errdefer alloc.free(assistant);

            const execution = try dupeExecutionMemory(alloc, entry.execution);
            break :blk .{ .assistant = .{
                .user = user,
                .assistant = assistant,
                .execution = execution,
            } };
        },
        .background_command => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);

            const execution = try dupeExecutionMemory(alloc, entry.execution);
            errdefer freeExecutionMemory(alloc, execution);

            const log_path = try alloc.dupe(u8, entry.log_path);
            errdefer alloc.free(log_path);

            const url = if (entry.url) |src| try alloc.dupe(u8, src) else null;
            errdefer if (url) |owned| alloc.free(owned);

            break :blk .{ .background_command = .{
                .user = user,
                .assistant = assistant,
                .execution = execution,
                .log_path = log_path,
                .expect_url = entry.expect_url,
                .url = url,
                .background_record_id = entry.background_record_id,
            } };
        },
        .interrupted => |entry| blk: {
            const user = try dupeUserTurn(alloc, entry.user);
            errdefer freeUserTurn(alloc, user);

            const assistant = if (entry.assistant) |text| try alloc.dupe(u8, text) else null;
            errdefer if (assistant) |text| alloc.free(text);

            const tool_call = if (entry.tool_call) |call| try dupeToolCall(alloc, call) else null;
            errdefer if (tool_call) |call| freeToolCall(alloc, call);

            const completed_tool_names = try dupeCompletedToolNames(alloc, entry.completed_tool_names);
            errdefer freeCompletedToolNames(alloc, completed_tool_names);

            const cancelled_command = if (entry.cancelled_command) |presentation|
                try dupeCancelledCommandPresentation(alloc, presentation)
            else
                null;
            errdefer if (cancelled_command) |presentation| {
                freeCancelledCommandPresentation(alloc, presentation);
            };

            const execution = try dupeExecutionMemory(alloc, entry.execution);

            break :blk .{ .interrupted = .{
                .user = user,
                .assistant = assistant,
                .tool_call = tool_call,
                .completed_tool_names = completed_tool_names,
                .execution = execution,
                .cancelled_command = cancelled_command,
                .terminal_reason = entry.terminal_reason,
            } };
        },
    };
}

pub fn dupeCancelledCommandPresentation(
    alloc: std.mem.Allocator,
    presentation: CancelledCommandPresentation,
) !CancelledCommandPresentation {
    const output_replay = if (presentation.output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    return .{
        .output_replay = output_replay,
        .command_artifact_handle = if (presentation.command_artifact_handle) |handle|
            try alloc.dupe(u8, handle)
        else
            null,
    };
}

pub fn freeCancelledCommandPresentation(
    alloc: std.mem.Allocator,
    presentation: CancelledCommandPresentation,
) void {
    if (presentation.output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    if (presentation.command_artifact_handle) |handle| alloc.free(@constCast(handle));
}

pub fn dupeFinishedPrompt(alloc: std.mem.Allocator, finished: FinishedPrompt) !FinishedPrompt {
    const turn = try dupeHistoryTurn(alloc, finished.turn);
    if (finished.snapshot_file_ownership) |ownership| ownership.retain();
    return .{
        .turn = turn,
        .summary = finished.summary,
        .terminal_projection = finished.terminal_projection,
        .terminal_outcome = finished.terminal_outcome,
        .snapshot_file_ownership = finished.snapshot_file_ownership,
    };
}

pub fn dupeCompletedToolNames(alloc: std.mem.Allocator, items: []const []u8) ![][]u8 {
    if (items.len == 0) return &.{};

    const copy = try alloc.alloc([]u8, items.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i]);
        }
    }

    for (items, 0..) |item, i| {
        copy[i] = try alloc.dupe(u8, item);
        copied += 1;
    }
    return copy;
}

pub fn freeCompletedToolNames(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    if (items.len > 0) alloc.free(items);
}

pub fn dupeExecutionMemory(alloc: std.mem.Allocator, memory: ExecutionMemory) !ExecutionMemory {
    const tool_steps = try dupeToolExecutionSteps(alloc, memory.tool_steps);
    errdefer freeToolExecutionSteps(alloc, tool_steps);
    const files = try dupeFileEvidenceSlice(alloc, memory.files);
    return .{
        .tool_steps = tool_steps,
        .files = files,
    };
}

pub fn freeExecutionMemory(alloc: std.mem.Allocator, memory: ExecutionMemory) void {
    freeToolExecutionSteps(alloc, memory.tool_steps);
    freeFileEvidenceSlice(alloc, memory.files);
}

pub fn dupeToolExecutionSteps(alloc: std.mem.Allocator, steps: []const ToolExecutionStep) ![]ToolExecutionStep {
    if (steps.len == 0) return &.{};

    const copy = try alloc.alloc(ToolExecutionStep, steps.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeToolExecutionStep(alloc, copy[i]);
    }

    for (steps, 0..) |step, i| {
        copy[i] = try dupeToolExecutionStep(alloc, step);
        copied += 1;
    }
    return copy;
}

pub fn freeToolExecutionSteps(alloc: std.mem.Allocator, steps: []ToolExecutionStep) void {
    for (steps) |step| freeToolExecutionStep(alloc, step);
    if (steps.len > 0) alloc.free(steps);
}

fn dupeToolExecutionStep(alloc: std.mem.Allocator, step: ToolExecutionStep) !ToolExecutionStep {
    const assistant = if (step.assistant) |text| try alloc.dupe(u8, text) else null;
    errdefer if (assistant) |text| alloc.free(text);
    const tool_calls = try dupeToolCallSlice(alloc, step.tool_calls);
    errdefer freeToolCallSlice(alloc, tool_calls);
    const tool_results = try dupePersistedToolResults(alloc, step.tool_results);
    errdefer freePersistedToolResults(alloc, tool_results);

    return .{
        .assistant = assistant,
        .tool_calls = tool_calls,
        .tool_results = tool_results,
    };
}

fn freeToolExecutionStep(alloc: std.mem.Allocator, step: ToolExecutionStep) void {
    if (step.assistant) |assistant| alloc.free(assistant);
    freeToolCallSlice(alloc, step.tool_calls);
    freePersistedToolResults(alloc, step.tool_results);
}

pub fn dupeToolCallSlice(alloc: std.mem.Allocator, calls: []const ToolCall) ![]ToolCall {
    if (calls.len == 0) return &.{};

    const copy = try alloc.alloc(ToolCall, calls.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeToolCall(alloc, copy[i]);
    }

    for (calls, 0..) |call, i| {
        copy[i] = try dupeToolCall(alloc, call);
        copied += 1;
    }
    return copy;
}

pub fn freeToolCallSlice(alloc: std.mem.Allocator, calls: []ToolCall) void {
    for (calls) |call| freeToolCall(alloc, call);
    if (calls.len > 0) alloc.free(calls);
}

pub fn dupePersistedToolResults(alloc: std.mem.Allocator, results: []const PersistedToolResult) ![]PersistedToolResult {
    if (results.len == 0) return &.{};

    const copy = try alloc.alloc(PersistedToolResult, results.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freePersistedToolResult(alloc, copy[i]);
    }

    for (results, 0..) |result, i| {
        copy[i] = try dupePersistedToolResult(alloc, result);
        copied += 1;
    }
    return copy;
}

pub fn freePersistedToolResults(alloc: std.mem.Allocator, results: []PersistedToolResult) void {
    for (results) |result| freePersistedToolResult(alloc, result);
    if (results.len > 0) alloc.free(results);
}

pub fn dupeCommittedFilePresentation(
    alloc: std.mem.Allocator,
    presentation: CommittedFilePresentation,
) !CommittedFilePresentation {
    const path = try alloc.dupe(u8, presentation.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(CommittedFilePresentationLine, presentation.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (presentation.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = line.kind,
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const previous_content = if (presentation.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (presentation.after_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?ToolLifecycleId = if (presentation.lifecycle_id) |id| .{
        .turn_id = id.turn_id,
        .call_id = try alloc.dupe(u8, id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = presentation.kind,
        .lines = lines,
        .additions = presentation.additions,
        .deletions = presentation.deletions,
        .truncated = presentation.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

pub fn freeCommittedFilePresentation(
    alloc: std.mem.Allocator,
    presentation: CommittedFilePresentation,
) void {
    alloc.free(@constCast(presentation.path));
    for (presentation.lines) |line| alloc.free(@constCast(line.text));
    if (presentation.lines.len > 0) alloc.free(@constCast(presentation.lines));
    if (presentation.previous_content) |content| alloc.free(@constCast(content));
    if (presentation.after_content) |content| alloc.free(@constCast(content));
    if (presentation.lifecycle_id) |id| alloc.free(@constCast(id.call_id));
}

fn dupePersistedToolResult(alloc: std.mem.Allocator, result: PersistedToolResult) !PersistedToolResult {
    const tool_call_id = try alloc.dupe(u8, result.tool_call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, result.tool_name);
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, result.output);
    errdefer alloc.free(output);
    const output_handle = if (result.output_handle) |handle| try alloc.dupe(u8, handle) else null;
    errdefer if (output_handle) |handle| alloc.free(handle);
    const preview = if (result.preview) |text| try alloc.dupe(u8, text) else null;
    errdefer if (preview) |text| alloc.free(text);
    const permission_feedback = try dupePermissionFeedback(alloc, result.permission_feedback);
    errdefer freePermissionFeedback(alloc, permission_feedback);
    const committed_file_presentation = if (result.committed_file_presentation) |presentation|
        try dupeCommittedFilePresentation(alloc, presentation)
    else
        null;
    errdefer if (committed_file_presentation) |presentation| freeCommittedFilePresentation(alloc, presentation);
    const command_output_replay = if (result.command_output_replay) |replay|
        try dupeCommandOutputReplay(alloc, replay)
    else
        null;
    errdefer if (command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = result.status,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = result.output_bytes,
        .stored_output_bytes = result.stored_output_bytes,
        .truncated = result.truncated,
        .provider_native = result.provider_native,
        .created_at_ms = result.created_at_ms,
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_process_presentation = result.command_process_presentation,
    };
}

fn freePersistedToolResult(alloc: std.mem.Allocator, result: PersistedToolResult) void {
    alloc.free(result.tool_call_id);
    alloc.free(result.tool_name);
    alloc.free(result.output);
    if (result.output_handle) |handle| alloc.free(handle);
    if (result.preview) |preview| alloc.free(preview);
    freePermissionFeedback(alloc, result.permission_feedback);
    if (result.committed_file_presentation) |presentation| {
        freeCommittedFilePresentation(alloc, presentation);
    }
    if (result.command_output_replay) |replay| freeCommandOutputReplay(alloc, replay);
}

pub fn dupeCommandOutputReplay(
    alloc: std.mem.Allocator,
    replay: CommandOutputReplay,
) !CommandOutputReplay {
    return switch (replay) {
        .available => |descriptor| .{ .available = .{
            .handle = try alloc.dupe(u8, descriptor.handle),
            .framed_bytes = descriptor.framed_bytes,
        } },
        .unavailable => .unavailable,
    };
}

pub fn freeCommandOutputReplay(
    alloc: std.mem.Allocator,
    replay: CommandOutputReplay,
) void {
    switch (replay) {
        .available => |descriptor| alloc.free(@constCast(descriptor.handle)),
        .unavailable => {},
    }
}

pub fn dupePermissionFeedback(
    alloc: std.mem.Allocator,
    feedback: []const []const u8,
) ![][]u8 {
    if (feedback.len == 0) return &.{};

    const copy = try alloc.alloc([]u8, feedback.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |text| alloc.free(text);
    }
    for (feedback, 0..) |text, i| {
        copy[i] = try alloc.dupe(u8, text);
        copied += 1;
    }
    return copy;
}

pub fn freePermissionFeedback(alloc: std.mem.Allocator, feedback: [][]u8) void {
    for (feedback) |text| alloc.free(text);
    if (feedback.len > 0) alloc.free(feedback);
}

pub fn dupeFileEvidenceSlice(alloc: std.mem.Allocator, files: []const FileEvidence) ![]FileEvidence {
    if (files.len == 0) return &.{};

    const copy = try alloc.alloc(FileEvidence, files.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) freeFileEvidence(alloc, copy[i]);
    }

    for (files, 0..) |file, i| {
        copy[i] = try dupeFileEvidence(alloc, file);
        copied += 1;
    }
    return copy;
}

pub fn freeFileEvidenceSlice(alloc: std.mem.Allocator, files: []FileEvidence) void {
    for (files) |file| freeFileEvidence(alloc, file);
    if (files.len > 0) alloc.free(files);
}

fn dupeFileEvidence(alloc: std.mem.Allocator, file: FileEvidence) !FileEvidence {
    const path = try alloc.dupe(u8, file.path);
    errdefer alloc.free(path);
    const new_path = if (file.new_path) |value| try alloc.dupe(u8, value) else null;
    errdefer if (new_path) |value| alloc.free(value);
    const tool_call_id = try alloc.dupe(u8, file.tool_call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, file.tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = file.action,
        .status = file.status,
        .model_view_covers_full_file = file.model_view_covers_full_file,
        .stale = file.stale,
    };
}

fn freeFileEvidence(alloc: std.mem.Allocator, file: FileEvidence) void {
    alloc.free(file.path);
    if (file.new_path) |new_path| alloc.free(new_path);
    alloc.free(file.tool_call_id);
    alloc.free(file.tool_name);
}

pub fn dupeToolCall(alloc: std.mem.Allocator, call: ToolCall) !ToolCall {
    const id = try alloc.dupe(u8, call.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, call.name);
    errdefer alloc.free(name);
    const arguments_json = try alloc.dupe(u8, call.arguments_json);
    errdefer alloc.free(arguments_json);
    const provisional_id = if (call.provisional_id) |value| try alloc.dupe(u8, value) else null;
    errdefer if (provisional_id) |value| alloc.free(value);
    const provider_result = if (call.provider_result) |result| try alloc.dupe(u8, result) else null;
    errdefer if (provider_result) |result| alloc.free(result);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = call.argument_integrity,
        .provisional_id = provisional_id,
        .provider_result = provider_result,
        .final_identity = call.final_identity,
        .provenance = call.provenance,
    };
}

pub fn freeToolCall(alloc: std.mem.Allocator, call: ToolCall) void {
    alloc.free(call.id);
    alloc.free(call.name);
    alloc.free(call.arguments_json);
    if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
    if (call.provider_result) |provider_result| alloc.free(provider_result);
}

test "dupeToolCall preserves argument integrity" {
    const source = ToolCall{
        .id = "call_1",
        .name = "ask_user_question",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    };

    const copy = try dupeToolCall(std.testing.allocator, source);
    defer freeToolCall(std.testing.allocator, copy);

    try std.testing.expectEqual(ToolArgumentIntegrity.malformed_json, copy.argument_integrity);
}

test "ToolArgumentIntegrity accepts complete serialized JSON roots" {
    const cases = [_][]const u8{
        "  {\"first\":1,\"second\":1e+02} \n",
        "[1,{\"nested\":true}]",
        "null",
        "true",
        "42",
        "\"text\"",
    };

    for (cases) |serialized| {
        try std.testing.expectEqual(
            ToolArgumentIntegrity.valid,
            try ToolArgumentIntegrity.classifySerialized(std.testing.allocator, serialized),
        );
    }
}

test "ToolArgumentIntegrity rejects malformed trailing and duplicate-key JSON" {
    const cases = [_][]const u8{
        "{]",
        "{} trailing",
        "{\"depth\":1,\"depth\":2}",
    };

    for (cases) |serialized| {
        try std.testing.expectEqual(
            ToolArgumentIntegrity.malformed_json,
            try ToolArgumentIntegrity.classifySerialized(std.testing.allocator, serialized),
        );
    }
}

test "ToolArgumentIntegrity preserves parser allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        ToolArgumentIntegrity.classifySerialized(failing.allocator(), "{\"path\":\"src/main.zig\"}"),
    );
}

pub fn freeUserTurn(alloc: std.mem.Allocator, user: UserTurn) void {
    alloc.free(user.text);
    freeImageAttachmentSlice(alloc, user.images);
    if (user.work_id) |work_id| alloc.free(work_id);
}

pub fn dupeUserTurn(alloc: std.mem.Allocator, user: UserTurn) !UserTurn {
    const text = try alloc.dupe(u8, user.text);
    errdefer alloc.free(text);

    const images = try dupeImageAttachmentSlice(alloc, user.images);
    errdefer freeImageAttachmentSlice(alloc, images);

    const work_id = if (user.work_id) |value| try alloc.dupe(u8, value) else null;

    return .{
        .text = text,
        .images = images,
        .work_id = work_id,
    };
}

pub fn dupeImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []const ImageAttachment) ![]ImageAttachment {
    if (attachments.len == 0) return &.{};

    const copy = try alloc.alloc(ImageAttachment, attachments.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            freeImageAttachment(alloc, copy[i]);
        }
    }

    for (attachments, 0..) |attachment, i| {
        const path = try alloc.dupe(u8, attachment.path);
        errdefer alloc.free(path);

        const media_type = try alloc.dupe(u8, attachment.media_type);
        errdefer alloc.free(media_type);

        const snapshot_path = if (attachment.snapshot_path) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (snapshot_path) |value| alloc.free(value);

        const snapshot_sha256 = if (attachment.snapshot_sha256) |value|
            try alloc.dupe(u8, value)
        else
            null;
        copy[i] = .{
            .id = attachment.id,
            .path = path,
            .media_type = media_type,
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = snapshot_sha256,
        };
        copied += 1;
    }
    return copy;
}

/// Frees the owned fields in one attachment; caller owns any containing storage.
pub fn freeImageAttachment(alloc: std.mem.Allocator, attachment: ImageAttachment) void {
    alloc.free(attachment.path);
    alloc.free(attachment.media_type);
    if (attachment.snapshot_path) |path| alloc.free(path);
    if (attachment.snapshot_sha256) |sha256| alloc.free(sha256);
}

pub fn freeImageAttachmentSlice(alloc: std.mem.Allocator, attachments: []ImageAttachment) void {
    if (attachments.len == 0) return;
    for (attachments) |attachment| freeImageAttachment(alloc, attachment);
    alloc.free(attachments);
}

pub fn dupePermissionGrantSlice(alloc: std.mem.Allocator, grants: []const PermissionGrant) ![]PermissionGrant {
    const copy = try alloc.alloc(PermissionGrant, grants.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i].tool_name);
            alloc.free(copy[i].target_path);
        }
    }

    for (grants, 0..) |grant, i| {
        const tool_name = try alloc.dupe(u8, grant.tool_name);
        errdefer alloc.free(tool_name);

        const target_path = try alloc.dupe(u8, grant.target_path);
        copy[i] = .{
            .tool_name = tool_name,
            .target_path = target_path,
        };
        copied += 1;
    }

    return copy;
}

pub fn freePermissionGrantSlice(alloc: std.mem.Allocator, grants: []PermissionGrant) void {
    for (grants) |grant| {
        alloc.free(grant.tool_name);
        alloc.free(grant.target_path);
    }
    alloc.free(grants);
}

pub fn dupePermissionRuleSlice(alloc: std.mem.Allocator, rules: []const PermissionRule) ![]PermissionRule {
    if (rules.len == 0) return &.{};

    const copy = try alloc.alloc(PermissionRule, rules.len);
    errdefer alloc.free(copy);

    var copied: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < copied) : (i += 1) {
            alloc.free(copy[i].permission);
            alloc.free(copy[i].pattern);
        }
    }

    for (rules, 0..) |rule, i| {
        const permission = try alloc.dupe(u8, rule.permission);
        errdefer alloc.free(permission);

        const pattern = try alloc.dupe(u8, rule.pattern);
        copy[i] = .{
            .permission = permission,
            .pattern = pattern,
            .action = rule.action,
        };
        copied += 1;
    }

    return copy;
}

pub fn freePermissionRuleSlice(alloc: std.mem.Allocator, rules: []PermissionRule) void {
    if (rules.len == 0) return;
    for (rules) |rule| {
        alloc.free(rule.permission);
        alloc.free(rule.pattern);
    }
    alloc.free(rules);
}

pub fn dupePermissionRuleSet(alloc: std.mem.Allocator, rules: PermissionRuleSet) !PermissionRuleSet {
    return .{
        .rules = try dupePermissionRuleSlice(alloc, rules.rules),
    };
}

test "ConversationLanguage preserves core constructors" {
    const default_lang = ConversationLanguage.default();
    try std.testing.expectEqualStrings("und", default_lang.view());

    const literal = ConversationLanguage.literal("en");
    try std.testing.expectEqual(@as(u8, 2), literal.len);
    try std.testing.expectEqualStrings("en", literal.view());

    const parsed = try ConversationLanguage.fromSlice("  ja  ");
    try std.testing.expectEqualStrings("ja", parsed.view());

    try std.testing.expectError(error.InvalidConversationLanguage, ConversationLanguage.fromSlice(""));
    try std.testing.expectError(error.InvalidConversationLanguage, ConversationLanguage.fromSlice(" \t\r\n "));
    try std.testing.expectError(error.InvalidConversationLanguage, ConversationLanguage.fromSlice("this-is-way-too-long-for-a-language-tag"));
}

test "ReasoningEffort preserves default aliases and opaque names" {
    const default_aliases = [_][]const u8{ "auto", "AUTO", "adaptive", "default" };
    for (default_aliases) |alias| {
        const parsed = ReasoningEffort.parseDisplayLabel(alias) orelse return error.ExpectedReasoningEffort;
        try std.testing.expectEqual(ReasoningEffort.auto, parsed);
        try std.testing.expectEqualStrings("auto", parsed.label());
        try std.testing.expectEqualStrings("default", parsed.displayLabel());
        try std.testing.expect(parsed.gatewayValue() == null);
    }

    const named_values = [_][]const u8{ "none", "low", "xhigh", "future-tier" };
    for (named_values) |raw| {
        const parsed = ReasoningEffort.parse(raw) orelse return error.ExpectedReasoningEffort;
        try std.testing.expectEqualStrings(raw, parsed.label());
        try std.testing.expectEqualStrings(raw, parsed.displayLabel());
        try std.testing.expectEqualStrings(raw, parsed.gatewayValue().?);
    }

    try std.testing.expect(ReasoningEffort.parse("") == null);
    try std.testing.expect(ReasoningEffort.parse("contains space") == null);
    try std.testing.expect(ReasoningEffort.parse("this-effort-name-is-deliberately-longer-than-the-supported-wire-boundary-of-sixty-four-bytes") == null);
}

test "HistoryTurn helpers duplicate and free owned turns" {
    const alloc = std.testing.allocator;

    const assistant_original: HistoryTurn = .{ .assistant = .{
        .user = .{ .text = try alloc.dupe(u8, "hello") },
        .assistant = try alloc.dupe(u8, "response"),
    } };
    const assistant_copy = try dupeHistoryTurn(alloc, assistant_original);
    try std.testing.expectEqualStrings("hello", assistant_copy.assistant.user.text);
    try std.testing.expectEqualStrings("response", assistant_copy.assistant.assistant);
    try std.testing.expect(assistant_copy.assistant.user.text.ptr != assistant_original.assistant.user.text.ptr);
    freeHistoryTurn(alloc, assistant_copy);
    freeHistoryTurn(alloc, assistant_original);

    var summary_root_messages = try alloc.alloc([]u8, 1);
    summary_root_messages[0] = try alloc.dupe(u8, "exact root request");
    var summary_feedback = try alloc.alloc([]u8, 1);
    summary_feedback[0] = try alloc.dupe(u8, "deny writes outside the workspace");
    const summary_original: HistoryTurn = .{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, "summary"),
        .removed_turn_count = 3,
        .compaction_count = 2,
        .root_user_messages = summary_root_messages,
        .root_user_messages_complete = false,
        .permission_feedback = summary_feedback,
        .permission_feedback_complete = false,
    } };
    const summary_copy = try dupeHistoryTurn(alloc, summary_original);
    try std.testing.expectEqualStrings("summary", summary_copy.compacted_summary.summary);
    try std.testing.expectEqual(@as(usize, 3), summary_copy.compacted_summary.removed_turn_count);
    try std.testing.expect(!summary_copy.compacted_summary.root_user_messages_complete);
    try std.testing.expect(!summary_copy.compacted_summary.permission_feedback_complete);
    try std.testing.expectEqualStrings(
        "deny writes outside the workspace",
        summary_copy.compacted_summary.permission_feedback[0],
    );
    try std.testing.expect(
        summary_copy.compacted_summary.permission_feedback[0].ptr !=
            summary_original.compacted_summary.permission_feedback[0].ptr,
    );
    try std.testing.expect(summary_copy.compacted_summary.summary.ptr != summary_original.compacted_summary.summary.ptr);
    freeHistoryTurn(alloc, summary_copy);
    freeHistoryTurn(alloc, summary_original);

    const background_original: HistoryTurn = .{ .background_command = .{
        .user = .{ .text = try alloc.dupe(u8, "run dev") },
        .assistant = try alloc.dupe(u8, "Starting the server."),
        .execution = .{ .files = blk: {
            const files = try alloc.alloc(FileEvidence, 1);
            files[0] = .{
                .path = try alloc.dupe(u8, "src/main.zig"),
                .tool_call_id = try alloc.dupe(u8, "call_1"),
                .tool_name = try alloc.dupe(u8, "read_file"),
                .action = .read,
                .status = .success,
                .model_view_covers_full_file = true,
            };
            break :blk files;
        } },
        .log_path = try alloc.dupe(u8, "/tmp/fx.log"),
        .expect_url = true,
        .url = try alloc.dupe(u8, "http://localhost:3000"),
    } };
    const background_copy = try dupeHistoryTurn(alloc, background_original);
    try std.testing.expectEqualStrings("run dev", background_copy.background_command.user.text);
    try std.testing.expectEqualStrings("/tmp/fx.log", background_copy.background_command.log_path);
    try std.testing.expectEqualStrings("http://localhost:3000", background_copy.background_command.url.?);
    try std.testing.expectEqualStrings("Starting the server.", background_copy.background_command.assistant.?);
    try std.testing.expectEqualStrings("src/main.zig", background_copy.background_command.execution.files[0].path);
    try std.testing.expect(background_copy.background_command.log_path.ptr != background_original.background_command.log_path.ptr);
    try std.testing.expect(background_copy.background_command.assistant.?.ptr != background_original.background_command.assistant.?.ptr);
    try std.testing.expect(background_copy.background_command.execution.files[0].path.ptr != background_original.background_command.execution.files[0].path.ptr);
    freeHistoryTurn(alloc, background_copy);
    freeHistoryTurn(alloc, background_original);

    const interrupted_original: HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = try alloc.dupe(u8, "stop") },
        .execution = .{ .files = blk: {
            const files = try alloc.alloc(FileEvidence, 1);
            files[0] = .{
                .path = try alloc.dupe(u8, "README.md"),
                .tool_call_id = try alloc.dupe(u8, "call_2"),
                .tool_name = try alloc.dupe(u8, "read_file"),
                .action = .read,
                .status = .failure,
            };
            break :blk files;
        } },
        .cancelled_command = .{
            .output_replay = .{ .available = .{
                .handle = try alloc.dupe(u8, "fx-command-replay.bin"),
                .framed_bytes = 42,
            } },
            .command_artifact_handle = try alloc.dupe(u8, "fx-command.log"),
        },
        .terminal_reason = .failed,
    } };
    const interrupted_copy = try dupeHistoryTurn(alloc, interrupted_original);
    try std.testing.expectEqualStrings("README.md", interrupted_copy.interrupted.execution.files[0].path);
    try std.testing.expect(interrupted_copy.interrupted.execution.files[0].path.ptr != interrupted_original.interrupted.execution.files[0].path.ptr);
    const copied_presentation = interrupted_copy.interrupted.cancelled_command.?;
    const original_presentation = interrupted_original.interrupted.cancelled_command.?;
    try std.testing.expectEqualStrings(
        "fx-command-replay.bin",
        copied_presentation.output_replay.?.available.handle,
    );
    try std.testing.expect(
        copied_presentation.output_replay.?.available.handle.ptr !=
            original_presentation.output_replay.?.available.handle.ptr,
    );
    try std.testing.expect(
        copied_presentation.command_artifact_handle.?.ptr !=
            original_presentation.command_artifact_handle.?.ptr,
    );
    try std.testing.expectEqual(
        InterruptedTerminalReason.failed,
        interrupted_copy.interrupted.terminal_reason,
    );
    freeHistoryTurn(alloc, interrupted_copy);
    freeHistoryTurn(alloc, interrupted_original);

    const finished_original = FinishedPrompt{
        .turn = .{ .interrupted = .{
            .user = .{ .text = try alloc.dupe(u8, "cancel") },
            .assistant = try alloc.dupe(u8, "I stopped here."),
        } },
        .terminal_projection = .assistant_text,
        .terminal_outcome = .completed,
    };
    const finished_copy = try dupeFinishedPrompt(alloc, finished_original);
    try std.testing.expectEqual(FinishedPromptProjection.assistant_text, finished_copy.terminal_projection);
    try std.testing.expectEqual(@as(?TurnPresentationOutcome, .completed), finished_copy.terminal_outcome);
    freeFinishedPrompt(alloc, finished_copy);
    freeFinishedPrompt(alloc, finished_original);
}

test "TurnSummary carries shared turn token progress" {
    const progress: TurnTokenProgress = .{
        .input_tokens = 50_000,
        .output_tokens = 240,
        .input_exact = true,
        .output_exact = false,
    };
    const summary: TurnSummary = .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = progress,
    };
    try std.testing.expectEqual(progress, summary.token_progress);
}

test "ImageAttachment helpers duplicate empty and populated slices" {
    const alloc = std.testing.allocator;

    const empty = try dupeImageAttachmentSlice(alloc, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    freeImageAttachmentSlice(alloc, empty);

    var originals = try alloc.alloc(ImageAttachment, 1);
    originals[0] = .{
        .path = try alloc.dupe(u8, "/tmp/image.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    };

    const copy = try dupeImageAttachmentSlice(alloc, originals);
    try std.testing.expectEqualStrings("/tmp/image.png", copy[0].path);
    try std.testing.expectEqualStrings("image/png", copy[0].media_type);
    try std.testing.expect(copy[0].path.ptr != originals[0].path.ptr);

    freeImageAttachmentSlice(alloc, copy);
    freeImageAttachmentSlice(alloc, originals);
}

test "Permission helpers duplicate and free grants rules and rule sets" {
    const alloc = std.testing.allocator;

    const grants = [_]PermissionGrant{.{
        .tool_name = @constCast("run_command"),
        .target_path = @constCast("/tmp/workspace"),
    }};
    const grant_copy = try dupePermissionGrantSlice(alloc, &grants);
    try std.testing.expectEqualStrings("run_command", grant_copy[0].tool_name);
    try std.testing.expectEqualStrings("/tmp/workspace", grant_copy[0].target_path);
    try std.testing.expect(grant_copy[0].tool_name.ptr != grants[0].tool_name.ptr);
    freePermissionGrantSlice(alloc, grant_copy);

    const expected_empty_grants = try alloc.alloc(PermissionGrant, 0);
    const empty_grant_copy = try dupePermissionGrantSlice(alloc, &.{});
    try std.testing.expectEqual(expected_empty_grants.ptr, empty_grant_copy.ptr);
    alloc.free(expected_empty_grants);
    freePermissionGrantSlice(alloc, empty_grant_copy);

    var rules = [_]PermissionRule{.{
        .permission = @constCast("write_file"),
        .pattern = @constCast("src/**"),
        .action = .allow,
    }};
    const rule_copy = try dupePermissionRuleSlice(alloc, &rules);
    try std.testing.expectEqualStrings("write_file", rule_copy[0].permission);
    try std.testing.expectEqualStrings("src/**", rule_copy[0].pattern);
    try std.testing.expectEqual(PermissionAction.allow, rule_copy[0].action);
    try std.testing.expect(rule_copy[0].permission.ptr != rules[0].permission.ptr);
    freePermissionRuleSlice(alloc, rule_copy);

    var ruleset = try dupePermissionRuleSet(alloc, .{ .rules = &rules });
    try std.testing.expectEqual(@as(usize, 1), ruleset.rules.len);
    ruleset.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), ruleset.rules.len);

    var empty_ruleset = PermissionRuleSet{};
    empty_ruleset.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), empty_ruleset.rules.len);
}

test "public types remain constructible" {
    const layout: Layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    try std.testing.expectEqual(@as(u16, 80), layout.cols);

    const metrics = Metrics{ .ansi_bytes = 1, .stream_chunks = 2 };
    try std.testing.expectEqual(@as(usize, 2), metrics.stream_chunks);

    const stream = StreamState{ .active = true, .last_activity_kind = .ask };
    try std.testing.expect(stream.active);
    try std.testing.expectEqual(ToolActivityKind.ask, stream.last_activity_kind.?);

    const tool_call = ToolCall{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{}",
        .provider_result = "ok",
    };
    const image = ImageAttachment{
        .path = @constCast("/tmp/image.png"),
        .media_type = @constCast("image/png"),
    };
    const chat = ChatMessage{
        .role = .assistant,
        .content = "content",
        .images = &.{image},
        .tool_calls = &.{tool_call},
    };
    try std.testing.expectEqual(ChatRole.assistant, chat.role);
    try std.testing.expectEqualStrings("ok", chat.tool_calls[0].provider_result.?);

    const completion = GatewayCompletion{
        .content = "done",
        .tool_calls = &.{tool_call},
        .finish_reason = .stop,
    };
    try std.testing.expectEqual(ProviderFinishReason.stop, completion.finish_reason.?);

    const option = QuestionOption{ .label = "Yes", .description = "Proceed" };
    const batch = QuestionBatchEntry{ .question = "Continue?", .options = &.{option} };
    try std.testing.expectEqualStrings("Continue?", batch.question);

    const mode = PermissionMode.ask;
    const decision = ToolPermissionDecision.always;
    const action = PermissionAction.deny;
    const resolve_mode = ResolveMode.create;
    _ = mode;
    _ = decision;
    _ = action;
    _ = resolve_mode;
}
