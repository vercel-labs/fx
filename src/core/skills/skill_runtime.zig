const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const list_window = @import("../shared/list_window.zig");
const model_context_encoding = @import("../shared/model_context_encoding.zig");
const pathing = @import("../workspace/pathing.zig");
const skill_contract = @import("skill_contract.zig");
const context_limits = @import("../config/context_limits.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");

const Allocator = std.mem.Allocator;
const catalog_notice_name_count: usize = 8;
const diagnostic_notice_item_count: usize = 4;
const diagnostic_path_max_bytes: usize = 4 * 1024;

pub const skill_menu_max_visible_rows: u16 = 4;

pub const Skill = skill_contract.Skill;

pub const BoundedPromptSection = struct {
    text: []u8,
    notice: ?[]u8 = null,
    diagnostic_notice: ?[]u8 = null,
    locations: skill_contract.Locations = .{},

    pub fn deinit(self: *BoundedPromptSection, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.notice) |notice| alloc.free(notice);
        if (self.diagnostic_notice) |notice| alloc.free(notice);
        if (self.locations.roots.len > 0) alloc.free(self.locations.roots);
        self.* = undefined;
    }
};

pub const SkillDiagnosticCause = skill_contract.SkillDiagnosticCause;
pub const SkillDiagnosticScope = skill_contract.SkillDiagnosticScope;
pub const SkillDiagnostic = skill_contract.SkillDiagnostic;

/// Owns the validated candidate directory and metadata file handles.
pub const OpenedSkillCandidate = struct {
    dir: std.Io.Dir,
    skill_file: std.Io.File,

    pub fn deinit(self: *OpenedSkillCandidate) void {
        self.skill_file.close(io_mod.getIo());
        self.dir.close(io_mod.getIo());
        self.* = undefined;
    }

    pub fn skillFile(self: *OpenedSkillCandidate) *std.Io.File {
        return &self.skill_file;
    }

    pub fn openResource(self: *OpenedSkillCandidate, resource: []const u8) !std.Io.File {
        const trimmed = std.mem.trim(u8, resource, " \t\r\n");
        if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return error.InvalidSkillResourcePath;
        var segments = std.mem.tokenizeAny(u8, trimmed, "/\\");
        var segment = segments.next() orelse return error.InvalidSkillResourcePath;
        if (invalidResourceSegment(segment)) return error.InvalidSkillResourcePath;

        const child_segment = segments.next() orelse {
            return self.dir.openFile(io_mod.getIo(), segment, .{
                .allow_directory = false,
                .follow_symlinks = false,
            });
        };
        if (invalidResourceSegment(child_segment)) return error.InvalidSkillResourcePath;

        var current_dir = try self.dir.openDir(io_mod.getIo(), segment, .{
            .follow_symlinks = false,
        });
        defer current_dir.close(io_mod.getIo());
        segment = child_segment;

        while (segments.next()) |next_segment| {
            if (invalidResourceSegment(next_segment)) return error.InvalidSkillResourcePath;
            const next_dir = try current_dir.openDir(io_mod.getIo(), segment, .{
                .follow_symlinks = false,
            });
            current_dir.close(io_mod.getIo());
            current_dir = next_dir;
            segment = next_segment;
        }
        return current_dir.openFile(io_mod.getIo(), segment, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
    }
};

pub const SkillCandidateOpenResult = union(enum) {
    current: OpenedSkillCandidate,
    missing,
    name_mismatch,
    skipped: SkillDiagnosticCause,
};

pub fn resourceIsSkillFile(resource: []const u8) bool {
    const trimmed = std.mem.trim(u8, resource, " \t\r\n");
    if (trimmed.len == 0 or std.fs.path.isAbsolute(trimmed)) return false;
    var segments = std.mem.tokenizeAny(u8, trimmed, "/\\");
    const segment = segments.next() orelse return false;
    return std.mem.eql(u8, segment, "SKILL.md") and segments.next() == null;
}

fn invalidResourceSegment(segment: []const u8) bool {
    return std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..");
}

pub fn writeDiagnosticSummary(alloc: Allocator, writer: *std.Io.Writer, diagnostics: []const SkillDiagnostic) !void {
    if (diagnostics.len == 0) return;
    try writer.writeAll("skill discovery warning: ");
    const shown_count = @min(diagnostics.len, diagnostic_notice_item_count);
    for (diagnostics[0..shown_count], 0..) |diagnostic, index| {
        if (index > 0) try writer.writeAll("; ");
        switch (diagnostic.scope) {
            .root => {
                try writer.writeAll("inventory incomplete because root \"");
                try writeBoundedDiagnosticPath(alloc, writer, diagnostic.path);
                try writer.writeAll("\" could not be read, so an unknown number of skills may be missing; fix access to the root and reload skills");
            },
            .candidate => {
                try writer.writeAll("candidate \"");
                try writeBoundedDiagnosticPath(alloc, writer, diagnostic.path);
                try writer.writeAll("\" was skipped because ");
                switch (diagnostic.cause) {
                    .invalid_metadata => |cause| try writer.print(
                        "its metadata is invalid ({s}); use one safe name and an optional inline description or a >, >-, or | block, then reload skills",
                        .{@tagName(cause)},
                    ),
                    .linked_candidate_unavailable => try writer.writeAll("its linked skill directory could not be resolved to an authorized readable directory; repair or remove the link, or authorize its external location, then reload skills"),
                    .unreadable => try writer.writeAll("SKILL.md is unreadable or not a regular file; fix the file type or access, then reload skills"),
                    .oversized => try writer.print(
                        "its frontmatter exceeds the supported {d}-byte metadata header; shorten the name/description header, then reload skills",
                        .{skill_contract.max_frontmatter_bytes},
                    ),
                }
            },
        }
    }
    if (diagnostics.len > shown_count) {
        try writer.print("; {d} additional diagnostic{s} omitted", .{
            diagnostics.len - shown_count,
            if (diagnostics.len - shown_count == 1) "" else "s",
        });
    }
    if (debug_trace.activeLogPath()) |trace_path| {
        try writer.print("; see \"{f}\" for details", .{std.zig.fmtString(trace_path)});
    } else {
        try writer.writeAll("; relaunch with FX_TRACE=1 to write a trace log");
    }
}

fn writeBoundedDiagnosticPath(alloc: Allocator, writer: *std.Io.Writer, path: []const u8) !void {
    const observed = try writeBoundedEncodedScalar(
        alloc,
        writer,
        path,
        diagnostic_path_max_bytes,
    );
    if (observed > diagnostic_path_max_bytes) try writer.writeAll("...");
}

pub fn traceDiagnostics(surface: []const u8, diagnostics: []const SkillDiagnostic) void {
    for (diagnostics) |diagnostic| {
        const path = std.zig.fmtString(diagnostic.path);
        switch (diagnostic.cause) {
            .invalid_metadata => |cause| debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=invalid_metadata cause={s} path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), @tagName(cause), path, diagnostic.path.len },
            ),
            .linked_candidate_unavailable => debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=io cause=linked_candidate_unavailable path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), path, diagnostic.path.len },
            ),
            .unreadable => debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=io cause=unreadable path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), path, diagnostic.path.len },
            ),
            .oversized => debug_trace.logf(
                "skills",
                "discovery_diagnostic surface={s} source={s} scope={s} kind=io cause=oversized path=\"{f}\" path_bytes={d}",
                .{ surface, @tagName(diagnostic.source), @tagName(diagnostic.scope), path, diagnostic.path.len },
            ),
        }
    }
}

pub const SkillDiscovery = struct {
    skills: []Skill = &.{},
    diagnostics: []SkillDiagnostic = &.{},

    pub fn deinit(self: *SkillDiscovery, alloc: Allocator) void {
        freeSkills(alloc, self.skills);
        freeSkillDiagnostics(alloc, self.diagnostics);
        self.* = .{};
    }
};

pub const SkillResolution = union(enum) {
    found: *const Skill,
    not_found,
    ambiguous_name,
    name_location_mismatch,
};

pub const SkillSummaryStyles = struct {
    source_label_style: []const u8 = "",
    reset_style: []const u8 = "",
};

pub const SkillSource = skill_contract.SkillSource;

pub const SkillMenuSourceFilter = enum {
    all,
    fx,
    workspace,
    opencode,
    codex,
    claude,
    agents,
    claw,
};

pub const skill_menu_source_filters = [_]SkillMenuSourceFilter{
    .all,
    .fx,
    .workspace,
    .claude,
    .codex,
    .agents,
    .opencode,
    .claw,
};

pub const SkillMenuOrigin = enum {
    command,
    dollar,
    slash,
    paste,

    pub fn isMention(self: SkillMenuOrigin) bool {
        return switch (self) {
            .dollar, .paste => true,
            .command, .slash => false,
        };
    }
};

test "skill menu origins classify mention surfaces exhaustively" {
    try std.testing.expect(SkillMenuOrigin.dollar.isMention());
    try std.testing.expect(SkillMenuOrigin.paste.isMention());
    try std.testing.expect(!SkillMenuOrigin.command.isMention());
    try std.testing.expect(!SkillMenuOrigin.slash.isMention());
}

pub const SkillMenuTarget = struct {
    start: usize = 0,
    end: usize = 0,
};

const SkillRoot = struct {
    path: []const u8,
    source: SkillSource,
    read_authority: ?[]const u8,
};

const SkillEntry = struct {
    name: []u8,
    linked: bool,
};

fn freeSkillEntries(alloc: Allocator, entries: *std.ArrayList(SkillEntry)) void {
    for (entries.items) |entry| alloc.free(entry.name);
    entries.deinit(alloc);
}

fn collectSkillEntries(
    alloc: Allocator,
    dir: *std.Io.Dir,
    allow_linked: bool,
) !std.ArrayList(SkillEntry) {
    var entries: std.ArrayList(SkillEntry) = .empty;
    errdefer freeSkillEntries(alloc, &entries);
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        const linked = entry.kind == .sym_link;
        if (entry.kind != .directory and !(linked and allow_linked)) continue;
        const name = try alloc.dupe(u8, entry.name);
        entries.append(alloc, .{ .name = name, .linked = linked }) catch |err| {
            alloc.free(name);
            return err;
        };
    }
    sort_utils.sort(SkillEntry, entries.items, {}, struct {
        fn lessThan(_: void, left: SkillEntry, right: SkillEntry) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);
    return entries;
}

/// Deduplicates filesystem aliases without collapsing distinct skills that
/// share metadata names. Ordered discovery makes the first logical root the
/// stable source and display path for each canonical candidate directory.
const CanonicalSkillPaths = struct {
    paths: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *CanonicalSkillPaths, alloc: Allocator) void {
        var keys = self.paths.keyIterator();
        while (keys.next()) |path| alloc.free(@constCast(path.*));
        self.paths.deinit(alloc);
        self.* = .{};
    }

    fn remember(self: *CanonicalSkillPaths, alloc: Allocator, logical_path: []const u8) !bool {
        const canonical_path = io_mod.realpathAlloc(alloc, logical_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return true;
        };
        if (self.paths.contains(canonical_path)) {
            alloc.free(canonical_path);
            return false;
        }
        errdefer alloc.free(canonical_path);
        try self.paths.put(alloc, canonical_path, {});
        return true;
    }
};

pub fn loadVisibleSkills(
    alloc: Allocator,
    workspace_root: ?[]const u8,
    home: ?[]const u8,
    skills_dir: []const u8,
    root_policy: skill_contract.RootPolicy,
) !SkillDiscovery {
    var skills: std.ArrayList(Skill) = .empty;
    errdefer {
        for (skills.items) |skill| freeSkill(alloc, skill);
        skills.deinit(alloc);
    }
    var diagnostics: std.ArrayList(SkillDiagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diagnostic| alloc.free(diagnostic.path);
        diagnostics.deinit(alloc);
    }
    var canonical_skill_paths: CanonicalSkillPaths = .{};
    defer canonical_skill_paths.deinit(alloc);

    var roots: std.ArrayList(SkillRoot) = .empty;
    defer {
        for (roots.items) |root| alloc.free(root.path);
        roots.deinit(alloc);
    }

    try appendConfiguredSkillRoots(
        alloc,
        &roots,
        workspace_root,
        home,
        skills_dir,
        root_policy,
    );

    for (roots.items) |root| {
        try appendSkillsFromDir(alloc, &skills, &diagnostics, &canonical_skill_paths, root);
    }

    const owned_skills = try skills.toOwnedSlice(alloc);
    errdefer freeSkills(alloc, owned_skills);
    const owned_diagnostics = try diagnostics.toOwnedSlice(alloc);
    return .{
        .skills = owned_skills,
        .diagnostics = owned_diagnostics,
    };
}

fn appendConfiguredSkillRoots(
    alloc: Allocator,
    roots: *std.ArrayList(SkillRoot),
    workspace_root: ?[]const u8,
    home: ?[]const u8,
    skills_dir: []const u8,
    root_policy: skill_contract.RootPolicy,
) !void {
    if (workspace_root) |root| {
        try appendWorkspaceRoots(
            alloc,
            roots,
            root,
            home,
            root_policy.workspace_roots,
        );
    }
    if (root_policy.managed_root_source) |source| {
        try appendDupeRoot(alloc, roots, source, skills_dir);
    }
    if (home) |home_root| {
        for (root_policy.global_roots) |spec| {
            try appendSpecRoot(alloc, roots, home_root, spec);
        }
    }
}

fn collectRootFingerprints(
    alloc: Allocator,
    workspace_root: ?[]const u8,
    home: ?[]const u8,
    skills_dir: []const u8,
    root_policy: skill_contract.RootPolicy,
) ![]RootFingerprint {
    var roots: std.ArrayList(SkillRoot) = .empty;
    defer {
        for (roots.items) |root| alloc.free(root.path);
        roots.deinit(alloc);
    }
    try appendConfiguredSkillRoots(
        alloc,
        &roots,
        workspace_root,
        home,
        skills_dir,
        root_policy,
    );
    const fingerprints = try alloc.alloc(RootFingerprint, roots.items.len);
    var filled: usize = 0;
    errdefer {
        for (fingerprints[0..filled]) |*root| root.deinit(alloc);
        if (fingerprints.len > 0) alloc.free(fingerprints);
    }
    while (filled < roots.items.len) : (filled += 1) {
        const root = roots.items[filled];
        const path = try alloc.dupe(u8, root.path);
        errdefer alloc.free(path);
        const stat = std.Io.Dir.cwd().statFile(
            io_mod.getIo(),
            root.path,
            .{ .follow_symlinks = false },
        ) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) {
                fingerprints[filled] = .{ .path = path, .exists = false };
                continue;
            }
            return err;
        };
        const candidate_digest = if (stat.kind == .directory)
            try candidateDirectoryDigest(alloc, root)
        else
            [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;
        fingerprints[filled] = .{
            .path = path,
            .exists = true,
            .inode = stat.inode,
            .mtime = stat.mtime,
            .candidate_digest = candidate_digest,
        };
    }
    return fingerprints;
}

fn candidateDirectoryDigest(
    alloc: Allocator,
    root: SkillRoot,
) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var dir = try openSkillRoot(alloc, root, .{ .iterate = true });
    defer dir.close(io_mod.getIo());
    var entries = try collectSkillEntries(alloc, &dir, root.read_authority != null);
    defer freeSkillEntries(alloc, &entries);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries.items) |entry| {
        hash.update(entry.name);
        hash.update(if (entry.linked) "\x01" else "\x00");
        const stat = if (entry.linked) linked: {
            const candidate_path = try std.fs.path.join(alloc, &.{ root.path, entry.name });
            defer alloc.free(candidate_path);
            var candidate_dir = openContainedDir(
                alloc,
                candidate_path,
                root.read_authority.?,
                .{},
            ) catch {
                hash.update("unavailable");
                continue;
            };
            defer candidate_dir.close(io_mod.getIo());
            break :linked candidate_dir.stat(io_mod.getIo()) catch {
                hash.update("unavailable");
                continue;
            };
        } else dir.statFile(
            io_mod.getIo(),
            entry.name,
            .{ .follow_symlinks = false },
        ) catch {
            hash.update("unavailable");
            continue;
        };
        hash.update(std.mem.asBytes(&stat.inode));
        hash.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    }
    return hash.finalResult();
}

fn appendWorkspaceRoots(
    alloc: Allocator,
    roots: *std.ArrayList(SkillRoot),
    workspace_root: []const u8,
    home: ?[]const u8,
    root_specs: []const skill_contract.RootSpec,
) !void {
    var current: ?[]const u8 = workspace_root;
    while (current) |dir| : (current = std.fs.path.dirname(dir)) {
        if (home) |home_root| {
            if (std.mem.eql(u8, dir, home_root)) break;
        }

        for (root_specs) |spec| {
            try appendSpecRoot(alloc, roots, dir, spec);
        }
    }
}

fn appendSpecRoot(alloc: Allocator, roots: *std.ArrayList(SkillRoot), base: []const u8, spec: skill_contract.RootSpec) !void {
    try appendOwnedRoot(alloc, roots, try std.fs.path.join(alloc, &.{ base, spec.path }), spec.source, base);
}

fn appendDupeRoot(alloc: Allocator, roots: *std.ArrayList(SkillRoot), source: SkillSource, path: []const u8) !void {
    try appendOwnedRoot(alloc, roots, try alloc.dupe(u8, path), source, null);
}

fn appendOwnedRoot(
    alloc: Allocator,
    roots: *std.ArrayList(SkillRoot),
    path: []u8,
    source: SkillSource,
    read_authority: ?[]const u8,
) !void {
    if (containsRootPath(roots.items, path)) {
        alloc.free(path);
        return;
    }

    roots.append(alloc, .{
        .path = path,
        .source = source,
        .read_authority = read_authority,
    }) catch |err| {
        alloc.free(path);
        return err;
    };
}

fn openContainedDir(
    alloc: Allocator,
    logical_path: []const u8,
    read_authority: []const u8,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    const canonical_path = try io_mod.realpathAlloc(alloc, logical_path);
    defer alloc.free(canonical_path);
    if (!try canonicalPathHasReadAuthority(alloc, read_authority, canonical_path)) {
        return error.PathOutsideReadAuthority;
    }
    return io_mod.openDirAbsoluteNoFollow(canonical_path, options);
}

fn pathInsideReadAuthorities(
    read_authority: []const u8,
    extra_authorities: []const []const u8,
    canonical_path: []const u8,
) bool {
    if (pathing.pathInside(read_authority, canonical_path)) return true;
    for (extra_authorities) |authority| {
        if (pathing.pathInside(authority, canonical_path)) return true;
    }
    return false;
}

fn canonicalPathHasReadAuthority(
    alloc: Allocator,
    read_authority: []const u8,
    canonical_path: []const u8,
) error{OutOfMemory}!bool {
    if (pathInsideReadAuthorities(read_authority, &.{}, canonical_path)) return true;
    const extra_authorities = try externalSymlinkAuthorities(alloc);
    defer freeExternalAuthorities(alloc, extra_authorities);
    return pathInsideReadAuthorities(read_authority, extra_authorities, canonical_path);
}

/// Parses FX_SKILL_SYMLINK_AUTHORITIES (colon-separated absolute paths) into
/// owned duplicates. Returns an empty slice when the variable is unset or
/// contains no valid absolute paths. Relative entries and entries containing
/// `..` components are silently skipped. The caller must free each entry and
/// the slice itself via `freeExternalAuthorities`.
fn externalSymlinkAuthorities(alloc: Allocator) ![][]const u8 {
    const raw = io_mod.getenv("FX_SKILL_SYMLINK_AUTHORITIES") orelse return &.{};
    if (raw.len == 0) return &.{};

    var authorities: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (authorities.items) |item| alloc.free(item);
        authorities.deinit(alloc);
    }

    var it = std.mem.tokenizeScalar(u8, raw, ':');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;
        if (!std.fs.path.isAbsolute(trimmed)) continue;
        if (pathContainsDotDot(trimmed)) continue;
        const owned = try alloc.dupe(u8, trimmed);
        errdefer alloc.free(owned);
        authorities.append(alloc, owned) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
    return try authorities.toOwnedSlice(alloc);
}

fn pathContainsDotDot(path: []const u8) bool {
    var it = std.fs.path.componentIterator(path);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return true;
    }
    return false;
}

fn freeExternalAuthorities(alloc: Allocator, authorities: [][]const u8) void {
    for (authorities) |authority| alloc.free(authority);
    if (authorities.len > 0) alloc.free(authorities);
}

fn containsRootPath(roots: []const SkillRoot, path: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, root.path, path)) return true;
    }
    return false;
}

fn appendSkillsFromDir(
    alloc: Allocator,
    skills: *std.ArrayList(Skill),
    diagnostics: ?*std.ArrayList(SkillDiagnostic),
    canonical_skill_paths: *CanonicalSkillPaths,
    root: SkillRoot,
) !void {
    var dir = openSkillRoot(alloc, root, .{ .iterate = true }) catch |err| {
        if ((err == error.FileNotFound or err == error.NotDir) and rootPathIsMissing(root.path)) return;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, root.path, root.source, .root, .unreadable);
        return;
    };
    defer dir.close(io_mod.getIo());

    var entries = collectSkillEntries(alloc, &dir, root.read_authority != null) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, root.path, root.source, .root, .unreadable);
        return;
    };
    defer freeSkillEntries(alloc, &entries);

    for (entries.items) |entry| {
        try appendSkillCandidate(alloc, skills, diagnostics, canonical_skill_paths, root, &dir, entry.name, entry.linked);
    }
}

fn openSkillRoot(
    alloc: Allocator,
    root: SkillRoot,
    options: std.Io.Dir.OpenOptions,
) !std.Io.Dir {
    return if (root.read_authority) |authority|
        openContainedDir(alloc, root.path, authority, options)
    else
        io_mod.openDirAbsoluteNoFollow(root.path, options);
}

fn rootPathIsMissing(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var components = std.fs.path.componentIterator(path);
    const root = components.root() orelse return false;
    var component = components.next() orelse return false;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{}) catch return false;
    defer dir.close(io_mod.getIo());

    while (true) {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) return false;
        const stat = dir.statFile(io_mod.getIo(), component.name, .{ .follow_symlinks = false }) catch |err| {
            return err == error.FileNotFound;
        };
        if (stat.kind != .directory) return false;
        const next_component = components.next() orelse return false;
        const next_dir = dir.openDir(io_mod.getIo(), component.name, .{ .follow_symlinks = false }) catch return false;
        dir.close(io_mod.getIo());
        dir = next_dir;
        component = next_component;
    }
}

const PrimarySkillFileOpenResult = union(enum) {
    opened: std.Io.File,
    missing,
    rejected,
};

const PrimarySkillFileOpenHook = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
};

const PrimarySkillFileOpenOptions = struct {
    after_preflight: ?PrimarySkillFileOpenHook = null,
    after_open: ?PrimarySkillFileOpenHook = null,
};

fn openPrimarySkillFile(
    alloc: Allocator,
    candidate_dir: *std.Io.Dir,
    read_authority: ?[]const u8,
) error{OutOfMemory}!PrimarySkillFileOpenResult {
    return openPrimarySkillFileWithOptions(alloc, candidate_dir, read_authority, .{});
}

