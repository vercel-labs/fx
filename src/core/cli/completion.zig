//! `fx completion bash|zsh|fish`: prints a completion script built from the
//! same command specs help and parsing read, and from the settings list.
//!
//! Every script walks the command line the same way. Words that name a
//! subcommand move down the command tree, flags are skipped along with the
//! value a flag takes, and any other word is an argument. At the cursor it
//! offers, in order: a flag's fixed values, the flags of the current command
//! when the word starts with `-`, setting keys after `fx config get|set|unset`,
//! and otherwise the command's subcommands. It never runs fx, so Tab works
//! offline and without touching the session store.

const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const cli_config = @import("cli_config.zig");
const cli_flags = @import("cli_flags.zig");
const settings_keys = @import("../config/settings_keys.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const OptionDoc = command_specs.OptionDoc;
const SubcommandDoc = command_specs.SubcommandDoc;

pub const Shell = enum { bash, zsh, fish };

pub fn parseShell(name: []const u8) ?Shell {
    return std.meta.stringToEnum(Shell, name);
}

const Entry = struct {
    name: []const u8,
    description: []const u8,
};

/// One place in the command tree: `config set` has `path` "config set".
const Node = struct {
    path: []const u8,
    words: std.ArrayList(Entry) = .empty,
    flags: std.ArrayList(Entry) = .empty,
    keys: KeyList = .none,
};

/// Which setting keys a word's `<key>` takes: every key for `config get`,
/// only the ones `fx config set` changes for `set` and `unset`.
const KeyList = enum { none, all, settable };

const ValueList = struct {
    flag: []const u8,
    values: []const []const u8,
};

/// What every script needs, read once from the registries.
const Model = struct {
    nodes: std.ArrayList(Node) = .empty,
    /// Flags that take a value, so the walk skips the word after them.
    value_flags: std.ArrayList([]const u8) = .empty,
    /// Fixed values by flag. The first list seen for a flag wins.
    values: std.ArrayList(ValueList) = .empty,
    setting_keys: std.ArrayList([]const u8) = .empty,
    settable_keys: std.ArrayList([]const u8) = .empty,

    fn addSettingKey(self: *Model, arena: Allocator, key: []const u8) !void {
        try self.setting_keys.append(arena, key);
        if (cli_config.settable(key)) try self.settable_keys.append(arena, key);
    }

    fn node(self: *Model, arena: Allocator, path: []const u8) !*Node {
        for (self.nodes.items) |*existing| {
            if (std.mem.eql(u8, existing.path, path)) return existing;
        }
        try self.nodes.append(arena, .{ .path = path });
        return &self.nodes.items[self.nodes.items.len - 1];
    }

    fn noteFlag(self: *Model, arena: Allocator, name: []const u8, takes_value: bool, values: []const []const u8) !void {
        if (takes_value and !contains(self.value_flags.items, name)) try self.value_flags.append(arena, name);
        if (values.len == 0) return;
        for (self.values.items) |entry| {
            if (std.mem.eql(u8, entry.flag, name)) return;
        }
        try self.values.append(arena, .{ .flag = name, .values = values });
    }
};

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |existing| {
        if (std.mem.eql(u8, existing, item)) return true;
    }
    return false;
}

fn addEntry(arena: Allocator, list: *std.ArrayList(Entry), entry: Entry) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing.name, entry.name)) return;
    }
    try list.append(arena, entry);
}

/// A flag's fixed values: its `values` list, or the alternatives written in
/// its placeholder, such as `today`, `7d`, and `month` in `--period <today|7d|month>`.
/// The caller owns the result when it isn't `doc.values`.
pub fn fixedValues(arena: Allocator, doc: OptionDoc) ![]const []const u8 {
    if (doc.values.len > 0) return doc.values;
    return placeholderValues(arena, doc.flag);
}

