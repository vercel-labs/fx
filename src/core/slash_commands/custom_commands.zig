//! Discovery of user-authored slash commands stored as `.md` files under the
//! configured command roots. Discovery never fails the caller: every rejected
//! file becomes exactly one typed diagnostic and every other file in the same
//! root still loads.

const std = @import("std");

const command_specs = @import("command_specs.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const skill_contract = @import("../skills/skill_contract.zig");

const Allocator = std.mem.Allocator;
const SkillSource = skill_contract.SkillSource;

/// Total number of command files read per load, across every root.
const max_commands: usize = 256;
const max_command_file_bytes: usize = 262_144;
const max_command_name_bytes: usize = 64;
const max_argument_hint_bytes: usize = 128;

const command_file_extension = ".md";
const argument_hint_key = "argument-hint";

/// One discovered command. Every slice is owned by the discovery allocator.
pub const CustomCommand = struct {
    name: []u8,
    description: []u8,
    /// False when `description` is the root-derived fallback. The merged spec
    /// appends the source label only to a frontmatter description, so a row
    /// never names its root twice.
    has_explicit_description: bool,
    argument_hint: ?[]u8,
    body: []u8,
    path: []u8,
    source: SkillSource,
};

pub const CommandDiagnosticCause = union(enum) {
    /// A command root exists but could not be opened or iterated.
    unreadable_root,
    /// A command file could not be opened, stat'ed, or read.
    unreadable,
    oversized,
    invalid_frontmatter,
    empty_body,
    invalid_name,
    /// The derived name matches a builtin token or alias, case-insensitively.
    builtin_collision,
    /// An earlier root already published this name.
    shadowed,
    /// The same root already published this name.
    duplicate_name,
    /// A symlinked entry whose canonical target leaves its root.
    escapes_root,
    /// Files left unread once the load hit `max_commands`.
    count_cap: usize,
};

pub const CommandDiagnostic = struct {
    /// Owned. The file path for file-scoped causes, the root path for
    /// `.unreadable_root`, and empty for `.count_cap`.
    path: []u8,
    /// Owned derived name, present once a name exists.
    name: ?[]u8 = null,
    /// Owned. The colliding builtin token for `.builtin_collision` and the
    /// winning file path for `.shadowed`.
    detail: ?[]u8 = null,
    source: SkillSource,
    cause: CommandDiagnosticCause,
};

pub const CommandDiscovery = struct {
    commands: []CustomCommand = &.{},
    diagnostics: []CommandDiagnostic = &.{},

    pub fn deinit(self: *CommandDiscovery, alloc: Allocator) void {
        freeCommands(alloc, self.commands);
        freeDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

fn freeCommand(alloc: Allocator, command: CustomCommand) void {
    alloc.free(command.name);
    alloc.free(command.description);
    if (command.argument_hint) |hint| alloc.free(hint);
    alloc.free(command.body);
    alloc.free(command.path);
}

fn freeCommands(alloc: Allocator, commands: []CustomCommand) void {
    for (commands) |command| freeCommand(alloc, command);
    if (commands.len > 0) alloc.free(commands);
}

fn freeDiagnostic(alloc: Allocator, diagnostic: CommandDiagnostic) void {
    alloc.free(diagnostic.path);
    if (diagnostic.name) |name| alloc.free(name);
    if (diagnostic.detail) |detail| alloc.free(detail);
}

fn freeDiagnostics(alloc: Allocator, diagnostics: []CommandDiagnostic) void {
    for (diagnostics) |diagnostic| freeDiagnostic(alloc, diagnostic);
    if (diagnostics.len > 0) alloc.free(diagnostics);
}

/// Writes the user-facing text for one diagnostic. The trace channel and every
/// future surface share this single wording.
fn writeDiagnosticMessage(writer: *std.Io.Writer, diagnostic: CommandDiagnostic) !void {
    const name = diagnostic.name orelse "";
    switch (diagnostic.cause) {
        .unreadable_root => try writer.print("cannot read command root: {s}", .{diagnostic.path}),
        .unreadable => try writer.print("cannot read command file: {s}", .{diagnostic.path}),
        .oversized => try writer.print(
            "command file exceeds {d} bytes: {s}",
            .{ max_command_file_bytes, diagnostic.path },
        ),
        .invalid_frontmatter => try writer.print("invalid command frontmatter: {s}", .{diagnostic.path}),
        .empty_body => try writer.print("command file has an empty body: {s}", .{diagnostic.path}),
        .invalid_name => try writer.print("invalid command name derived from {s}", .{diagnostic.path}),
        .builtin_collision => try writer.print(
            "command '{s}' conflicts with a built-in command: {s}",
            .{ diagnostic.detail orelse name, diagnostic.path },
        ),
        .shadowed => try writer.print(
            "command '{s}' from {s} is shadowed by {s}",
            .{ name, diagnostic.path, diagnostic.detail orelse "" },
        ),
        .duplicate_name => try writer.print(
            "duplicate command '{s}': {s} ignored",
            .{ name, diagnostic.path },
        ),
        .escapes_root => try writer.print("command file escapes its root: {s}", .{diagnostic.path}),
        .count_cap => |skipped| try writer.print(
            "skipped {d} command files above the {d} limit",
            .{ skipped, max_commands },
        ),
    }
}

/// Routes discovery diagnostics through the trace channel skills already use.
/// No diagnostic blocks or delays startup.
pub fn traceDiagnostics(surface: []const u8, diagnostics: []const CommandDiagnostic) void {
    for (diagnostics) |diagnostic| {
        var message_buf: [1024]u8 = undefined;
        var message_writer = std.Io.Writer.fixed(&message_buf);
        writeDiagnosticMessage(&message_writer, diagnostic) catch {};
        debug_trace.logf(
            "commands",
            "discovery_diagnostic surface={s} source={s} cause={s} message=\"{f}\"",
            .{
                surface,
                @tagName(diagnostic.source),
                @tagName(diagnostic.cause),
                std.zig.fmtString(message_writer.buffered()),
            },
        );
    }
}

const CommandRoot = struct {
    path: []const u8,
    source: SkillSource,
};

const CommandEntry = struct {
    name: []u8,
    linked: bool,
};

/// Deduplicates roots that resolve to the same directory so a symlinked or
/// repeated root is read exactly once per load.
const CanonicalRoots = struct {
    paths: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *CanonicalRoots, alloc: Allocator) void {
        var keys = self.paths.keyIterator();
        while (keys.next()) |path| alloc.free(@constCast(path.*));
        self.paths.deinit(alloc);
        self.* = .{};
    }

    /// Takes ownership of `canonical_path` when it is new.
    fn remember(self: *CanonicalRoots, alloc: Allocator, canonical_path: []u8) !bool {
        if (self.paths.contains(canonical_path)) return false;
        try self.paths.put(alloc, canonical_path, {});
        return true;
    }
};

const LoadState = struct {
    alloc: Allocator,
    commands: *std.ArrayList(CustomCommand),
    diagnostics: *std.ArrayList(CommandDiagnostic),
    by_name: *std.StringHashMapUnmanaged(usize),
    reserved: command_specs.SlashRegistry,
    considered: usize = 0,
    skipped_over_cap: usize = 0,
};

pub fn loadCustomCommands(
    alloc: Allocator,
    workspace_root: ?[]const u8,
    home: ?[]const u8,
    user_prompts_dir: []const u8,
    root_policy: skill_contract.RootPolicy,
    reserved: command_specs.SlashRegistry,
) !CommandDiscovery {
    var commands: std.ArrayList(CustomCommand) = .empty;
    errdefer {
        for (commands.items) |command| freeCommand(alloc, command);
        commands.deinit(alloc);
    }
    var diagnostics: std.ArrayList(CommandDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| freeDiagnostic(alloc, diagnostic);
        diagnostics.deinit(alloc);
    }
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_name.deinit(alloc);

    var roots: std.ArrayList(CommandRoot) = .empty;
    defer {
        for (roots.items) |root| alloc.free(@constCast(root.path));
        roots.deinit(alloc);
    }

    if (workspace_root) |root| {
        try appendWorkspaceRoots(alloc, &roots, root, home, root_policy.workspace_roots);
    }
    if (root_policy.managed_root_source) |source| {
        try appendRoot(alloc, &roots, try alloc.dupe(u8, user_prompts_dir), source);
    }
    if (home) |home_root| {
        for (root_policy.global_roots) |spec| {
            try appendRoot(alloc, &roots, try std.fs.path.join(alloc, &.{ home_root, spec.path }), spec.source);
        }
    }

    var canonical_roots: CanonicalRoots = .{};
    defer canonical_roots.deinit(alloc);

    var state: LoadState = .{
        .alloc = alloc,
        .commands = &commands,
        .diagnostics = &diagnostics,
        .by_name = &by_name,
        .reserved = reserved,
    };

    for (roots.items) |root| {
        try appendCommandsFromRoot(&state, &canonical_roots, root);
    }

    if (state.skipped_over_cap > 0) {
        try appendDiagnostic(alloc, &diagnostics, "", null, null, .global_fx, .{ .count_cap = state.skipped_over_cap });
    }

    const owned_commands = try commands.toOwnedSlice(alloc);
    errdefer freeCommands(alloc, owned_commands);
    const owned_diagnostics = try diagnostics.toOwnedSlice(alloc);
    return .{ .commands = owned_commands, .diagnostics = owned_diagnostics };
}

/// Walks the workspace root and each ancestor, stopping at the home directory
/// so a command root above `$HOME` is never read.
fn appendWorkspaceRoots(
    alloc: Allocator,
    roots: *std.ArrayList(CommandRoot),
    workspace_root: []const u8,
    home: ?[]const u8,
    root_specs: []const skill_contract.RootSpec,
) !void {
    // Without a usable home boundary, discover only the workspace itself. The
    // immediate root is always in scope, while walking any parent could load a
    // prompt from outside the user's intended workspace hierarchy. A home that
    // is not an ancestor is no boundary at all, so it follows the same rule.
    if (home == null or !pathing.pathInside(home.?, workspace_root)) {
        for (root_specs) |spec| {
            try appendRoot(alloc, roots, try std.fs.path.join(alloc, &.{ workspace_root, spec.path }), spec.source);
        }
        return;
    }

    var current: ?[]const u8 = workspace_root;
    while (current) |dir| : (current = std.fs.path.dirname(dir)) {
        if (home) |home_root| {
            if (std.mem.eql(u8, dir, home_root)) break;
        }
        for (root_specs) |spec| {
            try appendRoot(alloc, roots, try std.fs.path.join(alloc, &.{ dir, spec.path }), spec.source);
        }
    }
}

/// Takes ownership of `path`.
fn appendRoot(alloc: Allocator, roots: *std.ArrayList(CommandRoot), path: []u8, source: SkillSource) !void {
    for (roots.items) |root| {
        if (std.mem.eql(u8, root.path, path)) {
            alloc.free(path);
            return;
        }
    }
    roots.append(alloc, .{ .path = path, .source = source }) catch |err| {
        alloc.free(path);
        return err;
    };
}

fn appendCommandsFromRoot(state: *LoadState, canonical_roots: *CanonicalRoots, root: CommandRoot) !void {
    const alloc = state.alloc;
    const canonical_root = io_mod.realpathAlloc(alloc, root.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // An absent root is the normal case and never produces a diagnostic.
        if (err == error.FileNotFound or err == error.NotDir) return;
        try appendDiagnostic(alloc, state.diagnostics, root.path, null, null, root.source, .unreadable_root);
        return;
    };
    var canonical_owned = true;
    defer if (canonical_owned) alloc.free(canonical_root);

    if (!try canonical_roots.remember(alloc, canonical_root)) return;
    canonical_owned = false;

    var dir = io_mod.openDirAbsoluteNoFollow(canonical_root, .{ .iterate = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) return;
        try appendDiagnostic(alloc, state.diagnostics, root.path, null, null, root.source, .unreadable_root);
        return;
    };
    defer dir.close(io_mod.getIo());

    var entries: std.ArrayList(CommandEntry) = .empty;
    defer {
        for (entries.items) |entry| alloc.free(entry.name);
        entries.deinit(alloc);
    }

    var it = dir.iterate();
    while (true) {
        const entry = it.next(io_mod.getIo()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendDiagnostic(alloc, state.diagnostics, root.path, null, null, root.source, .unreadable_root);
            break;
        } orelse break;
        // Subdirectories are never descended into and never treated as commands.
        if (entry.kind == .directory) continue;
        const linked = entry.kind == .sym_link;
        if (entry.kind != .file and !linked) continue;
        if (!hasCommandExtension(entry.name)) continue;

        const owned_name = try alloc.dupe(u8, entry.name);
        entries.append(alloc, .{ .name = owned_name, .linked = linked }) catch |err| {
            alloc.free(owned_name);
            return err;
        };
    }

    for (entries.items) |entry| {
        try appendCommandCandidate(state, root, canonical_root, &dir, entry);
    }
}

fn appendCommandCandidate(
    state: *LoadState,
    root: CommandRoot,
    canonical_root: []const u8,
    dir: *std.Io.Dir,
    entry: CommandEntry,
) !void {
    const alloc = state.alloc;
    if (state.considered >= max_commands) {
        state.skipped_over_cap += 1;
        return;
    }
    state.considered += 1;

    const file_path = try std.fs.path.join(alloc, &.{ root.path, entry.name });
    defer alloc.free(file_path);

    var file = (try openCommandFile(alloc, state, root, canonical_root, dir, entry, file_path)) orelse return;
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .unreadable);
        return;
    };
    if (stat.kind != .file) {
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .unreadable);
        return;
    }
    if (stat.size > max_command_file_bytes) {
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .oversized);
        return;
    }

    const content = io_mod.readFileToEnd(alloc, &file, max_command_file_bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const cause: CommandDiagnosticCause = if (err == error.StreamTooLong) .oversized else .unreadable;
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, cause);
        return;
    };
    defer alloc.free(content);

    const parsed = skill_contract.parseSkillFileWithOptions(content, .{
        .name_mode = .ignored,
        .additional_scalar_key = argument_hint_key,
        .preserve_body_prefix = true,
    });
    switch (parsed.status) {
        .invalid => {
            try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .invalid_frontmatter);
            return;
        },
        .valid, .no_frontmatter => {},
    }
    // A frontmatter block above the supported header size is rejected rather
    // than parsed from a truncated prefix.
    if (content.len - parsed.body.len > skill_contract.max_frontmatter_bytes) {
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .invalid_frontmatter);
        return;
    }

    const body = parsed.body;
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) {
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .empty_body);
        return;
    }

    const derived_name = commandNameStem(entry.name);
    if (!validCommandName(derived_name)) {
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .invalid_name);
        return;
    }

    if (reservedCollision(state.reserved, derived_name)) |builtin_token| {
        try appendDiagnostic(alloc, state.diagnostics, file_path, derived_name, builtin_token, root.source, .builtin_collision);
        return;
    }

    if (state.by_name.get(derived_name)) |winner_index| {
        const winner = state.commands.items[winner_index];
        const winner_root = std.fs.path.dirname(winner.path) orelse "";
        const same_root = std.mem.eql(u8, winner_root, root.path);
        try appendDiagnostic(
            alloc,
            state.diagnostics,
            file_path,
            derived_name,
            if (same_root) null else winner.path,
            root.source,
            if (same_root) .duplicate_name else .shadowed,
        );
        return;
    }

    try appendCommand(state, root, file_path, derived_name, parsed, body);
}