fn openPrimarySkillFileWithOptions(
    alloc: Allocator,
    candidate_dir: *std.Io.Dir,
    read_authority: ?[]const u8,
    options: PrimarySkillFileOpenOptions,
) error{OutOfMemory}!PrimarySkillFileOpenResult {
    const path_stat = candidate_dir.statFile(io_mod.getIo(), "SKILL.md", .{ .follow_symlinks = false }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return if (err == error.FileNotFound) .missing else .rejected;
    };

    switch (path_stat.kind) {
        .file => {
            const file = io_mod.openExistingReadOnlyRegularFile(candidate_dir.*, "SKILL.md", .no_follow) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return if (err == error.FileNotFound) .missing else .rejected;
            };
            return .{ .opened = file };
        },
        .sym_link => {
            const authority = read_authority orelse return .rejected;

            const preflight_path = io_mod.dirRealpathAlloc(alloc, candidate_dir.*, "SKILL.md") catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .rejected;
            };
            defer alloc.free(preflight_path);
            if (!try canonicalPathHasReadAuthority(alloc, authority, preflight_path)) return .rejected;
            const preflight_stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), preflight_path, .{ .follow_symlinks = false }) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .rejected;
            };
            if (preflight_stat.kind != .file) return .rejected;
            if (options.after_preflight) |hook| hook.run(hook.ctx);

            var file = io_mod.openExistingReadOnlyRegularFile(candidate_dir.*, "SKILL.md", .follow) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .rejected;
            };
            errdefer file.close(io_mod.getIo());
            if (options.after_open) |hook| hook.run(hook.ctx);
            const opened_path = io_mod.openedFilePathAlloc(alloc, file) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                file.close(io_mod.getIo());
                return .rejected;
            };
            defer alloc.free(opened_path);
            if (!try canonicalPathHasReadAuthority(alloc, authority, opened_path)) {
                file.close(io_mod.getIo());
                return .rejected;
            }
            return .{ .opened = file };
        },
        else => return .rejected,
    }
}

fn appendSkillCandidate(
    alloc: Allocator,
    skills: *std.ArrayList(Skill),
    diagnostics: ?*std.ArrayList(SkillDiagnostic),
    canonical_skill_paths: *CanonicalSkillPaths,
    root: SkillRoot,
    root_dir: *std.Io.Dir,
    entry_name: []const u8,
    linked: bool,
) !void {
    const candidate_path = try std.fs.path.join(alloc, &.{ root.path, entry_name });
    defer alloc.free(candidate_path);

    var candidate_dir = if (linked) linked_candidate: {
        const read_authority = root.read_authority orelse return;
        break :linked_candidate openContainedDir(alloc, candidate_path, read_authority, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .linked_candidate_unavailable);
            return;
        };
    } else root_dir.openDir(io_mod.getIo(), entry_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .unreadable);
        return;
    };
    defer candidate_dir.close(io_mod.getIo());

    var file = switch (try openPrimarySkillFile(alloc, &candidate_dir, root.read_authority)) {
        .opened => |opened| opened,
        .missing => return,
        .rejected => {
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .unreadable);
            return;
        },
    };
    defer file.close(io_mod.getIo());
    const file_stat = file.stat(io_mod.getIo()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (diagnostics) |items| {
            try appendSkillDiagnostic(
                alloc,
                items,
                candidate_path,
                root.source,
                .candidate,
                .unreadable,
            );
        }
        return;
    };

    if (!try canonical_skill_paths.remember(alloc, candidate_path)) return;

    const inspection = try inspectSkillCandidateFile(alloc, &file, entry_name);
    const candidate = switch (inspection) {
        .valid => |value| value,
        .invalid => |cause| {
            if (diagnostics) |items| {
                try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .{ .invalid_metadata = cause });
            }
            return;
        },
        .unreadable => {
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .unreadable);
            return;
        },
        .oversized => {
            if (diagnostics) |items| try appendSkillDiagnostic(alloc, items, candidate_path, root.source, .candidate, .oversized);
            return;
        },
    };
    defer candidate.deinit(alloc);

    const skill_name = try alloc.dupe(u8, candidate.metadata.name);
    errdefer alloc.free(skill_name);
    const description = try alloc.alloc(u8, candidate.metadata.description_len());
    errdefer alloc.free(description);
    candidate.metadata.write_description(description);
    const path = try alloc.dupe(u8, candidate_path);
    errdefer alloc.free(path);
    const read_authority = if (root.read_authority) |authority|
        try alloc.dupe(u8, authority)
    else
        null;
    errdefer if (read_authority) |authority| alloc.free(authority);

    try skills.append(alloc, .{
        .name = skill_name,
        .description = description,
        .path = path,
        .source = root.source,
        .read_authority = read_authority,
        .metadata_inode = file_stat.inode,
        .metadata_size = file_stat.size,
        .metadata_mtime = file_stat.mtime,
    });
}

const CurrentSkillMetadata = struct {
    content: []u8,
    metadata: skill_contract.SkillMetadata,

    fn deinit(self: CurrentSkillMetadata, alloc: Allocator) void {
        alloc.free(self.content);
    }
};

const SkillCandidateInspection = union(enum) {
    valid: CurrentSkillMetadata,
    invalid: skill_contract.InvalidMetadataCause,
    unreadable,
    oversized,
};

fn inspectSkillCandidateFile(
    alloc: Allocator,
    file: *std.Io.File,
    fallback_name: []const u8,
) error{OutOfMemory}!SkillCandidateInspection {
    const stat = file.stat(io_mod.getIo()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .unreadable;
    };
    if (stat.kind != .file) return .unreadable;
    const file_size = std.math.cast(usize, stat.size) orelse return .oversized;
    const content = skill_contract.readMetadataPrefix(alloc, file, file_size) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return if (err == error.StreamTooLong) .oversized else .unreadable;
    };
    errdefer alloc.free(content);

    const parsed = skill_contract.parseSkillFile(content);
    const metadata = switch (skill_contract.resolveMetadata(parsed, fallback_name)) {
        .valid => |value| value,
        .invalid => |cause| {
            alloc.free(content);
            return .{ .invalid = cause };
        },
    };
    return .{ .valid = .{ .content = content, .metadata = metadata } };
}

/// Opens and validates the exact advertised candidate without rescanning skill roots.
/// The caller must deinitialize a `.current` candidate.
pub fn openValidatedSkillCandidate(alloc: Allocator, skill: Skill) error{OutOfMemory}!SkillCandidateOpenResult {
    const candidate_name = std.fs.path.basename(skill.path);
    if (candidate_name.len == 0) return .{ .skipped = .unreadable };

    var candidate_dir = if (skill.read_authority) |read_authority| authorized: {
        break :authorized openContainedDir(alloc, skill.path, read_authority, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (err == error.FileNotFound) .missing else .{ .skipped = .unreadable };
        };
    } else strict: {
        const parent_path = std.fs.path.dirname(skill.path) orelse return .{ .skipped = .unreadable };
        var parent_dir = io_mod.openDirAbsoluteNoFollow(parent_path, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (err == error.FileNotFound) .missing else .{ .skipped = .unreadable };
        };
        defer parent_dir.close(io_mod.getIo());
        break :strict parent_dir.openDir(io_mod.getIo(), candidate_name, .{ .follow_symlinks = false }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return if (err == error.FileNotFound) .missing else .{ .skipped = .unreadable };
        };
    };
    const primary_file = openPrimarySkillFile(alloc, &candidate_dir, skill.read_authority) catch |err| {
        candidate_dir.close(io_mod.getIo());
        return err;
    };
    var file = switch (primary_file) {
        .opened => |opened| opened,
        .missing => {
            candidate_dir.close(io_mod.getIo());
            return .missing;
        },
        .rejected => {
            candidate_dir.close(io_mod.getIo());
            return .{ .skipped = .unreadable };
        },
    };
    var keep_open = false;
    defer if (!keep_open) {
        file.close(io_mod.getIo());
        candidate_dir.close(io_mod.getIo());
    };

    const inspection = try inspectSkillCandidateFile(alloc, &file, candidate_name);
    return switch (inspection) {
        .valid => |candidate| blk: {
            defer candidate.deinit(alloc);
            if (!std.mem.eql(u8, candidate.metadata.name, skill.name)) break :blk .name_mismatch;
            keep_open = true;
            break :blk .{ .current = .{
                .dir = candidate_dir,
                .skill_file = file,
            } };
        },
        .invalid => |cause| .{ .skipped = .{ .invalid_metadata = cause } },
        .unreadable => .{ .skipped = .unreadable },
        .oversized => .{ .skipped = .oversized },
    };
}

fn appendSkillDiagnostic(
    alloc: Allocator,
    diagnostics: *std.ArrayList(SkillDiagnostic),
    path: []const u8,
    source: SkillSource,
    scope: SkillDiagnosticScope,
    cause: SkillDiagnosticCause,
) !void {
    const owned_path = try alloc.dupe(u8, path);
    diagnostics.append(alloc, .{
        .path = owned_path,
        .source = source,
        .scope = scope,
        .cause = cause,
    }) catch |err| {
        alloc.free(owned_path);
        return err;
    };
}

pub fn findSkillByName(skills: []const Skill, name: []const u8) ?Skill {
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

pub fn resolveSkill(skills: []const Skill, name: []const u8, location: ?[]const u8) SkillResolution {
    if (location) |exact_location| {
        for (skills, 0..) |skill, index| {
            if (!std.mem.eql(u8, skill.path, exact_location)) continue;
            if (!std.mem.eql(u8, skill.name, name)) return .name_location_mismatch;
            return .{ .found = &skills[index] };
        }
        return .not_found;
    }

    var found_index: ?usize = null;
    for (skills, 0..) |skill, index| {
        if (!std.mem.eql(u8, skill.name, name)) continue;
        if (found_index != null) return .ambiguous_name;
        found_index = index;
    }
    return if (found_index) |index| .{ .found = &skills[index] } else .not_found;
}

pub fn isManagedInstallSkill(skill: Skill) bool {
    return skill.source == .global_fx;
}

pub fn skillGroupLabel(source: SkillSource) []const u8 {
    return switch (source) {
        .global_fx => "Managed installs",
        .workspace_fx => "Workspace skills",
        .workspace_shared => "Workspace skills",
        .workspace_opencode,
        .workspace_codex,
        .workspace_claude,
        .workspace_agents,
        .workspace_claw,
        .global_opencode,
        .global_codex,
        .global_claude,
        .global_agents,
        .global_claw,
        => "Compatibility roots",
    };
}

pub fn skillGroupRank(source: SkillSource) usize {
    return switch (source) {
        .global_fx => 0,
        .workspace_fx => 1,
        .workspace_shared => 1,
        .workspace_opencode,
        .workspace_codex,
        .workspace_claude,
        .workspace_agents,
        .workspace_claw,
        .global_opencode,
        .global_codex,
        .global_claude,
        .global_agents,
        .global_claw,
        => 2,
    };
}

const skill_group_count: usize = 3;

pub fn skillSourceLabel(source: SkillSource) []const u8 {
    return switch (source) {
        .workspace_fx => "workspace .fx/skills",
        .workspace_shared => "workspace skills/",
        .workspace_opencode => "workspace .opencode/skills",
        .workspace_codex => "workspace .codex/skills",
        .workspace_claude => "workspace .claude/skills",
        .workspace_agents => "workspace .agents/skills",
        .workspace_claw => "workspace .claw/skills",
        .global_fx => "global ~/.fx/skills",
        .global_opencode => "global ~/.config/opencode/skills",
        .global_codex => "global ~/.codex/skills",
        .global_claude => "global ~/.claude/skills",
        .global_agents => "global ~/.agents/skills",
        .global_claw => "global ~/.claw/skills",
    };
}

pub fn skillSourceShortLabel(source: SkillSource) []const u8 {
    return switch (source) {
        .workspace_fx => "workspace .fx",
        .workspace_shared => "workspace skills/",
        .workspace_opencode => "workspace .opencode",
        .workspace_codex => "workspace .codex",
        .workspace_claude => "workspace .claude",
        .workspace_agents => "workspace .agents",
        .workspace_claw => "workspace .claw",
        .global_fx => "global .fx",
        .global_opencode => "global opencode",
        .global_codex => "global .codex",
        .global_claude => "global .claude",
        .global_agents => "global .agents",
        .global_claw => "global .claw",
    };
}

pub fn skillMenuFilterLabel(filter: SkillMenuSourceFilter) []const u8 {
    return switch (filter) {
        .all => "All",
        .fx => "fx",
        .workspace => "Workspace",
        .opencode => "OpenCode",
        .codex => "Codex",
        .claude => "Claude",
        .agents => "Agents",
        .claw => "Claw",
    };
}

pub fn skillMenuFilterForSource(source: SkillSource) SkillMenuSourceFilter {
    return switch (source) {
        .global_fx => .fx,
        .workspace_fx => .fx,
        .workspace_shared => .workspace,
        .workspace_opencode, .global_opencode => .opencode,
        .workspace_codex, .global_codex => .codex,
        .workspace_claude, .global_claude => .claude,
        .workspace_agents, .global_agents => .agents,
        .workspace_claw, .global_claw => .claw,
    };
}

pub fn skillSourceMatchesFilter(source: SkillSource, filter: SkillMenuSourceFilter) bool {
    return filter == .all or skillMenuFilterForSource(source) == filter;
}

pub fn skill_matches_menu_query(skill: Skill, query: []const u8) bool {
    return skillMatchRank(skill, query) != null;
}

pub fn skillDisplaySource(skills: []const Skill, selected: Skill) ?SkillSource {
    var matching_names: usize = 0;
    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, selected.name)) continue;
        matching_names += 1;
        if (matching_names > 1) return selected.source;
    }
    return null;
}

pub fn skillMenuFilterCount(skills: []const Skill, filter: SkillMenuSourceFilter) usize {
    return skillMenuFilterQueryCount(skills, filter, "");
}

pub fn skillMenuFilterQueryCount(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8) usize {
    var count: usize = 0;
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn skillMenuActualIndexAt(skills: []const Skill, filter: SkillMenuSourceFilter, display_index: usize) ?usize {
    return skillMenuActualIndexAtQuery(skills, filter, "", display_index);
}

pub fn skillMenuActualIndexAtQuery(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8, display_index: usize) ?usize {
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |entry| {
        if (entry.display_index == display_index) return entry.actual_index;
    }
    return null;
}

pub fn skillMenuDisplayIndexForActual(skills: []const Skill, filter: SkillMenuSourceFilter, wanted_actual_index: usize) ?usize {
    return skillMenuDisplayIndexForActualQuery(skills, filter, "", wanted_actual_index);
}

pub fn skillMenuDisplayIndexForActualQuery(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8, wanted_actual_index: usize) ?usize {
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |entry| {
        if (entry.actual_index == wanted_actual_index) return entry.display_index;
    }
    return null;
}

pub fn skillMenuSkillAt(skills: []const Skill, filter: SkillMenuSourceFilter, display_index: usize) ?Skill {
    return skillMenuSkillAtQuery(skills, filter, "", display_index);
}

pub fn skillMenuSkillAtQuery(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8, display_index: usize) ?Skill {
    const actual_index = skillMenuActualIndexAtQuery(skills, filter, query, display_index) orelse return null;
    return skills[actual_index];
}

pub fn fillSkillMenuRangeAtQuery(
    skills: []const Skill,
    filter: SkillMenuSourceFilter,
    query: []const u8,
    first_display_index: usize,
    out: []*const Skill,
) usize {
    var written: usize = 0;
    var it = SkillMenuView.init(skills, filter, query);
    while (it.next()) |entry| {
        if (entry.display_index < first_display_index) continue;
        if (written == out.len) break;
        out[written] = &skills[entry.actual_index];
        written += 1;
    }
    return written;
}

const SkillMenuViewEntry = struct {
    display_index: usize,
    actual_index: usize,
};

/// Owns one materialized menu query. Rebuilding mutates only this private
/// buffer; consumers borrow it until the next rebuild or deinit.
pub const SkillMenuIndex = struct {
    actual_indices: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *SkillMenuIndex, alloc: Allocator) void {
        self.actual_indices.deinit(alloc);
        self.* = .{};
    }

    pub fn rebuild(
        self: *SkillMenuIndex,
        alloc: Allocator,
        skills: []const Skill,
        filter: SkillMenuSourceFilter,
        query: []const u8,
    ) Allocator.Error!void {
        try self.actual_indices.ensureTotalCapacity(alloc, skills.len);
        self.rebuildAssumeCapacity(skills, filter, query);
    }

    fn rebuildAssumeCapacity(
        self: *SkillMenuIndex,
        skills: []const Skill,
        filter: SkillMenuSourceFilter,
        query: []const u8,
    ) void {
        std.debug.assert(self.actual_indices.capacity >= skills.len);
        std.debug.assert(skills.len <= std.math.maxInt(u32));
        self.actual_indices.clearRetainingCapacity();

        var view = SkillMenuView.init(skills, filter, query);
        while (view.next()) |entry| {
            self.actual_indices.appendAssumeCapacity(@intCast(entry.actual_index));
        }
    }

    pub fn count(self: *const SkillMenuIndex) usize {
        return self.actual_indices.items.len;
    }

    pub fn skillAt(
        self: *const SkillMenuIndex,
        skills: []const Skill,
        display_index: usize,
    ) ?*const Skill {
        if (display_index >= self.actual_indices.items.len) return null;
        const actual_index: usize = self.actual_indices.items[display_index];
        if (actual_index >= skills.len) return null;
        return &skills[actual_index];
    }
};

const SkillMenuView = struct {
    skills: []const Skill,
    filter: SkillMenuSourceFilter,
    query: []const u8,
    match_rank: usize = 0,
    source_rank: usize = 0,
    next_actual_index: usize = 0,
    next_display_index: usize = 0,

    fn init(skills: []const Skill, filter: SkillMenuSourceFilter, query: []const u8) SkillMenuView {
        return .{
            .skills = skills,
            .filter = filter,
            .query = query,
        };
    }

    fn next(self: *SkillMenuView) ?SkillMenuViewEntry {
        while (self.match_rank < skill_match_rank_count) {
            while (self.next_actual_index < self.skills.len) {
                const actual_index = self.next_actual_index;
                self.next_actual_index += 1;

                const skill = self.skills[actual_index];
                if (skillMatchRank(skill, self.query) != self.match_rank) continue;
                if (skillGroupRank(skill.source) != self.source_rank) continue;
                if (!skillSourceMatchesFilter(skill.source, self.filter)) continue;

                const display_index = self.next_display_index;
                self.next_display_index += 1;
                return .{
                    .display_index = display_index,
                    .actual_index = actual_index,
                };
            }

            self.source_rank += 1;
            if (self.source_rank == skill_group_count) {
                self.source_rank = 0;
                self.match_rank += 1;
            }
            self.next_actual_index = 0;
        }

        return null;
    }
};

const skill_match_rank_count: usize = 3;

fn skillMatchRank(skill: Skill, query: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, query, " \t\r\n/");
    if (trimmed.len == 0) return 0;
    if (std.ascii.startsWithIgnoreCase(skill.name, trimmed)) return 0;
    if (asciiContainsIgnoreCase(skill.name, trimmed)) return 1;
    if (asciiContainsIgnoreCase(skill.description, trimmed) or
        asciiContainsIgnoreCase(skillSourceShortLabel(skill.source), trimmed) or
        asciiContainsIgnoreCase(skill.path, trimmed))
    {
        return 2;
    }
    return null;
}

pub const SkillNameCompletion = struct {
    skill: Skill,
    suffix: []const u8,
};

pub fn firstSkillNameCompletion(skills: []const Skill, query: []const u8) ?SkillNameCompletion {
    if (query.len == 0) return null;
    for (skills) |skill| {
        if (skill.name.len <= query.len) continue;
        if (!std.ascii.startsWithIgnoreCase(skill.name, query)) continue;
        return .{
            .skill = skill,
            .suffix = skill.name[query.len..],
        };
    }
    return null;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) break;
        }
        if (i == needle.len) return true;
    }
    return false;
}

pub const SkillMenu = struct {
    active: bool = false,
    source_filter: SkillMenuSourceFilter = .all,
    selected_index: usize = 0,
    window_start: usize = 0,
    origin: SkillMenuOrigin = .command,
    target: ?SkillMenuTarget = null,
    query_buf: [256]u8 = undefined,
    query_len: usize = 0,

    pub fn open(self: *SkillMenu, items: []const Skill) void {
        self.openWithQuery(items, .command, null, "");
    }

    pub fn openWithQuery(self: *SkillMenu, items: []const Skill, origin: SkillMenuOrigin, target: ?SkillMenuTarget, query_text: []const u8) void {
        self.beginOpen(origin, target, query_text);
        self.clamp(items);
    }

    fn beginOpen(self: *SkillMenu, origin: SkillMenuOrigin, target: ?SkillMenuTarget, query_text: []const u8) void {
        self.active = true;
        self.source_filter = .all;
        self.origin = origin;
        self.target = target;
        self.setQuery(query_text);
    }

    pub fn openFocused(self: *SkillMenu, items: []const Skill, filter: SkillMenuSourceFilter, index: usize) void {
        self.beginOpenFocused(filter, index);
        self.clamp(items);
    }

    fn beginOpenFocused(self: *SkillMenu, filter: SkillMenuSourceFilter, index: usize) void {
        self.active = true;
        self.source_filter = filter;
        self.origin = .command;
        self.target = null;
        self.setQuery("");
        self.selected_index = index;
        self.window_start = 0;
    }

    pub fn close(self: *SkillMenu) void {
        self.* = .{};
    }

    pub fn query(self: *const SkillMenu) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *SkillMenu, query_text: []const u8) void {
        const len = @min(query_text.len, self.query_buf.len);
        if (len > 0) std.mem.copyForwards(u8, self.query_buf[0..len], query_text[0..len]);
        self.query_len = len;
    }

    pub fn move(self: *SkillMenu, items: []const Skill, delta: i32) bool {
        return self.moveVisibleRows(items, delta, skill_menu_max_visible_rows);
    }

    pub fn moveVisibleRows(self: *SkillMenu, items: []const Skill, delta: i32, visible_rows: u16) bool {
        return self.moveVisibleRowsCount(self.filteredItemCount(items), delta, visible_rows);
    }

    fn moveVisibleRowsCount(self: *SkillMenu, item_count: usize, delta: i32, visible_rows: u16) bool {
        if (!self.active or item_count == 0) return false;
        const max_rows: u16 = @max(visible_rows, 1);
        // Clamp at both ends instead of wrapping: at the top the selection
        // stays on the first skill, at the bottom on the last.
        const current: i32 = @intCast(self.selected_index % item_count);
        var next = current + delta;
        if (next < 0) next = 0;
        if (next >= @as(i32, @intCast(item_count))) next = @as(i32, @intCast(item_count)) - 1;
        self.selected_index = @intCast(next);
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            max_rows,
        );
        return true;
    }

    pub fn moveSourceFilter(self: *SkillMenu, items: []const Skill, delta: i32) bool {
        if (!self.advanceSourceFilter(delta)) return false;
        self.clamp(items);
        return true;
    }

    fn advanceSourceFilter(self: *SkillMenu, delta: i32) bool {
        if (!self.active) return false;
        const count = skill_menu_source_filters.len;
        const current = skillMenuSourceFilterIndex(self.source_filter);
        var next = @as(i32, @intCast(current)) + delta;
        if (next < 0) next = @as(i32, @intCast(count)) - 1;
        if (next >= @as(i32, @intCast(count))) next = 0;
        self.source_filter = skill_menu_source_filters[@intCast(next)];
        self.selected_index = 0;
        self.window_start = 0;
        return true;
    }

    pub fn clamp(self: *SkillMenu, items: []const Skill) void {
        self.clampCount(self.filteredItemCount(items));
    }

    fn clampCount(self: *SkillMenu, item_count: usize) void {
        if (item_count == 0) {
            self.selected_index = 0;
            self.window_start = 0;
            return;
        }
        if (self.selected_index >= item_count) self.selected_index = item_count - 1;
        self.window_start = list_window.updateEdgeStart(
            self.window_start,
            item_count,
            self.selected_index,
            skill_menu_max_visible_rows,
        );
    }

    pub fn filteredItemCount(self: SkillMenu, items: []const Skill) usize {
        return skillMenuFilterQueryCount(items, self.source_filter, self.query());
    }
};

