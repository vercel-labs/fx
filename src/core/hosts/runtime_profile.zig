const std = @import("std");

pub const Profile = struct {
    cooperative_agent: bool,
    durable_sessions: bool,
    profile_usage: bool,
    native_auth: bool,
    file_index: bool,
    mcp: bool,
    subagents: bool,
    auto_upgrade: bool,
    skills: bool,
    clipboard: bool,
    url_opening: bool,
    web_search: bool,
    generation_usage: bool,
    tools: bool,
    js_host_clipboard: bool,
    js_host_config: bool,
    js_host_prompt_history: bool,
    js_host_sessions: bool,
    js_host_auth: bool,
    js_host_url_open: bool,
    js_host_workspace: bool,
};

pub const Capability = std.meta.FieldEnum(Profile);

pub fn allows(comptime App: type, comptime capability: Capability) bool {
    if (!@hasDecl(App, "host_profile")) return @field(native, @tagName(capability));
    return @field(App.host_profile, @tagName(capability));
}

pub const native = Profile{
    .cooperative_agent = false,
    .durable_sessions = true,
    .profile_usage = true,
    .native_auth = true,
    .file_index = true,
    .mcp = true,
    .subagents = true,
    .auto_upgrade = true,
    .skills = true,
    .clipboard = true,
    .url_opening = true,
    .web_search = true,
    .generation_usage = true,
    .tools = true,
    .js_host_clipboard = false,
    .js_host_config = false,
    .js_host_prompt_history = false,
    .js_host_sessions = false,
    .js_host_auth = false,
    .js_host_url_open = false,
    .js_host_workspace = false,
};

pub const wasm = Profile{
    .cooperative_agent = true,
    .durable_sessions = false,
    .profile_usage = false,
    .native_auth = false,
    .file_index = false,
    .mcp = false,
    .subagents = false,
    .auto_upgrade = false,
    .skills = false,
    .clipboard = false,
    .url_opening = false,
    .web_search = false,
    .generation_usage = false,
    .tools = false,
    .js_host_clipboard = true,
    .js_host_config = true,
    .js_host_prompt_history = true,
    .js_host_sessions = true,
    .js_host_auth = true,
    .js_host_url_open = true,
    .js_host_workspace = true,
};

test "apps without a host profile retain native capabilities" {
    const App = struct {};
    try std.testing.expect(allows(App, .durable_sessions));
    try std.testing.expect(!allows(App, .js_host_sessions));
}

test "host profile capabilities are selected by field" {
    const App = struct {
        pub const host_profile = wasm;
    };
    try std.testing.expect(!allows(App, .durable_sessions));
    try std.testing.expect(allows(App, .js_host_config));
    try std.testing.expect(allows(App, .js_host_sessions));
    try std.testing.expect(allows(App, .js_host_clipboard));
}

test "native and wasm profiles select distinct auth host effects" {
    try std.testing.expect(native.native_auth);
    try std.testing.expect(native.url_opening);
    try std.testing.expect(!native.js_host_auth);
    try std.testing.expect(!native.js_host_url_open);

    try std.testing.expect(!wasm.native_auth);
    try std.testing.expect(!wasm.url_opening);
    try std.testing.expect(wasm.js_host_auth);
    try std.testing.expect(wasm.js_host_url_open);
}

test "workspace host capability is wasm only without enabling native tools" {
    try std.testing.expect(@hasField(Profile, "js_host_workspace"));
    try std.testing.expect(!native.js_host_workspace);
    try std.testing.expect(wasm.js_host_workspace);
    try std.testing.expect(!wasm.tools);
}