fn appendCommand(
    state: *LoadState,
    root: CommandRoot,
    file_path: []const u8,
    derived_name: []const u8,
    parsed: skill_contract.ParsedSkillFile,
    body: []const u8,
) !void {
    const alloc = state.alloc;
    const name = try alloc.dupe(u8, derived_name);
    errdefer alloc.free(name);

    const has_explicit_description = parsed.description != null;
    const description = if (parsed.description) |raw| description: {
        const metadata: skill_contract.SkillMetadata = .{
            .name = derived_name,
            .description = raw,
            .description_block = parsed.description_block,
        };
        const decoded = try alloc.alloc(u8, metadata.description_len());
        metadata.write_description(decoded);
        break :description decoded;
    } else description: {
        const display_root = try encodeSourceRoot(alloc, root.path);
        defer alloc.free(display_root);
        break :description try std.fmt.allocPrint(alloc, "custom command from {s}", .{display_root});
    };
    errdefer alloc.free(description);

    const argument_hint = if (parsed.additional_scalar) |raw|
        try sanitizeArgumentHint(alloc, raw)
    else
        null;
    errdefer if (argument_hint) |hint| alloc.free(hint);

    const owned_body = try alloc.dupe(u8, body);
    errdefer alloc.free(owned_body);
    const owned_path = try alloc.dupe(u8, file_path);
    errdefer alloc.free(owned_path);

    // Reserved before the append so no fallible step follows it and the
    // command list can never hold an entry the name index does not know.
    try state.by_name.ensureUnusedCapacity(alloc, 1);
    try state.commands.append(alloc, .{
        .name = name,
        .description = description,
        .has_explicit_description = has_explicit_description,
        .argument_hint = argument_hint,
        .body = owned_body,
        .path = owned_path,
        .source = root.source,
    });
    state.by_name.putAssumeCapacity(name, state.commands.items.len - 1);
}