fn placeholderValues(arena: Allocator, usage: []const u8) ![]const []const u8 {
    const space = std.mem.findScalarLast(u8, usage, ' ') orelse return &.{};
    var placeholder = usage[space + 1 ..];
    if (placeholder.len < 2) return &.{};
    const open = placeholder[0];
    const close = placeholder[placeholder.len - 1];
    if (!((open == '<' and close == '>') or (open == '[' and close == ']'))) return &.{};
    placeholder = placeholder[1 .. placeholder.len - 1];
    if (std.mem.findScalar(u8, placeholder, '|') == null) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, placeholder, '|');
    while (it.next()) |alternative| {
        if (alternative.len == 0 or std.mem.findAny(u8, alternative, "<>[] ") != null) continue;
        try list.append(arena, alternative);
    }
    return list.items;
}

fn addOptions(model: *Model, arena: Allocator, target: *Node, options: []const OptionDoc) !void {
    for (options) |doc| {
        if (doc.replacement != null or doc.hidden) continue;
        const name = cli_flags.flagName(doc);
        if (!std.mem.startsWith(u8, name, "-") or std.mem.eql(u8, name, "--")) continue;
        try addEntry(arena, &target.flags, .{ .name = name, .description = doc.description });
        try model.noteFlag(arena, name, cli_flags.takesValue(doc), try fixedValues(arena, doc));
    }
}

const help_flag: Entry = .{ .name = "--help", .description = "Show help for this command" };

/// A word offers only the flags it declares, plus `--help`: a parent's flags
/// may not apply, as `--api-key` doesn't after `fx login codex`.
fn addSubcommands(model: *Model, arena: Allocator, parent_path: []const u8, subcommands: []const SubcommandDoc) !void {
    for (subcommands) |sub| {
        const name = sub.name();
        {
            const parent = try model.node(arena, parent_path);
            try addEntry(arena, &parent.words, .{ .name = name, .description = sub.description });
        }
        const path = try arena.print("{s} {s}", .{ parent_path, name });
        const child = try model.node(arena, path);
        try addOptions(model, arena, child, sub.options);
        try addEntry(arena, &child.flags, help_flag);
        if (sub.takesSettingKey()) child.keys = if (sub.settable_key) .settable else .all;
        try addSubcommands(model, arena, path, sub.subcommands);
    }
}

/// The spellings in a top-level flag's usage: `--fast` and `--no-fast` in
/// `--fast, --no-fast`, and `--resume` in `-r, --resume [last|<id>]`.
/// The placeholder after the last spelling belongs to every spelling, so `-r`
/// takes a value too. Only long spellings are offered; a short one is still
/// read, so the value after it is skipped and completed.
fn addTopLevelFlag(model: *Model, arena: Allocator, root: *Node, flag: command_specs.TopLevelFlag, values_by_flag: []const ValueList) !void {
    const takes_value = std.mem.findScalarLast(u8, flag.usage, ' ') != null and
        std.mem.findAny(u8, flag.usage, "<[") != null;
    var values = try placeholderValues(arena, flag.usage);
    var parts = std.mem.splitSequence(u8, flag.usage, ", ");
    while (parts.next()) |part| {
        const end = std.mem.findScalar(u8, part, ' ') orelse part.len;
        const name = part[0..end];
        if (!std.mem.startsWith(u8, name, "-")) continue;
        for (values_by_flag) |entry| {
            if (values.len == 0 and std.mem.eql(u8, entry.flag, name)) values = entry.values;
        }
        if (std.mem.startsWith(u8, name, "--")) {
            try addEntry(arena, &root.flags, .{ .name = name, .description = flag.description });
        }
        try model.noteFlag(arena, name, takes_value, values);
    }
}