const RootFingerprint = struct {
    path: []u8,
    exists: bool,
    inode: std.Io.File.INode = 0,
    mtime: std.Io.Timestamp = .zero,
    candidate_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
        [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length,

    fn deinit(self: *RootFingerprint, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

fn freeRootFingerprints(alloc: Allocator, roots: []RootFingerprint) void {
    for (roots) |*root| root.deinit(alloc);
    if (roots.len > 0) alloc.free(roots);
}

pub const LoadedCatalog = struct {
    dir: []u8 = &.{},
    skills: []Skill = &.{},
    skill_backing: ?[]u8 = null,
    diagnostics: []SkillDiagnostic = &.{},
    root_fingerprints: []RootFingerprint = &.{},

    pub fn deinit(self: *LoadedCatalog, alloc: Allocator) void {
        if (self.dir.len > 0) alloc.free(self.dir);
        if (self.skill_backing) |backing| {
            alloc.free(backing);
            if (self.skills.len > 0) alloc.free(self.skills);
        } else {
            freeSkills(alloc, self.skills);
        }
        freeSkillDiagnostics(alloc, self.diagnostics);
        freeRootFingerprints(alloc, self.root_fingerprints);
        self.* = .{};
    }
};

const CatalogGeneration = struct {
    alloc: Allocator,
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    generation: u64,
    catalog: LoadedCatalog,

    fn create(
        alloc: Allocator,
        generation: u64,
        catalog: LoadedCatalog,
    ) Allocator.Error!*CatalogGeneration {
        const value = try alloc.create(CatalogGeneration);
        value.* = .{
            .alloc = alloc,
            .generation = generation,
            .catalog = catalog,
        };
        return value;
    }

    fn retain(self: *CatalogGeneration) void {
        _ = self.references.fetchAdd(1, .seq_cst);
    }

    fn release(self: *CatalogGeneration) void {
        if (self.references.fetchSub(1, .seq_cst) != 1) return;
        const alloc = self.alloc;
        self.catalog.deinit(alloc);
        alloc.destroy(self);
    }

    fn referenceCount(self: *const CatalogGeneration) usize {
        return self.references.load(.seq_cst);
    }
};

pub const CatalogLease = struct {
    generation: ?*CatalogGeneration = null,
    items: []const Skill = &.{},
    diagnostics: []const SkillDiagnostic = &.{},

    pub fn deinit(self: *CatalogLease) void {
        if (self.generation) |generation| generation.release();
        self.* = undefined;
    }
};

const PendingCatalog = struct {
    generation: u64,
    catalog: LoadedCatalog,

    fn deinit(self: *PendingCatalog, alloc: Allocator) void {
        self.catalog.deinit(alloc);
        self.* = undefined;
    }
};

const PendingRefresh = struct {
    alloc: Allocator,
    generation: u64,
    home: []u8,

    fn deinit(self: *PendingRefresh) void {
        self.alloc.free(self.home);
        self.* = undefined;
    }
};

const KnownCatalogRefresh = union(enum) {
    full_discovery,
    unchanged,
    catalog: LoadedCatalog,
};

fn refreshKnownCatalog(
    alloc: Allocator,
    workspace_root: []const u8,
    home: []const u8,
    skills_dir: []const u8,
    root_policy: skill_contract.RootPolicy,
    base: CatalogLease,
) !KnownCatalogRefresh {
    const generation = base.generation orelse return .full_discovery;
    if (base.diagnostics.len > 0 or
        generation.catalog.root_fingerprints.len == 0)
    {
        return .full_discovery;
    }
    const current_roots = try collectRootFingerprints(
        alloc,
        workspace_root,
        home,
        skills_dir,
        root_policy,
    );
    defer freeRootFingerprints(alloc, current_roots);
    if (!rootFingerprintsEqual(
        generation.catalog.root_fingerprints,
        current_roots,
    )) return .full_discovery;

    const changed = try alloc.alloc(bool, base.items.len);
    defer alloc.free(changed);
    var changed_count: usize = 0;
    for (base.items, 0..) |skill, index| {
        const stat = statKnownSkill(skill) catch return .full_discovery;
        const differs = stat.inode != skill.metadata_inode or
            stat.size != skill.metadata_size or
            !std.meta.eql(stat.mtime, skill.metadata_mtime);
        changed[index] = differs;
        changed_count += @intFromBool(differs);
    }
    if (changed_count == 0) return .unchanged;
    if (changed_count > 8) return .full_discovery;

    const replacements = try alloc.alloc(?Skill, base.items.len);
    defer alloc.free(replacements);
    @memset(replacements, null);
    errdefer for (replacements) |maybe_skill| {
        if (maybe_skill) |skill| freeSkill(alloc, skill);
    };
    for (base.items, 0..) |skill, index| {
        if (!changed[index]) continue;
        replacements[index] = (try loadKnownSkill(alloc, skill)) orelse {
            for (replacements) |maybe_skill| {
                if (maybe_skill) |owned| freeSkill(alloc, owned);
            }
            return .full_discovery;
        };
    }
    const compact = try compactCloneSkills(alloc, base.items, replacements);
    errdefer compact.deinit(alloc);
    for (replacements) |*maybe_skill| {
        if (maybe_skill.*) |skill| freeSkill(alloc, skill);
        maybe_skill.* = null;
    }
    const roots = try cloneRootFingerprints(
        alloc,
        generation.catalog.root_fingerprints,
    );
    errdefer freeRootFingerprints(alloc, roots);
    const dir = try alloc.dupe(u8, skills_dir);
    return .{ .catalog = .{
        .dir = dir,
        .skills = compact.skills,
        .skill_backing = compact.backing,
        .root_fingerprints = roots,
    } };
}

fn statKnownSkill(skill: Skill) !std.Io.File.Stat {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}" ++ std.fs.path.sep_str ++ "SKILL.md",
        .{skill.path},
    );
    return std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        path,
        .{ .follow_symlinks = false },
    );
}