/// Opens a candidate, enforcing that a symlinked entry never resolves outside
/// its own root. Returns null when the entry produced a diagnostic or vanished.
fn openCommandFile(
    alloc: Allocator,
    state: *LoadState,
    root: CommandRoot,
    canonical_root: []const u8,
    dir: *std.Io.Dir,
    entry: CommandEntry,
    file_path: []const u8,
) !?std.Io.File {
    if (!entry.linked) {
        return io_mod.openExistingReadOnlyRegularFile(dir.*, entry.name, .no_follow) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.FileNotFound) return null;
            try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .unreadable);
            return null;
        };
    }

    const target_path = io_mod.dirRealpathAlloc(alloc, dir.*, entry.name) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .escapes_root);
        return null;
    };
    defer alloc.free(target_path);
    if (!pathing.pathInside(canonical_root, target_path)) {
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .escapes_root);
        return null;
    }

    var file = io_mod.openExistingReadOnlyRegularFile(dir.*, entry.name, .follow) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) return null;
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .unreadable);
        return null;
    };
    errdefer file.close(io_mod.getIo());

    // Recheck after opening so a link swapped between preflight and open is
    // still rejected before a single byte is read.
    const opened_path = io_mod.openedFilePathAlloc(alloc, file) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        file.close(io_mod.getIo());
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .escapes_root);
        return null;
    };
    defer alloc.free(opened_path);
    if (!pathing.pathInside(canonical_root, opened_path)) {
        file.close(io_mod.getIo());
        try appendDiagnostic(alloc, state.diagnostics, file_path, null, null, root.source, .escapes_root);
        return null;
    }
    return file;
}

fn appendDiagnostic(
    alloc: Allocator,
    diagnostics: *std.ArrayList(CommandDiagnostic),
    path: []const u8,
    name: ?[]const u8,
    detail: ?[]const u8,
    source: SkillSource,
    cause: CommandDiagnosticCause,
) !void {
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    const owned_name = if (name) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_name) |value| alloc.free(value);
    const owned_detail = if (detail) |value| try alloc.dupe(u8, value) else null;
    errdefer if (owned_detail) |value| alloc.free(value);

    try diagnostics.append(alloc, .{
        .path = owned_path,
        .name = owned_name,
        .detail = owned_detail,
        .source = source,
        .cause = cause,
    });
}

/// Matches `.md` case-insensitively so `foo.MD` is a command file too.
fn hasCommandExtension(file_name: []const u8) bool {
    if (file_name.len <= command_file_extension.len) return false;
    const suffix = file_name[file_name.len - command_file_extension.len ..];
    return std.ascii.eqlIgnoreCase(suffix, command_file_extension);
}

fn commandNameStem(file_name: []const u8) []const u8 {
    return file_name[0 .. file_name.len - command_file_extension.len];
}

/// Restricts names to `[A-Za-z_][A-Za-z0-9_-]*` within 64 bytes, so no name can
/// encode whitespace, a leading digit, a path separator, or `..`.
pub fn validCommandName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_command_name_bytes) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') continue;
        return false;
    }
    return true;
}

/// Registry tokens carry their leading slash; a derived command name never
/// does. Comparing the two verbatim would never match, so the slash is dropped
/// before the comparison.
fn tokenName(token: []const u8) []const u8 {
    return if (token.len > 0 and token[0] == '/') token[1..] else token;
}