fn buildModel(arena: Allocator, registry: command_specs.TopLevelRegistry, launch_options: []const OptionDoc) !Model {
    var model: Model = .{};
    _ = try model.node(arena, "");

    for (registry.specs) |spec| {
        if (spec.hidden_from_top_level_help or spec.replaced_by != null) continue;
        {
            const root = try model.node(arena, "");
            try addEntry(arena, &root.words, .{ .name = spec.token, .description = spec.summary });
        }
        const command = try model.node(arena, spec.token);
        try addOptions(&model, arena, command, spec.options);
        try addEntry(arena, &command.flags, help_flag);
        try addSubcommands(&model, arena, spec.token, spec.subcommands);
    }

    // The launch flags' values, such as `--permission-mode`'s, also complete
    // the same flags written before the command.
    var launch_model: Model = .{};
    var scratch: Node = .{ .path = "" };
    try addOptions(&launch_model, arena, &scratch, launch_options);
    const root = try model.node(arena, "");
    for (registry.flags) |flag| try addTopLevelFlag(&model, arena, root, flag, launch_model.values.items);

    for (settings_keys.keys) |key| {
        // Old names, maps, a key fx refuses, and `$schema`, which is for
        // editors, are not settings to offer.
        if (key.deprecated() or key.map or key.kind == .refused or key.where == .editor) continue;
        if (key.children.len == 0) {
            try model.addSettingKey(arena, key.name);
            continue;
        }
        for (key.children) |child| {
            try model.addSettingKey(arena, try arena.print("{s}.{s}", .{ key.name, child }));
        }
    }
    return model;
}

/// Writes the completion script for `shell`.
pub fn writeScript(
    alloc: Allocator,
    writer: *Writer,
    shell: Shell,
    registry: command_specs.TopLevelRegistry,
    launch_options: []const OptionDoc,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const model = try buildModel(arena_state.allocator(), registry, launch_options);
    switch (shell) {
        .bash => try writeBash(writer, &model),
        .zsh => try writeZsh(writer, &model),
        .fish => try writeFish(writer, &model),
    }
}

// -- bash ---------------------------------------------------------------------

fn writeBash(w: *Writer, model: *const Model) !void {
    try w.writeAll(
        \\# bash completion for fx. Load it with:
        \\#   eval "$(fx completion bash)"
        \\# bash 3.2, the macOS default, loads nothing through source <(...).
        \\
        \\_fx_words() {
        \\    case "$1" in
        \\
    );
    for (model.nodes.items) |n| {
        if (n.words.items.len == 0) continue;
        try w.print("        '{s}') echo '", .{n.path});
        try writeNames(w, n.words.items);
        try w.writeAll("' ;;\n");
    }
    try w.writeAll(
        \\    esac
        \\}
        \\
        \\_fx_flags() {
        \\    case "$1" in
        \\
    );
    for (model.nodes.items) |n| {
        if (n.flags.items.len == 0) continue;
        try w.print("        '{s}') echo '", .{n.path});
        try writeNames(w, n.flags.items);
        try w.writeAll("' ;;\n");
    }
    try w.writeAll(
        \\    esac
        \\}
        \\
        \\_fx_values() {
        \\    case "$1" in
        \\
    );
    for (model.values.items) |entry| {
        try w.print("        {s}) echo '", .{entry.flag});
        try writeWords(w, entry.values);
        try w.writeAll("' ;;\n");
    }
    try w.writeAll(
        \\    esac
        \\}
        \\
        \\_fx_takes_value() {
        \\    case "$1" in
        \\        
    );
    try writeAlternatives(w, model.value_flags.items, false);
    try w.writeAll(
        \\) return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_fx_takes_key() {
        \\    case "$1" in
        \\        
    );
    try writeKeyPaths(w, model, true, .all);
    try w.writeAll(
        \\) return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_fx_keys='
    );
    try writeWords(w, model.setting_keys.items);
    try w.writeAll(
        \\'
        \\
        \\_fx_takes_settable_key() {
        \\    case "$1" in
        \\        
    );
    try writeKeyPaths(w, model, true, .settable);
    try w.writeAll(
        \\) return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_fx_settable_keys='
    );
    try writeWords(w, model.settable_keys.items);
    try w.writeAll(
        \\'
        \\
        \\_fx() {
        \\    local cur="${COMP_WORDS[COMP_CWORD]}" prev='' path='' word words i extra=0 skip=0
        \\    (( COMP_CWORD > 0 )) && prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    for (( i = 1; i < COMP_CWORD; i++ )); do
        \\        word="${COMP_WORDS[i]}"
        \\        if (( skip )); then skip=0; continue; fi
        \\        case "$word" in
        \\            --*=*) continue ;;
        \\            -*) _fx_takes_value "$word" && skip=1; continue ;;
        \\        esac
        \\        words=" $(_fx_words "$path") "
        \\        if (( extra == 0 )) && [[ "$words" == *" $word "* ]]; then
        \\            path="${path:+$path }$word"
        \\        else
        \\            extra=$((extra + 1))
        \\        fi
        \\    done
        \\    COMPREPLY=()
        \\    if (( skip )); then
        \\        words="$(_fx_values "$prev")"
        \\        [[ -n "$words" ]] && COMPREPLY=($(compgen -W "$words" -- "$cur"))
        \\        return 0
        \\    fi
        \\    if [[ "$cur" == -* ]]; then
        \\        COMPREPLY=($(compgen -W "$(_fx_flags "$path")" -- "$cur"))
        \\        return 0
        \\    fi
        \\    (( extra > 0 )) && return 0
        \\    if _fx_takes_settable_key "$path"; then
        \\        COMPREPLY=($(compgen -W "$_fx_settable_keys" -- "$cur"))
        \\    elif _fx_takes_key "$path"; then
        \\        COMPREPLY=($(compgen -W "$_fx_keys" -- "$cur"))
        \\    else
        \\        COMPREPLY=($(compgen -W "$(_fx_words "$path")" -- "$cur"))
        \\    fi
        \\    return 0
        \\}
        \\
        \\complete -o default -F _fx fx
        \\
    );
}