fn loadKnownSkill(alloc: Allocator, previous: Skill) !?Skill {
    var candidate_dir = if (previous.read_authority) |authority|
        openContainedDir(alloc, previous.path, authority, .{}) catch return null
    else
        io_mod.openDirAbsoluteNoFollow(previous.path, .{}) catch return null;
    defer candidate_dir.close(io_mod.getIo());
    var file = switch (try openPrimarySkillFile(
        alloc,
        &candidate_dir,
        previous.read_authority,
    )) {
        .opened => |opened| opened,
        .missing, .rejected => return null,
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return null;
    const entry_name = std.fs.path.basename(previous.path);
    const inspection = try inspectSkillCandidateFile(alloc, &file, entry_name);
    const candidate = switch (inspection) {
        .valid => |value| value,
        .invalid, .unreadable, .oversized => return null,
    };
    defer candidate.deinit(alloc);
    const name = try alloc.dupe(u8, candidate.metadata.name);
    errdefer alloc.free(name);
    const description = try alloc.alloc(u8, candidate.metadata.description_len());
    errdefer alloc.free(description);
    candidate.metadata.write_description(description);
    const path = try alloc.dupe(u8, previous.path);
    errdefer alloc.free(path);
    const authority = if (previous.read_authority) |value|
        try alloc.dupe(u8, value)
    else
        null;
    return .{
        .name = name,
        .description = description,
        .path = path,
        .source = previous.source,
        .read_authority = authority,
        .metadata_inode = stat.inode,
        .metadata_size = stat.size,
        .metadata_mtime = stat.mtime,
    };
}

const CompactSkills = struct {
    skills: []Skill,
    backing: []u8,

    fn deinit(self: CompactSkills, alloc: Allocator) void {
        alloc.free(self.backing);
        if (self.skills.len > 0) alloc.free(self.skills);
    }
};

fn compactCloneSkills(
    alloc: Allocator,
    source: []const Skill,
    replacements: []const ?Skill,
) !CompactSkills {
    std.debug.assert(source.len == replacements.len);
    var byte_count: usize = 0;
    for (source, replacements) |current, replacement| {
        const skill = replacement orelse current;
        byte_count = std.math.add(usize, byte_count, skill.name.len) catch
            return error.OutOfMemory;
        byte_count = std.math.add(usize, byte_count, skill.description.len) catch
            return error.OutOfMemory;
        byte_count = std.math.add(usize, byte_count, skill.path.len) catch
            return error.OutOfMemory;
        if (skill.read_authority) |authority| {
            byte_count = std.math.add(usize, byte_count, authority.len) catch
                return error.OutOfMemory;
        }
    }
    const skills = try alloc.alloc(Skill, source.len);
    errdefer if (skills.len > 0) alloc.free(skills);
    const backing = try alloc.alloc(u8, byte_count);
    errdefer alloc.free(backing);
    var cursor: usize = 0;
    for (source, replacements, 0..) |current, replacement, index| {
        const skill = replacement orelse current;
        const name = copyCompactString(backing, &cursor, skill.name);
        const description = copyCompactString(backing, &cursor, skill.description);
        const path = copyCompactString(backing, &cursor, skill.path);
        const authority = if (skill.read_authority) |value|
            copyCompactString(backing, &cursor, value)
        else
            null;
        skills[index] = .{
            .name = name,
            .description = description,
            .path = path,
            .source = skill.source,
            .read_authority = authority,
            .metadata_inode = skill.metadata_inode,
            .metadata_size = skill.metadata_size,
            .metadata_mtime = skill.metadata_mtime,
        };
    }
    std.debug.assert(cursor == backing.len);
    return .{ .skills = skills, .backing = backing };
}

fn copyCompactString(
    backing: []u8,
    cursor: *usize,
    value: []const u8,
) []const u8 {
    const start = cursor.*;
    const end = start + value.len;
    @memcpy(backing[start..end], value);
    cursor.* = end;
    return backing[start..end];
}

fn cloneRootFingerprints(
    alloc: Allocator,
    roots: []const RootFingerprint,
) ![]RootFingerprint {
    const copy = try alloc.alloc(RootFingerprint, roots.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |*root| root.deinit(alloc);
        if (copy.len > 0) alloc.free(copy);
    }
    while (filled < roots.len) : (filled += 1) {
        copy[filled] = roots[filled];
        copy[filled].path = try alloc.dupe(u8, roots[filled].path);
    }
    return copy;
}

pub const RefreshCompletion = enum {
    none,
    unchanged,
    adopted,
    failed,
};

pub const RefreshAction = union(enum) {
    list,
    show: []u8,
    notice: []u8,

    pub fn deinit(self: *RefreshAction, alloc: Allocator) void {
        switch (self.*) {
            .list => {},
            .show => |value| alloc.free(value),
            .notice => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const ReadyRefreshAction = struct {
    action: RefreshAction,
    succeeded: bool,

    pub fn deinit(self: *ReadyRefreshAction, alloc: Allocator) void {
        self.action.deinit(alloc);
        self.* = undefined;
    }
};

const PendingRefreshAction = struct {
    generation: u64,
    action: RefreshAction,

    fn deinit(self: *PendingRefreshAction, alloc: Allocator) void {
        self.action.deinit(alloc);
        self.* = undefined;
    }
};

const CatalogRefreshTask = struct {
    alloc: Allocator,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    workspace_root: []u8,
    home: []u8,
    skills_dir: []u8,
    root_policy: skill_contract.RootPolicy,
    generation: u64,
    base_catalog: CatalogLease,
    catalog: ?LoadedCatalog = null,
    unchanged: bool = false,
    failure: ?anyerror = null,

    fn create(
        alloc: Allocator,
        workspace_root: []const u8,
        home: []const u8,
        skills_dir: []const u8,
        root_policy: skill_contract.RootPolicy,
        generation: u64,
        base_catalog: CatalogLease,
    ) Allocator.Error!*CatalogRefreshTask {
        const task = try alloc.create(CatalogRefreshTask);
        errdefer alloc.destroy(task);
        const owned_workspace = try alloc.dupe(u8, workspace_root);
        errdefer alloc.free(owned_workspace);
        const owned_home = try alloc.dupe(u8, home);
        errdefer alloc.free(owned_home);
        const owned_skills_dir = try alloc.dupe(u8, skills_dir);
        errdefer alloc.free(owned_skills_dir);
        task.* = .{
            .alloc = alloc,
            .workspace_root = owned_workspace,
            .home = owned_home,
            .skills_dir = owned_skills_dir,
            .root_policy = root_policy,
            .generation = generation,
            .base_catalog = base_catalog,
        };
        return task;
    }

    fn start(self: *CatalogRefreshTask) !void {
        if (comptime @import("builtin").single_threaded) {
            self.run();
            return;
        }
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *CatalogRefreshTask) void {
        if (self.cancel_requested.load(.acquire)) {
            self.done.store(true, .release);
            return;
        }
        const known_refresh = refreshKnownCatalog(
            self.alloc,
            self.workspace_root,
            self.home,
            self.skills_dir,
            self.root_policy,
            self.base_catalog,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        switch (known_refresh) {
            .unchanged => {
                self.unchanged = true;
                self.done.store(true, .release);
                return;
            },
            .catalog => |catalog| {
                self.catalog = catalog;
                self.done.store(true, .release);
                return;
            },
            .full_discovery => {},
        }
        const discovery = loadVisibleSkills(
            self.alloc,
            self.workspace_root,
            self.home,
            self.skills_dir,
            self.root_policy,
        ) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        const roots = collectRootFingerprints(
            self.alloc,
            self.workspace_root,
            self.home,
            self.skills_dir,
            self.root_policy,
        ) catch |err| {
            var owned = discovery;
            owned.deinit(self.alloc);
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        const dir = self.alloc.dupe(u8, self.skills_dir) catch |err| {
            freeRootFingerprints(self.alloc, roots);
            var owned = discovery;
            owned.deinit(self.alloc);
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
        var catalog = LoadedCatalog{
            .dir = dir,
            .skills = discovery.skills,
            .diagnostics = discovery.diagnostics,
            .root_fingerprints = roots,
        };
        if (self.cancel_requested.load(.acquire)) {
            catalog.deinit(self.alloc);
        } else {
            self.catalog = catalog;
        }
        self.done.store(true, .release);
    }

    fn takeCatalog(self: *CatalogRefreshTask) ?LoadedCatalog {
        const catalog = self.catalog orelse return null;
        self.catalog = null;
        return catalog;
    }

    fn deinit(self: *CatalogRefreshTask) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.catalog) |*catalog| catalog.deinit(self.alloc);
        self.alloc.free(self.workspace_root);
        self.alloc.free(self.home);
        self.alloc.free(self.skills_dir);
        self.base_catalog.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

fn catalogMatches(runtime: *const Runtime, catalog: LoadedCatalog) bool {
    if (!std.mem.eql(u8, runtime.dir, catalog.dir) or
        runtime.items.len != catalog.skills.len or
        runtime.diagnostics.len != catalog.diagnostics.len)
    {
        return false;
    }
    for (runtime.items, catalog.skills) |active, refreshed| {
        if (!std.mem.eql(u8, active.name, refreshed.name) or
            !std.mem.eql(u8, active.description, refreshed.description) or
            !std.mem.eql(u8, active.path, refreshed.path) or
            active.source != refreshed.source or
            !optionalStringEqual(active.read_authority, refreshed.read_authority) or
            !skillFingerprintEqual(active, refreshed))
        {
            return false;
        }
    }
    for (runtime.diagnostics, catalog.diagnostics) |active, refreshed| {
        if (!std.mem.eql(u8, active.path, refreshed.path) or
            active.source != refreshed.source or
            active.scope != refreshed.scope or
            !std.meta.eql(active.cause, refreshed.cause))
        {
            return false;
        }
    }
    const active_catalog = runtime.active_catalog orelse return true;
    if (!rootFingerprintsEqual(
        active_catalog.catalog.root_fingerprints,
        catalog.root_fingerprints,
    )) return false;
    return true;
}

fn skillFingerprintEqual(left: Skill, right: Skill) bool {
    return left.metadata_inode == right.metadata_inode and
        left.metadata_size == right.metadata_size and
        std.meta.eql(left.metadata_mtime, right.metadata_mtime);
}

fn rootFingerprintsEqual(
    left: []const RootFingerprint,
    right: []const RootFingerprint,
) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.path, b.path) or
            a.exists != b.exists or
            a.inode != b.inode or
            !std.meta.eql(a.mtime, b.mtime) or
            !std.mem.eql(u8, &a.candidate_digest, &b.candidate_digest)) return false;
    }
    return true;
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn skillMenuSourceFilterIndex(filter: SkillMenuSourceFilter) usize {
    for (skill_menu_source_filters, 0..) |candidate, index| {
        if (candidate == filter) return index;
    }
    return 0;
}

pub const Runtime = struct {
    dir: []u8 = &.{},
    items: []Skill = &.{},
    diagnostics: []SkillDiagnostic = &.{},
    menu: SkillMenu = .{},
    menu_index: SkillMenuIndex = .{},
    menu_index_ready: bool = false,
    catalog_mutex: std.Io.Mutex = .init,
    active_catalog: ?*CatalogGeneration = null,
    retired_catalog: ?*CatalogGeneration = null,
    pending_catalog: ?PendingCatalog = null,
    next_refresh_generation: u64 = 0,
    fresh_through_generation: u64 = 0,
    failed_refresh_generation: ?u64 = null,
    pending_refresh_action: ?PendingRefreshAction = null,
    refresh_task: ?*CatalogRefreshTask = null,
    refresh_pending: ?PendingRefresh = null,

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        if (self.refresh_task) |task| task.deinit();
        self.refresh_task = null;
        if (self.pending_catalog) |*pending| pending.deinit(alloc);
        self.pending_catalog = null;
        if (self.pending_refresh_action) |*action| action.deinit(alloc);
        self.pending_refresh_action = null;
        if (self.refresh_pending) |*pending| pending.deinit();
        self.refresh_pending = null;
        self.freeLoaded(alloc);
        if (self.retired_catalog) |catalog| catalog.release();
        self.retired_catalog = null;
        self.menu.close();
        self.menu_index.deinit(alloc);
    }

    pub fn requestRefresh(
        self: *Runtime,
        alloc: Allocator,
        workspace_root: []const u8,
        home: ?[]const u8,
        root_policy: skill_contract.RootPolicy,
    ) !u64 {
        const configured_home = home orelse {
            const generation = self.nextGeneration();
            self.fresh_through_generation = @max(
                self.fresh_through_generation,
                generation,
            );
            return generation;
        };
        if (self.refresh_task != null or self.pending_catalog != null) {
            if (self.refresh_pending) |pending| return pending.generation;
            const owned_home = try alloc.dupe(u8, configured_home);
            const generation = self.nextGeneration();
            self.refresh_pending = .{
                .alloc = alloc,
                .generation = generation,
                .home = owned_home,
            };
            return generation;
        }
        const generation = self.nextGeneration();
        try self.startRefresh(
            alloc,
            workspace_root,
            configured_home,
            root_policy,
            generation,
        );
        return generation;
    }

    fn startRefresh(
        self: *Runtime,
        alloc: Allocator,
        workspace_root: []const u8,
        home: []const u8,
        root_policy: skill_contract.RootPolicy,
        generation: u64,
    ) !void {
        var base_catalog = self.acquireCatalog();
        var base_catalog_owned = true;
        defer if (base_catalog_owned) base_catalog.deinit();
        const task = try CatalogRefreshTask.create(
            alloc,
            workspace_root,
            home,
            self.dir,
            root_policy,
            generation,
            base_catalog,
        );
        base_catalog_owned = false;
        errdefer task.deinit();
        try task.start();
        self.refresh_task = task;
    }

    fn nextGeneration(self: *Runtime) u64 {
        self.next_refresh_generation +|= 1;
        return self.next_refresh_generation;
    }

    pub fn pollRefresh(
        self: *Runtime,
        alloc: Allocator,
        workspace_root: []const u8,
        root_policy: skill_contract.RootPolicy,
    ) !RefreshCompletion {
        self.reapRetiredCatalog();
        var completion: RefreshCompletion = .none;
        if (self.pending_catalog) |*pending| {
            if (try self.adoptCatalog(alloc, pending.generation, &pending.catalog)) {
                pending.catalog = .{};
                self.pending_catalog = null;
                completion = .adopted;
            }
        }
        const task = self.refresh_task orelse {
            try self.startPendingRefresh(
                alloc,
                workspace_root,
                root_policy,
            );
            return completion;
        };
        if (!task.done.load(.acquire)) return .none;
        if (task.thread) |thread| {
            thread.join();
            task.thread = null;
        }
        self.refresh_task = null;
        defer task.deinit();
        completion = .failed;
        if (task.failure == null) {
            if (task.unchanged) {
                self.fresh_through_generation = @max(
                    self.fresh_through_generation,
                    task.generation,
                );
                completion = .unchanged;
            } else if (task.takeCatalog()) |catalog_value| {
                var catalog = catalog_value;
                defer catalog.deinit(alloc);
                if (catalogMatches(self, catalog)) {
                    self.fresh_through_generation = @max(
                        self.fresh_through_generation,
                        task.generation,
                    );
                    completion = .unchanged;
                } else {
                    if (try self.adoptCatalog(alloc, task.generation, &catalog)) {
                        completion = .adopted;
                    } else {
                        self.pending_catalog = .{
                            .generation = task.generation,
                            .catalog = catalog,
                        };
                        catalog = .{};
                        completion = .none;
                    }
                }
            }
        } else {
            self.failed_refresh_generation = task.generation;
        }
        try self.startPendingRefresh(alloc, workspace_root, root_policy);
        return completion;
    }

    fn startPendingRefresh(
        self: *Runtime,
        alloc: Allocator,
        workspace_root: []const u8,
        root_policy: skill_contract.RootPolicy,
    ) !void {
        if (self.refresh_task != null or self.pending_catalog != null) return;
        var pending = self.refresh_pending orelse return;
        self.refresh_pending = null;
        defer pending.deinit();
        try self.startRefresh(
            alloc,
            workspace_root,
            pending.home,
            root_policy,
            pending.generation,
        );
    }

    pub const GenerationStatus = enum {
        pending,
        current,
        failed,
    };

    pub fn generationStatus(self: *const Runtime, generation: u64) GenerationStatus {
        if (self.fresh_through_generation >= generation) return .current;
        if (self.failed_refresh_generation) |failed| {
            if (failed == generation) return .failed;
        }
        return .pending;
    }

    pub fn refreshActive(self: *const Runtime) bool {
        return self.refresh_task != null or self.pending_catalog != null;
    }

    pub fn queueRefreshAction(
        self: *Runtime,
        alloc: Allocator,
        generation: u64,
        action: union(enum) {
            list,
            show: []const u8,
            notice: []const u8,
        },
    ) !void {
        const owned: RefreshAction = switch (action) {
            .list => .list,
            .show => |value| .{ .show = try alloc.dupe(u8, value) },
            .notice => |value| .{ .notice = try alloc.dupe(u8, value) },
        };
        if (self.pending_refresh_action) |*pending| {
            debug_trace.logf(
                "skills",
                "refresh action superseded prior_generation={d} prior_action={s} generation={d} action={s}",
                .{
                    pending.generation,
                    @tagName(pending.action),
                    generation,
                    @tagName(owned),
                },
            );
            pending.deinit(alloc);
            self.pending_refresh_action = null;
        }
        self.pending_refresh_action = .{
            .generation = generation,
            .action = owned,
        };
    }

    pub fn takeReadyRefreshAction(
        self: *Runtime,
    ) ?ReadyRefreshAction {
        const pending = self.pending_refresh_action orelse return null;
        const status = self.generationStatus(pending.generation);
        if (status == .pending) return null;
        self.pending_refresh_action = null;
        return .{
            .action = pending.action,
            .succeeded = status == .current,
        };
    }

    pub fn acquireCatalog(self: *Runtime) CatalogLease {
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlock(io_mod.getIo());
        if (self.active_catalog) |catalog| {
            catalog.retain();
            return .{
                .generation = catalog,
                .items = catalog.catalog.skills,
                .diagnostics = catalog.catalog.diagnostics,
            };
        }
        return .{
            .items = self.items,
            .diagnostics = self.diagnostics,
        };
    }

    fn reapRetiredCatalog(self: *Runtime) void {
        const retired = self.retired_catalog orelse return;
        if (retired.referenceCount() != 1) return;
        self.retired_catalog = null;
        retired.release();
    }

    fn freeLoaded(self: *Runtime, alloc: Allocator) void {
        if (self.active_catalog) |catalog| {
            self.active_catalog = null;
            catalog.release();
        } else {
            if (self.dir.len > 0) alloc.free(self.dir);
            freeSkills(alloc, self.items);
            freeSkillDiagnostics(alloc, self.diagnostics);
        }
        self.dir = &.{};
        self.items = &.{};
        self.diagnostics = &.{};
    }

    /// Transfers `dir`, `skills`, and `diagnostics` only after the menu index
    /// has reserved enough storage. On failure the caller retains all inputs
    /// and the current runtime catalog remains unchanged.
    pub fn replaceLoaded(
        self: *Runtime,
        alloc: Allocator,
        dir: []u8,
        skills: []Skill,
        diagnostics: []SkillDiagnostic,
    ) Allocator.Error!void {
        try self.menu_index.actual_indices.ensureTotalCapacity(alloc, skills.len);
        const generation = self.nextGeneration();
        var catalog = LoadedCatalog{
            .dir = dir,
            .skills = skills,
            .diagnostics = diagnostics,
        };
        const adopted = try self.adoptCatalog(alloc, generation, &catalog);
        std.debug.assert(adopted);
    }

    fn adoptCatalog(
        self: *Runtime,
        alloc: Allocator,
        generation: u64,
        catalog: *LoadedCatalog,
    ) Allocator.Error!bool {
        try self.menu_index.actual_indices.ensureTotalCapacity(
            alloc,
            catalog.skills.len,
        );
        self.reapRetiredCatalog();
        self.catalog_mutex.lockUncancelable(io_mod.getIo());
        defer self.catalog_mutex.unlock(io_mod.getIo());
        if (self.active_catalog) |active| {
            if (active.referenceCount() > 1 and self.retired_catalog != null) {
                return false;
            }
        }
        const next = try CatalogGeneration.create(alloc, generation, catalog.*);
        catalog.* = .{};
        if (self.active_catalog) |active| {
            if (active.referenceCount() > 1) {
                self.retired_catalog = active;
            } else {
                active.release();
            }
        } else {
            if (self.dir.len > 0) alloc.free(self.dir);
            freeSkills(alloc, self.items);
            freeSkillDiagnostics(alloc, self.diagnostics);
        }
        self.active_catalog = next;
        self.dir = next.catalog.dir;
        self.items = next.catalog.skills;
        self.diagnostics = next.catalog.diagnostics;
        self.fresh_through_generation = @max(
            self.fresh_through_generation,
            generation,
        );
        self.failed_refresh_generation = null;
        self.menu_index.rebuildAssumeCapacity(
            self.items,
            self.menu.source_filter,
            self.menu.query(),
        );
        self.menu_index_ready = true;
        self.menu.clampCount(self.menu_index.count());
        return true;
    }

    pub fn prepareMenuIndex(self: *Runtime, alloc: Allocator) Allocator.Error!void {
        try self.menu_index.rebuild(
            alloc,
            self.items,
            self.menu.source_filter,
            self.menu.query(),
        );
        self.menu_index_ready = true;
    }

    fn rebuildPreparedMenuIndex(self: *Runtime) void {
        if (self.menu_index.actual_indices.capacity < self.items.len) {
            self.menu_index.actual_indices.clearRetainingCapacity();
            self.menu_index_ready = false;
            return;
        }
        self.menu_index.rebuildAssumeCapacity(
            self.items,
            self.menu.source_filter,
            self.menu.query(),
        );
        self.menu_index_ready = true;
    }

    pub fn menuItemCount(self: Runtime) usize {
        if (self.menu_index_ready) return self.menu_index.count();
        return self.menu.filteredItemCount(self.items);
    }

    pub fn openMenu(self: *Runtime) void {
        self.menu.beginOpen(.command, null, "");
        self.rebuildPreparedMenuIndex();
        self.menu.clampCount(self.menuItemCount());
    }

    pub fn openMenuWithQuery(self: *Runtime, origin: SkillMenuOrigin, target: ?SkillMenuTarget, query: []const u8) void {
        self.menu.beginOpen(origin, target, query);
        self.rebuildPreparedMenuIndex();
        self.menu.clampCount(self.menuItemCount());
    }

    pub fn openMenuFocusedByName(self: *Runtime, name: []const u8) bool {
        var matched_index: ?usize = null;
        for (self.items, 0..) |skill, actual_index| {
            if (!std.mem.eql(u8, skill.name, name)) continue;
            if (matched_index != null) return false;
            matched_index = actual_index;
        }
        const actual_index = matched_index orelse return false;
        const skill = self.items[actual_index];
        const filter = skillMenuFilterForSource(skill.source);
        self.menu.beginOpenFocused(filter, 0);
        self.rebuildPreparedMenuIndex();
        const display_index = if (self.menu_index_ready)
            std.mem.indexOfScalar(
                u32,
                self.menu_index.actual_indices.items,
                @intCast(actual_index),
            )
        else
            skillMenuDisplayIndexForActual(self.items, filter, actual_index);
        self.menu.selected_index = display_index orelse return false;
        self.menu.clampCount(self.menuItemCount());
        return true;
    }

    pub fn closeMenu(self: *Runtime) void {
        self.menu.close();
    }

    pub fn moveMenuSelection(self: *Runtime, delta: i32) bool {
        return self.menu.moveVisibleRowsCount(
            self.menuItemCount(),
            delta,
            skill_menu_max_visible_rows,
        );
    }

    pub fn moveMenuSelectionVisibleRows(self: *Runtime, delta: i32, visible_rows: u16) bool {
        return self.menu.moveVisibleRowsCount(self.menuItemCount(), delta, visible_rows);
    }

    pub fn moveMenuSourceFilter(self: *Runtime, delta: i32) bool {
        if (!self.menu.advanceSourceFilter(delta)) return false;
        self.rebuildPreparedMenuIndex();
        self.menu.clampCount(self.menuItemCount());
        return true;
    }

    pub fn setMenuQuery(
        self: *Runtime,
        _: Allocator,
        query: []const u8,
    ) void {
        self.menu.setQuery(query);
        self.rebuildPreparedMenuIndex();
        const item_count = self.menuItemCount();
        if (item_count == 0) {
            self.menu.selected_index = 0;
            self.menu.window_start = 0;
            return;
        }
        if (self.menu.selected_index >= item_count) {
            self.menu.selected_index = item_count - 1;
        }
        self.menu.window_start = list_window.updateEdgeStart(
            self.menu.window_start,
            item_count,
            self.menu.selected_index,
            skill_menu_max_visible_rows,
        );
    }

    pub fn selectedMenuSkill(self: Runtime) ?Skill {
        if (!self.menu.active) return null;
        const item_count = self.menuItemCount();
        if (item_count == 0) return null;
        if (self.menu_index_ready) {
            const skill = self.menu_index.skillAt(
                self.items,
                self.menu.selected_index % item_count,
            ) orelse return null;
            return skill.*;
        }
        return skillMenuSkillAtQuery(self.items, self.menu.source_filter, self.menu.query(), self.menu.selected_index % item_count);
    }

    pub fn menuVisible(self: Runtime) bool {
        if (!self.menu.active) return false;
        if (!self.menu.origin.isMention()) return true;
        return skillMenuFilterQueryCount(self.items, .all, self.menu.query()) > 0;
    }
};

fn attachCatalogDiagnostics(
    alloc: Allocator,
    section: BoundedPromptSection,
    diagnostics: []const SkillDiagnostic,
) !BoundedPromptSection {
    var result = section;
    errdefer result.deinit(alloc);
    if (diagnostics.len == 0) return result;

    var candidate_count: usize = 0;
    var root_count: usize = 0;
    for (diagnostics) |diagnostic| switch (diagnostic.scope) {
        .candidate => candidate_count += 1,
        .root => root_count += 1,
    };
    const marker = try std.fmt.allocPrint(
        alloc,
        "<skill_discovery_warning skipped_candidate_count=\"{d}\" incomplete_root_count=\"{d}\" missing_from_incomplete_roots=\"{s}\" />\n",
        .{ candidate_count, root_count, if (root_count > 0) "unknown" else "0" },
    );
    defer alloc.free(marker);
    const marked_text = try std.mem.concat(alloc, u8, &.{ marker, result.text });
    alloc.free(result.text);
    result.text = marked_text;

    var diagnostic_notice: std.Io.Writer.Allocating = .init(alloc);
    defer diagnostic_notice.deinit();
    try writeDiagnosticSummary(alloc, &diagnostic_notice.writer, diagnostics);
    result.diagnostic_notice = try diagnostic_notice.toOwnedSlice();
    return result;
}

pub const ExplicitSelection = union(enum) {
    skill: usize,
    ambiguous: []const u8,
};

pub fn matchExplicitSkillIndices(alloc: Allocator, prompt: []const u8, skills: []const Skill) ![]usize {
    const selections = try collectExplicitSkillSelections(alloc, prompt, skills);
    defer alloc.free(selections);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(alloc);
    for (selections) |selection| switch (selection) {
        .skill => |index| try indices.append(alloc, index),
        .ambiguous => {},
    };
    return indices.toOwnedSlice(alloc);
}

/// Returned names borrow the catalog; the caller owns only the selection slice.
pub fn collectExplicitSkillSelections(alloc: Allocator, prompt: []const u8, skills: []const Skill) ![]ExplicitSelection {
    var selections: std.ArrayList(ExplicitSelection) = .empty;
    defer selections.deinit(alloc);
    const trimmed = std.mem.trimStart(u8, prompt, " \t\r\n");
    const natural_end = std.mem.findScalar(u8, prompt, '$') orelse prompt.len;
    var natural = try parseNaturalLanguageSkillReference(alloc, prompt[0..natural_end]);
    defer if (natural) |*reference| reference.deinit(alloc);
    for (skills, 0..) |skill, index| {
        const matches = matchesSigilSkillAt(trimmed, 0, skill.name, '/') or
            if (natural) |reference| reference.matchesSkillName(skill.name) else false;
        if (!matches) continue;
        var duplicates: usize = 0;
        for (skills) |other| {
            if (asciiEqlIgnoreCase(skill.name, other.name)) duplicates += 1;
        }
        try appendExplicitSelection(alloc, &selections, if (duplicates == 1)
            .{ .skill = index }
        else
            .{ .ambiguous = skill.name });
    }

    var quote: ?u8 = null;
    var code: ?struct { byte: u8, len: usize, fenced: bool } = null;
    var index: usize = 0;
    while (index < prompt.len) : (index += 1) {
        const byte = prompt[index];
        if (code) |active| {
            if (byte == active.byte) {
                const end = skill_code_run_end(prompt, index);
                const closes = if (active.fenced) closing: {
                    if (end - index < active.len or !skill_fence_line_start(prompt, index)) break :closing false;
                    const rest = prompt[end..];
                    const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
                    break :closing std.mem.trim(u8, rest[0..line_end], " \t\r").len == 0;
                } else end - index == active.len;
                if (closes) code = null;
                index = end - 1;
            }
            continue;
        }
        if (byte == '\\') {
            if (index + 1 < prompt.len) index += 1;
            continue;
        }
        if (quote) |active| {
            if (byte == active) quote = null;
            continue;
        }
        if (byte == '`' or byte == '~') {
            const end = skill_code_run_end(prompt, index);
            const fenced = if (end - index >= 3 and skill_fence_line_start(prompt, index)) opening: {
                const rest = prompt[end..];
                const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
                break :opening byte == '~' or std.mem.findScalar(u8, rest[0..line_end], '`') == null;
            } else false;
            if (fenced or byte == '`') code = .{ .byte = byte, .len = end - index, .fenced = fenced };
            index = end - 1;
            continue;
        }
        if (byte == '"' or
            (byte == '\'' and (index == 0 or !std.ascii.isAlphanumeric(prompt[index - 1]))))
        {
            quote = byte;
            continue;
        }
        if (std.mem.startsWith(u8, prompt[index..], "“") or std.mem.startsWith(u8, prompt[index..], "‘")) {
            const close = if (std.mem.startsWith(u8, prompt[index..], "“")) "”" else "’";
            const next = std.mem.find(u8, prompt[index + 3 ..], close) orelse break;
            index += 3 + next + close.len - 1;
            continue;
        }
        if (byte != '$' or explicitReferenceNegated(prompt[0..index])) continue;
        var found: ?usize = null;
        var longest: usize = 0;
        var ambiguous = false;
        for (skills, 0..) |skill, skill_index| {
            if (!matchesSigilSkillAt(prompt, index, skill.name, '$') or skill.name.len < longest) continue;
            if (skill.name.len > longest) {
                found = skill_index;
                longest = skill.name.len;
                ambiguous = false;
            } else {
                ambiguous = true;
            }
        }
        if (found) |skill_index| {
            try appendExplicitSelection(alloc, &selections, if (ambiguous)
                .{ .ambiguous = skills[skill_index].name }
            else
                .{ .skill = skill_index });
            index += longest;
        }
    }
    return selections.toOwnedSlice(alloc);
}

fn skill_code_run_end(text: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < text.len and text[end] == text[start]) : (end += 1) {}
    return end;
}

fn skill_fence_line_start(text: []const u8, index: usize) bool {
    var start = index;
    while (start > 0 and index - start < 3 and text[start - 1] == ' ') : (start -= 1) {}
    return start == 0 or text[start - 1] == '\n';
}

fn appendExplicitSelection(alloc: Allocator, selections: *std.ArrayList(ExplicitSelection), selection: ExplicitSelection) !void {
    for (selections.items) |existing| switch (selection) {
        .skill => |index| if (existing == .skill and existing.skill == index) return,
        .ambiguous => |name| if (existing == .ambiguous and asciiEqlIgnoreCase(existing.ambiguous, name)) return,
    };
    try selections.append(alloc, selection);
}

fn explicitReferenceNegated(before: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, before, " \t\r\n,:");
    const endings = [_][]const u8{
        "not",           "don't",        "without",   "not use",     "don't use",    "not apply",      "don't apply",
        "not invoke",    "don't invoke", "not run",   "don't run",   "not activate", "don't activate", "not use the",
        "don't use the", "never",        "never use", "never apply", "never invoke", "never run",      "never activate",
        "never use the",
    };
    for (endings) |ending| {
        if (trimmed.len < ending.len) continue;
        const start = trimmed.len - ending.len;
        if (start > 0 and std.ascii.isAlphanumeric(trimmed[start - 1])) continue;
        if (asciiEqlIgnoreCase(trimmed[start..], ending)) return true;
    }
    return false;
}

const NaturalLanguageSkillReference = struct {
    normalized_prompt: []u8,
    name_starts: [2]usize,
    name_start_count: usize,

    fn deinit(self: *NaturalLanguageSkillReference, alloc: Allocator) void {
        alloc.free(self.normalized_prompt);
        self.* = undefined;
    }

    fn matchesSkillName(self: NaturalLanguageSkillReference, skill_name: []const u8) bool {
        for (self.name_starts[0..self.name_start_count]) |name_start| {
            var search_start = name_start;
            while (std.mem.find(u8, self.normalized_prompt[search_start..], " skill")) |relative_marker_start| {
                const marker_start = search_start + relative_marker_start;
                const reference_end = marker_start + " skill".len;
                const has_boundary = reference_end == self.normalized_prompt.len or self.normalized_prompt[reference_end] == ' ';
                if (has_boundary and marker_start > name_start and
                    normalizedReferenceTextEql(skill_name, self.normalized_prompt[name_start..marker_start]))
                {
                    return true;
                }
                search_start = marker_start + 1;
            }
        }
        return false;
    }
};

fn parseNaturalLanguageSkillReference(alloc: Allocator, prompt: []const u8) !?NaturalLanguageSkillReference {
    const reference_start = naturalLanguageReferenceStart(prompt) orelse return null;
    const normalized_prompt = try normalizeReferenceText(alloc, reference_start);
    const name_start = naturalLanguageSkillNameStart(normalized_prompt) orelse {
        alloc.free(normalized_prompt);
        return null;
    };

    var reference: NaturalLanguageSkillReference = .{
        .normalized_prompt = normalized_prompt,
        .name_starts = .{ name_start, undefined },
        .name_start_count = 1,
    };
    if (std.mem.startsWith(u8, normalized_prompt[name_start..], "the ")) {
        reference.name_starts[1] = name_start + "the ".len;
        reference.name_start_count = 2;
    }
    return reference;
}

fn naturalLanguageSkillNameStart(normalized_prompt: []const u8) ?usize {
    for ([_][]const u8{ "use", "apply", "activate", "invoke", "run" }) |verb| {
        if (!std.mem.startsWith(u8, normalized_prompt, verb)) continue;
        if (normalized_prompt.len <= verb.len or normalized_prompt[verb.len] != ' ') continue;
        return verb.len + 1;
    }
    return null;
}

fn naturalLanguageReferenceStart(prompt: []const u8) ?[]const u8 {
    var text = std.mem.trimStart(u8, prompt, " \t\r\n");
    if (text.len >= "please".len and
        asciiEqlIgnoreCase(text[0.."please".len], "please") and
        (text.len == "please".len or !std.ascii.isAlphanumeric(text["please".len])))
    {
        text = std.mem.trimStart(u8, text["please".len..], " \t\r\n,:");
    }
    if (text.len == 0 or text[0] == '"' or text[0] == '\'' or text[0] == '`') return null;
    if (std.mem.startsWith(u8, text, "“") or std.mem.startsWith(u8, text, "‘")) return null;
    return text;
}

fn matchesSigilSkillAt(text: []const u8, index: usize, skill_name: []const u8, sigil: u8) bool {
    if (index >= text.len or text[index] != sigil) return false;
    const name_start = index + 1;
    if (text.len - name_start < skill_name.len) return false;
    if (!asciiEqlIgnoreCase(text[name_start .. name_start + skill_name.len], skill_name)) return false;
    const end = name_start + skill_name.len;
    return end == text.len or !isSkillNameContinuation(text[end]);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (std.ascii.toLower(a_byte) != std.ascii.toLower(b_byte)) return false;
    }
    return true;
}

fn isSkillNameContinuation(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn normalizedReferenceTextEql(text: []const u8, normalized: []const u8) bool {
    var normalized_index: usize = 0;
    var pending_space = false;
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (pending_space and normalized_index > 0) {
                if (normalized_index >= normalized.len or normalized[normalized_index] != ' ') return false;
                normalized_index += 1;
            }
            if (normalized_index >= normalized.len or normalized[normalized_index] != std.ascii.toLower(char)) return false;
            normalized_index += 1;
            pending_space = false;
        } else if (normalized_index > 0) {
            pending_space = true;
        }
    }
    return normalized_index == normalized.len;
}

fn normalizeReferenceText(alloc: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var previous_was_space = true;
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(alloc, std.ascii.toLower(char));
            previous_was_space = false;
        } else if (!previous_was_space) {
            try out.append(alloc, ' ');
            previous_was_space = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return try out.toOwnedSlice(alloc);
}

pub fn listSkillsSummary(alloc: Allocator, skills: []const Skill) ![]u8 {
    return listSkillsSummaryStyled(alloc, skills, .{});
}