/// Slash matching is byte-exact, so a case-only near-miss of a builtin is a
/// user error rather than a distinct command. Returns the colliding token in
/// the same slashless shape as a derived command name.
pub fn reservedCollision(reserved: command_specs.SlashRegistry, name: []const u8) ?[]const u8 {
    for (reserved.commands) |spec| {
        const command = tokenName(spec.command);
        if (std.ascii.eqlIgnoreCase(command, name)) return command;
        for (spec.aliases) |alias| {
            const alias_name = tokenName(alias);
            if (std.ascii.eqlIgnoreCase(alias_name, name)) return alias_name;
        }
    }
    return null;
}

/// Strips control bytes and truncates at a UTF-8 boundary so a hint can never
/// corrupt the TUI layout.
fn sanitizeArgumentHint(alloc: Allocator, raw: []const u8) !?[]u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(alloc);
    for (raw) |byte| {
        if (byte < 0x20 or byte == 0x7f) continue;
        try cleaned.append(alloc, byte);
    }

    var end = cleaned.items.len;
    if (end > max_argument_hint_bytes) {
        end = max_argument_hint_bytes;
        while (end > 0 and cleaned.items[end] & 0xC0 == 0x80) end -= 1;
    }
    const trimmed = std.mem.trim(u8, cleaned.items[0..end], " \t");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// Encodes every non-printable or non-ASCII source byte as `\xNN`. Source
/// roots are filesystem data, so they must not inject terminal controls or
/// depend on color to remain distinguishable in help and completion.
fn encodeSourceRoot(alloc: Allocator, raw: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (raw) |byte| {
        if (byte >= 0x20 and byte <= 0x7e) {
            try out.append(alloc, byte);
        } else {
            try out.appendSlice(alloc, "\\x");
            try out.append(alloc, hex[byte >> 4]);
            try out.append(alloc, hex[byte & 0x0f]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Owns the discovered commands and the merged registry slice that
/// `App.slashRegistry()` serves. The builtin specs come first, so a builtin
/// wins any token collision for free: every matcher returns on its first hit.
pub const CommandRuntime = struct {
    discovery: CommandDiscovery = .{},
    /// One owned `/name` per custom spec. It is both the spec token and its
    /// help entry, so a command costs a single string here.
    tokens: [][]u8 = &.{},
    /// One owned completion description per custom spec, naming the source
    /// root in plain text.
    descriptions: [][]u8 = &.{},
    /// One owned display label per custom spec: `/name <hint>` when the file
    /// declares an `argument-hint`, and the bare token otherwise, so a command
    /// without a hint renders no separator.
    labels: [][]u8 = &.{},
    /// `builtins ++ custom`, a single allocation. Left empty when no command
    /// was discovered so the builtin registry is served untouched.
    merged: []command_specs.SlashSpec = &.{},

    pub fn deinit(self: *CommandRuntime, alloc: Allocator) void {
        self.discovery.deinit(alloc);
        freeOwnedStrings(alloc, self.tokens);
        freeOwnedStrings(alloc, self.descriptions);
        freeOwnedStrings(alloc, self.labels);
        if (self.merged.len > 0) alloc.free(self.merged);
        self.* = .{};
    }

    /// Serves `builtins` verbatim when nothing was discovered, so an fx without
    /// a `.fx/prompts` directory anywhere is byte-identical to one built
    /// before this feature.
    pub fn registry(
        self: *const CommandRuntime,
        builtins: command_specs.SlashRegistry,
    ) command_specs.SlashRegistry {
        if (self.merged.len == 0) return builtins;
        return .{ .commands = self.merged };
    }

    /// Resolves a merged-registry index back to the command it was built from.
    ///
    /// Returns null for a builtin index and for any index past the end, so a
    /// reload that raced a queued invocation reports an unknown command instead
    /// of reading out of bounds.
    pub fn commandAt(
        self: *const CommandRuntime,
        builtins: command_specs.SlashRegistry,
        index: usize,
    ) ?*const CustomCommand {
        if (self.merged.len == 0) return null;
        if (index < builtins.commands.len) return null;
        const offset = index - builtins.commands.len;
        if (offset >= self.discovery.commands.len) return null;
        return &self.discovery.commands[offset];
    }
};

fn freeOwnedStrings(alloc: Allocator, strings: [][]u8) void {
    for (strings) |string| alloc.free(string);
    if (strings.len > 0) alloc.free(strings);
}

/// Releases a row that is still being filled: `built` is only a prefix view of
/// `storage`, so the strings and the full backing array must be freed
/// separately.
fn freePartialStrings(alloc: Allocator, storage: [][]u8, built: [][]u8) void {
    for (built) |string| alloc.free(string);
    if (storage.len > 0) alloc.free(storage);
}

/// Builds the merged registry from `discovery`, which the returned runtime owns
/// on success. On failure the caller still owns `discovery`.
pub fn buildRuntime(
    alloc: Allocator,
    builtins: command_specs.SlashRegistry,
    discovery: CommandDiscovery,
) Allocator.Error!CommandRuntime {
    if (discovery.commands.len == 0) return .{ .discovery = discovery };

    var runtime: CommandRuntime = .{};
    var token_storage: [][]u8 = &.{};
    var description_storage: [][]u8 = &.{};
    var label_storage: [][]u8 = &.{};
    errdefer {
        freePartialStrings(alloc, token_storage, runtime.tokens);
        freePartialStrings(alloc, description_storage, runtime.descriptions);
        freePartialStrings(alloc, label_storage, runtime.labels);
        if (runtime.merged.len > 0) alloc.free(runtime.merged);
    }

    const tokens = try alloc.alloc([]u8, discovery.commands.len);
    token_storage = tokens;
    runtime.tokens = tokens[0..0];
    for (discovery.commands) |command| {
        tokens[runtime.tokens.len] = try std.fmt.allocPrint(alloc, "/{s}", .{command.name});
        runtime.tokens = tokens[0 .. runtime.tokens.len + 1];
    }

    const descriptions = try alloc.alloc([]u8, discovery.commands.len);
    description_storage = descriptions;
    runtime.descriptions = descriptions[0..0];
    for (discovery.commands) |command| {
        const source_root = std.fs.path.dirname(command.path) orelse command.path;
        const display_root = try encodeSourceRoot(alloc, source_root);
        defer alloc.free(display_root);
        descriptions[runtime.descriptions.len] = if (command.has_explicit_description)
            try std.fmt.allocPrint(
                alloc,
                "{s} ({s})",
                .{ command.description, display_root },
            )
        else
            try alloc.dupe(u8, command.description);
        runtime.descriptions = descriptions[0 .. runtime.descriptions.len + 1];
    }

    const labels = try alloc.alloc([]u8, discovery.commands.len);
    label_storage = labels;
    runtime.labels = labels[0..0];
    for (discovery.commands, 0..) |command, index| {
        labels[runtime.labels.len] = if (command.argument_hint) |hint|
            try std.fmt.allocPrint(alloc, "{s} {s}", .{ tokens[index], hint })
        else
            try alloc.dupe(u8, tokens[index]);
        runtime.labels = labels[0 .. runtime.labels.len + 1];
    }

    const merged = try alloc.alloc(
        command_specs.SlashSpec,
        builtins.commands.len + discovery.commands.len,
    );
    runtime.merged = merged;
    @memcpy(merged[0..builtins.commands.len], builtins.commands);
    for (discovery.commands, 0..) |_, index| {
        merged[builtins.commands.len + index] = customSpec(
            tokens[index],
            labels[index],
            descriptions[index],
        );
    }

    runtime.discovery = discovery;
    return runtime;
}

/// Fills every field the visibility gates read, so a custom entry reaches the
/// help catalog and the completion picker on the same terms as `/mcp`.
fn customSpec(
    token: []const u8,
    label: []const u8,
    description: []const u8,
) command_specs.SlashSpec {
    return .{
        .kind = .custom,
        .command = token,
        // `/name <hint>` matches how a builtin such as `/model <id-or-query>`
        // states its arguments in the same catalog.
        .help_entry = label,
        .completion_label = label,
        .completion_description = description,
        .presentation_category = .extensions,
        .has_args = true,
        .accepts_payload = true,
        .requires_prompt_credential = true,
    };
}

const testing = std.testing;

const test_reserved_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .aliases = &.{"/h"} },
    .{ .kind = .model, .command = "/model" },
};
const test_reserved: command_specs.SlashRegistry = .{ .commands = &test_reserved_specs };

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn createTempSymlinkOrSkip(tmp: *std.testing.TmpDir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.fs.path.dirname(link_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    tmp.dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
}

fn tmpPath(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    if (sub_path.len == 0) return alloc.dupe(u8, root);
    return std.fs.path.join(alloc, &.{ root, sub_path });
}

/// Runs discovery over a tmp tree shaped like the production layout: `home` is
/// the tmp root, so the workspace ancestor walk stops there.
fn loadFromTmp(alloc: Allocator, tmp: *std.testing.TmpDir, workspace_sub_path: []const u8) !CommandDiscovery {
    const home = try tmpPath(alloc, tmp, "");
    defer alloc.free(home);
    const workspace = try tmpPath(alloc, tmp, workspace_sub_path);
    defer alloc.free(workspace);
    const user_dir = try tmpPath(alloc, tmp, "user/.fx/prompts");
    defer alloc.free(user_dir);
    return loadCustomCommands(alloc, workspace, home, user_dir, test_policy, test_reserved);
}

const test_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &[_]skill_contract.RootSpec{
        .{ .source = .workspace_fx, .path = ".fx/prompts" },
    },
    .managed_root_source = .global_fx,
};

fn findCommand(discovery: CommandDiscovery, name: []const u8) ?CustomCommand {
    for (discovery.commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

fn countDiagnostics(discovery: CommandDiscovery, cause: std.meta.Tag(CommandDiagnosticCause)) usize {
    var total: usize = 0;
    for (discovery.diagnostics) |diagnostic| {
        if (diagnostic.cause == cause) total += 1;
    }
    return total;
}

fn expectMessage(expected: []const u8, diagnostic: CommandDiagnostic) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeDiagnosticMessage(&writer, diagnostic);
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "discovery finds commands in workspace and user roots with source attribution" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/deploy.md", "Deploy $1 now.");
    try writeTempFile(&tmp, "user/.fx/prompts/notes.md", "Take notes.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), discovery.commands.len);
    try testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
    try testing.expectEqualStrings("deploy", discovery.commands[0].name);
    try testing.expectEqual(SkillSource.workspace_fx, discovery.commands[0].source);
    try testing.expectEqualStrings("Deploy $1 now.", discovery.commands[0].body);
    try testing.expectEqualStrings("notes", discovery.commands[1].name);
    try testing.expectEqual(SkillSource.global_fx, discovery.commands[1].source);
}

test "discovery returns nothing when no command root exists" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "a command root that is not a directory is diagnosed by path" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.fx/prompts", "not a directory");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.unreadable_root, discovery.diagnostics[0].cause);
    try testing.expect(std.mem.endsWith(u8, discovery.diagnostics[0].path, ".fx/prompts"));
}

test "a file without frontmatter uses the filename stem and a source fallback description" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.fx/prompts/review-pr.md", "Review pull request $1.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    const command = discovery.commands[0];
    try testing.expectEqualStrings("review-pr", command.name);
    try testing.expectEqualStrings("Review pull request $1.", command.body);
    const source_root = std.fs.path.dirname(command.path) orelse return error.TestExpectedPath;
    const expected_description = try std.fmt.allocPrint(alloc, "custom command from {s}", .{source_root});
    defer alloc.free(expected_description);
    try testing.expectEqualStrings(expected_description, command.description);
    try testing.expectEqual(@as(?[]u8, null), command.argument_hint);
}

test "frontmatter description and argument-hint are captured without unknown-key errors" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.fx/prompts/greet.md",
        \\---
        \\description: Greets a person
        \\argument-hint: <name>
        \\model: ignored-unknown-key
        \\---
        \\Hello $1.
    );

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    const command = discovery.commands[0];
    try testing.expectEqualStrings("greet", command.name);
    try testing.expectEqualStrings("Greets a person", command.description);
    try testing.expectEqualStrings("<name>", command.argument_hint.?);
    try testing.expectEqualStrings("Hello $1.", command.body);
}