fn writeNames(w: *Writer, entries: []const Entry) !void {
    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(entry.name);
    }
}

fn writeWords(w: *Writer, words: []const []const u8) !void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(word);
    }
}

/// `a|b|c` for a shell `case` pattern, each quoted when `quote` is set.
fn writeAlternatives(w: *Writer, words: []const []const u8, quote: bool) !void {
    if (words.len == 0) return w.writeAll("''");
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte('|');
        if (quote) try w.print("'{s}'", .{word}) else try w.writeAll(word);
    }
}

fn writeFishKeyPaths(w: *Writer, model: *const Model, list: KeyList) !void {
    var first = true;
    for (model.nodes.items) |n| {
        if (n.keys != list) continue;
        if (!first) try w.writeByte(' ');
        first = false;
        try w.print("'{s}'", .{n.path});
    }
}

fn writeKeyPaths(w: *Writer, model: *const Model, quote: bool, list: KeyList) !void {
    var first = true;
    for (model.nodes.items) |n| {
        if (n.keys != list) continue;
        if (!first) try w.writeByte('|');
        first = false;
        if (quote) try w.print("'{s}'", .{n.path}) else try w.writeAll(n.path);
    }
    if (first) try w.writeAll("''");
}

// -- zsh ----------------------------------------------------------------------

