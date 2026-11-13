#!/usr/bin/env python3
"""Rewrite Zig sources off the std APIs that Zig 0.17 deprecates or renamed.

usage: migrate.py [--write] PATH...   (directories are searched for .zig files)

Without --write it only reports what it would change. Only exact renames are
automated: each rule maps an old std name to the declaration it forwards to in
0.17, so behavior cannot change. Strings, multiline strings, character
literals, and comments are never edited. Sites that need judgment are printed
as NOTE lines and left alone.

Afterwards run `zig fmt` with Zig 0.17 (it rewrites @intFromEnum and
@enumFromInt), then check_deprecated.py for what remains: `**`, errdefer
captures, copyForwards, allocators, and the other non-mechanical changes.
Directories are searched for .zig files; symbolic links and files that are
not regular files are skipped there, and a file is never written through a
link. A file that cannot be read or is not UTF-8 is named, the run goes on
with the others, and the exit status is 1.
Reads and writes only the given files; no network access.
"""
import os
import re
import sys
from collections import Counter

# Running a script must leave no __pycache__ next to it in the user's tree.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zig_source import (  # noqa: E402
    ASCII_RENAMES, MEM_RENAMES, START, STD_RENAMES, Lines, aliases, code_mask, display,
    read_source, write_source, zig_files,
)

START_STD = r"(?:(?<=\.\.)|(?<![\w.@]))"

BUILTIN_FIELDS = {"os": "target.os", "cpu": "target.cpu", "abi": "target.abi", "object_format": "target.ofmt"}
OPTIMIZE_TAGS = {"Debug": "debug", "ReleaseSafe": "safe", "ReleaseFast": "fast", "ReleaseSmall": "small"}
SIMPLE_ALLOC = re.compile(r"^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*|\.\*|\(\))*$")
BUILTIN = '@import("builtin")'