test "the filename remains authoritative when frontmatter declares a name" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.fx/prompts/whatever.md",
        \\---
        \\name: 2 invalid and ignored
        \\---
        \\Ship it.
    );

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("whatever", discovery.commands[0].name);
}

test "command bodies preserve leading and trailing template whitespace" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected = "\n  Keep this indentation.  \n\n";
    try writeTempFile(&tmp, "workspace/.fx/prompts/verbatim.md", "---\ndescription: Preserve formatting\n---\n" ++ expected);

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings(expected, discovery.commands[0].body);
}

test "an empty body is rejected with a diagnostic" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.fx/prompts/hollow.md",
        \\---
        \\description: Nothing follows
        \\---
        \\
    );

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.empty_body, discovery.diagnostics[0].cause);
}

test "an unterminated frontmatter block is rejected without a truncated parse" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "workspace/.fx/prompts/broken.md",
        \\---
        \\description: never closed
        \\Body text.
    );

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.invalid_frontmatter, discovery.diagnostics[0].cause);
}

test "an oversized file is skipped while the rest of the root loads" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const big = try alloc.alloc(u8, max_command_file_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'x');
    try writeTempFile(&tmp, "workspace/.fx/prompts/huge.md", big);
    try writeTempFile(&tmp, "workspace/.fx/prompts/small.md", "Still loads.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("small", discovery.commands[0].name);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.oversized, discovery.diagnostics[0].cause);
}

