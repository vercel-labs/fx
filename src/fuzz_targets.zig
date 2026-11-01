//! Root of the `zig build fuzz` test binary. Each import below brings in a
//! file that holds an fx fuzz target listed in `tests/fuzz/targets.json`.
//! The build filters this binary to the registered fuzz tests, so ordinary
//! unit tests in these files never run here. A new fx fuzz target needs its
//! file imported here and an entry in the registry.

test {
    _ = @import("acp/jsonrpc.zig");
    _ = @import("acp/mcp_servers.zig");
    _ = @import("core/agent/assistant_presentation.zig");
    _ = @import("core/agent/runtime/execution_memory.zig");
    _ = @import("core/agent/runtime/vision_contracts.zig");
    _ = @import("core/images/image_attachments.zig");
    _ = @import("core/images/image_data.zig");
    _ = @import("core/images/image_route.zig");
    _ = @import("core/mcp/elicitation.zig");
    _ = @import("core/mcp/tool_search.zig");
    _ = @import("core/output/diff.zig");
    _ = @import("core/mcp_host/wire_tests.zig");
    _ = @import("core/session/session_adapter.zig");
    _ = @import("core/session/session_codec.zig");
    _ = @import("core/session/session_event.zig");
    _ = @import("core/shared/display_width.zig");
    _ = @import("core/shared/fuzzy_match.zig");
    _ = @import("core/shared/types.zig");
    _ = @import("core/shell_command/command_classification.zig");
    _ = @import("core/shell_command/command_effect.zig");
    _ = @import("core/shell_command/command_lex.zig");
    _ = @import("core/skills/skill_contract.zig");
    _ = @import("core/skills/skill_invocation.zig");
    _ = @import("core/terminal/engine.zig");
    _ = @import("core/tooling/command_output_content.zig");
    _ = @import("core/workspace/file_index.zig");
    _ = @import("gateway/chat_completions_protocol.zig");
    _ = @import("gateway/client.zig");
    _ = @import("gateway/openai_codex.zig");
    _ = @import("gateway/responses_protocol.zig");
    _ = @import("gateway/sse.zig");
    _ = @import("tools/agent/ask_user_question.zig");
    _ = @import("tools/web/http_fetch.zig");
    _ = @import("tools/web/url_policy.zig");
    _ = @import("ui/resize_tests.zig");
}