def first_arg(text, mask, open_paren):
    """Return (arg_start, arg_end, comma_index) for the first call argument."""
    depth, i = 0, open_paren + 1
    while i < len(text):
        if mask[i]:
            c = text[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    return None
                depth -= 1
            elif c == "," and depth == 0:
                return open_paren + 1, i, i
        i += 1
    return None


def migrate(path, text):
    """Return (new_text, Counter of applied rules, list of NOTE strings)."""
    mask = code_mask(text)
    lines = Lines(text)
    edits, notes = [], []

    def line(pos):
        return lines.number(pos)

    def add(start, end, repl, kind):
        if all(mask[start:end]):
            edits.append((start, end, repl, kind))

    for old in sorted(STD_RENAMES, key=len, reverse=True):
        for m in re.finditer(START_STD + re.escape(old) + r"(?!\w)", text):
            add(m.start(), m.end(), STD_RENAMES[old], old)

    fmt_aliases = aliases(text, "std.fmt")
    for a in fmt_aliases:
        for name, new in (("bufPrintSentinel", "std.mem.printSentinel"), ("bufPrint", "std.mem.print"), ("BufPrintError", "std.mem.PrintError")):
            for m in re.finditer(START + re.escape(a) + r"\." + name + r"\b", text):
                add(m.start(), m.end(), new, "std.fmt." + name)
    for a in aliases(text, "std.fs"):
        for name, new in (("path", "std.Io.Dir.path"), ("max_path_bytes", "std.Io.Dir.max_path_bytes"), ("max_name_bytes", "std.Io.Dir.max_name_bytes")):
            for m in re.finditer(START + re.escape(a) + r"\." + name + r"\b", text):
                add(m.start(), m.end(), new, "std.fs." + name)
    for a in aliases(text, "std.fs.path") | aliases(text, "std.Io.Dir.path"):
        for name, new in (("resolve", "resolveAlloc"), ("relative", "relativeAlloc")):
            for m in re.finditer(START + re.escape(a) + r"\." + name + r"(?=\s*\()", text):
                add(m.start(), m.end(), a + "." + new, "std.fs.path." + name)
    for module, renames in (("std.mem", MEM_RENAMES), ("std.ascii", ASCII_RENAMES)):
        for prefix in {module} | aliases(text, module):
            for old in sorted(renames, key=len, reverse=True):
                for m in re.finditer(START + re.escape(prefix) + r"\." + old + r"\b", text):
                    add(m.start(), m.end(), prefix + "." + renames[old], module + "." + old)

    # @import("builtin") fields: os/cpu/abi/object_format move under target, and
    # mode is optimize, whose old tags no longer work with == and !=.
    builtin_refs = [re.escape(b) for b in aliases(text, BUILTIN)] + [re.escape(BUILTIN)]
    ref = r"(?:" + START + r"(?:" + "|".join(builtin_refs[:-1]) + r")|" + builtin_refs[-1] + r")" if builtin_refs[:-1] else builtin_refs[-1]
    for field, new in BUILTIN_FIELDS.items():
        for m in re.finditer(r"(" + ref + r")\." + field + r"\b", text):
            dot = m.start() + len(m.group(1))
            if mask[m.start()] and all(mask[dot:m.end()]):
                edits.append((dot, m.end(), "." + new, "builtin." + field))
    compare = re.compile(r"(" + ref + r")\.mode(\s*(?:==|!=)\s*)\.(" + "|".join(OPTIMIZE_TAGS) + r")\b")
    compared = set()
    for m in compare.finditer(text):
        dot = m.start() + len(m.group(1))
        if mask[m.start()] and all(mask[dot:m.end()]):
            edits.append((dot, m.end(), ".optimize" + m.group(2) + "." + OPTIMIZE_TAGS[m.group(3)], "builtin.mode"))
            compared.add(dot)
    for m in re.finditer(r"(" + ref + r")\.mode\b", text):
        dot = m.start() + len(m.group(1))
        if dot not in compared and mask[m.start()] and all(mask[dot:m.end()]):
            notes.append(f"{path}:{line(m.start())}: builtin.mode is builtin.optimize; rename it and map old tags (.Debug -> .debug, .ReleaseSafe -> .safe, ...) by hand")

    # Old optimize tags where the type is known to be std.lang.Optimize: the
    # `.optimize` option field and comparisons with a variable named optimize.
    tags = "|".join(OPTIMIZE_TAGS)
    for m in re.finditer(r"((?<![\w])\.optimize\s*=\s*|" + START + r"optimize\s*(?:==|!=)\s*)\.(" + tags + r")\b", text):
        add(m.start(), m.end(), m.group(1) + "." + OPTIMIZE_TAGS[m.group(2)], "optimize tag")

    # std.fmt.allocPrint(alloc, ...) -> alloc.print(...).
    for prefix in {"std.fmt"} | fmt_aliases:
        for m in re.finditer(START + re.escape(prefix) + r"\.(allocPrint(?:Sentinel)?)\b", text):
            if not all(mask[m.start():m.end()]):
                continue
            j = m.end()
            while j < len(text) and text[j] in " \t":
                j += 1
            if j >= len(text) or text[j] != "(":
                notes.append(f"{path}:{line(m.start())}: non-call reference to {m.group(0)}")
                continue
            arg = first_arg(text, mask, j)
            if arg is None:
                notes.append(f"{path}:{line(m.start())}: could not parse the {m.group(0)} call")
                continue
            a0, a1, comma = arg
            alloc = text[a0:a1].strip()
            if "\n" in alloc or "//" in alloc or not alloc:
                notes.append(f"{path}:{line(m.start())}: multi-line allocator argument to {m.group(0)}")
                continue
            receiver = alloc if SIMPLE_ALLOC.match(alloc) else f"({alloc})"
            method = "print" if m.group(1) == "allocPrint" else "printSentinel"
            # Keep the layout after the comma: a newline stays, spaces go.
            k = comma + 1
            while k < len(text) and text[k] in " \t":
                k += 1
            tail_start = k if (k < len(text) and text[k] != "\n") else comma + 1
            edits.append((m.start(), tail_start, f"{receiver}.{method}(", "std.fmt." + m.group(1)))

    # Earliest start wins, then the longest match.
    edits.sort(key=lambda e: (e[0], -(e[1] - e[0])))
    kept, last_end = [], -1
    for e in edits:
        if e[0] >= last_end:
            kept.append(e)
            last_end = e[1]
    pieces, pos = [], 0
    for start, end, repl, _ in kept:
        pieces += (text[pos:start], repl)
        pos = end
    pieces.append(text[pos:])
    out = "".join(pieces)

    # Drop file-level aliases that the edits left unused.
    for target in ("std.fmt", "std.fs"):
        for a in aliases(out, target):
            uses = len(re.findall(START + re.escape(a) + r"\b", out))
            before = len(re.findall(START + re.escape(a) + r"\b", text))
            if uses == 1 and before > 1:
                out = re.sub(r"^[ \t]*(?:pub\s+)?const\s+" + re.escape(a) + r"\s*=\s*" + re.escape(target) + r"\s*;[ \t]*\n", "", out, count=1, flags=re.M)
    return out, Counter(e[3] for e in kept), notes


def main(argv):
    write = "--write" in argv
    paths = [a for a in argv if a != "--write"] or ["."]
    total, all_notes, changed = Counter(), [], 0
    errors, warnings = [], []
    for f in zig_files(paths, errors, warnings):
        try:
            text = read_source(f)
        except OSError as e:
            errors.append(f"{display(f)}: {e.strerror or e}")
            continue
        except ValueError as e:
            errors.append(f"{display(f)}: {e}")
            continue
        out, counts, notes = migrate(display(f), text)
        if out != text and write:
            try:
                write_source(f, out)
            except OSError as e:
                errors.append(f"{display(f)}: not written: {e.strerror or e}")
                continue
        total.update(counts)
        all_notes.extend(notes)
        if out != text:
            changed += 1
    for k, v in total.most_common():
        print(f"{v:6}  {k}")
    print(f"files changed: {changed}  edits: {sum(total.values())}" + ("" if write else "  (dry run; pass --write to apply)"))
    for n in all_notes:
        print("NOTE", n)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