test "non-markdown files and subdirectories are ignored without diagnostics" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/readme.txt", "not a command");
    try writeTempFile(&tmp, "workspace/.fx/prompts/nested/deep.md", "not discovered");
    try writeTempFile(&tmp, "workspace/.fx/prompts/real.md", "A real command.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("real", discovery.commands[0].name);
    try testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "a builtin collision is rejected and names the builtin, including case-only near misses" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/help.md", "Shadow attempt.");
    try writeTempFile(&tmp, "workspace/.fx/prompts/Model.md", "Case-only near miss.");
    try writeTempFile(&tmp, "workspace/.fx/prompts/h.md", "Alias collision.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try testing.expectEqual(@as(usize, 3), discovery.diagnostics.len);
    for (discovery.diagnostics) |diagnostic| {
        try testing.expectEqual(CommandDiagnosticCause.builtin_collision, diagnostic.cause);
        try testing.expect(diagnostic.detail != null);
    }
    var model_diagnostic: ?CommandDiagnostic = null;
    for (discovery.diagnostics) |diagnostic| {
        if (diagnostic.name) |name| {
            if (std.mem.eql(u8, name, "Model")) model_diagnostic = diagnostic;
        }
    }
    const diagnostic = model_diagnostic orelse return error.TestExpectedModelDiagnostic;
    const expected = try std.fmt.allocPrint(
        alloc,
        "command 'model' conflicts with a built-in command: {s}",
        .{diagnostic.path},
    );
    defer alloc.free(expected);
    try expectMessage(expected, diagnostic);
}

test "invalid derived names are rejected before reaching the registry" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/my command.md", "Whitespace name.");
    try writeTempFile(&tmp, "workspace/.fx/prompts/2fast.md", "Leading digit.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), discovery.commands.len);
    try testing.expectEqual(@as(usize, 2), countDiagnostics(discovery, .invalid_name));
}

test "validCommandName enforces the documented character and length rules" {
    try testing.expect(validCommandName("review-pr"));
    try testing.expect(validCommandName("_private"));
    try testing.expect(validCommandName("a1"));
    try testing.expect(!validCommandName(""));
    try testing.expect(!validCommandName("2fast"));
    try testing.expect(!validCommandName("my command"));
    try testing.expect(!validCommandName("nested/name"));
    try testing.expect(!validCommandName(".."));
    try testing.expect(!validCommandName("a" ** (max_command_name_bytes + 1)));
    try testing.expect(validCommandName("a" ** max_command_name_bytes));
}

test "a cross-root duplicate keeps the earlier root and diagnoses the loser" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/deploy.md", "Workspace wins.");
    try writeTempFile(&tmp, "user/.fx/prompts/deploy.md", "User loses.");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("Workspace wins.", discovery.commands[0].body);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    const diagnostic = discovery.diagnostics[0];
    try testing.expectEqual(CommandDiagnosticCause.shadowed, diagnostic.cause);
    try testing.expectEqualStrings("deploy", diagnostic.name.?);
    try testing.expectEqualStrings(discovery.commands[0].path, diagnostic.detail.?);
}

test "a same-root duplicate keeps the first entry in directory order" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/foo.md", "lowercase file.");
    try writeTempFile(&tmp, "workspace/.fx/prompts/foo.MD", "uppercase file.");

    var prompts_dir = try tmp.dir.openDir(io_mod.getIo(), "workspace/.fx/prompts", .{ .iterate = true });
    defer prompts_dir.close(io_mod.getIo());
    var iterator = prompts_dir.iterate();
    const first_entry = (try iterator.next(io_mod.getIo())).?;
    const second_entry = (try iterator.next(io_mod.getIo())) orelse {
        // A case-insensitive volume cannot represent both extension variants,
        // so the same-root collision is not constructible on that filesystem.
        return error.SkipZigTest;
    };
    const first_name = try alloc.dupe(u8, first_entry.name);
    defer alloc.free(first_name);
    const second_name = try alloc.dupe(u8, second_entry.name);
    defer alloc.free(second_name);

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("foo", discovery.commands[0].name);
    try testing.expect(std.mem.endsWith(u8, discovery.commands[0].path, first_name));
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.duplicate_name, discovery.diagnostics[0].cause);
    try testing.expect(std.mem.endsWith(u8, discovery.diagnostics[0].path, second_name));
}

test "a symlinked entry whose target escapes the root is rejected and never read" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "outside/secret.md", "Should never load.");
    try writeTempFile(&tmp, "workspace/.fx/prompts/inside.md", "Loads fine.");
    const outside = try tmpPath(alloc, &tmp, "outside/secret.md");
    defer alloc.free(outside);
    try createTempSymlinkOrSkip(&tmp, outside, "workspace/.fx/prompts/escape.md");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("inside", discovery.commands[0].name);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.escapes_root, discovery.diagnostics[0].cause);
    try testing.expect(std.mem.endsWith(u8, discovery.diagnostics[0].path, "escape.md"));
}

test "a symlinked entry that stays inside the root loads" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/base.md", "Shared body.");
    const inside = try tmpPath(alloc, &tmp, "workspace/.fx/prompts/base.md");
    defer alloc.free(inside);
    try createTempSymlinkOrSkip(&tmp, inside, "workspace/.fx/prompts/alias.md");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), discovery.commands.len);
    try testing.expect(findCommand(discovery, "alias") != null);
    try testing.expect(findCommand(discovery, "base") != null);
    try testing.expectEqualStrings("Shared body.", findCommand(discovery, "alias").?.body);
    try testing.expectEqualStrings("Shared body.", findCommand(discovery, "base").?.body);
    try testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "a symlink to a directory inside the root is diagnosed as unreadable" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/nested/keep.txt", "placeholder");
    try writeTempFile(&tmp, "workspace/.fx/prompts/real.md", "Still loads.");
    const nested = try tmpPath(alloc, &tmp, "workspace/.fx/prompts/nested");
    defer alloc.free(nested);
    try createTempSymlinkOrSkip(&tmp, nested, "workspace/.fx/prompts/bogus.md");

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("real", discovery.commands[0].name);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.unreadable, discovery.diagnostics[0].cause);
}

test "a file without read permission is skipped and discovery still returns" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/locked.md", "Never read.");
    try writeTempFile(&tmp, "workspace/.fx/prompts/open.md", "Still loads.");

    {
        var locked = try tmp.dir.openFile(io_mod.getIo(), "workspace/.fx/prompts/locked.md", .{});
        defer locked.close(io_mod.getIo());
        locked.setPermissions(io_mod.getIo(), @enumFromInt(@as(std.posix.mode_t, 0o000))) catch return error.SkipZigTest;
    }

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("open", discovery.commands[0].name);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(CommandDiagnosticCause.unreadable, discovery.diagnostics[0].cause);
    try testing.expect(std.mem.endsWith(u8, discovery.diagnostics[0].path, "locked.md"));
}

