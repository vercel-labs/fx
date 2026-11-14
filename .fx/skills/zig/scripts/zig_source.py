"""What check_deprecated.py and migrate.py share: which files they read, how
they read them, how they tell code from comments and literals, and the std
names that Zig 0.17 renamed.

Reads files only; no network access and no code execution.
"""
import bisect
import os
import re
import stat

# A name starts after a non-word, non-dot character or right after a range
# `..`; a single `.` before it means field access on something else.
START = r"(?:(?<=\.\.)|(?<![\w.]))"

SKIP_DIRS = {".zig-cache", "zig-cache", "zig-out", "zig-pkg", ".git", "node_modules"}

# Exact renames: each old name forwards to the new one in 0.17, so rewriting it
# cannot change behavior. check_deprecated.py reports every old name here, and
# test_rename_tables.py checks that.
MEM_RENAMES = {
    "indexOfScalarPos": "findScalarPos", "indexOfScalar": "findScalar",
    "indexOfAnyPos": "findAnyPos", "indexOfAny": "findAny",
    "indexOfNone": "findNone", "indexOfDiff": "findDiff",
    "indexOfSentinel": "findSentinel", "indexOfMinMax": "findMinMax",
    "indexOfMin": "findMin", "indexOfPos": "findPos", "indexOf": "find",
    "lastIndexOfScalar": "findScalarLast", "lastIndexOfAny": "findLastAny",
    "lastIndexOfNone": "findLastNone", "lastIndexOfLinear": "findLastLinear",
    "lastIndexOf": "findLast",
}
# The old std.ascii names no longer compile on 0.17.
ASCII_RENAMES = {
    "indexOfIgnoreCasePosLinear": "findIgnoreCasePosLinear",
    "indexOfIgnoreCasePos": "findIgnoreCasePos",
    "indexOfIgnoreCase": "findIgnoreCase",
}
STD_RENAMES = {
    "std.ArrayListAlignedUnmanaged": "std.array_list.Aligned",
    "std.ArrayListAligned": "std.array_list.Aligned",
    "std.ArrayListUnmanaged": "std.ArrayList",
    "std.StringArrayHashMapUnmanaged": "std.array_hash_map.String",
    "std.AutoArrayHashMapUnmanaged": "std.array_hash_map.Auto",
    "std.ArrayHashMapUnmanaged": "std.array_hash_map.Custom",
    "std.DynamicBitSetUnmanaged": "std.bit_set.Dynamic",
    "std.StaticBitSet": "std.bit_set.Static",
    "std.bit_set.IntegerBitSet": "std.bit_set.Integer",
    "std.bit_set.ArrayBitSet": "std.bit_set.Array",
    "std.bit_set.StaticBitSet": "std.bit_set.Static",
    "std.bit_set.DynamicBitSetUnmanaged": "std.bit_set.Dynamic",
    "std.builtin.OptimizeMode": "std.lang.Optimize",
    "std.lang.OptimizeMode": "std.lang.Optimize",
    "std.builtin": "std.lang",
    "std.fs.max_path_bytes": "std.Io.Dir.max_path_bytes",
    "std.fs.max_name_bytes": "std.Io.Dir.max_name_bytes",
    "std.fs.path.resolve": "std.Io.Dir.path.resolveAlloc",
    "std.fs.path.relative": "std.Io.Dir.path.relativeAlloc",
    "std.fs.path": "std.Io.Dir.path",
    "std.fmt.bufPrintSentinel": "std.mem.printSentinel",
    "std.fmt.bufPrint": "std.mem.print",
    "std.fmt.BufPrintError": "std.mem.PrintError",
}


def code_mask(text):
    """Flag each character as code (1) or comment/string/char literal (0)."""
    mask = bytearray(b"\x01") * len(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i) or c == "\\" and text.startswith("\\\\", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
        elif c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
        else:
            i += 1
            continue
        mask[i:j] = b"\x00" * (j - i)
        i = j
    return mask


def aliases(text, target):
    pat = re.compile(r"\bconst\s+([A-Za-z_]\w*)\s*=\s*" + re.escape(target) + r"\s*;")
    return {m.group(1) for m in pat.finditer(text)}


class Lines:
    """1-based line numbers by binary search, so many findings on one long
    line cost no more than a few on a short one."""

    def __init__(self, text):
        self.starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def number(self, pos):
        return bisect.bisect_right(self.starts, pos)


def display(path):
    """A path that is safe to print: control bytes and bytes the file system
    name did not decode are written as \\xNN, so a file name cannot drive the
    terminal."""
    out = []
    for ch in path:
        o = ord(ch)
        if 0xDC80 <= o <= 0xDCFF:
            out.append(f"\\x{o - 0xDC00:02x}")
        elif o < 0x20 or 0x7F <= o < 0xA0:
            out.append(f"\\x{o:02x}")
        else:
            out.append(ch)
    return "".join(out)


def zig_files(paths, errors, warnings):
    """Yield the regular files to read, in a stable order.

    A path given on the command line may be any regular file, or a directory
    to search for `.zig` files. Inside a directory, symbolic links and
    anything that is not a regular file, such as a FIFO, are skipped and named
    in `warnings`, so a run neither leaves the tree nor blocks on a read. A
    given path that is missing, a symbolic link to a file, or neither a file
    nor a directory is named in `errors`.
    """
    for p in paths:
        try:
            st = os.lstat(p)
        except OSError as e:
            errors.append(f"{display(p)}: {e.strerror or e}")
            continue
        if stat.S_ISLNK(st.st_mode):
            if os.path.isdir(p):
                yield from _walk(p, errors, warnings)
            else:
                errors.append(f"{display(p)}: is a symbolic link; pass the file it points to")
        elif stat.S_ISDIR(st.st_mode):
            yield from _walk(p, errors, warnings)
        elif stat.S_ISREG(st.st_mode):
            yield p
        else:
            errors.append(f"{display(p)}: not a regular file or directory")


def _walk(top, errors, warnings):
    def failed(e):
        errors.append(f"{display(e.filename or top)}: {e.strerror or e}")

    for root, dirs, files in os.walk(top, onerror=failed):
        kept = []
        for d in sorted(dirs):
            if d in SKIP_DIRS:
                continue
            if os.path.islink(os.path.join(root, d)):
                warnings.append(f"{display(os.path.join(root, d))}: skipped a symbolic link")
                continue
            kept.append(d)
        dirs[:] = kept
        for name in sorted(files):
            if not name.endswith(".zig"):
                continue
            path = os.path.join(root, name)
            try:
                mode = os.lstat(path).st_mode
            except OSError as e:
                errors.append(f"{display(path)}: {e.strerror or e}")
                continue
            if stat.S_ISLNK(mode):
                warnings.append(f"{display(path)}: skipped a symbolic link")
            elif not stat.S_ISREG(mode):
                warnings.append(f"{display(path)}: skipped, not a regular file")
            else:
                yield path


def read_source(path):
    """Return the file's text. Raises OSError, or ValueError naming the first
    byte that is not UTF-8, which Zig rejects in source files too."""
    # O_NONBLOCK: a file swapped for a FIFO after the type check cannot block.
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as f:
        data = f.read()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ValueError(f"not UTF-8 at byte {e.start}") from None


def write_source(path, text):
    """Rewrite a file found by zig_files in place, never through a link."""
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(text)
