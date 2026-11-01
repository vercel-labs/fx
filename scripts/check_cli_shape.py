"""Fail CI when fx's user-facing controls drift from the shape rules.

The check reads the real source rather than a model of it:

  env       every FX_* name in src/ is registered with a job and a stability,
            test hooks and only test hooks start with FX_TEST_, every other
            env var read by name is listed, and nothing is stale
  flags     flags are kebab-case and carry no value inside their name
  parsing   CLI code reads flags through cli_flags and the option lists help
            renders, so no command compares an argument with a flag by hand
  settings  settings keys are snake_case, and the settings list in
            src/core/config/settings_keys.zig marks exactly the keys
            parseProjectSafeFields reads as project-safe
  warnings  every key the profile parser reads is in the settings list as
            profile-only, so fx doctor knows it and a project .fx.json that
            sets it gets a warning

Known exceptions live in scripts/cli_shape_registry.json, each with the reason
and the finding that removes it. An exception that no longer matches anything
is reported as stale, so the list only shrinks.

Run from the repository root: python3 -m scripts.check_cli_shape
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REGISTRY = "scripts/cli_shape_registry.json"
COMMANDS = "src/builtins/commands.zig"
MAIN = "src/main.zig"
COMMAND_SPECS = "src/core/slash_commands/command_specs.zig"
CLI_SURFACE = "src/core/cli/cli_surface.zig"
CLI_ASK = "src/core/cli/cli_ask.zig"
CONFIG_RUNTIME = "src/core/config/config_runtime.zig"
SETTINGS_KEYS = "src/core/config/settings_keys.zig"
ACP_SESSIONS = "src/acp/sessions.zig"
ACP_SERVER = "src/acp/server.zig"
LIBFX_TYPES = "sdk/types/libfx.d.cts"

JOBS = {
    "setting-override",
    "credentials",
    "location",
    "integration",
    "diagnostics",
    "test",
    "internal",
    "experimental",
}
STABILITIES = {"stable", "experimental", "deprecated", "internal"}

KEBAB_FLAG = re.compile(r"^--[a-z0-9]+(?:-[a-z0-9]+)*$")
SHORT_FLAG = re.compile(r"^-[A-Za-z0-9]$")
SNAKE_KEY = re.compile(r"^[a-z][a-z0-9_]*$")
FX_LITERAL = re.compile(r'"(FX_[A-Z0-9_]+)"')
GETENV_LITERAL = re.compile(r'getenv\("([A-Za-z_][A-Za-z0-9_]*)"\)')
FLAG_LITERAL = re.compile(r'"(--?[A-Za-z0-9][A-Za-z0-9_<>-]*)=?"')
KEY_READ = re.compile(r'\.(?:get|getPtr|contains)\("([^"]+)"\)')
# An ACP config option as sessions.zig writes it: {\"id\":\"model\",\"name\":...
ACP_CONFIG_ID = re.compile(r'\\"id\\":\\"([a-z_]+)\\",\\"name\\"')
# fx's version, and the release that drops the old spellings.
VERSION = re.compile(r'^pub const version = "(\d+)\.(\d+)\.(\d+)";', re.M)
OLD_SPELLING_REMOVAL = re.compile(r'^pub const old_spelling_removal = "(\d+)\.(\d+)\.(\d+)";', re.M)
# A config option ID that session/set_config_option accepts.
ACP_SET_ID = re.compile(r'std\.mem\.eql\(u8, config_id, "([a-z_]+)"\)')
LIBFX_MODEL_FIELD = re.compile(r"^\s+([a-z][A-Za-z]*)\??:")
# The libfx types a non-model run option is a field of: each provider config.
LIBFX_PROVIDER_TYPES = ("FxGatewayProvider", "FxSubscriptionProvider", "FxCustomProvider")
TOP_LEVEL_KEY_READ = re.compile(r'\broot\.object\.(?:get|getPtr|contains)\("([^"]+)"\)')
SETTING_ENTRY = re.compile(r'\.name = "([^"]+)", \.where = \.([a-z_]+)')
TEST_START = re.compile(r"^\s*test\b")
HAND_FLAG = r'(-{1,2}[A-Za-z][A-Za-z0-9-]*=?)'
# `eql(u8, arg, "--x")` and `eql(u8, "--x", arg)`.
HAND_COMPARE = re.compile(r'(?:eql|startsWith)\(u8,\s*[^,"]+,\s*"' + HAND_FLAG + '"')
HAND_COMPARE_FIRST = re.compile(r'(?:eql|startsWith)\(u8,\s*"' + HAND_FLAG + r'"\s*,')
# A flag kept in a named constant, such as `const resume_short_flag = "-r";`.
FLAG_CONSTANT = re.compile(r'\bconst\s+(\w+)\s*=\s*"' + HAND_FLAG + '";')
CLI_DIR = "src/core/cli"
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
CHAR = re.compile(r"'(?:\\.|[^'\\])+'")


@dataclass(frozen=True)
class Line:
    path: str
    number: int
    text: str
    code: str


@dataclass(frozen=True)
class Problem:
    path: str
    number: int
    check: str
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.number}: [{self.check}] {self.message}"


class ShapeSourceError(Exception):
    """The source no longer has the structure the check reads."""


def code_only(text: str) -> str:
    """Drop strings, character literals, and comments so braces can be counted."""
    if text.lstrip().startswith("\\\\"):
        return ""
    without_strings = CHAR.sub("' '", STRING.sub('""', text))
    return without_strings.split("//", 1)[0]


def non_test_lines(path: str, text: str) -> list[Line]:
    """Every line outside `test` blocks, which use odd arguments on purpose."""
    lines: list[Line] = []
    depth = 0
    in_test = False
    opened = False
    for number, raw in enumerate(text.splitlines(), 1):
        code = code_only(raw)
        if not in_test and TEST_START.match(raw):
            in_test, depth, opened = True, 0, False
        if in_test:
            depth += code.count("{") - code.count("}")
            opened = opened or depth > 0
            if opened and depth <= 0:
                in_test = False
            continue
        lines.append(Line(path, number, raw, code))
    return lines


def compared_flags(text: str, constants: dict[str, str]) -> list[str]:
    """The flag literals a line compares with an argument, in either order or
    through a named constant."""
    flags = [m.group(1) for m in HAND_COMPARE.finditer(text)]
    flags += [m.group(1) for m in HAND_COMPARE_FIRST.finditer(text)]
    for name, flag in constants.items():
        if re.search(r"(?:eql|startsWith)\(u8,\s*(?:[^,]+,\s*" + name + r"\b|" + name + r"\s*,)", text):
            flags.append(flag)
    return flags


def function_body(lines: list[Line], name: str) -> list[Line]:
    header = re.compile(rf"^\s*(?:pub\s+)?fn\s+{re.escape(name)}\s*\(")
    for index, line in enumerate(lines):
        if not header.match(line.text):
            continue
        depth = 0
        opened = False
        body: list[Line] = []
        for current in lines[index:]:
            body.append(current)
            depth += current.code.count("{") - current.code.count("}")
            opened = opened or depth > 0
            if opened and depth <= 0:
                return body
    raise ShapeSourceError(f"cannot find fn {name}")


def help_flags(lines: list[Line]) -> dict[str, Line]:
    """Flags named by `.flag` and flag-shaped `.usage` entries in a spec region."""
    flags: dict[str, Line] = {}
    entry = re.compile(r'\.(?:flag|usage) = "(-[^"]*)"')
    for line in lines:
        if "json_option" in line.code:
            flags.setdefault("--json", line)
        for match in entry.finditer(line.text):
            for part in match.group(1).split(", "):
                token = part.split(" ", 1)[0]
                if token != "--":
                    flags.setdefault(token, line)
    return flags


def parsed_flags(lines: list[Line]) -> dict[str, Line]:
    flags: dict[str, Line] = {}
    for line in lines:
        for match in FLAG_LITERAL.finditer(line.text):
            flags.setdefault(match.group(1), line)
    return flags


class Checker:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.problems: list[Problem] = []
        self.registry = json.loads((root / REGISTRY).read_text())
        self.exceptions = self.registry.get("exceptions", {})
        self.used_exceptions: set[tuple[str, str]] = set()
        self.cache: dict[str, list[Line]] = {}

    def lines(self, path: str) -> list[Line]:
        if path not in self.cache:
            self.cache[path] = non_test_lines(path, (self.root / path).read_text())
        return self.cache[path]

    def report(self, line: Line | None, check: str, message: str, path: str = REGISTRY) -> None:
        if line is None:
            self.problems.append(Problem(path, 1, check, message))
        else:
            self.problems.append(Problem(line.path, line.number, check, message))

    def excepted(self, kind: str, value: str) -> bool:
        if value in self.exceptions.get(kind, {}):
            self.used_exceptions.add((kind, value))
            return True
        return False

    def run(self) -> list[Problem]:
        self.check_env()
        self.check_flags()
        self.check_parsing()
        self.check_settings()
        self.check_run_options()
        self.check_removal()
        for kind, entries in self.exceptions.items():
            for value in entries:
                if (kind, value) not in self.used_exceptions:
                    self.report(
                        None,
                        "registry",
                        f'exception {kind} "{value}" no longer matches anything; remove it',
                    )
        return self.problems

    def check_env(self) -> None:
        registered = self.registry.get("env", {})
        external = set(self.registry.get("external_env", []))
        not_env = self.registry.get("not_env", {})
        seen: dict[str, Line] = {}
        seen_external: dict[str, Line] = {}
        for source in sorted((self.root / "src").rglob("*.zig")):
            path = source.relative_to(self.root).as_posix()
            for line in self.lines(path):
                for match in FX_LITERAL.finditer(line.text):
                    seen.setdefault(match.group(1), line)
                for match in GETENV_LITERAL.finditer(line.text):
                    name = match.group(1)
                    if not name.startswith("FX_"):
                        seen_external.setdefault(name, line)
        for name in sorted(set(not_env) - set(seen)):
            self.report(None, "env", f"not_env lists {name}, which src/ no longer contains; remove it")
        for name, line in sorted(seen.items()):
            if name not in registered and name not in not_env:
                self.report(
                    line,
                    "env",
                    f"{name} is not in {REGISTRY}. Register it with a job and a "
                    "stability, or reuse an existing variable (Env vars in .fx/skills/fx-cli-shape/references/rules.md).",
                )
        for name, entry in sorted(registered.items()):
            if name not in seen:
                self.report(None, "env", f"{name} is registered but no longer appears in src/; remove it")
            if entry.get("job") not in JOBS:
                self.report(None, "env", f"{name} has job {entry.get('job')!r}; use one of {sorted(JOBS)}")
            if (entry.get("job") == "test") != name.startswith("FX_TEST_"):
                self.report(
                    None,
                    "env",
                    f"{name} has job {entry.get('job')!r}, but test hooks and only test hooks "
                    "start with FX_TEST_; rename it or change its job",
                )
            if entry.get("stability") not in STABILITIES:
                self.report(
                    None,
                    "env",
                    f"{name} has stability {entry.get('stability')!r}; use one of {sorted(STABILITIES)}",
                )
        for name, line in sorted(seen_external.items()):
            if name not in external:
                self.report(
                    line,
                    "env",
                    f"{name} is read but is neither an FX_* variable nor listed in "
                    f"external_env in {REGISTRY}. fx's own variables use the FX_ prefix.",
                )
        for name in sorted(external - set(seen_external)):
            self.report(None, "env", f"external_env lists {name}, which src/ no longer reads; remove it")

    def check_flags(self) -> None:
        flags: dict[str, Line] = {}
        flags.update(help_flags(self.lines(COMMANDS)))
        for path in (CLI_SURFACE, CLI_ASK):
            for flag, line in parsed_flags(self.lines(path)).items():
                flags.setdefault(flag, line)
        for flag, line in sorted(flags.items()):
            if KEBAB_FLAG.match(flag) or SHORT_FLAG.match(flag):
                continue
            if self.excepted("flag_names", flag):
                continue
            self.report(
                line,
                "flags",
                f'"{flag}" must be kebab-case with no value inside the name; '
                "pass values as an argument (Flags in .fx/skills/fx-cli-shape/references/rules.md)",
            )

    def check_parsing(self) -> None:
        """Commands read flags through cli_flags, from the lists help renders.

        Comparing an argument with a flag literal by hand is how flags used to
        slip past help, so each remaining comparison needs a listed reason.
        """
        allowed = self.registry.get("hand_parsed_flags", {})
        files = self.registry.get("hand_parsed_files", {})
        seen: set[str] = set()
        seen_files: set[str] = set()
        for source in sorted((self.root / "src").rglob("*.zig")):
            path = source.relative_to(self.root).as_posix()
            lines = self.lines(path)
            constants = {m.group(1): m.group(2) for line in lines for m in FLAG_CONSTANT.finditer(line.text)}
            for line in lines:
                for flag in compared_flags(line.text, constants):
                    if path in files:
                        seen_files.add(path)
                        continue
                    seen.add(flag)
                    if flag in allowed:
                        continue
                    self.report(
                        line,
                        "parsing",
                        f"{flag} is compared with an argument by hand. Add it to the "
                        f"command's option list in {COMMANDS} and read it through "
                        "cli_flags (Flags and One source of truth in .fx/skills/fx-cli-shape/references/rules.md), or list it in "
                        f"hand_parsed_flags in {REGISTRY} with the reason.",
                    )
        for flag in sorted(set(allowed) - seen):
            self.report(None, "registry", f'hand_parsed_flags lists "{flag}", which no CLI code compares; remove it')
        for path in sorted(set(files) - seen_files):
            self.report(None, "registry", f'hand_parsed_files lists "{path}", which compares no flag by hand; remove it')

    def check_settings(self) -> None:
        config = self.lines(CONFIG_RUNTIME)
        profile = function_body(config, "parseProfileOnlyFields")
        project = function_body(config, "parseProjectSafeFields")
        for line in profile + project:
            for match in KEY_READ.finditer(line.text):
                key = match.group(1)
                if SNAKE_KEY.match(key) or self.excepted("setting_keys", key):
                    continue
                self.report(line, "settings", f'settings key "{key}" must be snake_case (Settings in .fx/skills/fx-cli-shape/references/rules.md)')
        listed = {
            match.group(1): (line, match.group(2))
            for line in self.lines(SETTINGS_KEYS)
            if (match := SETTING_ENTRY.search(line.text))
        }
        if not listed:
            raise ShapeSourceError(f"cannot read the settings list in {SETTINGS_KEYS}")
        reported: set[str] = set()
        for line in profile:
            for match in TOP_LEVEL_KEY_READ.finditer(line.text):
                key = match.group(1)
                if key in reported or listed.get(key, (None, ""))[1] == "profile":
                    continue
                reported.add(key)
                self.report(
                    line,
                    "warnings",
                    f'"{key}" is profile-only, so a project .fx.json that sets it is '
                    f"ignored. List it in {SETTINGS_KEYS} with .where = .profile so the "
                    "user is told and fx doctor knows the key.",
                )
        project_reads: set[str] = set()
        for line in project:
            for match in TOP_LEVEL_KEY_READ.finditer(line.text):
                key = match.group(1)
                project_reads.add(key)
                if key in reported or listed.get(key, (None, ""))[1] == "project_safe":
                    continue
                reported.add(key)
                self.report(
                    line,
                    "settings",
                    f'.fx.json may set "{key}", so list it in {SETTINGS_KEYS} with .where = .project_safe.',
                )
        for key, (line, where) in sorted(listed.items()):
            if where == "project_safe" and key not in project_reads:
                self.report(
                    line,
                    "settings",
                    f'{SETTINGS_KEYS} marks "{key}" project-safe, but parseProjectSafeFields '
                    "doesn't read it. Mark it .profile, or read it there.",
                    SETTINGS_KEYS,
                )

    def check_run_options(self) -> None:
        """Each option a run can set has one row naming it on every surface,
        so an ACP config option or a libfx model option can't drift from the
        flag, setting, and variable it stands for."""
        rows = {name: row for name, row in self.registry.get("run_options", {}).items() if not name.startswith("_")}
        if not rows:
            self.report(None, "names", "the registry needs a run_options table")
            return
        commands = "\n".join(line.text for line in self.lines(COMMANDS))
        settings = {match.group(1) for line in self.lines(SETTINGS_KEYS) if (match := SETTING_ENTRY.search(line.text))}
        env = self.registry.get("env", {})
        libfx = (self.root / LIBFX_TYPES).read_text()
        for name, row in sorted(rows.items()):
            if not re.search(rf'"{re.escape(str(row.get("flag")))}(?=[ ",])', commands):
                self.report(None, "names", f'run_options "{name}" names flag {row.get("flag")}, which {COMMANDS} doesn\'t list')
            if row.get("setting") not in settings:
                self.report(None, "names", f'run_options "{name}" names setting {row.get("setting")}, which {SETTINGS_KEYS} doesn\'t list')
            # check_env reports a malformed entry; this reports only a
            # variable that is missing or does another job.
            job = env.get(row.get("env"), {}).get("job")
            if job != "setting-override" and (job is None or job in JOBS):
                self.report(None, "names", f'run_options "{name}" names {row.get("env")}, which the registry doesn\'t list as a setting-override')
            option = row.get("libfx")
            if option and not option.startswith("model."):
                for type_name in LIBFX_PROVIDER_TYPES:
                    if option not in (interface_fields(libfx, type_name) or set()):
                        self.report(None, "names", f'run_options "{name}" names libfx option {option}, which {type_name} in {LIBFX_TYPES} doesn\'t declare')

        acp_ids: dict[str, Line] = {}
        for line in self.lines(ACP_SESSIONS):
            for config_id in ACP_CONFIG_ID.findall(line.text):
                acp_ids.setdefault(config_id, line)
        named_acp = {row["acp"] for row in rows.values() if "acp" in row}
        for config_id, line in sorted(acp_ids.items()):
            if config_id not in named_acp:
                self.report(line, "names", f'ACP config option "{config_id}" needs a run_options row in {REGISTRY} naming its flag, setting, and variable')
        for config_id in sorted(named_acp - acp_ids.keys()):
            self.report(None, "names", f'run_options names ACP config option "{config_id}", which {ACP_SESSIONS} doesn\'t offer')
        set_ids: dict[str, Line] = {}
        for line in self.lines(ACP_SERVER):
            for config_id in ACP_SET_ID.findall(line.text):
                set_ids.setdefault(config_id, line)
        for config_id, line in sorted(set_ids.items()):
            if config_id not in named_acp:
                self.report(line, "names", f'ACP set_config_option takes "{config_id}", which needs a run_options row in {REGISTRY}')
        for config_id in sorted(named_acp - set_ids.keys()):
            self.report(None, "names", f'run_options names ACP config option "{config_id}", which set_config_option in {ACP_SERVER} doesn\'t take')

        fields = libfx_model_fields(libfx)
        if fields is None:
            raise ShapeSourceError(f"cannot find FxModelOptions in {LIBFX_TYPES}")
        named_fields = {row["libfx"].removeprefix("model.") for row in rows.values() if row.get("libfx", "").startswith("model.")}
        for field in sorted(fields - named_fields):
            self.report(None, "names", f'libfx model option "{field}" needs a run_options row in {REGISTRY}', LIBFX_TYPES)
        for field in sorted(named_fields - fields):
            self.report(None, "names", f'run_options names libfx model option "{field}", which FxModelOptions doesn\'t declare')

    def check_removal(self) -> None:
        """Old spellings, such as `fx setup`, keep working with a warning until
        old_spelling_removal; once fx reaches that version they must go."""
        version = version_tuple(VERSION, (self.root / MAIN).read_text(), MAIN)
        removal = version_tuple(OLD_SPELLING_REMOVAL, (self.root / COMMAND_SPECS).read_text(), COMMAND_SPECS)
        if version >= removal:
            shown = ".".join(str(part) for part in removal)
            self.report(
                None,
                "removal",
                f"fx {shown} drops the old spellings that warn they stop working in it: remove them, then old_spelling_removal "
                f"(see decided-names.md in .fx/skills/fx-cli-shape/references)",
                COMMAND_SPECS,
            )


def version_tuple(pattern: re.Pattern[str], text: str, path: str) -> tuple[int, int, int]:
    match = pattern.search(text)
    if match is None:
        raise ShapeSourceError(f"cannot find {pattern.pattern} in {path}")
    major, minor, patch = (int(part) for part in match.groups())
    return (major, minor, patch)


def libfx_model_fields(text: str) -> set[str] | None:
    """The fields of `FxModelOptions`, or None when the interface is missing."""
    return interface_fields(text, "FxModelOptions")


def interface_fields(text: str, name: str) -> set[str] | None:
    """The top-level fields of TypeScript interface `name`, or None when the
    interface is missing. A field of another interface doesn't count."""
    match = re.search(rf"^(?:export )?interface {re.escape(name)}\b[^{{\n]*\{{", text, re.M)
    if match is None:
        return None
    end = text.find("\n}", match.end())
    body = text[match.end():end].splitlines()
    return {field.group(1) for line in body if (field := LIBFX_MODEL_FIELD.match(line))}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="repository root")
    args = parser.parse_args(argv)
    try:
        problems = Checker(args.root).run()
    except (OSError, ValueError, ShapeSourceError) as err:
        print(f"check_cli_shape: {err}", file=sys.stderr)
        return 2
    for problem in problems:
        print(problem.render())
    if problems:
        print(f"{len(problems)} shape problem(s). See .fx/skills/fx-cli-shape/SKILL.md.")
        return 1
    print("CLI shape: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