test "roots that resolve to the same canonical path are read once" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/once.md", "Only once.");

    const home = try tmpPath(alloc, &tmp, "");
    defer alloc.free(home);
    const workspace = try tmpPath(alloc, &tmp, "workspace");
    defer alloc.free(workspace);
    const user_dir = try tmpPath(alloc, &tmp, "workspace/.fx/prompts");
    defer alloc.free(user_dir);

    var discovery = try loadCustomCommands(alloc, workspace, home, user_dir, test_policy, test_reserved);
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqual(SkillSource.workspace_fx, discovery.commands[0].source);
    try testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "the workspace ancestor walk stops at the home directory" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, ".fx/prompts/above-home.md", "Above the boundary.");
    try writeTempFile(&tmp, "home/workspace/.fx/prompts/below-home.md", "Below the boundary.");

    const home = try tmpPath(alloc, &tmp, "home");
    defer alloc.free(home);
    const workspace = try tmpPath(alloc, &tmp, "home/workspace");
    defer alloc.free(workspace);
    const user_dir = try tmpPath(alloc, &tmp, "home/.fx/prompts");
    defer alloc.free(user_dir);

    var discovery = try loadCustomCommands(alloc, workspace, home, user_dir, test_policy, test_reserved);
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("below-home", discovery.commands[0].name);
}

test "a workspace outside home does not scan parent prompt roots" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "outside/workspace/.fx/prompts/local.md", "Local prompt.");
    try writeTempFile(&tmp, "outside/.fx/prompts/parent.md", "Must not load.");
    try tmp.dir.createDirPath(io_mod.getIo(), "home");

    const home = try tmpPath(alloc, &tmp, "home");
    defer alloc.free(home);
    const workspace = try tmpPath(alloc, &tmp, "outside/workspace");
    defer alloc.free(workspace);
    const user_dir = try tmpPath(alloc, &tmp, "home/.fx/prompts");
    defer alloc.free(user_dir);

    var discovery = try loadCustomCommands(alloc, workspace, home, user_dir, test_policy, test_reserved);
    defer discovery.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), discovery.commands.len);
    try testing.expectEqualStrings("local", discovery.commands[0].name);
}

test "the command count cap loads the first files and reports the remainder once" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var index: usize = 0;
    while (index < max_commands + 3) : (index += 1) {
        const name = try std.fmt.allocPrint(alloc, "workspace/.fx/prompts/cmd{d:0>4}.md", .{index});
        defer alloc.free(name);
        try writeTempFile(&tmp, name, "Body.");
    }

    var prompts_dir = try tmp.dir.openDir(io_mod.getIo(), "workspace/.fx/prompts", .{ .iterate = true });
    defer prompts_dir.close(io_mod.getIo());
    var iterator = prompts_dir.iterate();
    const first_entry = (try iterator.next(io_mod.getIo())).?;
    const first_name = commandNameStem(first_entry.name);

    var discovery = try loadFromTmp(alloc, &tmp, "workspace");
    defer discovery.deinit(alloc);

    try testing.expectEqual(max_commands, discovery.commands.len);
    try testing.expectEqualStrings(first_name, discovery.commands[0].name);
    try testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try testing.expectEqual(@as(usize, 3), discovery.diagnostics[0].cause.count_cap);
    try expectMessage("skipped 3 command files above the 256 limit", discovery.diagnostics[0]);
}

test "diagnostic messages match the documented wording" {
    const path = "/repo/.fx/prompts/deploy.md";
    try expectMessage("cannot read command root: /repo/.fx/prompts", .{
        .path = @constCast("/repo/.fx/prompts"),
        .source = .workspace_fx,
        .cause = .unreadable_root,
    });
    try expectMessage("cannot read command file: " ++ path, .{
        .path = @constCast(path),
        .source = .workspace_fx,
        .cause = .unreadable,
    });
    try expectMessage("command file exceeds 262144 bytes: " ++ path, .{
        .path = @constCast(path),
        .source = .workspace_fx,
        .cause = .oversized,
    });
    try expectMessage("invalid command frontmatter: " ++ path, .{
        .path = @constCast(path),
        .source = .workspace_fx,
        .cause = .invalid_frontmatter,
    });
    try expectMessage("command file has an empty body: " ++ path, .{
        .path = @constCast(path),
        .source = .workspace_fx,
        .cause = .empty_body,
    });
    try expectMessage("invalid command name derived from " ++ path, .{
        .path = @constCast(path),
        .source = .workspace_fx,
        .cause = .invalid_name,
    });
    try expectMessage("command 'help' conflicts with a built-in command: " ++ path, .{
        .path = @constCast(path),
        .name = @constCast(@as([]const u8, "help")),
        .detail = @constCast(@as([]const u8, "help")),
        .source = .workspace_fx,
        .cause = .builtin_collision,
    });
    try expectMessage("command 'deploy' from " ++ path ++ " is shadowed by /home/.fx/prompts/deploy.md", .{
        .path = @constCast(path),
        .name = @constCast(@as([]const u8, "deploy")),
        .detail = @constCast(@as([]const u8, "/home/.fx/prompts/deploy.md")),
        .source = .global_fx,
        .cause = .shadowed,
    });
    try expectMessage("duplicate command 'deploy': " ++ path ++ " ignored", .{
        .path = @constCast(path),
        .name = @constCast(@as([]const u8, "deploy")),
        .source = .workspace_fx,
        .cause = .duplicate_name,
    });
    try expectMessage("command file escapes its root: " ++ path, .{
        .path = @constCast(path),
        .source = .workspace_fx,
        .cause = .escapes_root,
    });
}

test "an argument hint is stripped of control bytes and truncated" {
    const alloc = testing.allocator;
    const sanitized = (try sanitizeArgumentHint(alloc, "  <na\x07me>  ")).?;
    defer alloc.free(sanitized);
    try testing.expectEqualStrings("<name>", sanitized);

    const long = "x" ** (max_argument_hint_bytes + 40);
    const truncated = (try sanitizeArgumentHint(alloc, long)).?;
    defer alloc.free(truncated);
    try testing.expectEqual(max_argument_hint_bytes, truncated.len);

    try testing.expectEqual(@as(?[]u8, null), try sanitizeArgumentHint(alloc, "   "));
}

test "reservedCollision matches builtin tokens and aliases case-insensitively" {
    try testing.expectEqualStrings("help", reservedCollision(test_reserved, "HELP").?);
    try testing.expectEqualStrings("h", reservedCollision(test_reserved, "h").?);
    try testing.expectEqual(@as(?[]const u8, null), reservedCollision(test_reserved, "model-review"));
    // A derived name never carries a slash, so a slashed candidate is not a
    // collision, it is an invalid name rejected earlier.
    try testing.expectEqual(@as(?[]const u8, null), reservedCollision(test_reserved, "/help"));
}

/// Discovers into a runtime the caller owns, mirroring the production sequence
/// where a failed merge leaves the previous registry untouched.
fn runtimeFromTmp(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    workspace_sub_path: []const u8,
) !CommandRuntime {
    var discovery = try loadFromTmp(alloc, tmp, workspace_sub_path);
    return buildRuntime(alloc, test_reserved, discovery) catch |err| {
        discovery.deinit(alloc);
        return err;
    };
}

