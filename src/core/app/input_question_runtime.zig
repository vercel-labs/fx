const std = @import("std");
const question_prompt = @import("../agent/question_prompt.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const edit_contract = @import("../input/editor_state.zig");
const gesture_state = @import("../input/gesture_state.zig");
const input_action = @import("../input/input_action.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const question_ui = @import("../../ui/footer/question_ui.zig");
const question_freeform_layout = @import("../../ui/footer/question_freeform_layout.zig");
const input_interrupt_runtime = @import("input_interrupt_runtime.zig");

pub fn QuestionRuntime(comptime App: type) type {
    return struct {
        const interrupt = input_interrupt_runtime.InterruptRuntime(App);

        pub fn handleQuestionAction(app: *App, action: question_prompt.Action) !bool {
            return switch (try handleQuestionActionWithLimit(app, action, null)) {
                .consumed => true,
                .ignored => false,
                .limit_exceeded => unreachable,
            };
        }

        pub fn handleQuestionActionBounded(
            app: *App,
            action: question_prompt.Action,
            max_len: usize,
        ) !edit_contract.ByteResult {
            return handleQuestionActionWithLimit(app, action, max_len);
        }

        fn handleQuestionActionWithLimit(
            app: *App,
            action: question_prompt.Action,
            max_len: ?usize,
        ) !edit_contract.ByteResult {
            const event = if (max_len) |limit|
                try app.question_prompt.applyBounded(app.alloc, action, limit)
            else
                try app.question_prompt.apply(app.alloc, action);
            switch (event) {
                .none => return if (questionActionConsumesNoop(action)) .consumed else .ignored,
                .redraw, .decision => {
                    try rerenderQuestionBlock(app);
                    return .consumed;
                },
                .all_decided => {
                    try submitQuestionBatch(app);
                    return .consumed;
                },
                .cancelled => {
                    try cancelQuestionPrompt(app);
                    return .consumed;
                },
                .limit_exceeded => return .limit_exceeded,
            }
        }

        pub fn cancelQuestionPrompt(app: *App) !void {
            const route_recovery = isRouteRecoveryPrompt(app);
            const mcp_elicitation = isMcpElicitationPrompt(app);
            interrupt.traceInterruptRequested(app, "input_question");
            if (!route_recovery) {
                if (comptime @hasDecl(@TypeOf(app.worker), "requestInteractiveCancel")) {
                    app.worker.requestInteractiveCancel();
                } else {
                    app.worker.requestCancel();
                }
            }
            app.pacer.clear(app.alloc);
            if (!route_recovery and !mcp_elicitation) try finalizeQuestionTranscript(app, true);
            try app.worker.submitQuestionBatchAnswer(std.heap.c_allocator, null);
            app.question_prompt.discard(app.alloc, "cancelled");
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            const gesture_transition = gesture_state.disarmEscapeClear(
                app.input_runtime.gestures,
            );
            app.input_runtime.gestures = gesture_transition.next;
            app.stopStream();
            app.shell.render_requests.request(.modal);
        }

        pub fn submitQuestionBatch(app: *App) !void {
            var labels: std.ArrayList([]const u8) = .empty;
            defer labels.deinit(app.alloc);
            try labels.ensureTotalCapacity(app.alloc, app.question_prompt.entries.items.len);
            for (app.question_prompt.entries.items) |entry| {
                labels.appendAssumeCapacity(entry.answer.?);
            }

            if (!isRouteRecoveryPrompt(app) and !isMcpElicitationPrompt(app)) {
                try finalizeQuestionTranscript(app, false);
            }
            try app.worker.submitQuestionBatchAnswer(std.heap.c_allocator, labels.items);
            app.question_prompt.resetAfterSubmission(app.alloc);
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            app.shell.render_requests.request(.modal);
        }

        pub fn rerenderQuestionBlock(app: *App) !void {
            app.shell.render_requests.request(.modal);
        }

        fn isRouteRecoveryPrompt(app: *App) bool {
            const Worker = @TypeOf(app.worker);
            if (comptime @hasDecl(Worker, "pendingQuestionBatchSource")) {
                return app.worker.pendingQuestionBatchSource() == worker_runtime.QuestionPromptSource.route_recovery;
            }
            return false;
        }

        fn isMcpElicitationPrompt(app: *App) bool {
            const Worker = @TypeOf(app.worker);
            if (comptime @hasDecl(Worker, "pendingQuestionBatchSource")) {
                return app.worker.pendingQuestionBatchSource() == worker_runtime.QuestionPromptSource.mcp_elicitation;
            }
            return false;
        }

        fn finalizeQuestionTranscript(app: *App, cancelled: bool) !void {
            const text = try question_ui.composeQuestionResolutions(
                app.alloc,
                &app.question_prompt,
                cancelled,
                app.shell.layout.cols,
            );
            defer app.alloc.free(text);
            try appendQuestionResolution(app, text, cancelled);
        }

        fn appendQuestionResolution(app: *App, body: []const u8, cancelled: bool) !void {
            _ = if (cancelled)
                try app.appendReplaceableTranscriptLineClassified(body, .question_resolution)
            else
                try app.appendReplaceableTranscriptLine(body);
            app.shell.render_requests.request(.modal);
        }

        pub fn routeQuestionEscapeAction(
            app: *App,
            action: input_action.Action,
            question_action: ?question_prompt.Action,
        ) !void {
            app.input_runtime.vertical_navigation.reset();
            app.input_runtime.input_limit_rejection = input_limit_rejection.clear();
            if (question_action) |typed| {
                if (try handleQuestionAction(app, typed)) return;
            }
            if (app.question_prompt.isFreeformSelected()) {
                switch (action) {
                    .cursor_up => {
                        // At the top of the freeform draft, Up leaves the
                        // slot and resumes option navigation.
                        if (!moveFreeformCursorVertical(app, .up)) {
                            app.question_prompt.moveChoice(-1);
                        }
                        try rerenderQuestionBlock(app);
                        return;
                    },
                    .cursor_down => {
                        if (!moveFreeformCursorVertical(app, .down)) {
                            app.question_prompt.moveChoice(1);
                        }
                        try rerenderQuestionBlock(app);
                        return;
                    },
                    .history_up => {
                        app.question_prompt.moveChoice(-1);
                        try rerenderQuestionBlock(app);
                        return;
                    },
                    .history_down => {
                        app.question_prompt.moveChoice(1);
                        try rerenderQuestionBlock(app);
                        return;
                    },
                    else => {},
                }
            }

            switch (action) {
                .history_up, .cursor_up => {
                    app.question_prompt.moveChoice(-1);
                    try rerenderQuestionBlock(app);
                },
                .history_down, .cursor_down => {
                    app.question_prompt.moveChoice(1);
                    try rerenderQuestionBlock(app);
                },
                .cursor_left, .word_left => {
                    switch (app.question_prompt.retreatToPrevious()) {
                        .redraw => try rerenderQuestionBlock(app),
                        else => {},
                    }
                },
                .cursor_right, .word_right => {
                    // Enter advances; right arrow remains inert to avoid skipping answers.
                },
                else => {},
            }
        }

        fn moveFreeformCursorVertical(
            app: *App,
            direction: question_freeform_layout.Direction,
        ) bool {
            const view = app.question_prompt.freeformCursorView() orelse return false;
            const movement = question_freeform_layout.moveCursor(
                view.buffer,
                view.cursor,
                question_freeform_layout.contentWidth(
                    view.choice_index,
                    app.shell.layout.cols,
                ),
                direction,
                view.preferred_column,
            );
            app.question_prompt.applyFreeformCursorMove(
                movement.cursor,
                movement.preferred_column,
            );
            return movement.moved;
        }

        fn questionActionConsumesNoop(action: question_prompt.Action) bool {
            return switch (action) {
                .backspace, .insert_ascii, .edit_freeform => true,
                else => false,
            };
        }
    };
}
