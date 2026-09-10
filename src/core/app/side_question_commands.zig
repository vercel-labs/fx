const std = @import("std");
const side_question_runtime = @import("side_question_runtime.zig");
const session_runtime = @import("../session/session.zig");
const types = @import("../shared/types.zig");
const prompt_context = @import("../agent/runtime/prompt_context.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

pub const Kind = side_question_runtime.Kind;

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn requestSideQuestion(
            app: *App,
            runtime: *side_question_runtime.Runtime,
            kind: Kind,
            payload: []const u8,
        ) !void {
            const question = std.mem.trim(u8, payload, " \t\r\n");
            if (kind == .btw and question.len == 0) {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .warning,
                    .body = "Usage: /btw <question>",
                });
                return;
            }
            if (kind == .recap and question.len != 0) {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .warning,
                    .body = "Usage: /recap",
                });
                return;
            }
            if (runtime.isActive()) {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .warning,
                    .body = "A side question is already running.",
                });
                return;
            }

            var snapshot_arena = std.heap.ArenaAllocator.init(app.alloc);
            defer snapshot_arena.deinit();
            const arena = snapshot_arena.allocator();
            const history = try app.session.snapshotHistory(arena);
            if (kind == .recap and history.len == 0) {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .neutral,
                    .body = "No conversation history to recap.",
                });
                return;
            }

            const selection = app.provider_selection.selection();
            if (selection.model.len == 0) {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .warning,
                    .body = "No model is selected.",
                });
                return;
            }
            const gateway_credential = app.auth.gatewayCredential() orelse {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .warning,
                    .body = "No provider credential is available.",
                });
                return;
            };

            const capabilities = app.resolvedModelCapabilities(selection.model);
            var messages: std.ArrayList(types.ChatMessage) = .empty;
            defer messages.deinit(arena);
            try session_runtime.appendHistoryChatMessagesBudgeted(
                arena,
                &messages,
                history,
                .{ .max_tokens = prompt_context.usableInputTokens(capabilities) orelse 32_000 },
            );
            const language = app.session.languageSnapshot().view();
            if (!std.mem.eql(u8, language, "und")) {
                const language_context = try std.fmt.allocPrint(
                    arena,
                    "Respond in {s}.",
                    .{language},
                );
                try messages.append(arena, .{ .role = .user, .content = language_context });
            }

            const provider = app.providerSet().select(selection.provider).agent_stream_or_unavailable();
            const credential: types.CredentialLease = .{ .direct = .{
                .secret_bytes = gateway_credential.api_key orelse "",
                .source = gateway_credential.source,
                .account_id = app.auth.accountId(),
                .tenant_context = gateway_credential.gateway_team,
            } };
            const provider_options = model_capabilities.resolveProviderOptionsForCapabilities(
                capabilities,
                app.effort,
                app.fast_mode,
            );

            try app.shell.setTransientNotice(app.alloc, .{
                .topic = "side_question",
                .tone = .information,
                .body = "Side question running.",
            });
            runtime.start(app.alloc, .{
                .kind = kind,
                .question = if (kind == .btw) question else "",
                .messages = messages.items,
                .credential = credential,
                .model = selection.model,
                .provider = provider,
                .provider_options = provider_options,
                .trace_ctx = .{
                    .turn_id = debug_trace.nextTurnId(),
                    .step_id = debug_trace.nextStepId(),
                },
            }) catch |err| {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .@"error",
                    .body = @errorName(err),
                });
            };
        }
        pub fn collectSideQuestionFacts(app: *App, runtime: *side_question_runtime.Runtime) !void {
            const completion = runtime.takeCompleted() orelse return;
            var result = completion;
            defer result.deinit();
            if (result.error_message) |message| {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .@"error",
                    .body = message,
                });
            } else if (result.answer) |answer| {
                try app.shell.setTransientNotice(app.alloc, .{
                    .topic = "side_question",
                    .tone = .neutral,
                    .body = answer,
                });
            }
        }
    };
}