fn writeZsh(w: *Writer, model: *const Model) !void {
    try w.writeAll(
        \\# zsh completion for fx. Load it after compinit with:
        \\#   source <(fx completion zsh)
        \\
        \\_fx_words() {
        \\    case "$1" in
        \\
    );
    for (model.nodes.items) |n| {
        if (n.words.items.len == 0) continue;
        try w.print("        '{s}') reply=(", .{n.path});
        try writeZshEntries(w, n.words.items);
        try w.writeAll(") ;;\n");
    }
    try w.writeAll(
        \\        *) reply=() ;;
        \\    esac
        \\}
        \\
        \\_fx_flags() {
        \\    case "$1" in
        \\
    );
    for (model.nodes.items) |n| {
        if (n.flags.items.len == 0) continue;
        try w.print("        '{s}') reply=(", .{n.path});
        try writeZshEntries(w, n.flags.items);
        try w.writeAll(") ;;\n");
    }
    try w.writeAll(
        \\        *) reply=() ;;
        \\    esac
        \\}
        \\
        \\_fx_values() {
        \\    case "$1" in
        \\
    );
    for (model.values.items) |entry| {
        try w.print("        {s}) reply=(", .{entry.flag});
        try writeWords(w, entry.values);
        try w.writeAll(") ;;\n");
    }
    try w.writeAll(
        \\        *) reply=() ;;
        \\    esac
        \\}
        \\
        \\_fx_takes_value() {
        \\    case "$1" in
        \\        
    );
    try writeAlternatives(w, model.value_flags.items, false);
    try w.writeAll(
        \\) return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_fx_takes_key() {
        \\    case "$1" in
        \\        
    );
    try writeKeyPaths(w, model, true, .all);
    try w.writeAll(
        \\) return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_fx_keys=(
    );
    try writeWords(w, model.setting_keys.items);
    try w.writeAll(
        \\)
        \\
        \\_fx_takes_settable_key() {
        \\    case "$1" in
        \\        
    );
    try writeKeyPaths(w, model, true, .settable);
    try w.writeAll(
        \\) return 0 ;;
        \\    esac
        \\    return 1
        \\}
        \\
        \\_fx_settable_keys=(
    );
    try writeWords(w, model.settable_keys.items);
    try w.writeAll(
        \\)
        \\
        \\_fx() {
        \\    local word path='' i extra=0 skip=0
        \\    local -a reply names
        \\    for (( i = 2; i < CURRENT; i++ )); do
        \\        word=${words[i]}
        \\        if (( skip )); then skip=0; continue; fi
        \\        case $word in
        \\            --*=*) continue ;;
        \\            -*) _fx_takes_value "$word" && skip=1; continue ;;
        \\        esac
        \\        _fx_words "$path"
        \\        names=(${reply%%:*})
        \\        if (( extra == 0 && ${names[(Ie)$word]} )); then
        \\            path=${path:+$path }$word
        \\        else
        \\            extra=$((extra + 1))
        \\        fi
        \\    done
        \\    if (( skip )); then
        \\        _fx_values "${words[CURRENT-1]}"
        \\        if (( ${#reply} )); then compadd -a reply; else _files; fi
        \\        return
        \\    fi
        \\    if [[ ${words[CURRENT]} == -* ]]; then
        \\        _fx_flags "$path"
        \\        _describe -t options 'fx option' reply
        \\        return
        \\    fi
        \\    if (( extra > 0 )); then _files; return; fi
        \\    if _fx_takes_settable_key "$path"; then compadd -a _fx_settable_keys; return; fi
        \\    if _fx_takes_key "$path"; then compadd -a _fx_keys; return; fi
        \\    _fx_words "$path"
        \\    if (( ${#reply} )); then _describe -t commands 'fx command' reply; else _files; fi
        \\}
        \\
        \\if (( $+functions[compdef] )); then
        \\    compdef _fx fx
        \\else
        \\    print -u2 'fx completion: run compinit before loading this script'
        \\fi
        \\
    );
}

/// `'name:description'` items for `_describe`, quoted for zsh.
fn writeZshEntries(w: *Writer, entries: []const Entry) !void {
    for (entries, 0..) |entry, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeByte('\'');
        try writeEscaped(w, entry.name, .zsh_name);
        if (entry.description.len > 0) {
            try w.writeByte(':');
            try writeEscaped(w, entry.description, .zsh);
        }
        try w.writeByte('\'');
    }
}

// -- fish ---------------------------------------------------------------------

fn writeFish(w: *Writer, model: *const Model) !void {
    try w.writeAll(
        \\# fish completion for fx. Load it with:
        \\#   fx completion fish | source
        \\
        \\function __fx_words
        \\    switch $argv[1]
        \\
    );
    for (model.nodes.items) |n| {
        if (n.words.items.len == 0) continue;
        try w.print("        case '{s}'\n            printf '%s\\t%s\\n'", .{n.path});
        try writeFishEntries(w, n.words.items);
        try w.writeByte('\n');
    }
    try w.writeAll(
        \\    end
        \\end
        \\
        \\function __fx_flags
        \\    switch $argv[1]
        \\
    );
    for (model.nodes.items) |n| {
        if (n.flags.items.len == 0) continue;
        try w.print("        case '{s}'\n            printf '%s\\t%s\\n'", .{n.path});
        try writeFishEntries(w, n.flags.items);
        try w.writeByte('\n');
    }
    try w.writeAll(
        \\    end
        \\end
        \\
        \\function __fx_values
        \\    switch $argv[1]
        \\
    );
    for (model.values.items) |entry| {
        try w.print("        case {s}\n            printf '%s\\n' ", .{entry.flag});
        try writeWords(w, entry.values);
        try w.writeByte('\n');
    }
    try w.writeAll(
        \\    end
        \\end
        \\
        \\function __fx_takes_value
        \\    contains -- $argv[1] 
    );
    try writeWords(w, model.value_flags.items);
    try w.writeAll(
        \\
        \\end
        \\
        \\function __fx_takes_key
        \\    contains -- $argv[1] 
    );
    try writeFishKeyPaths(w, model, .all);
    try w.writeAll(
        \\
        \\end
        \\
        \\set -g __fx_keys 
    );
    try writeWords(w, model.setting_keys.items);
    try w.writeAll(
        \\
        \\
        \\function __fx_takes_settable_key
        \\    contains -- $argv[1] 
    );
    try writeFishKeyPaths(w, model, .settable);
    try w.writeAll(
        \\
        \\end
        \\
        \\set -g __fx_settable_keys 
    );
    try writeWords(w, model.settable_keys.items);
    try w.writeAll(
        \\
        \\
        \\function __fx_complete
        \\    set -l tokens (commandline -opc)
        \\    set -l cur (commandline -ct)
        \\    set -e tokens[1]
        \\    set -l path ''
        \\    set -l extra 0
        \\    set -l skip 0
        \\    set -l prev ''
        \\    for word in $tokens
        \\        set prev $word
        \\        if test $skip = 1
        \\            set skip 0
        \\            continue
        \\        end
        \\        switch $word
        \\            case '--*=*'
        \\                continue
        \\            case '-*'
        \\                __fx_takes_value $word; and set skip 1
        \\                continue
        \\        end
        \\        set -l names (__fx_words "$path" | string replace -r '\t.*' '')
        \\        if test $extra = 0; and contains -- $word $names
        \\            if test -z "$path"
        \\                set path $word
        \\            else
        \\                set path "$path $word"
        \\            end
        \\        else
        \\            set extra (math $extra + 1)
        \\        end
        \\    end
        \\    if test $skip = 1
        \\        set -l values (__fx_values $prev)
        \\        if test (count $values) -gt 0
        \\            printf '%s\n' $values
        \\        else
        \\            __fish_complete_path $cur
        \\        end
        \\        return
        \\    end
        \\    if string match -q -- '-*' $cur
        \\        __fx_flags "$path"
        \\        return
        \\    end
        \\    if test $extra -gt 0
        \\        __fish_complete_path $cur
        \\        return
        \\    end
        \\    if __fx_takes_settable_key "$path"
        \\        printf '%s\n' $__fx_settable_keys
        \\        return
        \\    end
        \\    if __fx_takes_key "$path"
        \\        printf '%s\n' $__fx_keys
        \\        return
        \\    end
        \\    set -l words (__fx_words "$path")
        \\    if test (count $words) -gt 0
        \\        printf '%s\n' $words
        \\    else
        \\        __fish_complete_path $cur
        \\    end
        \\end
        \\
        \\complete -c fx -f -a '(__fx_complete)'
        \\
    );
}

/// ` name 'description'` pairs for `printf '%s\t%s\n'`, quoted for fish.
fn writeFishEntries(w: *Writer, entries: []const Entry) !void {
    for (entries) |entry| {
        try w.writeAll(" '");
        try writeEscaped(w, entry.name, .fish);
        try w.writeAll("' '");
        try writeEscaped(w, entry.description, .fish);
        try w.writeByte('\'');
    }
}

const Quoting = enum { zsh, zsh_name, fish };

/// Writes `text` for the inside of a single-quoted string.
fn writeEscaped(w: *Writer, text: []const u8, quoting: Quoting) !void {
    for (text) |byte| switch (quoting) {
        .zsh, .zsh_name => switch (byte) {
            '\'' => try w.writeAll("'\\''"),
            ':' => if (quoting == .zsh_name) try w.writeAll("\\:") else try w.writeByte(':'),
            else => try w.writeByte(byte),
        },
        .fish => switch (byte) {
            '\'' => try w.writeAll("\\'"),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(byte),
        },
    };
}

test "a flag's fixed values come from its list or its placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const period = try fixedValues(arena, .{ .flag = "--period <today|7d|month>", .description = "" });
    try std.testing.expectEqual(@as(usize, 3), period.len);
    try std.testing.expectEqualStrings("7d", period[1]);
    const listed = try fixedValues(arena, .{ .flag = "--permission-mode <mode>", .description = "", .values = &.{ "ask", "auto" } });
    try std.testing.expectEqualStrings("auto", listed[1]);
    try std.testing.expectEqual(@as(usize, 0), (try fixedValues(arena, .{ .flag = "--limit <1-100>", .description = "" })).len);
    try std.testing.expectEqual(@as(usize, 0), (try fixedValues(arena, .{ .flag = "--model <id>", .description = "" })).len);
    const resume_values = try placeholderValues(arena, "--resume [last|<id>]");
    try std.testing.expectEqual(@as(usize, 1), resume_values.len);
    try std.testing.expectEqualStrings("last", resume_values[0]);
}

test "the model follows subcommands, keeps parent flags, and marks setting-key paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const specs = [_]command_specs.TopLevelSpec{.{
        .kind = .config,
        .token = "config",
        .usage = "config",
        .summary = "Show and change fx settings",
        .options = &.{.{ .flag = "--global", .description = "Only the profile" }},
        .subcommands = &.{
            .{ .usage = "get <key>", .description = "Print a value" },
            .{ .usage = "trust", .description = "", .subcommands = &.{.{ .usage = "reset", .description = "Forget" }} },
        },
    }};
    const registry: command_specs.TopLevelRegistry = .{
        .specs = &specs,
        .description = "",
        .interactive_hint = "",
        .flags = &.{.{ .usage = "--permission-mode <mode>", .description = "Set the mode" }},
    };
    const launch = [_]OptionDoc{.{ .flag = "--permission-mode <mode>", .description = "", .values = &.{ "ask", "auto" } }};
    const model = try buildModel(arena, registry, &launch);

    var get: ?Node = null;
    var reset: ?Node = null;
    for (model.nodes.items) |n| {
        if (std.mem.eql(u8, n.path, "config get")) get = n;
        if (std.mem.eql(u8, n.path, "config trust reset")) reset = n;
    }
    try std.testing.expectEqual(KeyList.all, get.?.keys);
    // A word offers its own flags and --help, not its parent's.
    try std.testing.expectEqual(@as(usize, 1), get.?.flags.items.len);
    try std.testing.expectEqualStrings("--help", reset.?.flags.items[0].name);
    try std.testing.expect(contains(model.value_flags.items, "--permission-mode"));
    try std.testing.expectEqualStrings("auto", model.values.items[0].values[1]);
    try std.testing.expect(contains(model.setting_keys.items, "status_line.context"));
    try std.testing.expect(!contains(model.setting_keys.items, "notifications.turn_end"));
    try std.testing.expect(!contains(model.setting_keys.items, "models"));
    try std.testing.expect(contains(model.settable_keys.items, "fast_mode"));
    try std.testing.expect(contains(model.setting_keys.items, "permission_mode"));
    try std.testing.expect(!contains(model.settable_keys.items, "permission_mode"));
}

test "descriptions are quoted for each shell" {
    var buffer: [64]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try writeEscaped(&w, "it's: here", .zsh);
    try std.testing.expectEqualStrings("it'\\''s: here", w.buffered());
    w = .fixed(&buffer);
    try writeEscaped(&w, "a:b", .zsh_name);
    try std.testing.expectEqualStrings("a\\:b", w.buffered());
    w = .fixed(&buffer);
    try writeEscaped(&w, "it's \\n", .fish);
    try std.testing.expectEqualStrings("it\\'s \\\\n", w.buffered());
}
