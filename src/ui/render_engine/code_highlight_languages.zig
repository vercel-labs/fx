const std = @import("std");
const string_pool = @import("../../core/shared/comptime_string_pool.zig");

const Allocator = std.mem.Allocator;

pub const KeywordCase = enum {
    sensitive,
    ascii_insensitive,
};

const BlockCommentSpec = struct {
    start: []const u8,
    end: []const u8,
};

pub const Detection = enum {
    none,
    typescript_assertion,
    json,
    shell_shebang,
    python_header,
    sql_select,
    dockerfile_from,
    go_package,
    rust_function,
};

const ProfileSpec = struct {
    label: []const u8,
    aliases: []const []const u8,
    line_comments: []const []const u8 = &.{},
    block_comment: ?BlockCommentSpec = null,
    quotes: []const u8 = &.{},
    keywords: []const []const u8 = &.{},
    literals: []const []const u8 = &.{},
    keyword_case: KeywordCase = .sensitive,
    detection: Detection = .none,
};

const double_quote = &[_]u8{'"'};
const double_single_quotes = &[_]u8{ '"', '\'' };
const shell_quotes = &[_]u8{ '"', '\'', '`' };

const profile_specs = [_]ProfileSpec{
    .{
        .label = "zig",
        .aliases = &.{"zig"},
        .line_comments = &.{"//"},
        .quotes = double_quote,
        .keywords = &.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "struct", "enum", "union", "try", "catch", "comptime", "defer", "errdefer", "async", "await", "anytype", "void" },
    },
    .{
        .label = "ts",
        .aliases = &.{ "js", "jsx", "javascript", "ts", "tsx", "typescript" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = shell_quotes,
        .keywords = &.{ "const", "let", "var", "function", "class", "interface", "type", "export", "import", "from", "return", "if", "else", "for", "while", "async", "await", "new", "extends", "implements", "public", "private", "readonly" },
        .literals = &.{ "true", "false", "null", "undefined" },
        .detection = .typescript_assertion,
    },
    .{
        .label = "json",
        .aliases = &.{"json"},
        .quotes = double_quote,
        .literals = &.{ "true", "false", "null" },
        .detection = .json,
    },
    .{
        .label = "sh",
        .aliases = &.{ "sh", "bash", "zsh", "shell" },
        .line_comments = &.{"#"},
        .quotes = shell_quotes,
        .keywords = &.{ "if", "then", "fi", "for", "do", "done", "in", "case", "esac", "function", "local", "export", "readonly", "return" },
        .literals = &.{ "true", "false", "null" },
        .detection = .shell_shebang,
    },
    .{
        .label = "python",
        .aliases = &.{ "python", "py" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &.{ "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import", "from", "as", "try", "except", "with", "lambda", "async", "await", "pass", "raise", "yield", "match", "case" },
        .literals = &.{ "True", "False", "None" },
        .detection = .python_header,
    },
    .{
        .label = "yaml",
        .aliases = &.{ "yaml", "yml" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .literals = &.{ "true", "false", "null", "yes", "no", "on", "off" },
    },
    .{
        .label = "toml",
        .aliases = &.{"toml"},
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .literals = &.{ "true", "false" },
    },
    .{
        .label = "sql",
        .aliases = &.{"sql"},
        .line_comments = &.{"--"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "select", "from", "where", "join", "left", "right", "inner", "outer", "on", "insert", "into", "values", "update", "set", "delete", "create", "alter", "drop", "table", "index", "group", "by", "order", "having", "limit", "as", "and", "or", "not", "distinct", "union" },
        .literals = &.{ "true", "false", "null" },
        .keyword_case = .ascii_insensitive,
        .detection = .sql_select,
    },
    .{
        .label = "dockerfile",
        .aliases = &.{ "dockerfile", "docker" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &.{ "from", "run", "cmd", "entrypoint", "copy", "add", "workdir", "env", "arg", "expose", "volume", "user", "label", "onbuild", "stopsignal", "healthcheck", "shell", "maintainer" },
        .keyword_case = .ascii_insensitive,
        .detection = .dockerfile_from,
    },
    .{
        .label = "rust",
        .aliases = &.{ "rust", "rs" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "return", "if", "else", "match", "for", "while", "loop", "async", "await", "move", "where", "self", "super" },
        .literals = &.{ "true", "false", "None", "Some" },
        .detection = .rust_function,
    },
    .{
        .label = "go",
        .aliases = &.{"go"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = &[_]u8{ '"', '`' },
        .keywords = &.{ "package", "import", "func", "var", "const", "type", "struct", "interface", "return", "if", "else", "for", "range", "switch", "case", "go", "defer", "select", "chan", "map" },
        .literals = &.{ "true", "false", "nil" },
        .detection = .go_package,
    },
    .{
        .label = "c",
        .aliases = &.{ "c", "h" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "int", "long", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while" },
        .literals = &.{ "true", "false", "NULL" },
    },
    .{
        .label = "cpp",
        .aliases = &.{ "cpp", "c++", "cc", "cxx", "hpp" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "auto", "bool", "class", "const", "constexpr", "decltype", "delete", "enum", "explicit", "friend", "inline", "namespace", "new", "nullptr", "private", "protected", "public", "template", "this", "typename", "using", "virtual", "void" },
        .literals = &.{ "true", "false", "nullptr", "NULL" },
    },
    .{
        .label = "csharp",
        .aliases = &.{ "csharp", "cs" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "class", "namespace", "using", "public", "private", "protected", "internal", "static", "void", "string", "int", "var", "new", "return", "if", "else", "for", "foreach", "while", "async", "await", "interface", "record", "get", "set" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .label = "java",
        .aliases = &.{"java"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "class", "interface", "package", "import", "public", "private", "protected", "static", "final", "void", "new", "return", "if", "else", "for", "while", "try", "catch", "throws", "extends", "implements", "record", "var" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .label = "kotlin",
        .aliases = &.{ "kotlin", "kt", "kts" },
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "fun", "val", "var", "class", "object", "interface", "package", "import", "public", "private", "return", "if", "else", "when", "for", "while", "try", "catch", "data", "sealed", "suspend" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .label = "php",
        .aliases = &.{"php"},
        .line_comments = &.{ "//", "#" },
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "function", "class", "public", "private", "protected", "namespace", "use", "return", "if", "else", "foreach", "for", "while", "try", "catch", "new", "static", "const", "echo", "yield" },
        .literals = &.{ "true", "false", "null" },
    },
    .{
        .label = "ruby",
        .aliases = &.{ "ruby", "rb" },
        .line_comments = &.{"#"},
        .quotes = double_single_quotes,
        .keywords = &.{ "def", "class", "module", "end", "return", "if", "elsif", "else", "unless", "case", "when", "do", "while", "for", "in", "begin", "rescue", "require", "attr_reader" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .label = "swift",
        .aliases = &.{"swift"},
        .line_comments = &.{"//"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "func", "let", "var", "class", "struct", "enum", "protocol", "extension", "import", "public", "private", "return", "if", "else", "guard", "for", "while", "switch", "case", "async", "await", "throws", "try" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .label = "powershell",
        .aliases = &.{ "powershell", "ps1", "pwsh", "ps" },
        .line_comments = &.{"#"},
        .block_comment = .{ .start = "<#", .end = "#>" },
        .quotes = double_single_quotes,
        .keywords = &.{ "function", "param", "if", "else", "elseif", "foreach", "for", "while", "switch", "return", "throw", "try", "catch", "finally", "begin", "process", "end", "filter", "class", "enum" },
        .literals = &.{ "true", "false", "null" },
        .keyword_case = .ascii_insensitive,
    },
    .{
        .label = "lua",
        .aliases = &.{"lua"},
        .line_comments = &.{"--"},
        .block_comment = .{ .start = "--[[", .end = "]]" },
        .quotes = double_single_quotes,
        .keywords = &.{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" },
        .literals = &.{ "true", "false", "nil" },
    },
    .{
        .label = "html",
        .aliases = &.{ "html", "htm" },
        .block_comment = .{ .start = "<!--", .end = "-->" },
        .quotes = double_single_quotes,
        .keywords = &.{ "html", "head", "body", "main", "header", "footer", "section", "article", "div", "span", "a", "p", "script", "style", "link", "meta", "title", "button", "input", "form", "img", "ul", "li" },
    },
    .{
        .label = "xml",
        .aliases = &.{"xml"},
        .block_comment = .{ .start = "<!--", .end = "-->" },
        .quotes = double_single_quotes,
        .keywords = &.{ "xml", "version", "encoding", "DOCTYPE", "CDATA" },
    },
    .{
        .label = "css",
        .aliases = &.{"css"},
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "color", "background", "display", "position", "margin", "padding", "border", "font", "width", "height", "flex", "grid", "align", "justify", "transition", "transform", "animation", "media" },
    },
    .{
        .label = "hcl",
        .aliases = &.{ "hcl", "terraform", "tf" },
        .line_comments = &.{ "#", "//" },
        .block_comment = .{ .start = "/*", .end = "*/" },
        .quotes = double_single_quotes,
        .keywords = &.{ "resource", "module", "variable", "output", "provider", "terraform", "locals", "data", "dynamic", "for_each", "count" },
        .literals = &.{ "true", "false", "null" },
    },
};

// Every string in the spec table is interned into one comptime blob; the
// published profiles reference it with 6-byte (offset, length) pairs
// instead of 16-byte slices. The spec table above stays in natural form.
const pool = string_pool.Interned(blk: {
    var flat: []const []const u8 = &.{};
    for (profile_specs) |p| {
        flat = flat ++ &[1][]const u8{p.label};
        flat = flat ++ p.aliases;
        flat = flat ++ p.line_comments;
        if (p.block_comment) |bc| flat = flat ++ &[2][]const u8{ bc.start, bc.end };
        flat = flat ++ p.keywords;
        flat = flat ++ p.literals;
    }
    break :blk flat;
});

pub const Ref = pool.Ref;

pub const BlockComment = struct {
    start: Ref,
    end: Ref,
};

pub const Profile = struct {
    label: Ref,
    aliases: []const Ref,
    line_comments: []const Ref = &.{},
    block_comment: ?BlockComment = null,
    quotes: []const u8 = &.{},
    keywords: []const Ref = &.{},
    literals: []const Ref = &.{},
    keyword_case: KeywordCase = .sensitive,
    detection: Detection = .none,
};

pub const profiles = blk: {
    var out: [profile_specs.len]Profile = undefined;
    for (profile_specs, 0..) |spec, i| {
        out[i] = .{
            .label = pool.ref(spec.label),
            .aliases = pool.List(spec.aliases).items[0..],
            .line_comments = pool.List(spec.line_comments).items[0..],
            .block_comment = if (spec.block_comment) |bc| .{
                .start = pool.ref(bc.start),
                .end = pool.ref(bc.end),
            } else null,
            .quotes = spec.quotes,
            .keywords = pool.List(spec.keywords).items[0..],
            .literals = pool.List(spec.literals).items[0..],
            .keyword_case = spec.keyword_case,
            .detection = spec.detection,
        };
    }
    break :blk out;
};

pub fn resolve(label: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        for (profile.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(label, alias.get())) return profile;
        }
    }
    return null;
}

pub fn infer(alloc: Allocator, source: []const u8) ?*const Profile {
    for (&profiles) |*profile| {
        if (matchesDetection(alloc, profile.detection, source)) return profile;
    }
    return null;
}

fn matchesDetection(alloc: Allocator, detection: Detection, source: []const u8) bool {
    return switch (detection) {
        .none => false,
        .typescript_assertion => matchesTypeScriptAssertion(source),
        .json => isValidJson(alloc, source),
        .shell_shebang => matchesShellShebang(source),
        .python_header => matchesPythonHeader(source),
        .sql_select => matchesSqlSelect(source),
        .dockerfile_from => startsWithIgnoreCase(firstNonblankLine(source), "from "),
        .go_package => startsWith(firstNonblankLine(source), "package ") and containsLineStart(source, "func "),
        .rust_function => matchesRustFunction(source),
    };
}

fn matchesTypeScriptAssertion(source: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, "} as ")) |assertion_start| {
        const type_start = assertion_start + "} as ".len;
        if (type_start < source.len and std.ascii.isUpper(source[type_start])) return true;
        start = type_start;
    }
    return false;
}

fn isValidJson(alloc: Allocator, source: []const u8) bool {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .object or parsed.value == .array;
}

fn matchesShellShebang(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return std.mem.startsWith(u8, line, "#!") and
        (std.mem.indexOf(u8, line, "bash") != null or std.mem.indexOf(u8, line, "zsh") != null or std.mem.indexOf(u8, line, "/sh") != null);
}

fn matchesPythonHeader(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return (std.mem.startsWith(u8, line, "def ") or std.mem.startsWith(u8, line, "class ")) and std.mem.endsWith(u8, line, ":");
}

fn matchesSqlSelect(source: []const u8) bool {
    const line = firstNonblankLine(source);
    return startsWithIgnoreCase(line, "select ") and containsWordIgnoreCase(source, "from");
}

fn matchesRustFunction(source: []const u8) bool {
    const line = firstNonblankLine(source);
    if (!std.mem.startsWith(u8, line, "fn ") and !std.mem.startsWith(u8, line, "pub fn ")) return false;
    return std.mem.indexOf(u8, source, "let ") != null or std.mem.indexOf(u8, source, "println!") != null or std.mem.indexOf(u8, line, "->") != null;
}

fn firstNonblankLine(source: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn containsLineStart(source: []const u8, prefix: []const u8) bool {
    if (std.mem.startsWith(u8, source, prefix)) return true;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, source, start, "\n")) |newline| {
        const line_start = newline + 1;
        if (std.mem.startsWith(u8, source[line_start..], prefix)) return true;
        start = line_start;
    }
    return false;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn containsWordIgnoreCase(source: []const u8, word: []const u8) bool {
    if (word.len > source.len) return false;
    var index: usize = 0;
    while (index + word.len <= source.len) : (index += 1) {
        const end = index + word.len;
        if (std.ascii.eqlIgnoreCase(source[index..end], word) and
            (index == 0 or !isWordByte(source[index - 1])) and
            (end == source.len or !isWordByte(source[end]))) return true;
    }
    return false;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "TypeScript assertions infer the canonical TypeScript label" {
    const source =
        "const hook = await resumeHook(token, { cleanup: true } as CleanupSignal);";

    try std.testing.expectEqualStrings("ts", infer(std.testing.allocator, source).?.label.get());
    try std.testing.expect(infer(std.testing.allocator, "const value = 1;") == null);
    try std.testing.expect(infer(std.testing.allocator, "const value = {} as cleanupSignal;") == null);
}

test "supported code fence labels resolve case insensitively" {
    const cases = [_]struct { label: []const u8, profile: []const u8 }{
        .{ .label = "Zig", .profile = "zig" },
        .{ .label = "js", .profile = "ts" },
        .{ .label = "JSX", .profile = "ts" },
        .{ .label = "javascript", .profile = "ts" },
        .{ .label = "TS", .profile = "ts" },
        .{ .label = "tsx", .profile = "ts" },
        .{ .label = "TypeScript", .profile = "ts" },
        .{ .label = "JSON", .profile = "json" },
        .{ .label = "sh", .profile = "sh" },
        .{ .label = "BASH", .profile = "sh" },
        .{ .label = "zsh", .profile = "sh" },
        .{ .label = "Shell", .profile = "sh" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.profile, resolve(case.label).?.label.get());
    try std.testing.expect(resolve("") == null);
    try std.testing.expect(resolve("text") == null);
}

test "expanded code fence labels resolve through the language registry" {
    const cases = [_]struct { label: []const u8, profile: []const u8 }{
        .{ .label = "python", .profile = "python" },         .{ .label = "py", .profile = "python" },
        .{ .label = "yaml", .profile = "yaml" },             .{ .label = "yml", .profile = "yaml" },
        .{ .label = "toml", .profile = "toml" },             .{ .label = "sql", .profile = "sql" },
        .{ .label = "dockerfile", .profile = "dockerfile" }, .{ .label = "rust", .profile = "rust" },
        .{ .label = "rs", .profile = "rust" },               .{ .label = "go", .profile = "go" },
        .{ .label = "c", .profile = "c" },                   .{ .label = "cpp", .profile = "cpp" },
        .{ .label = "c++", .profile = "cpp" },               .{ .label = "csharp", .profile = "csharp" },
        .{ .label = "cs", .profile = "csharp" },             .{ .label = "java", .profile = "java" },
        .{ .label = "kotlin", .profile = "kotlin" },         .{ .label = "php", .profile = "php" },
        .{ .label = "ruby", .profile = "ruby" },             .{ .label = "swift", .profile = "swift" },
        .{ .label = "powershell", .profile = "powershell" }, .{ .label = "ps1", .profile = "powershell" },
        .{ .label = "lua", .profile = "lua" },               .{ .label = "html", .profile = "html" },
        .{ .label = "xml", .profile = "xml" },               .{ .label = "css", .profile = "css" },
        .{ .label = "hcl", .profile = "hcl" },               .{ .label = "terraform", .profile = "hcl" },
        .{ .label = "tf", .profile = "hcl" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.profile, resolve(case.label).?.label.get());
}

test "high-confidence source shapes infer registered profiles" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { source: []const u8, profile: []const u8 }{
        .{ .source = "{\"ready\": true}", .profile = "json" },
        .{ .source = "#!/usr/bin/env bash\necho ready", .profile = "sh" },
        .{ .source = "def render(value):\n    return value", .profile = "python" },
        .{ .source = "SELECT id FROM users", .profile = "sql" },
        .{ .source = "FROM alpine:3.20\nRUN echo ready", .profile = "dockerfile" },
        .{ .source = "package main\nfunc main() {}", .profile = "go" },
        .{ .source = "fn main() { println!(\"ready\"); }", .profile = "rust" },
    };

    for (cases) |case| try std.testing.expectEqualStrings(case.profile, infer(alloc, case.source).?.label.get());
    try std.testing.expect(infer(alloc, "const value = 1;") == null);
    try std.testing.expect(infer(alloc, "title: ready") == null);
}

test "aliases do not collide across profiles" {
    for (profiles, 0..) |profile, profile_index| {
        for (profile.aliases) |alias| {
            for (profiles[profile_index + 1 ..]) |other| {
                for (other.aliases) |other_alias| {
                    try std.testing.expect(!std.ascii.eqlIgnoreCase(alias.get(), other_alias.get()));
                }
            }
        }
    }
}