pub fn listSkillsSummaryStyled(alloc: Allocator, skills: []const Skill, styles: SkillSummaryStyles) ![]u8 {
    if (skills.len == 0) {
        return alloc.dupe(u8, "No skills available.\n");
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const group_order = [_][]const u8{
        "Managed installs",
        "Workspace skills",
        "Compatibility roots",
    };

    try out.writer.print("Visible skills ({d}):\n", .{skills.len});
    for (group_order) |group| {
        var count: usize = 0;
        for (skills) |skill| {
            if (std.mem.eql(u8, skillGroupLabel(skill.source), group)) count += 1;
        }
        if (count == 0) continue;

        try out.writer.print("\n{s} ({d}):\n", .{ group, count });
        for (skills) |skill| {
            if (!std.mem.eql(u8, skillGroupLabel(skill.source), group)) continue;
            if (skill.description.len > 0) {
                try out.writer.print("  - {s}: {s} ", .{ skill.name, skill.description });
            } else {
                try out.writer.print("  - {s} ", .{skill.name});
            }
            try writeStyledSourceLabel(&out.writer, styles, skillSourceLabel(skill.source));
            try out.writer.writeByte('\n');
        }
    }

    return try out.toOwnedSlice();
}

fn writeStyledSourceLabel(writer: *std.Io.Writer, styles: SkillSummaryStyles, label: []const u8) !void {
    if (styles.source_label_style.len == 0) {
        try writer.print("[{s}]", .{label});
        return;
    }
    try writer.print("{s}[{s}]{s}", .{ styles.source_label_style, label, styles.reset_style });
}

fn buildSkillsSystemPromptSectionWithLimits(
    alloc: Allocator,
    all_skills: []const Skill,
    limits: context_limits.Values,
) !BoundedPromptSection {
    return buildSkillPrompt(alloc, all_skills, &.{}, limits, null);
}

/// Borrows skill paths until the returned section is released.
pub fn buildSkillPrompt(
    alloc: Allocator,
    skills: []const Skill,
    diagnostics: []const SkillDiagnostic,
    limits: context_limits.Values,
    context_window: ?u32,
) !BoundedPromptSection {
    var visible: std.ArrayList(Skill) = .empty;
    defer visible.deinit(alloc);
    var identity_scratch = std.heap.ArenaAllocator.init(alloc);
    defer identity_scratch.deinit();
    for (skills) |skill| {
        if (!try tool_result_limits.modelProjectionPreservesText(identity_scratch.allocator(), skill.name) or
            !try tool_result_limits.modelProjectionPreservesText(identity_scratch.allocator(), skill.path)) continue;
        try visible.append(alloc, skill);
    }
    var section = renderSkillPrompt(alloc, visible.items, limits, context_window, catalog_namespace(visible.items)) catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
    section.locations.skills = skills;
    section.locations.diagnostics = diagnostics;
    {
        errdefer section.deinit(alloc);
        if (visible.items.len < skills.len) {
            const notice = try std.fmt.allocPrint(alloc, "{s}[context] {d} skill identities withheld because they cannot be safely represented to the model.\n", .{
                section.notice orelse "", skills.len - visible.items.len,
            });
            if (section.notice) |previous| alloc.free(previous);
            section.notice = notice;
        }
    }
    return attachCatalogDiagnostics(alloc, section, diagnostics) catch |err| {
        if (err == error.WriteFailed) return error.OutOfMemory;
        return err;
    };
}

const SkillPromptBudget = struct {
    limit: usize,
    characters: bool = false,

    fn resolve(limit: context_limits.Resolved, context_window: ?u32) SkillPromptBudget {
        if (limit.source != .compiled_default) return .{ .limit = limit.effectiveBytes() };
        if (context_window) |window| {
            if (window > 0) return .{ .limit = @intCast(@min(
                @as(u64, context_limits.emergency_ceiling_bytes),
                @max(1, @as(u64, window) * 2 / 100) * 4,
            )) };
        }
        return .{ .limit = 8000, .characters = true };
    }

    fn cost(self: SkillPromptBudget, bytes: []const u8) usize {
        return if (self.characters)
            std.unicode.utf8CountCodepoints(bytes) catch bytes.len
        else
            bytes.len;
    }
};

const SkillPromptEntry = struct {
    prefix: []u8,
    description: []u8,
    suffix: []u8,
    root_count: usize,
    description_end: usize = 0,
    description_limited: bool,

    fn deinit(self: SkillPromptEntry, alloc: Allocator) void {
        alloc.free(self.prefix);
        alloc.free(self.description);
        alloc.free(self.suffix);
    }
};

fn catalog_namespace(skills: []const Skill) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx-skill-locations");
    for (skills) |skill| {
        for ([_][]const u8{ skill.name, skill.path }) |value| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(value.len), .little);
            hash.update(&length);
            hash.update(value);
        }
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn renderSkillPrompt(
    alloc: Allocator,
    skills: []const Skill,
    limits: context_limits.Values,
    context_window: ?u32,
    namespace: u64,
) !BoundedPromptSection {
    if (skills.len == 0) return .{ .text = try alloc.dupe(u8, "") };
    const budget = SkillPromptBudget.resolve(limits.skill_catalog_bytes, context_window);
    const header =
        "Skills provide task instructions. Use named skills and clearly matching skills before substantive work.\n" ++
        "Read selected skills completely, including required references. Descriptions may be shortened; metadata is not loaded instructions.\n" ++
        "<available_skills>\n";
    const footer = "</available_skills>\n";

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(alloc);
    var root_lines: std.ArrayList([]u8) = .empty;
    defer {
        for (root_lines.items) |line| alloc.free(line);
        root_lines.deinit(alloc);
    }
    var entries: std.ArrayList(SkillPromptEntry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    for (skills) |skill| {
        const root = std.fs.path.dirname(skill.path) orelse "";
        const root_index = index: {
            for (roots.items, 0..) |existing, index| {
                if (std.mem.eql(u8, existing, root)) break :index index;
            }
            const index = roots.items.len;
            var line: std.Io.Writer.Allocating = .init(alloc);
            defer line.deinit();
            try line.writer.print("Root {d}: ", .{index});
            try model_context_encoding.writeScalar(&line.writer, root);
            try line.writer.writeByte('\n');
            const owned = try line.toOwnedSlice();
            errdefer alloc.free(owned);
            try roots.append(alloc, root);
            try root_lines.append(alloc, owned);
            break :index index;
        };
        var prefix: std.Io.Writer.Allocating = .init(alloc);
        defer prefix.deinit();
        try prefix.writer.writeAll("- ");
        try model_context_encoding.writeScalar(&prefix.writer, skill.name);
        try prefix.writer.writeAll(": ");
        const owned_prefix = try prefix.toOwnedSlice();
        errdefer alloc.free(owned_prefix);

        var description: std.Io.Writer.Allocating = .init(alloc);
        defer description.deinit();
        const safe_description = try tool_result_limits.prepareRedactedOutput(alloc, skill.description);
        defer alloc.free(safe_description);
        var description_limited = false;
        if (limits.skill_description_bytes.source == .compiled_default) {
            const end = skillDescriptionPrefix(safe_description, 1024);
            try model_context_encoding.writeScalar(&description.writer, safe_description[0..end]);
            description_limited = end < safe_description.len;
        } else {
            const observed = try writeBoundedEncodedScalar(
                alloc,
                &description.writer,
                safe_description,
                limits.skill_description_bytes.effectiveBytes(),
            );
            description_limited = observed > description.written().len;
        }
        const owned_description = try description.toOwnedSlice();
        errdefer alloc.free(owned_description);

        var suffix: std.Io.Writer.Allocating = .init(alloc);
        defer suffix.deinit();
        try suffix.writer.print(" (location: skill:{x:0>16}:{d}/", .{ namespace, root_index });
        try (std.Uri.Component{ .raw = std.fs.path.basename(skill.path) }).formatEscaped(&suffix.writer);
        try suffix.writer.writeAll(")\n");
        const owned_suffix = try suffix.toOwnedSlice();
        errdefer alloc.free(owned_suffix);
        try entries.append(alloc, .{
            .prefix = owned_prefix,
            .description = owned_description,
            .suffix = owned_suffix,
            .root_count = roots.items.len,
            .description_limited = description_limited,
        });
    }

    const base_cost = budget.cost(header) + budget.cost(footer);
    var minimum_cost = base_cost;
    for (root_lines.items) |line| minimum_cost = try std.math.add(usize, minimum_cost, budget.cost(line));
    for (entries.items) |entry| minimum_cost = try std.math.add(
        usize,
        minimum_cost,
        budget.cost(entry.prefix) + budget.cost(entry.suffix),
    );
    var retained = entries.items.len;
    var retained_roots = roots.items.len;
    var marker: [128]u8 = undefined;
    var marker_text: []const u8 = "";
    if (minimum_cost > budget.limit) {
        retained = 0;
        retained_roots = 0;
        minimum_cost = base_cost;
        var candidate_cost = base_cost;
        var candidate_roots: usize = 0;
        for (entries.items, 0..) |entry, index| {
            for (root_lines.items[candidate_roots..entry.root_count]) |line| {
                candidate_cost = try std.math.add(usize, candidate_cost, budget.cost(line));
            }
            candidate_roots = entry.root_count;
            candidate_cost = try std.math.add(
                usize,
                candidate_cost,
                budget.cost(entry.prefix) + budget.cost(entry.suffix),
            );
            marker_text = try std.fmt.bufPrint(&marker, "Omitted skills: {d}.\n", .{entries.items.len - index - 1});
            if (candidate_cost + budget.cost(marker_text) > budget.limit) break;
            retained = index + 1;
            retained_roots = candidate_roots;
            minimum_cost = candidate_cost;
        }
        marker_text = try std.fmt.bufPrint(&marker, "Omitted skills: {d}.\n", .{entries.items.len - retained});
        minimum_cost += budget.cost(marker_text);
    }

    var available = budget.limit -| minimum_cost;
    var output_bytes = header.len + footer.len + marker_text.len;
    for (root_lines.items[0..retained_roots]) |line| output_bytes = try std.math.add(usize, output_bytes, line.len);
    for (entries.items[0..retained]) |entry| output_bytes = try std.math.add(
        usize,
        output_bytes,
        entry.prefix.len + entry.suffix.len,
    );
    var progress = true;
    while (progress and available > 0) {
        progress = false;
        for (entries.items[0..retained]) |*entry| {
            const rest = entry.description[entry.description_end..];
            if (rest.len == 0) continue;
            const length = encodedScalarLength(rest);
            const cost = budget.cost(rest[0..length]);
            if (cost > available or length > context_limits.emergency_ceiling_bytes -| output_bytes) continue;
            entry.description_end += length;
            available -= cost;
            output_bytes += length;
            progress = true;
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (minimum_cost <= budget.limit and output_bytes <= context_limits.emergency_ceiling_bytes) {
        try out.writer.writeAll(header);
        for (root_lines.items[0..retained_roots]) |line| try out.writer.writeAll(line);
        for (entries.items[0..retained]) |entry| {
            try out.writer.writeAll(entry.prefix);
            try out.writer.writeAll(entry.description[0..entry.description_end]);
            try out.writer.writeAll(entry.suffix);
        }
        try out.writer.writeAll(marker_text);
        try out.writer.writeAll(footer);
    } else {
        retained = 0;
        retained_roots = 0;
    }
    var description_shortened: usize = 0;
    var catalog_shortened: usize = 0;
    for (entries.items[0..retained]) |entry| {
        if (entry.description_limited) description_shortened += 1;
        if (entry.description_end < entry.description.len) catalog_shortened += 1;
    }
    const text = try out.toOwnedSlice();
    errdefer alloc.free(text);
    const owned_roots = try alloc.dupe([]const u8, roots.items[0..retained_roots]);
    errdefer alloc.free(owned_roots);
    var notices: std.Io.Writer.Allocating = .init(alloc);
    defer notices.deinit();
    if (description_shortened > 0) {
        try notices.writer.print("[context] skill descriptions shortened: {d}; source={s}\n", .{ description_shortened, limits.skill_description_bytes.source.label() });
    }
    if (catalog_shortened > 0) {
        try notices.writer.print("[context] skill catalog shortened {d} descriptions: effective={d} {s} source={s}\n", .{
            catalog_shortened, budget.limit, if (budget.characters) "characters" else "bytes", limits.skill_catalog_bytes.source.label(),
        });
    }
    if (retained < skills.len) {
        const omitted = skills[retained..];
        const shown = @min(omitted.len, catalog_notice_name_count);
        try notices.writer.print("[context] skill catalog omitted {d} entries (", .{omitted.len});
        for (omitted[0..shown], 0..) |skill, index| {
            if (index > 0) try notices.writer.writeAll(", ");
            try writeBoundedSkillName(alloc, &notices.writer, skill.name);
        }
        if (shown < omitted.len) try notices.writer.print(", +{d} more", .{omitted.len - shown});
        try notices.writer.print("): effective={d} {s} source={s}\n", .{
            budget.limit, if (budget.characters) "characters" else "bytes", limits.skill_catalog_bytes.source.label(),
        });
    }
    const notice = if (notices.written().len > 0) try notices.toOwnedSlice() else null;
    return .{
        .text = text,
        .notice = notice,
        .locations = .{ .namespace = namespace, .roots = owned_roots, .skills = skills },
    };
}

fn skillDescriptionPrefix(text: []const u8, max_characters: usize) usize {
    var offset: usize = 0;
    var characters: usize = 0;
    while (offset < text.len and characters < max_characters) : (characters += 1) {
        const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
        offset += @min(length, text.len - offset);
    }
    return offset;
}

fn encodedScalarLength(text: []const u8) usize {
    if (text[0] == '&') {
        if (std.mem.findScalar(u8, text, ';')) |end| return end + 1;
    }
    return @min(std.unicode.utf8ByteSequenceLength(text[0]) catch 1, text.len);
}

fn writeBoundedSkillName(alloc: Allocator, writer: *std.Io.Writer, name: []const u8) !void {
    const observed = try writeBoundedEncodedScalar(alloc, writer, name, skill_contract.max_name_bytes);
    if (observed > skill_contract.max_name_bytes) try writer.writeAll("...");
}

fn writeBoundedEncodedScalar(alloc: Allocator, writer: *std.Io.Writer, value: []const u8, max_bytes: usize) !usize {
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try model_context_encoding.writeScalar(&encoded.writer, value);
    const observed = encoded.written().len;
    var prefix_len = context_limits.utf8PrefixLength(encoded.written(), max_bytes);
    if (std.mem.lastIndexOfScalar(u8, encoded.written()[0..prefix_len], '&')) |amp_index| {
        if (std.mem.indexOfScalar(u8, encoded.written()[amp_index..prefix_len], ';') == null) {
            prefix_len = amp_index;
        }
    }
    try writer.writeAll(encoded.written()[0..prefix_len]);
    return observed;
}

pub fn freeSkill(alloc: Allocator, skill: Skill) void {
    alloc.free(skill.name);
    alloc.free(skill.description);
    alloc.free(skill.path);
    if (skill.read_authority) |read_authority| alloc.free(read_authority);
}

pub fn freeSkills(alloc: Allocator, skills: []Skill) void {
    for (skills) |skill| freeSkill(alloc, skill);
    if (skills.len == 0) return;
    alloc.free(skills);
}

pub fn freeSkillDiagnostics(alloc: Allocator, diagnostics: []SkillDiagnostic) void {
    for (diagnostics) |diagnostic| alloc.free(diagnostic.path);
    if (diagnostics.len == 0) return;
    alloc.free(diagnostics);
}

fn staticSkill(name: []const u8, description: []const u8, source: SkillSource) Skill {
    return .{
        .name = name,
        .description = description,
        .path = "",
        .source = source,
    };
}

test "skill name completion returns the first canonical prefix suffix" {
    const skills = [_]Skill{
        staticSkill("managed-menu", "", .global_fx),
        staticSkill("manual-review", "", .workspace_shared),
    };

    const completion = firstSkillNameCompletion(&skills, "MAN").?;
    try std.testing.expectEqualStrings("managed-menu", completion.skill.name);
    try std.testing.expectEqualStrings("aged-menu", completion.suffix);
}

test "skill name completion ignores empty exact and metadata-only matches" {
    const skills = [_]Skill{.{
        .name = "review",
        .description = "managed workflow",
        .path = "/tmp/managed-menu",
        .source = .global_fx,
    }};

    try std.testing.expectEqual(@as(?SkillNameCompletion, null), firstSkillNameCompletion(&skills, ""));
    try std.testing.expectEqual(@as(?SkillNameCompletion, null), firstSkillNameCompletion(&skills, "review"));
    try std.testing.expectEqual(@as(?SkillNameCompletion, null), firstSkillNameCompletion(&skills, "managed"));
}

const test_workspace_roots = [_]skill_contract.RootSpec{
    .{ .source = .workspace_shared, .path = "skills" },
    .{ .source = .workspace_codex, .path = ".codex/skills" },
    .{ .source = .workspace_agents, .path = ".agents/skills" },
};

const test_global_roots = [_]skill_contract.RootSpec{
    .{ .source = .global_codex, .path = ".codex/skills" },
    .{ .source = .global_agents, .path = ".agents/skills" },
};

const test_root_policy: skill_contract.RootPolicy = .{
    .workspace_roots = &test_workspace_roots,
    .managed_root_source = .global_fx,
    .global_roots = &test_global_roots,
};

const test_managed_root_policy: skill_contract.RootPolicy = .{
    .managed_root_source = .global_fx,
};

test "skill discovery bounds near-emergency valid metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "root/huge");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "root/huge/SKILL.md", .{});
        defer file.close(io_mod.getIo());
        const header = "---\nname: ";
        const footer = "\n---\nbody\n";
        try file.writeStreamingAll(io_mod.getIo(), header);
        const chunk: [16 * 1024]u8 = @splat('n');
        var remaining = context_limits.emergency_ceiling_bytes - header.len - footer.len - 1;
        while (remaining > 0) {
            const count = @min(remaining, chunk.len);
            try file.writeStreamingAll(io_mod.getIo(), chunk[0..count]);
            remaining -= count;
        }
        try file.writeStreamingAll(io_mod.getIo(), footer);
    }

    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "root");
    defer std.testing.allocator.free(root);
    var backing: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var discovery = try loadVisibleSkills(fixed.allocator(), null, null, root, test_managed_root_policy);
    defer discovery.deinit(fixed.allocator());

    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticCause.oversized, discovery.diagnostics[0].cause);
}

test "skill group labels distinguish managed workspace and compatibility roots" {
    try std.testing.expectEqualStrings("Managed installs", skillGroupLabel(.global_fx));
    try std.testing.expectEqualStrings("Workspace skills", skillGroupLabel(.workspace_shared));
    try std.testing.expectEqualStrings("Compatibility roots", skillGroupLabel(.workspace_agents));
    try std.testing.expectEqualStrings("Compatibility roots", skillGroupLabel(.global_claude));
    try std.testing.expectEqualStrings("Compatibility roots", skillGroupLabel(.global_codex));
}

test "skill display source is present only for ambiguous names" {
    const skills = [_]Skill{
        staticSkill("review", "managed skill", .global_fx),
        staticSkill("review", "workspace skill", .workspace_shared),
        staticSkill("deploy", "workspace skill", .workspace_shared),
    };

    try std.testing.expectEqual(SkillSource.global_fx, skillDisplaySource(&skills, skills[0]).?);
    try std.testing.expectEqual(SkillSource.workspace_shared, skillDisplaySource(&skills, skills[1]).?);
    try std.testing.expectEqual(@as(?SkillSource, null), skillDisplaySource(&skills, skills[2]));
}

test "skill menu display order groups by source without copying inventory" {
    const skills = [_]Skill{
        staticSkill("compat", "compatibility skill", .global_agents),
        staticSkill("workspace", "workspace skill", .workspace_shared),
        staticSkill("managed", "managed skill", .global_fx),
    };

    try std.testing.expectEqualStrings("managed", skillMenuSkillAt(&skills, .all, 0).?.name);
    try std.testing.expectEqualStrings("workspace", skillMenuSkillAt(&skills, .all, 1).?.name);
    try std.testing.expectEqualStrings("compat", skillMenuSkillAt(&skills, .all, 2).?.name);
    try std.testing.expectEqualStrings("compat", skillMenuSkillAt(&skills, .agents, 0).?.name);
    try std.testing.expect(skillMenuSkillAt(&skills, .codex, 0) == null);
}

test "skill menu query view preserves grouped display and actual indexes" {
    const skills = [_]Skill{
        staticSkill("review", "compatibility skill", .global_agents),
        staticSkill("review", "workspace skill", .workspace_shared),
        staticSkill("review", "managed skill", .global_fx),
        staticSkill("deploy", "managed skill", .global_fx),
    };

    try std.testing.expectEqual(@as(usize, 3), skillMenuFilterQueryCount(&skills, .all, "review"));
    try std.testing.expectEqual(@as(usize, 2), skillMenuActualIndexAtQuery(&skills, .all, "review", 0).?);
    try std.testing.expectEqual(@as(usize, 1), skillMenuActualIndexAtQuery(&skills, .all, "review", 1).?);
    try std.testing.expectEqual(@as(usize, 0), skillMenuActualIndexAtQuery(&skills, .all, "review", 2).?);
    try std.testing.expectEqual(@as(usize, 1), skillMenuDisplayIndexForActualQuery(&skills, .all, "review", 1).?);
    try std.testing.expect(skillMenuDisplayIndexForActualQuery(&skills, .all, "review", 3) == null);
    try std.testing.expectEqualStrings("managed skill", skillMenuSkillAtQuery(&skills, .all, "review", 0).?.description);
}

test "skill menu query ranks name matches before metadata matches" {
    const skills = [_]Skill{
        staticSkill("metadata-first", "zig workflow", .global_fx),
        staticSkill("contains-zig-name", "compatibility skill", .global_agents),
        staticSkill("zig-best-practices", "compatibility skill", .global_agents),
        staticSkill("workspace-zig-name", "workspace skill", .workspace_shared),
    };

    try std.testing.expectEqual(@as(usize, 4), skillMenuFilterQueryCount(&skills, .all, "zig"));
    try std.testing.expectEqualStrings("zig-best-practices", skillMenuSkillAtQuery(&skills, .all, "zig", 0).?.name);
    try std.testing.expectEqualStrings("workspace-zig-name", skillMenuSkillAtQuery(&skills, .all, "zig", 1).?.name);
    try std.testing.expectEqualStrings("contains-zig-name", skillMenuSkillAtQuery(&skills, .all, "zig", 2).?.name);
    try std.testing.expectEqualStrings("metadata-first", skillMenuSkillAtQuery(&skills, .all, "zig", 3).?.name);
    try std.testing.expectEqual(@as(usize, 2), skillMenuActualIndexAtQuery(&skills, .all, "zig", 0).?);
    try std.testing.expectEqual(@as(usize, 3), skillMenuDisplayIndexForActualQuery(&skills, .all, "zig", 0).?);
}

test "skill menu index materializes and reuses one stable query snapshot" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = "zig-best-practices", .description = "Zig guidance", .path = "/skills/zig", .source = .global_fx },
        .{ .name = "pure-core", .description = "Functional core", .path = "/skills/pure", .source = .global_codex },
        .{ .name = "zig-review", .description = "Review Zig", .path = "/skills/review", .source = .workspace_agents },
    };

    var index: SkillMenuIndex = .{};
    defer index.deinit(alloc);

    try index.rebuild(alloc, &skills, .all, "zig");
    try std.testing.expectEqual(@as(usize, 2), index.count());
    try std.testing.expectEqualStrings("zig-best-practices", index.skillAt(&skills, 0).?.name);
    try std.testing.expectEqualStrings("zig-review", index.skillAt(&skills, 1).?.name);
    const retained_ptr = index.actual_indices.items.ptr;
    const retained_capacity = index.actual_indices.capacity;

    try index.rebuild(alloc, &skills, .all, "core");
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expectEqualStrings("pure-core", index.skillAt(&skills, 0).?.name);
    try std.testing.expectEqual(retained_ptr, index.actual_indices.items.ptr);
    try std.testing.expectEqual(retained_capacity, index.actual_indices.capacity);
}

test "skill runtime keeps menu count selection and query on one index" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = "zig-best-practices", .description = "Zig guidance", .path = "/skills/zig", .source = .global_fx },
        .{ .name = "pure-core", .description = "Functional core", .path = "/skills/pure", .source = .global_codex },
        .{ .name = "zig-review", .description = "Review Zig", .path = "/skills/review", .source = .workspace_agents },
    };
    var runtime = Runtime{ .items = @constCast(&skills) };
    defer {
        runtime.items = &.{};
        runtime.deinit(alloc);
    }

    try runtime.prepareMenuIndex(alloc);
    runtime.openMenu();
    try std.testing.expectEqual(@as(usize, 3), runtime.menuItemCount());
    try std.testing.expectEqualStrings("zig-best-practices", runtime.selectedMenuSkill().?.name);

    runtime.setMenuQuery(alloc, "core");
    try std.testing.expectEqual(@as(usize, 1), runtime.menuItemCount());
    try std.testing.expectEqualStrings("pure-core", runtime.selectedMenuSkill().?.name);
    try std.testing.expectEqualSlices(u32, &.{1}, runtime.menu_index.actual_indices.items);
}

test "skill menu query navigation and close stay allocation free for ten thousand cycles" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = "alpha", .description = "first", .path = "/skills/alpha", .source = .global_fx },
        .{ .name = "beta", .description = "second", .path = "/skills/beta", .source = .global_codex },
        .{ .name = "gamma", .description = "third", .path = "/skills/gamma", .source = .workspace_agents },
    };
    var runtime = Runtime{ .items = @constCast(&skills) };
    defer {
        runtime.items = &.{};
        runtime.deinit(alloc);
    }
    try runtime.prepareMenuIndex(alloc);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });

    for (0..10_000) |cycle| {
        runtime.openMenu();
        runtime.setMenuQuery(
            failing.allocator(),
            if (cycle & 1 == 0) "a" else "",
        );
        _ = runtime.moveMenuSelection(1);
        _ = runtime.moveMenuSourceFilter(1);
        runtime.closeMenu();
    }
}

test "skill runtime replacement preserves the active catalog when index allocation fails" {
    const alloc = std.testing.allocator;
    const active = [_]Skill{
        .{ .name = "active", .description = "active", .path = "/skills/active", .source = .global_fx },
    };
    const replacement = [_]Skill{.{
        .name = "replacement",
        .description = "replacement",
        .path = "/skills/replacement",
        .source = .global_fx,
    }} ** 64;
    var runtime = Runtime{ .items = @constCast(&active) };
    defer {
        runtime.items = &.{};
        runtime.diagnostics = &.{};
        runtime.dir = &.{};
        runtime.deinit(alloc);
    }
    try runtime.prepareMenuIndex(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        runtime.replaceLoaded(
            failing.allocator(),
            @constCast("/replacement"),
            @constCast(&replacement),
            &.{},
        ),
    );
    try std.testing.expect(runtime.items.ptr == active[0..].ptr);
    try std.testing.expectEqual(@as(usize, 1), runtime.menu_index.count());
    try std.testing.expectEqualStrings("active", runtime.menu_index.skillAt(runtime.items, 0).?.name);
}

