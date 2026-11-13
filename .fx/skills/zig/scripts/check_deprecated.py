#!/usr/bin/env python3
"""Report Zig code that Zig 0.17.x deprecates, removed, or silently changed.

usage: check_deprecated.py [--review] [--strict] [PATH ...]   (default PATH: .)

Each finding prints `path:line: [kind] old -> replacement`.
  deprecated  still compiles on 0.17, scheduled for removal
  removed     does not compile on 0.17
  review      compiles, but 0.17 changed its meaning; read the call site.
              Counted always, listed only with --review (use it when migrating).
Exit status is 1 when any deprecated or removed finding exists, or any
finding at all with --strict, and 2 when a given path could not be read.
Directories are searched for .zig files; symbolic links and files that are
not regular files are skipped there. Comments and string literals are ignored.
File-level aliases such as `const mem = std.mem;` are resolved.
Reads files only; no network access and no code execution.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zig_source import (  # noqa: E402
    ASCII_RENAMES, MEM_RENAMES, START, Lines, aliases, code_mask, display, read_source, zig_files,
)

# (module, regex for the member, replacement, kind)
MODULE_RULES = [
    *(("std.mem", re.escape(old), f"std.mem.{new}", "deprecated") for old, new in MEM_RENAMES.items()),
    *(("std.ascii", re.escape(old), f"std.ascii.{new}", "removed") for old, new in ASCII_RENAMES.items()),
    ("std.fmt", r"allocPrint(?!Sentinel)", "Allocator.print: allocator.print(fmt, args)", "deprecated"),
    ("std.fmt", r"allocPrintSentinel", "Allocator.printSentinel: allocator.printSentinel(fmt, args, sentinel)", "deprecated"),
    ("std.fmt", r"bufPrint(?!Sentinel)", "std.mem.print(buf, fmt, args)", "deprecated"),
    ("std.fmt", r"bufPrintSentinel", "std.mem.printSentinel(buf, fmt, args, sentinel)", "deprecated"),
    ("std.fmt", r"BufPrintError", "std.mem.PrintError", "deprecated"),
    ("std.mem", r"copy(?:Forwards|Backwards)", "@memmove(dest[0..src.len], src) (lengths must match)", "deprecated"),
    ("std.mem", r"byteSwapAllFields(?:Aligned)?", "std.mem.byteSwap / byteSwapAligned", "deprecated"),
    ("std.mem", r"(?:read|write)PackedInt(?:Native|Foreign)", "std.mem.readPackedInt / writePackedInt", "removed"),
    ("std.mem", r"containsAtLeastScalar2", "std.mem.containsAtLeastScalar(T, list, element, minimum)", "removed"),
    ("std.fs", r"path\.(?:resolve|relative)(?=\s*\()", "std.Io.Dir.path.resolveAlloc / relativeAlloc", "deprecated"),
    ("std.fs", r"path", "std.Io.Dir.path", "deprecated"),
    ("std.fs", r"max_path_bytes", "std.Io.Dir.max_path_bytes", "deprecated"),
    ("std.fs", r"max_name_bytes", "std.Io.Dir.max_name_bytes", "deprecated"),
    ("std.fs", r"base64_(?:alphabet|encoder|decoder)", "std.base64.url_safe", "deprecated"),
    ("std.unicode", r"(?:utf8|wtf8)Decode(?=\s*\()", "check utf8ByteSequenceLength, then utf8Decode2/3/4", "deprecated"),
    ("std.meta", r"field(?:Info|Names|Types)", "@typeInfo(T).@\"struct\".field_names / field_types", "deprecated"),
    ("std.debug", r"runtime_safety", "@import(\"builtin\").optimize.runtimeSafety()", "deprecated"),
    ("std.heap", r"DebugAllocator(?:Config)?", "std.heap.SafeAllocator (a separate implementation; or init.gpa from main(init: std.process.Init))", "deprecated"),
    ("std.heap", r"(?:StackFallbackAllocator|stackFallback)", "std.heap.BufferFirstAllocator.init(buffer, fallback)", "removed"),
    ("std.heap", r"Check", "(deprecated; no replacement)", "deprecated"),
    ("std.ascii", r"indexOfIgnoreCase\w*", "std.ascii.findIgnoreCase*", "removed"),
    ("std.tar", r"pipeToFileSystem", "std.tar.extract", "deprecated"),
    ("std.tar", r"PipeOptions", "std.tar.ExtractOptions", "deprecated"),
    ("std.zig", r"allocPrintCmd", "(deprecated)", "deprecated"),
    ("std.testing", r"parent_dir_path", "(deprecated)", "deprecated"),
    ("std.lang", r"OptimizeMode", "std.lang.Optimize", "deprecated"),
]
STD_RULES = [
    (r"std\.builtin\b", "std.lang", "deprecated"),
    (r"std\.gpu\b", "std.spirv", "removed"),
    (r"std\.ArrayListUnmanaged\b", "std.ArrayList", "deprecated"),
    (r"std\.ArrayListAligned(?:Unmanaged)?\b", "std.array_list.Aligned", "deprecated"),
    (r"std\.array_list\.(?:Aligned)?Managed\b", "std.ArrayList (pass the allocator)", "deprecated"),
    (r"std\.StringArrayHashMapUnmanaged\b", "std.array_hash_map.String", "deprecated"),
    (r"std\.AutoArrayHashMapUnmanaged\b", "std.array_hash_map.Auto", "deprecated"),
    (r"std\.ArrayHashMapUnmanaged\b", "std.array_hash_map.Custom", "deprecated"),
    (r"std\.(?:bit_set\.)?DynamicBitSetUnmanaged\b", "std.bit_set.Dynamic", "deprecated"),
    (r"std\.(?:bit_set\.)?DynamicBitSet\b", "std.bit_set.Dynamic (allocator per call)", "deprecated"),
    (r"std\.(?:bit_set\.)?StaticBitSet\b", "std.bit_set.Static", "deprecated"),
    (r"std\.bit_set\.IntegerBitSet\b", "std.bit_set.Integer", "deprecated"),
    (r"std\.bit_set\.ArrayBitSet\b", "std.bit_set.Array", "deprecated"),
    (r"std\.heap\.memory_pool\.(?:Aligned|Extra)Managed\b", "std.heap.memory_pool.Aligned / Extra", "removed"),
]
BUILTIN_FIELDS = [
    ("os", "target.os"), ("cpu", "target.cpu"), ("abi", "target.abi"),
    ("object_format", "target.ofmt"), ("mode", "optimize"),
]
SYNTAX_RULES = [
    (r"@intFromEnum\s*\(", "@intFromEnum", "@backingInt", "deprecated"),
    (r"@enumFromInt\s*\(", "@enumFromInt", "@fromBackingInt (result type inferred; argument must be the exact backing type)", "deprecated"),
    (r"@cImport\s*\(", "@cImport", "translate-c package (see build-system reference)", "removed"),
    # Only after a string or array literal: `**u8` after `]` or `)` is a type.
    (r"(?:\"|\})\s*\*\*\s*[\w(]", "** array repetition", "@splat for arrays, a comptime loop for repeated strings", "removed"),
    (r"\berrdefer\s*\|", "errdefer capture", "split into an inner function and handle the error in the caller", "removed"),
    # zig fmt writes the removed value syntax as `void{}` and a void function body as `void {}`.
    (r"(?<![\w.!])void\{\s*\}", "void{}", "{}", "removed"),
    # Only in type positions, so a variable named i0 is not reported.
    (r"(?:(?<=[:\]*?!])\s*|@as\(\s*)i0\b", "i0", "u0", "removed"),
    (r"\.Release(?:Safe|Fast|Small)\b", "Debug/ReleaseSafe/ReleaseFast/ReleaseSmall tag", ".debug / .safe / .fast / .small", "deprecated"),
    (r"\.getLast(?:OrNull)?\s*\(\s*\)", "ArrayList.getLast/getLastOrNull", "last() (optional) or last().?", "deprecated"),
    (r"\.readAlloc\s*\(", "Io.Reader.readAlloc", "readAllocAll", "deprecated"),
    (r"\.sendMany\s*\(", "Io.net sendMany", "sendManyTimeout(..., .none)", "deprecated"),
    (r"\.(?:initEmpty|initFull)\s*\(\s*\)", "bit set / EnumSet initEmpty()/initFull()", ".empty / .full", "removed"),
]
# Reported only when the second pattern follows on the same line.
SAME_LINE_RULES = [
    (r"\.(?:internal|link_once)\b", r"linkage", "internal/link_once linkage", "do not @export, or use .weak", "removed"),
    (r"\.Debug\b", r"optimize|mode|Optimize", "Debug/ReleaseSafe/ReleaseFast/ReleaseSmall tag", ".debug / .safe / .fast / .small", "deprecated"),
]
REVIEW_RULES = [
    (r"containsAtLeastScalar\s*\(", "containsAtLeastScalar", "0.17 order is (T, list, element, minimum); 0.16 was (T, list, minimum, element)"),
    (r"@hasDecl\s*\(", "@hasDecl", "0.17 only sees pub declarations, even in the same file"),
    (r"@bitCast\s*\(", "@bitCast", "0.17 redefined casts involving arrays/vectors and rejects extern struct/union operands"),
    (r"(?<![\w.])std\.Io\.Evented\b", "std.Io.Evented", "does not compile on 0.17.0 or 0.17.1; use std.Io.Threaded"),
]


def findings(text):
    mask = code_mask(text)
    lines = Lines(text)
    seen = set()

    def emit(m, old, new, kind, start=None):
        s = m.start() if start is None else start
        if not mask[s] or (s, kind) in seen:
            return None
        seen.add((s, kind))
        return (lines.number(s), kind, old, new)

    out = []
    for module, member, new, kind in MODULE_RULES:
        prefixes = [re.escape(module)] + [re.escape(a) for a in aliases(text, module)]
        if module == "std.fs":
            prefixes += [re.escape(a) + r"(?=\.(?:resolve|relative)\s*\()" for a in aliases(text, "std.fs.path")]
        for p in prefixes:
            pat = START + p + (r"\." + member if "(?=" not in p else r"\.(?:resolve|relative)") + r"\b"
            for m in re.finditer(pat, text):
                f = emit(m, m.group(0), new, kind)
                if f:
                    out.append(f)
    for pat, new, kind in STD_RULES:
        for m in re.finditer(START + pat, text):
            f = emit(m, m.group(0), new, kind)
            if f:
                out.append(f)
    names = aliases(text, '@import("builtin")')
    for field, new in BUILTIN_FIELDS:
        for b in names:
            for m in re.finditer(START + re.escape(b) + r"\." + field + r"\b", text):
                f = emit(m, m.group(0), f"{b}.{new}", "deprecated")
                if f:
                    out.append(f)
        for m in re.finditer(r'@import\("builtin"\)\.' + field + r"\b", text):
            f = emit(m, m.group(0), f'@import("builtin").{new}', "deprecated")
            if f:
                out.append(f)
    for pat, old, new, kind in SYNTAX_RULES:
        for m in re.finditer(pat, text):
            start = m.start()
            if old == "** array repetition":
                start = text.index("**", m.start())
            f = emit(m, old, new, kind, start)
            if f:
                out.append(f)
    for pat, after, old, new, kind in SAME_LINE_RULES:
        # The last start of `after` on each line, found in one pass.
        last_after = {}
        for m in re.finditer(after, text):
            last_after[lines.number(m.start())] = m.start()
        for m in re.finditer(pat, text):
            if last_after.get(lines.number(m.start()), -1) >= m.end():
                f = emit(m, old, new, kind)
                if f:
                    out.append(f)
    for pat, old, note in REVIEW_RULES:
        for m in re.finditer(pat, text):
            f = emit(m, old, note, "review")
            if f:
                out.append(f)
    return sorted(out)


def main(argv):
    strict = "--strict" in argv
    show_review = "--review" in argv or strict
    paths = [a for a in argv if a not in ("--strict", "--review")] or ["."]
    counts = {"deprecated": 0, "removed": 0, "review": 0}
    errors, warnings = [], []
    for path in sorted(zig_files(paths, errors, warnings)):
        try:
            text = read_source(path)
        except OSError as e:
            errors.append(f"{display(path)}: {e.strerror or e}")
            continue
        except ValueError as e:
            errors.append(f"{display(path)}: {e}")
            continue
        for line, kind, old, new in findings(text):
            counts[kind] += 1
            if kind != "review" or show_review:
                print(f"{display(path)}:{line}: [{kind}] {old} -> {new}")
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    unread = f", {len(errors)} could not be read" if errors else ""
    print(f"summary: {counts['removed']} removed, {counts['deprecated']} deprecated, {counts['review']} to review{unread}")
    if errors:
        return 2
    failing = counts["removed"] + counts["deprecated"] + (counts["review"] if strict else 0)
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
