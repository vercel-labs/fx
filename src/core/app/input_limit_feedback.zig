const debug_trace = @import("../shared/debug_trace.zig");
const input_limit_rejection = @import("../input/input_limit_rejection.zig");
const text_scalar = @import("../input/text_scalar.zig");

pub fn report(
    comptime App: type,
    app: *App,
    owner: text_scalar.Owner,
    attempted_bytes: usize,
) !void {
    debug_trace.logf(
        "input",
        "edit rejected owner={s} bytes={d} boundary={s} reason=input_limit",
        .{
            @tagName(owner),
            attempted_bytes,
            switch (owner) {
                .composer => "prompt_resource",
                .question_freeform, .approval_amendment => "decision_input",
            },
        },
    );
    const transition = input_limit_rejection.begin(
        app.input_runtime.input_limit_rejection,
        owner,
    );
    app.input_runtime.input_limit_rejection = transition.next;
    if (!transition.should_report) return;
    errdefer app.input_runtime.input_limit_rejection = input_limit_rejection.clear();

    app.shell.render_requests.request(switch (owner) {
        .composer => .footer,
        .question_freeform, .approval_amendment => .modal,
    });
    try app.writeDomainNotice(.{
        .topic = "input",
        .tone = .@"error",
        .body = switch (owner) {
            .composer => "that edit exceeds the local prompt safety limit and was not applied.",
            .question_freeform, .approval_amendment => "that edit exceeds the input limit and was not applied.",
        },
    }, true);
}