test "skill catalog lease keeps one retired generation alive until release" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    const first = try alloc.alloc(Skill, 1);
    first[0] = .{
        .name = try alloc.dupe(u8, "first"),
        .description = try alloc.dupe(u8, "first generation"),
        .path = try alloc.dupe(u8, "/skills/first"),
        .source = .global_fx,
    };
    try runtime.replaceLoaded(
        alloc,
        try alloc.dupe(u8, "/skills"),
        first,
        &.{},
    );

    var lease = runtime.acquireCatalog();
    var lease_owned = true;
    defer if (lease_owned) lease.deinit();
    const second = try alloc.alloc(Skill, 1);
    second[0] = .{
        .name = try alloc.dupe(u8, "second"),
        .description = try alloc.dupe(u8, "second generation"),
        .path = try alloc.dupe(u8, "/skills/second"),
        .source = .global_fx,
    };
    try runtime.replaceLoaded(
        alloc,
        try alloc.dupe(u8, "/skills"),
        second,
        &.{},
    );

    try std.testing.expectEqualStrings("first", lease.items[0].name);
    try std.testing.expectEqualStrings("second", runtime.items[0].name);
    try std.testing.expect(runtime.retired_catalog != null);
    lease.deinit();
    lease_owned = false;
    runtime.reapRetiredCatalog();
    try std.testing.expect(runtime.retired_catalog == null);
}

test "skill refresh publishes one generation and coalesces one latest request" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(
        &tmp,
        "home/.fx/skills/refreshable/SKILL.md",
        "---\nname: refreshable\ndescription: refreshed off-thread\n---\nbody\n",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills/added");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const managed = try std.fs.path.join(alloc, &.{ home, ".fx", "skills" });
    defer alloc.free(managed);
    var runtime = Runtime{ .dir = try alloc.dupe(u8, managed) };
    defer runtime.deinit(alloc);
    const policy: skill_contract.RootPolicy = .{ .managed_root_source = .global_fx };

    const first_generation = try runtime.requestRefresh(alloc, home, home, policy);
    const pending_generation = try runtime.requestRefresh(alloc, home, home, policy);
    try std.testing.expect(pending_generation > first_generation);
    try std.testing.expectEqual(
        pending_generation,
        runtime.refresh_pending.?.generation,
    );

    var adopted = false;
    for (0..100_000) |_| {
        switch (try runtime.pollRefresh(alloc, home, policy)) {
            .adopted => adopted = true,
            .none, .unchanged, .failed => {},
        }
        if (adopted and runtime.refresh_task == null) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expect(adopted);
    try std.testing.expectEqual(@as(usize, 1), runtime.items.len);
    try std.testing.expectEqualStrings("refreshable", runtime.items[0].name);

    var terminal: RefreshCompletion = .none;
    _ = try runtime.requestRefresh(alloc, home, home, policy);
    for (0..100_000) |_| {
        terminal = try runtime.pollRefresh(alloc, home, policy);
        if (terminal != .none) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(RefreshCompletion.unchanged, terminal);

    try writeTempFile(
        &tmp,
        "home/.fx/skills/refreshable/SKILL.md",
        "---\nname: refreshable-v2\ndescription: one-file delta refresh with a new size\n---\nbody changed\n",
    );
    _ = try runtime.requestRefresh(alloc, home, home, policy);
    for (0..100_000) |_| {
        terminal = try runtime.pollRefresh(alloc, home, policy);
        if (terminal != .none) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(RefreshCompletion.adopted, terminal);
    try std.testing.expectEqualStrings("refreshable-v2", runtime.items[0].name);

    try writeTempFile(
        &tmp,
        "home/.fx/skills/added/SKILL.md",
        "---\nname: added\ndescription: root manifest changed\n---\nbody\n",
    );
    _ = try runtime.requestRefresh(alloc, home, home, policy);
    for (0..100_000) |_| {
        terminal = try runtime.pollRefresh(alloc, home, policy);
        if (terminal != .none) break;
        std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    try std.testing.expectEqual(RefreshCompletion.adopted, terminal);
    try std.testing.expectEqual(@as(usize, 2), runtime.items.len);
}

test "overlapping skill refresh actions retain only the latest bounded action" {
    const alloc = std.testing.allocator;
    var runtime = Runtime{};
    defer runtime.deinit(alloc);

    try runtime.queueRefreshAction(alloc, 1, .list);
    try runtime.queueRefreshAction(alloc, 2, .{ .show = "newest" });
    runtime.fresh_through_generation = 2;

    var ready = runtime.takeReadyRefreshAction() orelse
        return error.MissingReadyRefreshAction;
    defer ready.deinit(alloc);
    try std.testing.expect(ready.succeeded);
    switch (ready.action) {
        .show => |name| try std.testing.expectEqualStrings("newest", name),
        else => return error.ExpectedLatestShowAction,
    }
}

test "skill menu fills a bounded query range in display order" {
    const skills = [_]Skill{
        staticSkill("metadata-first", "zig workflow", .global_fx),
        staticSkill("contains-zig-name", "compatibility skill", .global_agents),
        staticSkill("zig-best-practices", "compatibility skill", .global_agents),
        staticSkill("workspace-zig-name", "workspace skill", .workspace_shared),
    };

    var range: [3]*const Skill = undefined;
    try std.testing.expectEqual(
        @as(usize, range.len),
        fillSkillMenuRangeAtQuery(&skills, .all, "zig", 1, &range),
    );
    try std.testing.expectEqualStrings("workspace-zig-name", range[0].name);
    try std.testing.expectEqualStrings("contains-zig-name", range[1].name);
    try std.testing.expectEqualStrings("metadata-first", range[2].name);

    var filtered: [1]*const Skill = undefined;
    try std.testing.expectEqual(
        @as(usize, filtered.len),
        fillSkillMenuRangeAtQuery(&skills, .agents, "zig", 0, &filtered),
    );
    try std.testing.expectEqualStrings("zig-best-practices", filtered[0].name);

    var past_end: [2]*const Skill = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        fillSkillMenuRangeAtQuery(&skills, .all, "zig", skills.len, &past_end),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        fillSkillMenuRangeAtQuery(&skills, .all, "zig", 0, &.{}),
    );
}

test "skill menu empty query and source filters preserve source grouping" {
    const skills = [_]Skill{
        staticSkill("compat", "zig compatibility", .global_agents),
        staticSkill("workspace", "zig workspace", .workspace_shared),
        staticSkill("managed", "zig managed", .global_fx),
    };

    try std.testing.expectEqualStrings("managed", skillMenuSkillAtQuery(&skills, .all, "", 0).?.name);
    try std.testing.expectEqualStrings("workspace", skillMenuSkillAtQuery(&skills, .all, "", 1).?.name);
    try std.testing.expectEqualStrings("compat", skillMenuSkillAtQuery(&skills, .all, "", 2).?.name);
    try std.testing.expectEqualStrings("compat", skillMenuSkillAtQuery(&skills, .agents, "zig", 0).?.name);
    try std.testing.expectEqual(@as(usize, 1), skillMenuFilterQueryCount(&skills, .agents, "zig"));
}

test "skill menu opens focuses moves and clamps loaded items" {
    const skills = [_]Skill{
        staticSkill("managed", "managed skill", .global_fx),
        staticSkill("workspace", "workspace skill", .workspace_shared),
        staticSkill("compat", "compatibility skill", .global_agents),
    };
    var runtime = Runtime{ .items = @constCast(&skills) };

    runtime.openMenu();
    try std.testing.expect(runtime.menu.active);
    try std.testing.expectEqual(@as(usize, 0), runtime.menu.selected_index);
    try std.testing.expectEqualStrings("managed", runtime.selectedMenuSkill().?.name);

    // Up from the top clamps instead of wrapping to the last item.
    try std.testing.expect(runtime.moveMenuSelection(-1));
    try std.testing.expectEqual(@as(usize, 0), runtime.menu.selected_index);
    try std.testing.expectEqualStrings("managed", runtime.selectedMenuSkill().?.name);

    // Down past the last item clamps on the last skill.
    try std.testing.expect(runtime.moveMenuSelection(1));
    try std.testing.expect(runtime.moveMenuSelection(1));
    try std.testing.expect(runtime.moveMenuSelection(1));
    try std.testing.expectEqual(@as(usize, 2), runtime.menu.selected_index);
    try std.testing.expectEqualStrings("compat", runtime.selectedMenuSkill().?.name);

    try std.testing.expect(runtime.openMenuFocusedByName("workspace"));
    try std.testing.expectEqual(SkillMenuSourceFilter.workspace, runtime.menu.source_filter);
    try std.testing.expectEqual(@as(usize, 0), runtime.menu.selected_index);
    try std.testing.expectEqualStrings("workspace", runtime.selectedMenuSkill().?.name);

    try std.testing.expect(runtime.moveMenuSourceFilter(1));
    try std.testing.expectEqual(SkillMenuSourceFilter.claude, runtime.menu.source_filter);
    try std.testing.expect(runtime.selectedMenuSkill() == null);
    try std.testing.expect(runtime.moveMenuSourceFilter(-1));
    try std.testing.expectEqual(SkillMenuSourceFilter.workspace, runtime.menu.source_filter);
    try std.testing.expectEqualStrings("workspace", runtime.selectedMenuSkill().?.name);

    runtime.items = runtime.items[0..1];
    runtime.menu.source_filter = .all;
    runtime.menu.clamp(runtime.items);
    try std.testing.expect(runtime.menu.active);
    try std.testing.expectEqual(@as(usize, 0), runtime.menu.selected_index);
    try std.testing.expectEqualStrings("managed", runtime.selectedMenuSkill().?.name);

    runtime.closeMenu();
    try std.testing.expect(!runtime.menu.active);
    try std.testing.expect(runtime.selectedMenuSkill() == null);
}

test "skill menu visibility hides only zero-result mention queries" {
    const skills = [_]Skill{
        staticSkill("managed", "managed skill", .global_fx),
        staticSkill("workspace", "workspace skill", .workspace_shared),
    };
    var runtime = Runtime{ .items = @constCast(&skills) };

    try std.testing.expect(!runtime.menuVisible());

    runtime.openMenuWithQuery(.command, null, "missing");
    try std.testing.expect(runtime.menuVisible());

    runtime.openMenuWithQuery(.dollar, .{ .start = 4, .end = 5 }, "");
    try std.testing.expect(runtime.menuVisible());

    runtime.menu.setQuery("missing");
    try std.testing.expect(!runtime.menuVisible());

    runtime.menu.setQuery("managed");
    runtime.menu.source_filter = .claude;
    try std.testing.expect(runtime.selectedMenuSkill() == null);
    try std.testing.expect(runtime.menuVisible());

    runtime.closeMenu();
    try std.testing.expect(!runtime.menuVisible());
}

test "skill menu movement uses rendered visible rows before scrolling" {
    const skills = [_]Skill{
        staticSkill("skill-00", "skill 00", .global_fx),
        staticSkill("skill-01", "skill 01", .global_fx),
        staticSkill("skill-02", "skill 02", .global_fx),
        staticSkill("skill-03", "skill 03", .global_fx),
        staticSkill("skill-04", "skill 04", .global_fx),
        staticSkill("skill-05", "skill 05", .global_fx),
        staticSkill("skill-06", "skill 06", .global_fx),
        staticSkill("skill-07", "skill 07", .global_fx),
        staticSkill("skill-08", "skill 08", .global_fx),
        staticSkill("skill-09", "skill 09", .global_fx),
    };
    var runtime = Runtime{ .items = @constCast(&skills) };

    runtime.openMenu();
    const visible_rows: u16 = 8;

    var move_count: usize = 0;
    while (move_count < visible_rows - 1) : (move_count += 1) {
        try std.testing.expect(runtime.moveMenuSelectionVisibleRows(1, visible_rows));
        try std.testing.expectEqual(move_count + 1, runtime.menu.selected_index);
        try std.testing.expectEqual(@as(usize, 0), runtime.menu.window_start);
    }

    try std.testing.expect(runtime.moveMenuSelectionVisibleRows(1, visible_rows));
    try std.testing.expectEqual(@as(usize, 8), runtime.menu.selected_index);
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.window_start);

    try std.testing.expect(runtime.moveMenuSelectionVisibleRows(-1, visible_rows));
    try std.testing.expectEqual(@as(usize, 7), runtime.menu.selected_index);
    try std.testing.expectEqual(@as(usize, 1), runtime.menu.window_start);
}

test "skill menu focus refuses an ambiguous duplicate name" {
    const skills = [_]Skill{
        staticSkill("review", "managed wins", .global_fx),
        staticSkill("review", "compat duplicate", .global_agents),
    };
    var runtime = Runtime{ .items = @constCast(&skills) };

    try std.testing.expect(!runtime.openMenuFocusedByName("review"));
    try std.testing.expect(!runtime.menu.active);
}

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

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn createTempFifoOrSkip(alloc: Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) {
        return error.SkipZigTest;
    }
    if (std.fs.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, sub_path });
    defer alloc.free(path);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    if (mkfifo(path_z, 0o600) != 0) return error.SkipZigTest;
}

fn openFileDescriptorCount() !usize {
    const path = switch (@import("builtin").os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => return error.SkipZigTest,
    };
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{ .iterate = true });
    defer dir.close(io_mod.getIo());
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |_| count += 1;
    return count;
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

test "skill runtime replaces and frees owned discovery diagnostics" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinit(alloc);

    const first_dir = try alloc.dupe(u8, "/tmp/first-skills");
    const first_diagnostics = try alloc.alloc(SkillDiagnostic, 1);
    first_diagnostics[0] = .{
        .path = try alloc.dupe(u8, "/tmp/first-skills/bad"),
        .source = .global_fx,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    };
    try runtime.replaceLoaded(alloc, first_dir, &.{}, first_diagnostics);

    try std.testing.expectEqual(@as(usize, 1), runtime.diagnostics.len);
    try std.testing.expectEqualStrings("/tmp/first-skills/bad", runtime.diagnostics[0].path);

    try runtime.replaceLoaded(
        alloc,
        try alloc.dupe(u8, "/tmp/second-skills"),
        &.{},
        &.{},
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.diagnostics.len);
}

test "explicit skill matching finds multiple mentions in request order" {
    const skills = [_]Skill{
        staticSkill("review", "review help", .workspace_shared),
        staticSkill("release", "release help", .global_fx),
    };
    const alloc = std.testing.allocator;
    const indices = try matchExplicitSkillIndices(alloc, "Please work with $release, then $review and $release again.", &skills);
    defer alloc.free(indices);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, indices);
}

test "explicit dollar references do not select a composite natural language name" {
    const skills = [_]Skill{
        staticSkill("release", "release", .global_fx),
        staticSkill("review", "review", .global_fx),
        staticSkill("release and review", "unrelated composite name", .global_fx),
    };
    const alloc = std.testing.allocator;
    const indices = try matchExplicitSkillIndices(alloc, "Use $release and $review skill", &skills);
    defer alloc.free(indices);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, indices);
}

test "explicit skill matching accepts sigils and verbs without fuzzy activation" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("review", "review help", .workspace_shared),
        staticSkill("release-notes", "release help", .global_fx),
    };
    const cases = [_]struct {
        prompt: []const u8,
        expected: usize,
    }{
        .{ .prompt = "$review inspect this patch", .expected = 0 },
        .{ .prompt = "please use the release-notes skill", .expected = 1 },
        .{ .prompt = "apply review skill", .expected = 0 },
        .{ .prompt = "activate the review skill", .expected = 0 },
        .{ .prompt = "invoke release_notes skill", .expected = 1 },
        .{ .prompt = "run the release notes skill for this patch", .expected = 1 },
        .{ .prompt = "/review inspect this patch", .expected = 0 },
    };
    for (cases) |case| {
        const indices = try matchExplicitSkillIndices(alloc, case.prompt, &skills);
        defer alloc.free(indices);
        try std.testing.expectEqual(@as(usize, 1), indices.len);
        try std.testing.expectEqual(case.expected, indices[0]);
    }

    const fuzzy = try matchExplicitSkillIndices(alloc, "review this patch and write release notes", &skills);
    defer alloc.free(fuzzy);
    try std.testing.expectEqual(@as(usize, 0), fuzzy.len);
}

test "explicit skill matching parses natural language once for a large catalog" {
    const catalog_size = 128;
    const target_index = 73;
    var name_storage: [catalog_size][32]u8 = undefined;
    var skills: [catalog_size]Skill = undefined;
    for (&skills, 0..) |*skill, index| {
        const name = if (index == target_index)
            "release-notes"
        else
            try std.fmt.bufPrint(&name_storage[index], "catalog-skill-{d}", .{index});
        skill.* = staticSkill(name, "", .workspace_shared);
    }

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocation_count = count: {
        const matches = try matchExplicitSkillIndices(
            counting.allocator(),
            "Please invoke the release_notes skill for this patch.",
            &skills,
        );
        defer counting.allocator().free(matches);
        try std.testing.expectEqualSlices(usize, &.{target_index}, matches);
        break :count counting.alloc_index;
    };

    try std.testing.expect(allocation_count < catalog_size);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
}

test "explicit skill matching ignores negated quoted and pasted references" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("review", "review help", .workspace_shared),
    };
    const prompts = [_][]const u8{
        "Do not use the review skill.",
        "Please do not apply the review skill.",
        "Explain why \"use the review skill\" is unsafe.",
        "\"use the review skill\" is only an example.",
        "A pasted example says: use the review skill.",
        "Please use the reviewer skill.",
        "Please use the review skills.",
        "Please use the review skillful workflow.",
        "Do not $review this patch.",
        "Do not use $review for this patch.",
        "The escaped \\$review stays text.",
        "The quoted \"$review\" stays text.",
        "The literal `$review` should remain text.",
    };

    for (prompts) |prompt| {
        const indices = try matchExplicitSkillIndices(alloc, prompt, &skills);
        defer alloc.free(indices);
        try std.testing.expectEqual(@as(usize, 0), indices.len);
    }
}

test "explicit skill matching preserves never negation across invocation forms" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("acceptance-workflow", "workflow help", .workspace_shared),
    };
    const prompts = [_][]const u8{
        "Never use $acceptance-workflow. Calculate 17 times 19 and do not modify files.",
        "Never $acceptance-workflow.",
        "Never apply $acceptance-workflow.",
        "Never invoke $acceptance-workflow.",
        "Never run $acceptance-workflow.",
        "Never activate $acceptance-workflow.",
        "Never use the $acceptance-workflow.",
        "NEVER USE $acceptance-workflow.",
    };
    for (prompts) |prompt| {
        const indices = try matchExplicitSkillIndices(alloc, prompt, &skills);
        defer alloc.free(indices);
        try std.testing.expectEqual(@as(usize, 0), indices.len);
    }
    const positive = try matchExplicitSkillIndices(alloc, "Never modify files; use $acceptance-workflow to review them.", &skills);
    defer alloc.free(positive);
    try std.testing.expectEqualSlices(usize, &.{0}, positive);
}

test "explicit skill matching excludes Markdown code spans with matching delimiter runs" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("review", "review help", .workspace_shared),
        staticSkill("release", "release help", .global_fx),
    };
    const prompts = [_][]const u8{
        "The literal ``$review`` stays text; use $release.",
        "Literal ``a ` $review ` value``; use $release.",
        "Literal `a `` $review `` value`; use $release.",
        "Literal ``a \\` $review value``; use $release.",
        "Literal ``first\n$review\nlast``; use $release.",
    };
    for (prompts) |prompt| {
        const indices = try matchExplicitSkillIndices(alloc, prompt, &skills);
        defer alloc.free(indices);
        try std.testing.expectEqualSlices(usize, &.{1}, indices);
    }
}

test "explicit skill matching excludes Markdown fenced code through its closing fence" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("review", "review help", .workspace_shared),
        staticSkill("release", "release help", .global_fx),
    };
    const prompts = [_][]const u8{
        "Example:\n```sh\nprintf '`'\n$review\n```\nUse $release.",
        "Example:\n~~~sh\n$review\n~~~\nUse $release.",
        "  ~~~~sh\n$review\n~~~\n$review\n  ~~~~~\nUse $release.",
        "```sh\n~~~\n$review\n``` trailing text\n$review\n```\nUse $release.",
        "```sh\n$review\n    ```\n$review\n   ```\nUse $release.",
        "~~~sh\r\n$review\r\n~~~ \t\r\nUse $release.",
        "Use $release.\n~~~\n$review\nNo closing fence",
    };
    for (prompts) |prompt| {
        const indices = try matchExplicitSkillIndices(alloc, prompt, &skills);
        defer alloc.free(indices);
        try std.testing.expectEqualSlices(usize, &.{1}, indices);
    }
}

test "explicit skill matching refuses ambiguous duplicate names" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("review", "workspace", .workspace_shared),
        staticSkill("review", "global", .global_fx),
    };
    const indices = try matchExplicitSkillIndices(alloc, "$review", &skills);
    defer alloc.free(indices);
    try std.testing.expectEqual(@as(usize, 0), indices.len);
}

test "skill diagnostic summary identifies candidate and root consequences" {
    const diagnostics = [_]SkillDiagnostic{
        .{
            .path = "/tmp/hostile\npath/body-sentinel",
            .source = .workspace_shared,
            .scope = .candidate,
            .cause = .{ .invalid_metadata = .missing_name },
        },
        .{
            .path = "/tmp/unreadable-root",
            .source = .global_fx,
            .scope = .root,
            .cause = .unreadable,
        },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try writeDiagnosticSummary(std.testing.allocator, &out.writer, &diagnostics);

    try std.testing.expect(std.mem.find(u8, out.written(), "candidate \"/tmp/hostile&#x0a;path/body-sentinel\" was skipped") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "metadata is invalid (missing_name)") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "optional inline description or a >, >-, or | block") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "inventory incomplete because root \"/tmp/unreadable-root\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "unknown number of skills may be missing") != null);
    try std.testing.expect(std.mem.findScalar(u8, out.written(), '\n') == null);
}

test "skill diagnostic summary escapes the active trace path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "hostile\ntrace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "skills");

    const diagnostics = [_]SkillDiagnostic{.{
        .path = "/tmp/candidate-is-visible",
        .source = .workspace_shared,
        .scope = .candidate,
        .cause = .{ .invalid_metadata = .missing_name },
    }};
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeDiagnosticSummary(alloc, &out.writer, &diagnostics);

    try std.testing.expect(std.mem.find(u8, out.written(), "hostile\\ntrace.log") != null);
    try std.testing.expect(std.mem.findScalar(u8, out.written(), '\n') == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "candidate-is-visible") != null);
}

test "skill diagnostic summary reports exact omitted count and metadata limit" {
    var diagnostics: [6]SkillDiagnostic = undefined;
    for (&diagnostics) |*diagnostic| {
        diagnostic.* = .{
            .path = "/tmp/oversized",
            .source = .workspace_shared,
            .scope = .candidate,
            .cause = .oversized,
        };
    }
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeDiagnosticSummary(std.testing.allocator, &out.writer, &diagnostics);

    try std.testing.expect(std.mem.find(u8, out.written(), "frontmatter exceeds the supported 65536-byte metadata header") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "2 additional diagnostics omitted") != null);
}