test "merged registry keeps builtins first and custom entries in root precedence order" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/deploy.md", "Deploy $1 now.");
    try writeTempFile(&tmp, "user/.fx/prompts/notes.md", "Take notes.");

    var runtime = try runtimeFromTmp(alloc, &tmp, "workspace");
    defer runtime.deinit(alloc);

    const registry = runtime.registry(test_reserved);
    try testing.expectEqual(test_reserved.commands.len + 2, registry.commands.len);
    for (test_reserved.commands, registry.commands[0..test_reserved.commands.len]) |expected, actual| {
        try testing.expectEqualStrings(expected.command, actual.command);
        try testing.expectEqual(expected.kind, actual.kind);
    }
    try testing.expectEqualStrings("/deploy", registry.commands[test_reserved.commands.len].command);
    try testing.expectEqualStrings("/notes", registry.commands[test_reserved.commands.len + 1].command);

    // The builtin still wins its own token even though the merged slice is
    // longer, because every matcher returns on its first hit.
    try testing.expectEqual(
        command_specs.SlashKind.help,
        registry.lookup("/help").?.kind,
    );
    try testing.expectEqual(
        command_specs.SlashKind.custom,
        registry.lookup("/deploy").?.kind,
    );
}

test "custom specs fill every field the visibility gates read" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/deploy.md", "Deploy $1 now.");

    var runtime = try runtimeFromTmp(alloc, &tmp, "workspace");
    defer runtime.deinit(alloc);

    const spec = runtime.registry(test_reserved).commands[test_reserved.commands.len];
    try testing.expectEqual(command_specs.SlashKind.custom, spec.kind);
    try testing.expect(spec.requires_prompt_credential);
    try testing.expect(spec.has_args);
    try testing.expect(spec.accepts_payload);
    try testing.expectEqualStrings("/deploy", spec.help_entry.?);
    try testing.expect(spec.completion_description != null);
    try testing.expectEqual(
        command_specs.SlashPresentationCategory.extensions,
        spec.presentation_category.?,
    );
}

test "an explicit description names its source root and a fallback is not doubled" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/deploy.md",
        \\---
        \\description: Ship a service
        \\---
        \\Deploy $1 now.
    );
    try writeTempFile(&tmp, "user/.fx/prompts/notes.md", "Take notes.");

    var runtime = try runtimeFromTmp(alloc, &tmp, "workspace");
    defer runtime.deinit(alloc);

    const commands = runtime.registry(test_reserved).commands[test_reserved.commands.len..];
    const workspace_root = std.fs.path.dirname(runtime.discovery.commands[0].path) orelse return error.TestExpectedPath;
    const expected_explicit = try std.fmt.allocPrint(alloc, "Ship a service ({s})", .{workspace_root});
    defer alloc.free(expected_explicit);
    try testing.expectEqualStrings(expected_explicit, commands[0].completion_description.?);
    // The fallback already names the root, so the merge leaves it alone.
    const user_root = std.fs.path.dirname(runtime.discovery.commands[1].path) orelse return error.TestExpectedPath;
    const expected_fallback = try std.fmt.allocPrint(alloc, "custom command from {s}", .{user_root});
    defer alloc.free(expected_fallback);
    try testing.expectEqualStrings(expected_fallback, commands[1].completion_description.?);
    for (commands) |spec| {
        for (spec.completion_description.?) |byte| {
            try testing.expect(byte >= 0x20 and byte < 0x7f);
        }
    }
}

test "source roots are ASCII-encoded before help and completion rendering" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = "work\x1b-\xc3\xa9";
    try writeTempFile(&tmp, "work\x1b-\xc3\xa9/.fx/prompts/explicit.md",
        \\---
        \\description: Explicit command
        \\---
        \\Prompt.
    );
    try writeTempFile(&tmp, "work\x1b-\xc3\xa9/.fx/prompts/fallback.md", "Prompt.");

    var runtime = try runtimeFromTmp(alloc, &tmp, workspace);
    defer runtime.deinit(alloc);

    const registry = runtime.registry(test_reserved);
    const explicit = registry.lookup("/explicit").?.completion_description.?;
    const fallback = registry.lookup("/fallback").?.completion_description.?;
    for ([_][]const u8{ explicit, fallback }) |description| {
        try testing.expect(std.mem.find(u8, description, "\\x1B") != null);
        try testing.expect(std.mem.find(u8, description, "\\xC3\\xA9") != null);
        try testing.expect(std.mem.findScalar(u8, description, 0x1b) == null);
        for (description) |byte| try testing.expect(byte >= 0x20 and byte < 0x7f);
    }
}

test "a load with no commands serves the builtin registry unchanged" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");

    var runtime = try runtimeFromTmp(alloc, &tmp, "workspace");
    defer runtime.deinit(alloc);

    const registry = runtime.registry(test_reserved);
    try testing.expectEqual(test_reserved.commands.len, registry.commands.len);
    try testing.expectEqual(test_reserved.commands.ptr, registry.commands.ptr);
}

test "rebuilding to an empty load releases the previously merged commands" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "workspace/.fx/prompts/deploy.md", "Deploy $1 now.");
    var runtime = try runtimeFromTmp(alloc, &tmp, "workspace");
    defer runtime.deinit(alloc);
    try testing.expect(runtime.registry(test_reserved).lookup("/deploy") != null);

    try tmp.dir.deleteFile(io_mod.getIo(), "workspace/.fx/prompts/deploy.md");
    var rebuilt = try runtimeFromTmp(alloc, &tmp, "workspace");
    runtime.deinit(alloc);
    runtime = rebuilt;
    rebuilt = .{};

    try testing.expectEqual(@as(?*const command_specs.SlashSpec, null), runtime.registry(test_reserved).lookup("/deploy"));
}

test "a merge that runs out of memory releases every partial allocation" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "workspace/.fx/prompts/deploy.md",
        "---\ndescription: Deploy the app\n---\nDeploy $1 now.",
    );
    try writeTempFile(&tmp, "user/.fx/prompts/notes.md", "Take notes.");

    // Every allocation the merge makes is failed in turn. The token and
    // description rows are prefix views while they fill, so an unwind that
    // mistook the prefix for the whole row would leak or free the backing
    // array with the wrong length, and the testing allocator would report it.
    // The ceiling only has to exceed the real allocation count, which shifts
    // with the formatting internals `allocPrint` uses.
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var discovery = try loadFromTmp(alloc, &tmp, "workspace");
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        var runtime = buildRuntime(failing.allocator(), test_reserved, discovery) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            discovery.deinit(alloc);
            continue;
        };
        // The budget covered the whole merge, so no later index can fail.
        defer runtime.deinit(failing.allocator());
        try testing.expectEqual(test_reserved.commands.len + 2, runtime.registry(test_reserved).commands.len);
        break;
    } else return error.MergeNeverSucceeded;
}
