"""Fail CI when new code breaks the mechanical size rules in RULES.md.

  trace-loops  R6.6   a debug_trace call inside a loop body, unless a
                      `// trace:` comment on that line or the line above
                      says why the loop is not per byte, line, or item
  inline       R6.9   an `inline fn` declaration
  std-generic  R6.10  `std.mem.sort`, or `std.json.parseFromSlice` into a
                      type other than `std.json.Value`, outside the modules
                      that cannot import sort_utils or json_decode
  long-fns     R6.11  a function longer than 300 lines
  same-body    R6.15  one function body written in two files
  ceilings     R6.19  a PGSO size ceiling that differs from the recorded one
  test-hooks   R6.21  an FX_TEST_* hook in shipped code that no E2E file,
                      TLA+ driver, eval, or PGSO scenario sets

The findings on main are recorded in scripts/size_rules_baseline.json. A
finding the baseline does not hold fails, and so does a recorded count or
length that grew. A recorded finding that shrank or went away prints a note.
`--write-baseline` records the current tree. Changing the baseline needs
@fazxes's review (CODEOWNERS).

Run from the repository root:

  python3 -m scripts.check_size_rules
  python3 -m scripts.check_size_rules --write-baseline

The pull request size gate (R6.18) reads the Binary Size report:

  python3 -m scripts.check_size_rules size-gate --report report.json \
    --body-file body.md --labels "type: feature,size: approved" --approved-by fazxes
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from scripts.check_cli_shape import Line, Problem, non_test_lines

BASELINE = "scripts/size_rules_baseline.json"
MAX_FUNCTION_LINES = 300
# Bodies shorter than this are too generic to call copies.
MIN_SAME_BODY_CHARS = 80
MIN_SAME_BODY_LINES = 3
# R6.18: __text growth on macOS arm64 that needs a `## Size` section, and
# growth that also needs the `size: approved` label.
SIZE_NOTE_BYTES = 16 * 1024
SIZE_APPROVAL_BYTES = 50 * 1024
SIZE_APPROVAL_LABEL = "size: approved"
# Anyone with triage access can add a label, so the gate also checks who did.
SIZE_APPROVER = "fazxes"
# Modules that may not import sort_utils or json_decode: the indexer, the
# session manager, and the MCP engine import only std and themselves.
STD_ONLY_DIRS = ("src/core/indexer/", "src/core/session_manager/", "src/mcp/")
STD_GENERIC_OWNERS = ("src/core/shared/sort_utils.zig", "src/core/shared/json_decode.zig")
TEST_SUITES = ("tests/e2e", "tests/tla", "tests/evals")
CORPUS = "scripts/pgso/corpus.json"
MACOS_PLATFORM = "scripts/pgso/macos.py"
LINUX_PLATFORMS = "scripts/pgso/linux.py"

FN_HEADER = re.compile(r"^\s*(?:pub\s+)?(?:export\s+)?(?:inline\s+|noinline\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
INLINE_FN = re.compile(r"^\s*(?:pub\s+)?inline\s+fn\s")
RETURNS_TYPE = re.compile(r"\)\s*type\s*\{")
LOOP_HEAD = re.compile(r"\b(?:for|while)\s*\(")
TRACE_CALL = re.compile(r"\bdebug_trace\.(?:logf|eventf)\(")
TRACE_REASON = "// trace:"
STD_SORT = re.compile(r"\bstd\.mem\.sort\(")
STD_JSON_PARSE = re.compile(r"\bstd\.json\.parseFromSlice(?:Leaky)?\(\s*([^,]+?)\s*,")
IMPORT = re.compile(r'@import\("([^"]+)"\)')
TEST_HOOK = re.compile(r'"(FX_TEST_[A-Z0-9_]+)"')
ANY_TEST_HOOK = re.compile(r"\bFX_TEST_[A-Z0-9_]+\b")
MACOS_CEILING = re.compile(r"^SIZE_CEILING_MIB = ([0-9.]+)", re.M)
LINUX_CEILING = re.compile(r'TARGET="([^"]+)".*?SIZE_CEILING_MIB=([0-9.]+)', re.S)
SIZE_SECTION = re.compile(r"^##\s+Size\s*$\n+(?P<text>\S.*)", re.M)


@dataclass(frozen=True)
class Function:
    path: str
    name: str
    lines: tuple[Line, ...]

    @property
    def length(self) -> int:
        return self.lines[-1].number - self.lines[0].number + 1


def is_test_file(path: str) -> bool:
    parts = path.split("/")
    name = parts[-1]
    return "tests" in parts[:-1] or name.endswith(("_tests.zig", "_test.zig")) or name == "fuzz_targets.zig"


def functions(lines: list[Line]) -> list[Function]:
    """Every function with a body. A function that returns `type` is a
    namespace, so its members are read as functions of their own."""
    found: list[Function] = []
    index = 0
    while index < len(lines):
        match = FN_HEADER.match(lines[index].code)
        if not match:
            index += 1
            continue
        depth = 0
        opened = False
        header = ""
        end = index
        while end < len(lines):
            code = lines[end].code
            if not opened:
                header += code
            depth += code.count("{") - code.count("}")
            opened = opened or "{" in code
            if opened and depth <= 0:
                break
            if not opened and code.rstrip().endswith(";"):
                break
            end += 1
        if not opened or RETURNS_TYPE.search(header):
            index += 1
            continue
        found.append(Function(lines[index].path, match.group(1), tuple(lines[index : end + 1])))
        index = end + 1
    return found


def traces_in_loops(function: Function) -> list[Line]:
    """Trace calls inside a loop body, braced or a single statement."""
    hits: list[Line] = []
    frames: list[bool] = []
    awaiting_body = False
    previous = ""
    for line in function.lines:
        code = line.code
        head = LOOP_HEAD.search(code)
        inside = any(frames) or awaiting_body
        same_line_loop = head is not None and TRACE_CALL.search(code[head.end() :]) is not None
        if TRACE_CALL.search(code) and (inside or same_line_loop):
            if TRACE_REASON not in line.text and not previous.strip().startswith(TRACE_REASON):
                hits.append(line)
        marker = head.end() if head else None
        for position, char in enumerate(code):
            if char == "{":
                literal = code[:position].rstrip().endswith(".")
                is_loop = not literal and (awaiting_body or (marker is not None and position >= marker))
                frames.append(is_loop)
                if is_loop:
                    awaiting_body = False
                    marker = None
            elif char == "}" and frames:
                frames.pop()
        if marker is not None:
            awaiting_body = not code.rstrip().endswith(";")
        elif awaiting_body and code.rstrip().endswith(";"):
            awaiting_body = False
        previous = line.text
    return hits


def body_key(function: Function) -> str | None:
    """A hash of the code after the signature, or None for a short body."""
    code = "\n".join(line.code for line in function.lines)
    body = code[code.find("{") + 1 :]
    meaningful = [line for line in body.splitlines() if line.strip() and line.strip() != "}"]
    compact = re.sub(r"\s+", "", body)
    if len(compact) < MIN_SAME_BODY_CHARS or len(meaningful) < MIN_SAME_BODY_LINES:
        return None
    return hashlib.sha256(compact.encode()).hexdigest()


def imports_only_std(text: str) -> bool:
    return all(name in ("std", "builtin") for name in IMPORT.findall(text))


class Checker:
    def __init__(self, root: Path) -> None:
        self.root = root
        # Where each finding is, for messages; the baseline holds no line numbers.
        self.lines: dict[str, list[int]] = {}

    def read(self, path: str) -> str:
        return (self.root / path).read_text(errors="replace")

    def sources(self) -> list[str]:
        return sorted(
            str(path.relative_to(self.root))
            for path in (self.root / "src").rglob("*.zig")
            if not is_test_file(str(path.relative_to(self.root)))
        )

    def findings(self) -> dict:
        long_functions: dict[str, int] = {}
        inline_fns: dict[str, int] = {}
        std_generic: dict[str, int] = {}
        trace_loops: dict[str, int] = {}
        bodies: dict[str, set[str]] = {}
        hooks: set[str] = set()
        for path in self.sources():
            text = self.read(path)
            lines = non_test_lines(path, text)
            seen: dict[str, int] = {}
            for function in functions(lines):
                seen[function.name] = seen.get(function.name, 0) + 1
                ident = f"{path}::{function.name}" + (f"#{seen[function.name]}" if seen[function.name] > 1 else "")
                if function.length > MAX_FUNCTION_LINES:
                    long_functions[ident] = function.length
                    self.lines[ident] = [function.lines[0].number]
                hits = traces_in_loops(function)
                if hits:
                    trace_loops[path] = trace_loops.get(path, 0) + len(hits)
                    self.lines.setdefault(f"trace_loops:{path}", []).extend(line.number for line in hits)
                key = body_key(function)
                if key:
                    bodies.setdefault(key, set()).add(ident)
            inline = [line.number for line in lines if INLINE_FN.match(line.code)]
            if inline:
                inline_fns[path] = len(inline)
                self.lines[f"inline_fns:{path}"] = inline
            if not (path.startswith(STD_ONLY_DIRS) or path in STD_GENERIC_OWNERS or imports_only_std(text)):
                code = "\n".join(line.code for line in lines)
                generic = len(STD_SORT.findall(code))
                generic += sum(1 for kind in STD_JSON_PARSE.findall(code) if kind != "std.json.Value")
                if generic:
                    std_generic[path] = generic
            hooks.update(TEST_HOOK.findall("\n".join(line.text for line in lines if "//" not in line.text.split('"')[0])))
        same_bodies = sorted(
            sorted(members) for members in bodies.values() if len({member.split("::")[0] for member in members}) > 1
        )
        return {
            "ceilings": self.ceilings(),
            "long_functions": dict(sorted(long_functions.items())),
            "inline_fns": dict(sorted(inline_fns.items())),
            "std_generic": dict(sorted(std_generic.items())),
            "trace_loops": dict(sorted(trace_loops.items())),
            "same_bodies": same_bodies,
            "test_hooks": sorted(hooks - self.hooks_set_by_tests()),
        }

    def ceilings(self) -> dict[str, float]:
        found = {"aarch64-macos": float(m.group(1)) for m in MACOS_CEILING.finditer(self.read(MACOS_PLATFORM))}
        found.update({target: float(mib) for target, mib in LINUX_CEILING.findall(self.read(LINUX_PLATFORMS))})
        if "aarch64-macos" not in found or len(found) < 3:
            raise ValueError("cannot read the PGSO size ceilings from scripts/pgso/")
        return dict(sorted(found.items()))

    def hooks_set_by_tests(self) -> set[str]:
        corpus = json.loads(self.read(CORPUS))
        excluded = set(corpus.get("intentional_exclusions", {}))
        names = set(ANY_TEST_HOOK.findall(self.read(CORPUS)))
        for suite in TEST_SUITES:
            for path in (self.root / suite).rglob("*"):
                if not path.is_file() or "node_modules" in path.parts or path.name in excluded:
                    continue
                if path.suffix in (".ts", ".js", ".mjs", ".py", ".sh", ".json", ".zig"):
                    names.update(ANY_TEST_HOOK.findall(path.read_text(errors="replace")))
        return names

    def compare(self, baseline: dict) -> tuple[list[Problem], list[str]]:
        now = self.findings()
        problems: list[Problem] = []
        notes: list[str] = []
        for target, mib in now["ceilings"].items():
            if baseline.get("ceilings", {}).get(target) != mib:
                problems.append(Problem(MACOS_PLATFORM if target.endswith("macos") else LINUX_PLATFORMS, 0, "ceilings",
                    f"{target} ceiling {mib} MiB differs from the recorded {baseline.get('ceilings', {}).get(target)} MiB; "
                    "raising a ceiling needs @fazxes's approval and a growth report (R6.19)"))
        for ident, length in now["long_functions"].items():
            recorded = baseline.get("long_functions", {}).get(ident)
            if recorded is None or length > recorded:
                limit = f"its recorded {recorded}" if recorded else str(MAX_FUNCTION_LINES)
                problems.append(Problem(ident.split("::")[0], self.lines[ident][0], "long-fns",
                    f"{ident.split('::')[1]} is {length} lines, over {limit}; split it (R6.11)"))
        for ident, recorded in baseline.get("long_functions", {}).items():
            if now["long_functions"].get(ident, 0) < recorded:
                notes.append(f"long-fns: {ident} is now {now['long_functions'].get(ident, 'within the limit or gone')}; its baseline can be lowered")
        for key, check, rule, what in (
            ("inline_fns", "inline", "R6.9", "inline fn declaration(s)"),
            ("std_generic", "std-generic", "R6.10", "std.mem.sort or typed std.json parse call(s); use sort_utils or json_decode"),
            ("trace_loops", "trace-loops", "R6.6", "trace call(s) inside a loop; add a `// trace:` reason or move the call"),
        ):
            recorded = baseline.get(key, {})
            for path, count in now[key].items():
                if count > recorded.get(path, 0):
                    at = self.lines.get(f"{key}:{path}", [0])
                    where = f" at lines {', '.join(map(str, at))}" if len(at) > 1 else ""
                    problems.append(Problem(path, at[0], check, f"{count} {what}{where}, {recorded.get(path, 0)} recorded ({rule})"))
            for path, count in recorded.items():
                if now[key].get(path, 0) < count:
                    notes.append(f"{check}: {path} has {now[key].get(path, 0)} of {count} recorded; its baseline can be lowered")
        recorded_groups = [set(group) for group in baseline.get("same_bodies", [])]
        for group in now["same_bodies"]:
            if not any(set(group) <= known for known in recorded_groups):
                problems.append(Problem(group[0].split("::")[0], 0, "same-body",
                    "same function body in " + ", ".join(group) + "; import one copy (R6.15)"))
        for hook in now["test_hooks"]:
            if hook not in baseline.get("test_hooks", []):
                problems.append(Problem("src", 0, "test-hooks",
                    f"{hook} ships in fx but no E2E file, TLA+ driver, eval, or PGSO scenario sets it; "
                    "keep it behind builtin.is_test (R6.21)"))
        return problems, notes


def size_gate(report: dict, body: str, labels: list[str], approved_by: str) -> list[str]:
    """R6.18: macOS arm64 __text growth needs a reason, and large growth an approval."""
    growth = int(report.get("section_deltas_bytes", {}).get("__TEXT.__text", 0))
    failures: list[str] = []
    if growth >= SIZE_NOTE_BYTES and not SIZE_SECTION.search(body):
        failures.append(
            f"__text grew by {growth:,} bytes (one 16 KB page or more). Add a `## Size` section to the PR "
            "description that says what the growth buys, then rerun this job (R6.18)."
        )
    if growth >= SIZE_APPROVAL_BYTES and not (SIZE_APPROVAL_LABEL in labels and approved_by == SIZE_APPROVER):
        failures.append(
            f"__text grew by {growth:,} bytes (50 KB or more). This needs the `{SIZE_APPROVAL_LABEL}` label "
            f"added by @{SIZE_APPROVER}, then a rerun of this job (R6.18)."
        )
    return failures


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="repository root")
    parser.add_argument("--write-baseline", action="store_true", help="record the current tree as the baseline")
    sub = parser.add_subparsers(dest="command")
    gate = sub.add_parser("size-gate", help="R6.18 check of a Binary Size report")
    gate.add_argument("--report", type=Path, required=True)
    gate.add_argument("--body-file", type=Path, required=True)
    gate.add_argument("--labels", default="", help="comma-separated pull request labels")
    gate.add_argument("--approved-by", default="", help=f"who last added the {SIZE_APPROVAL_LABEL} label")
    args = parser.parse_args(argv)

    if args.command == "size-gate":
        labels = [label.strip() for label in args.labels.split(",") if label.strip()]
        body = args.body_file.read_text(errors="replace")
        failures = size_gate(json.loads(args.report.read_text()), body, labels, args.approved_by)
        for failure in failures:
            print(f"::error title=Binary size rule::{failure}")
        return 1 if failures else 0

    checker = Checker(args.root)
    try:
        if args.write_baseline:
            (args.root / BASELINE).write_text(json.dumps(checker.findings(), indent=2) + "\n")
            print(f"wrote {BASELINE}")
            return 0
        problems, notes = checker.compare(json.loads(checker.read(BASELINE)))
    except (OSError, ValueError) as err:
        print(f"check_size_rules: {err}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"note: {note}")
    for problem in problems:
        print(problem.render())
    if problems:
        print(f"{len(problems)} size rule problem(s). See RULES.md section 6.")
        return 1
    print("size rules: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