test "skill diagnostic trace preserves every exact path as one escaped line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "skill-diagnostics.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "skills");

    var diagnostics: [18]SkillDiagnostic = undefined;
    for (&diagnostics) |*diagnostic| {
        diagnostic.* = .{
            .path = "/tmp/plain",
            .source = .workspace_shared,
            .scope = .candidate,
            .cause = .{ .invalid_metadata = .missing_name },
        };
    }
    var hostile_path: [700]u8 = undefined;
    @memset(&hostile_path, 'a');
    const prefix = "/tmp/";
    @memcpy(hostile_path[0..prefix.len], prefix);
    const suffix = "\ntrail-\"\xc3\xa9";
    @memcpy(hostile_path[hostile_path.len - suffix.len ..], suffix);
    diagnostics[diagnostics.len - 1].path = &hostile_path;

    traceDiagnostics("test", &diagnostics);
    debug_trace.shutdown();

    const trace = try readAbsoluteFile(alloc, trace_path, 64 * 1024);
    defer alloc.free(trace);
    try std.testing.expectEqual(diagnostics.len, std.mem.count(u8, trace, " kind="));
    try std.testing.expect(std.mem.find(u8, trace, "\\ntrail-\\\"\\xc3\\xa9\" path_bytes=700") != null);
    try std.testing.expect(std.mem.find(u8, trace, "omitted=") == null);
}

test "listSkillsSummary empty" {
    const alloc = std.testing.allocator;
    const result = try listSkillsSummary(alloc, &.{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("No skills available.\n", result);
}

test "listSkillsSummary with skills" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("managed", "installed", .global_fx),
        staticSkill("local", "", .workspace_shared),
        staticSkill("compat", "external", .global_agents),
    };
    const result = try listSkillsSummary(alloc, &skills);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(
        \\Visible skills (3):
        \\
        \\Managed installs (1):
        \\  - managed: installed [global ~/.fx/skills]
        \\
        \\Workspace skills (1):
        \\  - local [workspace skills/]
        \\
        \\Compatibility roots (1):
        \\  - compat: external [global ~/.agents/skills]
        \\
    , result);
}

test "listSkillsSummaryStyled dims only source labels" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        staticSkill("managed", "installed", .global_fx),
    };
    const result = try listSkillsSummaryStyled(alloc, &skills, .{
        .source_label_style = "\x1b[38;5;245m",
        .reset_style = "\x1b[0m",
    });
    defer alloc.free(result);

    try std.testing.expect(std.mem.find(u8, result, "  - managed: installed \x1b[38;5;245m[global ~/.fx/skills]\x1b[0m\n") != null);
    try std.testing.expect(std.mem.find(u8, result, "\x1b[38;5;245mmanaged") == null);
    try std.testing.expect(std.mem.find(u8, result, "\x1b[38;5;245minstalled") == null);
}

test "buildSkillsSystemPromptSection with no skills" {
    const alloc = std.testing.allocator;
    var result = try buildSkillsSystemPromptSectionWithLimits(alloc, &.{}, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("", result.text);
}

test "buildSkillsSystemPromptSection includes all visible skills without active indices" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = "deploy", .description = "deployment help", .path = "/tmp/deploy", .source = .workspace_shared },
        .{ .name = "review", .description = "review help", .path = "/tmp/review", .source = .global_fx },
    };
    var result = try buildSkillsSystemPromptSectionWithLimits(alloc, &skills, .{});
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, result.text, "<available_skills>") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "- deploy: deployment help") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "- review: review help") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "Explicitly referenced skills") == null);
    try std.testing.expect(std.mem.find(u8, result.text, "Run deploy steps") == null);
}

test "skill catalog uses model capacity and preserves explicit byte overrides" {
    const alloc = std.testing.allocator;
    var storage: [16][24]u8 = undefined;
    var skills: [16]Skill = undefined;
    for (&skills, 0..) |*skill, index| {
        const name = try std.fmt.bufPrint(&storage[index], "entry-{d}", .{index});
        skill.* = .{ .name = name, .description = "useful instructions " ** 80, .path = name, .source = .global_fx };
    }
    var unknown = try buildSkillPrompt(alloc, &skills, &.{}, .{}, null);
    defer unknown.deinit(alloc);
    var large = try buildSkillPrompt(alloc, &skills, &.{}, .{}, 200_000);
    defer large.deinit(alloc);
    try std.testing.expect(unknown.text.len <= 8000);
    try std.testing.expect(large.text.len > unknown.text.len);
    try std.testing.expect(large.text.len <= 16000);
    var limits = context_limits.Values{};
    limits.skill_catalog_bytes = .{ .value = .{ .bytes = 1600 }, .source = .user_global };
    var small = try buildSkillPrompt(alloc, &skills, &.{}, limits, 200_000);
    defer small.deinit(alloc);
    var same = try buildSkillPrompt(alloc, &skills, &.{}, limits, 1_000_000);
    defer same.deinit(alloc);
    try std.testing.expectEqualStrings(small.text, same.text);
    try std.testing.expect(small.text.len <= 1600);
}

test "skill catalog locations reject a changed identity mapping" {
    const alloc = std.testing.allocator;
    const first = [_]Skill{.{ .name = "review", .description = "Review", .path = "/first/review", .source = .global_fx }};
    const changed = [_]Skill{.{ .name = "review", .description = "Review", .path = "/second/review", .source = .global_fx }};
    var before = try buildSkillPrompt(alloc, &first, &.{}, .{}, null);
    defer before.deinit(alloc);
    var after = try buildSkillPrompt(alloc, &changed, &.{}, .{}, null);
    defer after.deinit(alloc);
    const location = try std.fmt.allocPrint(alloc, "skill:{x:0>16}:0/review", .{before.locations.namespace});
    defer alloc.free(location);
    const resolved = try before.locations.resolve(alloc, location);
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("/first/review", resolved);
    try std.testing.expectError(error.StaleSkillLocation, after.locations.resolve(alloc, location));
}

test "skill catalog does not expose sensitive descriptions or encoded locations" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = "safe", .description = "Release checks. API_KEY=description-secret", .path = "/root/safe", .source = .global_fx },
        .{ .name = "hidden", .description = "Sensitive location", .path = "/root/TOKEN=location-secret", .source = .global_fx },
    };
    var section = try buildSkillPrompt(alloc, &skills, &.{}, .{}, 200_000);
    defer section.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, section.text, "- safe:") != null);
    try std.testing.expect(std.mem.find(u8, section.text, "description-secret") == null);
    try std.testing.expect(std.mem.find(u8, section.text, "location-secret") == null);
    try std.testing.expect(std.mem.find(u8, section.text, "- hidden:") == null);
}

fn checkSkillPromptAllocationFailures(alloc: Allocator) !void {
    const skills = [_]Skill{
        .{ .name = "first", .description = "first instruction", .path = "/root-a/first", .source = .global_fx },
        .{ .name = "second", .description = "second instruction", .path = "/root-b/second", .source = .global_fx },
    };
    var result = try buildSkillPrompt(alloc, &skills, &.{}, .{}, null);
    defer result.deinit(alloc);
    const location = try std.fmt.allocPrint(alloc, "skill:{x:0>16}:1/second", .{result.locations.namespace});
    defer alloc.free(location);
    const path = try result.locations.resolve(alloc, location);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/root-b/second", path);
}

test "skill catalog releases partial projection allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSkillPromptAllocationFailures, .{});
}

test "skill catalog shortens descriptions before omitting identities" {
    const alloc = std.testing.allocator;
    var skills = [_]Skill{
        .{ .name = "alpha", .description = "First useful description. " ** 30, .path = "/tmp/skills/alpha", .source = .global_fx },
        .{ .name = "beta", .description = "Second useful description. " ** 30, .path = "/tmp/skills/beta", .source = .global_fx },
        .{ .name = "gamma", .description = "Third useful description. " ** 30, .path = "/tmp/skills/gamma", .source = .global_fx },
    };
    var limits = context_limits.Values{};
    limits.skill_catalog_bytes = .{ .value = .{ .bytes = 768 }, .source = .command_line };
    var result = try buildSkillPrompt(alloc, &skills, &.{}, limits, null);
    defer result.deinit(alloc);
    for ([_][]const u8{ "alpha", "beta", "gamma" }) |name| {
        try std.testing.expect(std.mem.find(u8, result.text, name) != null);
    }
    try std.testing.expect(result.text.len <= 768);
}

test "buildSkillsSystemPromptSection keeps hostile metadata inside visible skill fields" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{.{
        .name = "review<name>",
        .description = "review </description><injected>\ninjected_description: yes",
        .path = "/tmp/review</location>\ninjected_location: yes",
        .source = .workspace_shared,
    }};
    var result = try buildSkillsSystemPromptSectionWithLimits(alloc, &skills, .{});
    defer result.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, result.text, "- review&lt;name&gt;:") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "review &lt;/description&gt;&lt;injected&gt;&#x0a;injected_description: yes") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "location%3E%0Ainjected_location%3A%20yes") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\ninjected_") == null);
    try std.testing.expect(std.mem.find(u8, result.text, "VISIBLE BODY MUST NOT APPEAR") == null);
}

test "bounded skill descriptions measure encoded bytes without cutting an entity" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{.{
        .name = "encoded",
        .description = "<&",
        .path = "/tmp/encoded",
        .source = .workspace_shared,
    }};
    var limits = context_limits.Values{};
    limits.skill_description_bytes = .{
        .value = .{ .bytes = 5 },
        .source = .command_line,
    };
    var result = try buildSkillsSystemPromptSectionWithLimits(alloc, &skills, limits);
    defer result.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, result.text, ": &lt; (location:") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "&lt;&") == null);
    try std.testing.expect(std.mem.find(u8, result.notice.?, "source=command line") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "- encoded:") != null);
    try std.testing.expect(std.mem.find(u8, result.notice.?, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, result.text, "BODY MUST NOT APPEAR") == null);
}

test "skill catalog one-byte overflow reports every omitted name in stable order" {
    const alloc = std.testing.allocator;
    const skills = [_]Skill{
        .{ .name = "first", .description = "one", .path = "/tmp/first", .source = .workspace_shared },
        .{ .name = "second", .description = "two", .path = "/tmp/second", .source = .global_fx },
    };
    var exact = try buildSkillsSystemPromptSectionWithLimits(alloc, skills[0..1], .{});
    defer exact.deinit(alloc);
    var limits = context_limits.Values{};
    limits.skill_catalog_bytes = .{
        .value = .{ .bytes = exact.text.len - 1 },
        .source = .user_workspace,
    };
    var result = try buildSkillsSystemPromptSectionWithLimits(alloc, &skills, limits);
    defer result.deinit(alloc);

    try std.testing.expect(result.notice != null);
    try std.testing.expect(std.mem.find(u8, result.notice.?, "first, second") != null);
    try std.testing.expect(std.mem.find(u8, result.notice.?, "source=workspace settings") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "FIRST BODY") == null);
    try std.testing.expect(std.mem.find(u8, result.text, "SECOND BODY") == null);
    try std.testing.expect(result.text.len <= limits.skill_catalog_bytes.effectiveBytes());
    if (std.mem.find(u8, result.text, "<context_limit")) |_| {
        try std.testing.expect(std.mem.find(u8, result.text, "omitted_count=") != null);
        try std.testing.expect(std.mem.find(u8, result.text, "/>\n") != null);
        try std.testing.expect(std.mem.find(u8, result.text, "omitted_names") == null);
    }
    if (std.mem.find(u8, result.text, "<available_skills>")) |_| {
        try std.testing.expect(std.mem.find(u8, result.text, "</available_skills>") != null);
    }

    limits.skill_catalog_bytes = .{ .value = .{ .bytes = 0 }, .source = .command_line };
    var zero = try buildSkillsSystemPromptSectionWithLimits(alloc, &skills, limits);
    defer zero.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), zero.text.len);
    try std.testing.expect(std.mem.find(u8, zero.notice.?, "first, second") != null);
}

test "skill catalog omission notices bound hostile names and list length" {
    const alloc = std.testing.allocator;
    const huge_name = "n" ** 4096;
    var skills: [20]Skill = undefined;
    for (&skills) |*skill| skill.* = staticSkill(huge_name, "", .workspace_shared);
    var limits = context_limits.Values{};
    limits.skill_catalog_bytes = .{ .value = .{ .bytes = 0 }, .source = .command_line };

    var result = try buildSkillsSystemPromptSectionWithLimits(alloc, &skills, limits);
    defer result.deinit(alloc);

    const notice = result.notice orelse return error.TestExpectedEqual;
    try std.testing.expect(notice.len < 16 * 1024);
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, notice, "n" ** skill_contract.max_name_bytes));
    try std.testing.expect(std.mem.find(u8, notice, "+12 more") != null);
}

test "skill discovery decodes supported descriptions and isolates malformed neighbors" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "root/folded/SKILL.md",
        "---\nname: folded\ndescription: >\n  first line\n  second line\n\n  next paragraph\n---\nbody\n",
    );
    try writeTempFile(
        &tmp,
        "root/literal/SKILL.md",
        "---\nname: literal\ndescription: |\n  first line\n  second line\n---\nbody\n",
    );
    try writeTempFile(
        &tmp,
        "root/inline/SKILL.md",
        "---\nname: inline\ndescription: keeps  internal   spaces\n---\nbody\n",
    );
    try writeTempFile(
        &tmp,
        "root/bad/SKILL.md",
        "---\nname: bad\ndescription: >\n   first\n  smaller indent\n---\nbody\n",
    );

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);

    var discovery = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), discovery.skills.len);
    try std.testing.expectEqualStrings(
        "keeps  internal   spaces",
        findSkillByName(discovery.skills, "inline").?.description,
    );
    try std.testing.expectEqualStrings(
        "first line second line\n\nnext paragraph\n",
        findSkillByName(discovery.skills, "folded").?.description,
    );
    try std.testing.expectEqualStrings(
        "first line\nsecond line\n",
        findSkillByName(discovery.skills, "literal").?.description,
    );
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(
        SkillDiagnosticCause{ .invalid_metadata = .unsupported_multiline },
        discovery.diagnostics[0].cause,
    );
}

test "loadVisibleSkills scans only roots supplied by policy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/workspace/app/custom-skills/injected/SKILL.md", "---\nname: injected\ndescription: selected by policy\n---\nbody\n");
    try writeTempFile(&tmp, "home/workspace/app/skills/ignored/SKILL.md", "---\nname: ignored\ndescription: not selected\n---\nbody\n");
    try writeTempFile(&tmp, "home/.fx/skills/ignored-managed/SKILL.md", "---\nname: ignored-managed\ndescription: not selected\n---\nbody\n");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace/app");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    const workspace_roots = [_]skill_contract.RootSpec{
        .{ .source = .workspace_claw, .path = "custom-skills" },
    };
    const root_policy: skill_contract.RootPolicy = .{
        .workspace_roots = &workspace_roots,
        .managed_root_source = null,
    };

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqualStrings("injected", discovery.skills[0].name);
    try std.testing.expectEqual(SkillSource.workspace_claw, discovery.skills[0].source);
    try std.testing.expect(findSkillByName(discovery.skills, "ignored") == null);
    try std.testing.expect(findSkillByName(discovery.skills, "ignored-managed") == null);
}

test "loadVisibleSkills preserves root-distinct duplicate skill names" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/workspace/app/.agents/skills/review/SKILL.md", "---\nname: review\ndescription: closest\n---\n\nclosest body\n");
    try writeTempFile(&tmp, "home/workspace/.agents/skills/review/SKILL.md", "---\nname: review\ndescription: ancestor\n---\n\nancestor body\n");
    try writeTempFile(&tmp, "home/.fx/skills/review/SKILL.md", "---\nname: review\ndescription: managed\n---\n\nmanaged body\n");
    try writeTempFile(&tmp, "home/.agents/skills/review/SKILL.md", "---\nname: review\ndescription: global compatibility\n---\n\nglobal body\n");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace/app");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    const skills = discovery.skills;

    try std.testing.expectEqual(@as(usize, 4), skills.len);
    try std.testing.expectEqualStrings("closest", skills[0].description);
    try std.testing.expectEqual(SkillSource.workspace_agents, skills[0].source);
    try std.testing.expectEqualStrings("ancestor", skills[1].description);
    try std.testing.expectEqual(SkillSource.workspace_agents, skills[1].source);
    try std.testing.expectEqualStrings("managed", skills[2].description);
    try std.testing.expectEqual(SkillSource.global_fx, skills[2].source);
    try std.testing.expectEqualStrings("global compatibility", skills[3].description);
    try std.testing.expectEqual(SkillSource.global_agents, skills[3].source);
    try std.testing.expectEqual(@as(usize, 4), skillMenuFilterQueryCount(skills, .all, "review"));
    try std.testing.expectEqual(@as(usize, 3), skillMenuFilterQueryCount(skills, .agents, "review"));
}

test "loadVisibleSkills deduplicates symlinked workspace and global roots while preserving physical same-name candidates" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/workspace/.agents/skills/alpha/SKILL.md",
        "---\nname: review\ndescription: alpha workflow\n---\n\nalpha body\n",
    );
    try writeTempFile(
        &tmp,
        "home/workspace/.agents/skills/beta/SKILL.md",
        "---\nname: review\ndescription: beta workflow\n---\n\nbeta body\n",
    );
    try writeTempFile(
        &tmp,
        "home/.agents/skills/global/SKILL.md",
        "---\nname: review\ndescription: global workflow\n---\n\nglobal body\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../.agents/skills",
        "home/workspace/.claude/skills",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../.agents/skills",
        "home/.claude/skills",
    );

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const unused_managed_root = try std.fs.path.join(alloc, &.{ home_root, ".fx/skills" });
    defer alloc.free(unused_managed_root);

    const workspace_roots = [_]skill_contract.RootSpec{
        .{ .source = .workspace_claude, .path = ".claude/skills" },
        .{ .source = .workspace_agents, .path = ".agents/skills" },
    };
    const global_roots = [_]skill_contract.RootSpec{
        .{ .source = .global_claude, .path = ".claude/skills" },
        .{ .source = .global_agents, .path = ".agents/skills" },
    };
    const root_policy: skill_contract.RootPolicy = .{
        .workspace_roots = &workspace_roots,
        .managed_root_source = null,
        .global_roots = &global_roots,
    };

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, unused_managed_root, root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), discovery.skills.len);
    try std.testing.expectEqualStrings("review", discovery.skills[0].name);
    try std.testing.expectEqualStrings("alpha workflow", discovery.skills[0].description);
    try std.testing.expectEqual(SkillSource.workspace_claude, discovery.skills[0].source);
    try std.testing.expectEqualStrings("review", discovery.skills[1].name);
    try std.testing.expectEqualStrings("beta workflow", discovery.skills[1].description);
    try std.testing.expectEqual(SkillSource.workspace_claude, discovery.skills[1].source);
    try std.testing.expectEqualStrings("review", discovery.skills[2].name);
    try std.testing.expectEqualStrings("global workflow", discovery.skills[2].description);
    try std.testing.expectEqual(SkillSource.global_claude, discovery.skills[2].source);

    const alpha_alias = try std.fs.path.join(alloc, &.{ workspace_root, ".claude/skills/alpha" });
    defer alloc.free(alpha_alias);
    const beta_alias = try std.fs.path.join(alloc, &.{ workspace_root, ".claude/skills/beta" });
    defer alloc.free(beta_alias);
    const global_alias = try std.fs.path.join(alloc, &.{ home_root, ".claude/skills/global" });
    defer alloc.free(global_alias);
    try std.testing.expectEqualStrings(alpha_alias, discovery.skills[0].path);
    try std.testing.expectEqualStrings(beta_alias, discovery.skills[1].path);
    try std.testing.expectEqualStrings(global_alias, discovery.skills[2].path);
    try std.testing.expectEqual(SkillResolution.ambiguous_name, resolveSkill(discovery.skills, "review", null));
    switch (resolveSkill(discovery.skills, "review", beta_alias)) {
        .found => |skill| try std.testing.expectEqualStrings("beta workflow", skill.description),
        else => return error.TestExpectedExactSkill,
    }
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "loadVisibleSkills stops ancestor walking before home and keeps home agents global" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/skills/home-shared/SKILL.md", "---\nname: home-shared\ndescription: should not load\n---\n\nbody\n");
    try writeTempFile(&tmp, "home/.agents/skills/review/SKILL.md", "---\nname: review\ndescription: global agents\n---\n\nbody\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace/app");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace/app");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    const skills = discovery.skills;

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("review", skills[0].name);
    try std.testing.expectEqual(SkillSource.global_agents, skills[0].source);
}

test "loadVisibleSkills discovers workspace and global codex roots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "home/workspace/app/.codex/skills/local-codex/SKILL.md", "---\nname: local-codex\ndescription: workspace codex\n---\n\nbody\n");
    try writeTempFile(&tmp, "home/.codex/skills/global-codex/SKILL.md", "---\nname: global-codex\ndescription: global codex\n---\n\nbody\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace/app");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    const skills = discovery.skills;

    try std.testing.expectEqual(@as(usize, 2), skills.len);
    try std.testing.expectEqual(SkillSource.workspace_codex, findSkillByName(skills, "local-codex").?.source);
    try std.testing.expectEqual(SkillSource.global_codex, findSkillByName(skills, "global-codex").?.source);
}

test "loadVisibleSkills discovers and reopens contained linked metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/workspace/skill-source/linked-leaf/SKILL.md",
        "---\nname: linked-leaf\ndescription: contained metadata link\n---\n\nLINKED_LEAF_BODY\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../skill-source/linked-leaf/SKILL.md",
        "home/workspace/.codex/skills/linked-leaf/SKILL.md",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const logical_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/linked-leaf" });
    defer alloc.free(logical_path);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
    try std.testing.expectEqualStrings("linked-leaf", discovery.skills[0].name);
    try std.testing.expectEqualStrings(logical_path, discovery.skills[0].path);

    var candidate = switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .current => |current| current,
        .missing, .name_mismatch, .skipped => return error.TestExpectedCurrentSkill,
    };
    defer candidate.deinit();
    const body = try io_mod.readFileToEnd(alloc, candidate.skillFile(), 4096);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "LINKED_LEAF_BODY") != null);
}

test "linked metadata reauthorizes a target changed after preflight" {
    const Retarget = struct {
        dir: std.Io.Dir,
        failed: bool = false,

        fn run(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.dir.deleteFile(io_mod.getIo(), "home/workspace/.codex/skills/linked-leaf/SKILL.md") catch {
                self.failed = true;
                return;
            };
            self.dir.symLink(
                io_mod.getIo(),
                "../../../../outside/SKILL.md",
                "home/workspace/.codex/skills/linked-leaf/SKILL.md",
                .{ .is_directory = false },
            ) catch {
                self.failed = true;
            };
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "home/workspace/source/SKILL.md", "---\nname: linked-leaf\n---\ninside\n");
    try writeTempFile(&tmp, "home/outside/SKILL.md", "---\nname: linked-leaf\n---\noutside\n");
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../source/SKILL.md",
        "home/workspace/.codex/skills/linked-leaf/SKILL.md",
    );

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const candidate_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/linked-leaf" });
    defer alloc.free(candidate_path);
    var candidate_dir = try io_mod.openDirAbsoluteNoFollow(candidate_path, .{});
    defer candidate_dir.close(io_mod.getIo());
    var retarget = Retarget{ .dir = tmp.dir };

    const result = try openPrimarySkillFileWithOptions(
        alloc,
        &candidate_dir,
        workspace_root,
        .{ .after_preflight = .{ .ctx = &retarget, .run = Retarget.run } },
    );
    try std.testing.expect(!retarget.failed);
    try std.testing.expect(result == .rejected);
}

test "linked metadata and resources stay on the opened candidate after rebinding" {
    const ReplaceCandidate = struct {
        dir: std.Io.Dir,
        failed: bool = false,

        fn run(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.dir.rename(
                "home/workspace/.codex/skills/linked",
                self.dir,
                "home/workspace/.codex/skills/original-linked",
                io_mod.getIo(),
            ) catch {
                self.failed = true;
                return;
            };
            self.dir.createDirPath(io_mod.getIo(), "home/workspace/.codex/skills/linked") catch {
                self.failed = true;
                return;
            };
            self.dir.writeFile(io_mod.getIo(), .{
                .sub_path = "home/workspace/.codex/skills/linked/metadata.md",
                .data = "replacement metadata",
            }) catch {
                self.failed = true;
                return;
            };
            self.dir.writeFile(io_mod.getIo(), .{
                .sub_path = "home/workspace/.codex/skills/linked/asset.txt",
                .data = "replacement resource",
            }) catch {
                self.failed = true;
                return;
            };
            self.dir.symLink(
                io_mod.getIo(),
                "metadata.md",
                "home/workspace/.codex/skills/linked/SKILL.md",
                .{ .is_directory = false },
            ) catch {
                self.failed = true;
            };
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "home/workspace/.codex/skills/linked/metadata.md", "original metadata");
    try writeTempFile(&tmp, "home/workspace/.codex/skills/linked/asset.txt", "original resource");
    try createTempSymlinkOrSkip(
        &tmp,
        "metadata.md",
        "home/workspace/.codex/skills/linked/SKILL.md",
    );

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const candidate_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/linked" });
    defer alloc.free(candidate_path);
    var candidate_dir = try io_mod.openDirAbsoluteNoFollow(candidate_path, .{});
    defer candidate_dir.close(io_mod.getIo());
    var replace = ReplaceCandidate{ .dir = tmp.dir };

    var metadata_file = switch (try openPrimarySkillFileWithOptions(
        alloc,
        &candidate_dir,
        workspace_root,
        .{ .after_open = .{ .ctx = &replace, .run = ReplaceCandidate.run } },
    )) {
        .opened => |file| file,
        .missing, .rejected => return error.TestExpectedOpenedFile,
    };
    defer metadata_file.close(io_mod.getIo());
    try std.testing.expect(!replace.failed);

    const metadata = try io_mod.readFileToEnd(alloc, &metadata_file, 128);
    defer alloc.free(metadata);
    try std.testing.expectEqualStrings("original metadata", metadata);
    var resource_file = try candidate_dir.openFile(io_mod.getIo(), "asset.txt", .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer resource_file.close(io_mod.getIo());
    const resource = try io_mod.readFileToEnd(alloc, &resource_file, 128);
    defer alloc.free(resource);
    try std.testing.expectEqualStrings("original resource", resource);
}

test "linked metadata outside authority is rejected before descriptor open" {
    const MarkOpen = struct {
        called: bool = false,

        fn run(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.called = true;
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(&tmp, "home/outside/SKILL.md", "---\nname: linked-leaf\n---\noutside\n");
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../../outside/SKILL.md",
        "home/workspace/.codex/skills/linked-leaf/SKILL.md",
    );

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const candidate_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/linked-leaf" });
    defer alloc.free(candidate_path);
    var candidate_dir = try io_mod.openDirAbsoluteNoFollow(candidate_path, .{});
    defer candidate_dir.close(io_mod.getIo());
    var mark = MarkOpen{};

    const result = try openPrimarySkillFileWithOptions(
        alloc,
        &candidate_dir,
        workspace_root,
        .{ .after_preflight = .{ .ctx = &mark, .run = MarkOpen.run } },
    );
    try std.testing.expect(result == .rejected);
    try std.testing.expect(!mark.called);
}

test "linked metadata FIFO is rejected before descriptor open" {
    const MarkOpen = struct {
        called: bool = false,

        fn run(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.called = true;
        }
    };
    const BlockedWriter = struct {
        path: [*:0]const u8,
        started: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            const fd = std.posix.openatZ(std.posix.AT.FDCWD, self.path, .{ .ACCMODE = .WRONLY }, 0) catch {
                self.failed.store(true, .seq_cst);
                self.finished.store(true, .seq_cst);
                return;
            };
            var file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
            file.close(io_mod.getIo());
            self.finished.store(true, .seq_cst);
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createTempFifoOrSkip(alloc, &tmp, "home/workspace/metadata.fifo");
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../metadata.fifo",
        "home/workspace/.codex/skills/fifo/SKILL.md",
    );

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const fifo_path = try std.fs.path.join(alloc, &.{ workspace_root, "metadata.fifo" });
    defer alloc.free(fifo_path);
    var fifo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fifo_path_z = try std.fmt.bufPrintZ(&fifo_path_buf, "{s}", .{fifo_path});
    const candidate_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/fifo" });
    defer alloc.free(candidate_path);
    var candidate_dir = try io_mod.openDirAbsoluteNoFollow(candidate_path, .{});
    defer candidate_dir.close(io_mod.getIo());
    var mark = MarkOpen{};
    var writer = BlockedWriter{ .path = fifo_path_z };
    const writer_thread = try std.Thread.spawn(.{}, BlockedWriter.run, .{&writer});
    defer {
        if (!writer.finished.load(.seq_cst)) {
            const reader_fd = std.posix.openatZ(
                std.posix.AT.FDCWD,
                fifo_path_z,
                .{ .ACCMODE = .RDONLY, .NONBLOCK = true },
                0,
            ) catch -1;
            if (reader_fd >= 0) {
                var reader = std.Io.File{ .handle = reader_fd, .flags = .{ .nonblocking = true } };
                reader.close(io_mod.getIo());
            }
        }
        writer_thread.join();
    }
    while (!writer.started.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..1000) |_| std.Thread.yield() catch {};
    try std.testing.expect(!writer.finished.load(.seq_cst));

    const result = try openPrimarySkillFileWithOptions(
        alloc,
        &candidate_dir,
        workspace_root,
        .{ .after_preflight = .{ .ctx = &mark, .run = MarkOpen.run } },
    );
    try std.testing.expect(result == .rejected);
    try std.testing.expect(!mark.called);
    try std.testing.expect(!writer.finished.load(.seq_cst));
    try std.testing.expect(!writer.failed.load(.seq_cst));
}

test "loadVisibleSkills discovers and reopens a contained linked workspace candidate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/workspace/skill-source/linked-skill/SKILL.md",
        "---\nname: linked-skill\ndescription: contained link\n---\n\nLINKED_SKILL_BODY\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../skill-source/linked-skill",
        "home/workspace/.codex/skills/linked-skill",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const logical_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/linked-skill" });
    defer alloc.free(logical_path);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqualStrings("linked-skill", discovery.skills[0].name);
    try std.testing.expectEqualStrings(logical_path, discovery.skills[0].path);
    try std.testing.expectEqual(SkillSource.workspace_codex, discovery.skills[0].source);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);

    var candidate = switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .current => |current| current,
        .missing, .name_mismatch, .skipped => return error.TestExpectedCurrentSkill,
    };
    candidate.deinit();

    try writeTempFile(
        &tmp,
        "home/outside-skill/SKILL.md",
        "---\nname: linked-skill\ndescription: outside\n---\n\nOUTSIDE_BODY_MUST_NOT_LOAD\n",
    );
    try tmp.dir.deleteFile(io_mod.getIo(), "home/workspace/.codex/skills/linked-skill");
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../outside-skill",
        "home/workspace/.codex/skills/linked-skill",
    );
    switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .skipped => |cause| try std.testing.expectEqual(SkillDiagnosticCause.unreadable, cause),
        .current => |current_value| {
            var current = current_value;
            current.deinit();
            return error.TestExpectedSkippedSkill;
        },
        .missing, .name_mismatch => return error.TestExpectedSkippedSkill,
    }
}

test "loadVisibleSkills diagnoses an unavailable linked workspace candidate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createTempSymlinkOrSkip(
        &tmp,
        "../../skill-source/missing-skill",
        "home/workspace/.codex/skills/missing-skill",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const logical_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/missing-skill" });
    defer alloc.free(logical_path);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqualStrings(logical_path, discovery.diagnostics[0].path);
    try std.testing.expectEqual(SkillSource.workspace_codex, discovery.diagnostics[0].source);
    try std.testing.expectEqual(SkillDiagnosticScope.candidate, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.linked_candidate_unavailable, discovery.diagnostics[0].cause);

    var summary: std.Io.Writer.Allocating = .init(alloc);
    defer summary.deinit();
    try writeDiagnosticSummary(alloc, &summary.writer, discovery.diagnostics);
    try std.testing.expect(std.mem.find(u8, summary.written(), "linked skill directory could not be resolved to an authorized readable directory") != null);
    try std.testing.expect(std.mem.find(u8, summary.written(), "repair or remove the link") != null);
}

test "loadVisibleSkills discovers a contained linked workspace root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/workspace/skill-root/root-linked/SKILL.md",
        "---\nname: root-linked\ndescription: linked root\n---\n\nROOT_LINKED_BODY\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../skill-root",
        "home/workspace/.codex/skills",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    const skill = findSkillByName(discovery.skills, "root-linked") orelse return error.TestExpectedSkill;
    try std.testing.expectEqual(SkillSource.workspace_codex, skill.source);
    try std.testing.expectEqualStrings(workspace_root, skill.read_authority.?);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "loadVisibleSkills diagnoses an escaping linked workspace candidate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/outside-skill/SKILL.md",
        "---\nname: escaping-skill\ndescription: outside\n---\n\nOUTSIDE_BODY_MUST_NOT_LOAD\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../outside-skill",
        "home/workspace/.codex/skills/escaping-skill",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const logical_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/escaping-skill" });
    defer alloc.free(logical_path);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqualStrings(logical_path, discovery.diagnostics[0].path);
    try std.testing.expectEqual(SkillDiagnosticScope.candidate, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.linked_candidate_unavailable, discovery.diagnostics[0].cause);
}

fn checkContainedLinkedSkillAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    home_root: []const u8,
    managed_root: []const u8,
) !void {
    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expect(discovery.skills[0].read_authority != null);
}

test "loadVisibleSkills cleans contained-link authority allocation failures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/workspace/skill-source/linked-skill/SKILL.md",
        "---\nname: linked-skill\ndescription: allocation cleanup\n---\n\nbody\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../skill-source/linked-skill",
        "home/workspace/.codex/skills/linked-skill",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkContainedLinkedSkillAllocationFailures,
        .{ workspace_root, home_root, managed_root },
    );
}

test "loadVisibleSkills skips missing or unreadable skill files without failing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "root/good/SKILL.md", "---\nname: good\ndescription: loads\n---\n\nbody\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "root/missing");
    try tmp.dir.createDirPath(io_mod.getIo(), "root/unreadable/SKILL.md");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);

    var discovery = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer discovery.deinit(alloc);
    const skills = discovery.skills;

    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("good", skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticScope.candidate, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.unreadable, discovery.diagnostics[0].cause);
}

test "loadVisibleSkills ignores nested installer transaction payloads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "root/review/SKILL.md", "---\nname: review\ndescription: installed\n---\nbody\n");
    try writeTempFile(&tmp, "root/.review.transaction-1/staged/SKILL.md", "---\nname: review\ndescription: staged\n---\nbody\n");
    try writeTempFile(&tmp, "root/.review.transaction-1/backup/SKILL.md", "---\nname: review\ndescription: backup\n---\nbody\n");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);

    var discovery = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqualStrings("review", discovery.skills[0].name);
    try std.testing.expectEqualStrings("installed", discovery.skills[0].description);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "skill discovery rejects symlinked metadata outside its selected root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "outside/SKILL.md", "---\nname: external-secret\ndescription: must not escape\n---\nbody\n");
    try createTempSymlinkOrSkip(&tmp, "../../outside/SKILL.md", "root/linked/SKILL.md");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);

    var visible = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer visible.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), visible.skills.len);
    try std.testing.expectEqual(@as(usize, 1), visible.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticScope.candidate, visible.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.unreadable, visible.diagnostics[0].cause);
}

test "skill discovery rejects a symlinked selected root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "real-root/external/SKILL.md", "---\nname: external\ndescription: must not load\n---\nbody\n");
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, "real-root", "linked-root", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const linked_root = try std.fs.path.join(alloc, &.{ tmp_root, "linked-root" });
    defer alloc.free(linked_root);

    var discovery = try loadVisibleSkills(alloc, null, null, linked_root, test_managed_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticScope.root, discovery.diagnostics[0].scope);
}

test "skill discovery reports a broken symlinked selected root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, "missing-root", "broken-root", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };
    const tmp_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(tmp_root);
    const broken_root = try std.fs.path.join(alloc, &.{ tmp_root, "broken-root" });
    defer alloc.free(broken_root);

    var discovery = try loadVisibleSkills(alloc, null, null, broken_root, test_managed_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticScope.root, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.unreadable, discovery.diagnostics[0].cause);
}

test "skill discovery rejects symlinked ancestors inside an automatic root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "outside/skills/external/SKILL.md", "---\nname: external\ndescription: must not load\n---\nbody\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, "../../outside", "home/workspace/.agents", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticScope.root, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.unreadable, discovery.diagnostics[0].cause);
}

test "skill discovery reports a symlinked automatic root whose target lacks the trailing component" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "outside");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    tmp.dir.symLink(std.testing.io, "../../outside", "home/workspace/.agents", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticScope.root, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.unreadable, discovery.diagnostics[0].cause);
}

test "loadVisibleSkills discovers a skill whose body exceeds the old discovery cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const oversized = try alloc.alloc(u8, 1024 * 1024 + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    const header = "---\nname: too-large\ndescription: remains discoverable\n---\n";
    @memcpy(oversized[0..header.len], header);
    try writeTempFile(&tmp, "root/too-large/SKILL.md", oversized);

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);
    var discovery = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqualStrings("too-large", discovery.skills[0].name);
    try std.testing.expectEqualStrings("remains discoverable", discovery.skills[0].description);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
}

test "loadVisibleSkills orders valid candidates diagnoses invalid metadata and resolves exact identity" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "root/zeta/SKILL.md", "zeta body without frontmatter\n");
    try writeTempFile(&tmp, "root/beta/SKILL.md", "---\nname: duplicate\n---\nbeta body\n");
    try writeTempFile(&tmp, "root/alpha/SKILL.md", "---\nname: duplicate\n---\nalpha body\n");
    try writeTempFile(&tmp, "root/bad/SKILL.md", "---\nname: \"\"\n---\ninvalid body\n");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);
    const alpha_path = try std.fs.path.join(alloc, &.{ root, "alpha" });
    defer alloc.free(alpha_path);
    const beta_path = try std.fs.path.join(alloc, &.{ root, "beta" });
    defer alloc.free(beta_path);
    const bad_path = try std.fs.path.join(alloc, &.{ root, "bad" });
    defer alloc.free(bad_path);

    var discovery = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), discovery.skills.len);
    try std.testing.expectEqualStrings(alpha_path, discovery.skills[0].path);
    try std.testing.expectEqualStrings(beta_path, discovery.skills[1].path);
    try std.testing.expectEqualStrings("zeta", discovery.skills[2].name);
    try std.testing.expectEqualStrings("", discovery.skills[2].description);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqualStrings(bad_path, discovery.diagnostics[0].path);
    try std.testing.expectEqual(SkillSource.global_fx, discovery.diagnostics[0].source);
    try std.testing.expectEqual(SkillDiagnosticScope.candidate, discovery.diagnostics[0].scope);
    switch (discovery.diagnostics[0].cause) {
        .invalid_metadata => |cause| try std.testing.expectEqual(skill_contract.InvalidMetadataCause.missing_name, cause),
        else => return error.TestExpectedInvalidMetadataDiagnostic,
    }

    try std.testing.expectEqual(SkillResolution.ambiguous_name, resolveSkill(discovery.skills, "duplicate", null));
    switch (resolveSkill(discovery.skills, "duplicate", beta_path)) {
        .found => |skill| try std.testing.expectEqualStrings(beta_path, skill.path),
        else => return error.TestExpectedExactSkill,
    }
    try std.testing.expectEqual(SkillResolution.name_location_mismatch, resolveSkill(discovery.skills, "other", beta_path));
    try std.testing.expectEqual(SkillResolution.not_found, resolveSkill(discovery.skills, "duplicate", "/outside/root"));
}

test "loadVisibleSkills diagnoses a hostile no-frontmatter directory name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(&tmp, "root/hostile\nname/SKILL.md", "body without frontmatter\n");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);
    const candidate_path = try std.fs.path.join(alloc, &.{ root, "hostile\nname" });
    defer alloc.free(candidate_path);

    var discovery = try loadVisibleSkills(alloc, null, null, root, test_managed_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqualStrings(candidate_path, discovery.diagnostics[0].path);
    try std.testing.expectEqual(SkillSource.global_fx, discovery.diagnostics[0].source);
    switch (discovery.diagnostics[0].cause) {
        .invalid_metadata => |cause| try std.testing.expectEqual(skill_contract.InvalidMetadataCause.control_byte, cause),
        else => return error.TestExpectedInvalidMetadataDiagnostic,
    }
}

fn checkLoadVisibleSkillsAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    home_root: []const u8,
    managed_root: []const u8,
) !void {
    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_managed_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
}

test "loadVisibleSkills cleans every partial allocation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/.fx/skills/review/SKILL.md",
        "---\nname: review\ndescription: >-\n  allocation\n  cleanup\n---\nbody\n",
    );
    try writeTempFile(&tmp, "home/.fx/skills/bad/SKILL.md", "---\nname: first\nname: duplicate\n---\nbad body\n");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/workspace");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    try std.testing.checkAllAllocationFailures(
        alloc,
        checkLoadVisibleSkillsAllocationFailures,
        .{ workspace_root, home_root, managed_root },
    );
}

fn checkLinkedMetadataAllocationFailures(
    alloc: Allocator,
    workspace_root: []const u8,
    home_root: []const u8,
    managed_root: []const u8,
) !void {
    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);

    var candidate = switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .current => |current| current,
        .missing, .name_mismatch, .skipped => return error.TestExpectedCurrentSkill,
    };
    candidate.deinit();
}

test "linked metadata cleans every partial allocation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "home/workspace/source/SKILL.md",
        "---\nname: linked\ndescription: allocation cleanup\n---\nbody\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../source/SKILL.md",
        "home/workspace/.codex/skills/linked/SKILL.md",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);

    const descriptor_count_before = try openFileDescriptorCount();
    try std.testing.checkAllAllocationFailures(
        alloc,
        checkLinkedMetadataAllocationFailures,
        .{ workspace_root, home_root, managed_root },
    );
    try std.testing.expectEqual(descriptor_count_before, try openFileDescriptorCount());
}

test "freeSkills accepts static empty slice" {
    freeSkills(std.testing.allocator, &.{});
}

var stable_test_environ: ?*std.process.Environ.Map = null;

fn stableEmptyTestEnviron() !*const std.process.Environ.Map {
    if (stable_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_test_environ = map;
    return map;
}

const TestEnviron = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator) !*TestEnviron {
        _ = try stableEmptyTestEnviron();

        const self = try alloc.create(TestEnviron);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn put(self: *TestEnviron, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }

    fn deinit(self: *TestEnviron) void {
        if (stable_test_environ) |map| {
            io_mod.setEnvironMap(map);
        }
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "externalSymlinkAuthorities parses colon-separated absolute paths" {
    const alloc = std.testing.allocator;

    const env = try TestEnviron.install(alloc);
    defer env.deinit();
    try env.put("FX_SKILL_SYMLINK_AUTHORITIES", "/nix/store:/opt/skills: relative :/bad/../path");

    const authorities = try externalSymlinkAuthorities(alloc);
    defer freeExternalAuthorities(alloc, authorities);
    try std.testing.expectEqual(@as(usize, 2), authorities.len);
    try std.testing.expectEqualStrings("/nix/store", authorities[0]);
    try std.testing.expectEqualStrings("/opt/skills", authorities[1]);
}

test "externalSymlinkAuthorities returns empty when unset" {
    const alloc = std.testing.allocator;

    const env = try TestEnviron.install(alloc);
    defer env.deinit();

    const authorities = try externalSymlinkAuthorities(alloc);
    try std.testing.expectEqual(@as(usize, 0), authorities.len);
}

test "loadVisibleSkills discovers linked metadata through external authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "external-store/linked-leaf/SKILL.md",
        "---\nname: linked-leaf\ndescription: external metadata link\n---\n\nEXTERNAL_LEAF_BODY\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../../../external-store/linked-leaf/SKILL.md",
        "home/workspace/.codex/skills/linked-leaf/SKILL.md",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const external_authority = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external-store");
    defer alloc.free(external_authority);

    const env = try TestEnviron.install(alloc);
    defer env.deinit();
    try env.put("FX_SKILL_SYMLINK_AUTHORITIES", external_authority);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);
    try std.testing.expectEqualStrings("linked-leaf", discovery.skills[0].name);

    var candidate = switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .current => |current| current,
        .missing, .name_mismatch, .skipped => return error.TestExpectedCurrentSkill,
    };
    candidate.deinit();
}

test "loadVisibleSkills discovers a linked candidate resolved via external symlink authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The skill source lives outside the home/workspace, simulating a Nix
    // store path. The symlink in the skills directory points to it.
    try writeTempFile(
        &tmp,
        "external-store/linked-skill/SKILL.md",
        "---\nname: linked-skill\ndescription: external link\n---\n\nEXTERNAL_BODY\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../../external-store/linked-skill",
        "home/workspace/.codex/skills/linked-skill",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const external_authority = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external-store");
    defer alloc.free(external_authority);

    const env = try TestEnviron.install(alloc);
    defer env.deinit();
    try env.put("FX_SKILL_SYMLINK_AUTHORITIES", external_authority);

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), discovery.skills.len);
    try std.testing.expectEqualStrings("linked-skill", discovery.skills[0].name);
    try std.testing.expectEqual(@as(usize, 0), discovery.diagnostics.len);

    var candidate = switch (try openValidatedSkillCandidate(alloc, discovery.skills[0])) {
        .current => |current| current,
        .missing, .name_mismatch, .skipped => return error.TestExpectedCurrentSkill,
    };
    candidate.deinit();
}

test "loadVisibleSkills still rejects external symlinks without an authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTempFile(
        &tmp,
        "external-store/escaping-skill/SKILL.md",
        "---\nname: escaping-skill\ndescription: outside\n---\n\nOUTSIDE_BODY_MUST_NOT_LOAD\n",
    );
    try createTempSymlinkOrSkip(
        &tmp,
        "../../../../external-store/escaping-skill",
        "home/workspace/.codex/skills/escaping-skill",
    );
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx/skills");

    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/workspace");
    defer alloc.free(workspace_root);
    const home_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home_root);
    const managed_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home/.fx/skills");
    defer alloc.free(managed_root);
    const logical_path = try std.fs.path.join(alloc, &.{ workspace_root, ".codex/skills/escaping-skill" });
    defer alloc.free(logical_path);

    const env = try TestEnviron.install(alloc);
    defer env.deinit();

    var discovery = try loadVisibleSkills(alloc, workspace_root, home_root, managed_root, test_root_policy);
    defer discovery.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), discovery.skills.len);
    try std.testing.expectEqual(@as(usize, 1), discovery.diagnostics.len);
    try std.testing.expectEqualStrings(logical_path, discovery.diagnostics[0].path);
    try std.testing.expectEqual(SkillDiagnosticScope.candidate, discovery.diagnostics[0].scope);
    try std.testing.expectEqual(SkillDiagnosticCause.linked_candidate_unavailable, discovery.diagnostics[0].cause);
}
