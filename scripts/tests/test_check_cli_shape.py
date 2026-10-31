from __future__ import annotations

import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

from scripts import check_cli_shape


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

COMMANDS = """\
pub const top_level_flags = [_]TopLevelFlag{
    .{
        .usage = "--model <id>",
        .description = "Override the model",
    },
    .{
        .usage = "--fast, --no-fast",
        .description = "Turn Fast mode on or off",
    },
};

const specs = .{
    .{
        .kind = .ask,
        .token = "ask",
        .options = &.{
            .{ .flag = "--model <id>", .description = "Override the model" },
            json_option,
        },
    },
    .{
        .kind = .acp,
        .token = "acp",
    },
};
"""

CLI_SURFACE = """\
fn parseGlobalLaunchArgs(args: []const []const u8) void {
    var parser: cli_flags.Parser = .initPrefix(&builtin_commands.launch_options, args);
    _ = &parser;
}
"""

CLI_ASK = """\
fn parseAskOptions(args: []const []const u8) void {
    var parser: cli_flags.Parser = .init(&builtin_commands.ask_options, args);
    _ = &parser;
}

fn wantsJson(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

test "tests may use odd arguments" {
    _ = "--Weird_Flag";
    _ = "FX_ONLY_IN_TESTS";
    _ = std.mem.eql(u8, arg, "--only-in-tests");
    _ = .{ .text = "}" };
}
"""

SETTINGS_KEYS = """\
pub const keys = [_]Key{
    .{ .name = "max_agent_steps", .where = .project_safe },
    .{ .name = "model", .where = .profile },
};
"""

CONFIG_RUNTIME = """\
fn parseProfileOnlyFields(root: std.json.Value) void {
    if (root.object.get("model")) |value| {
        _ = value;
    }
}

fn parseProjectSafeFields(root: std.json.Value) void {
    if (root.object.get("max_agent_steps")) |value| {
        _ = value;
    }
}
"""

ACP_SESSIONS = r"""fn writeModelOption(w: *std.Io.Writer) !void {
    try w.writeAll("{\"id\":\"model\",\"name\":\"Model\",\"type\":\"select\"}");
}
"""

MAIN = 'pub const version = "0.0.14";\n'
COMMAND_SPECS = 'pub const old_spelling_removal = "0.0.17";\n'

ACP_SERVER = """\
fn handleSetConfigOption() void {
    if (std.mem.eql(u8, config_id, "model")) {}
}
"""

LIBFX_TYPES = """\
export interface FxModelOptions {
  /** Model ID. */
  id: string;
}
"""

ENV = """\
const model = io_mod.getenv("FX_MODEL");
const home = io_mod.getenv("HOME");
"""


def registry() -> dict:
    return {
        "env": {"FX_MODEL": {"job": "setting-override", "stability": "stable"}},
        "not_env": {},
        "external_env": ["HOME"],
        "hand_parsed_flags": {"--json": "picks the error format"},
        "run_options": {
            "model": {"flag": "--model", "setting": "model", "env": "FX_MODEL", "acp": "model", "libfx": "model.id"},
        },
        "exceptions": {"flag_names": {}, "setting_keys": {}},
    }


class CheckCliShapeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.files = {
            check_cli_shape.COMMANDS: COMMANDS,
            check_cli_shape.CLI_SURFACE: CLI_SURFACE,
            check_cli_shape.CLI_ASK: CLI_ASK,
            check_cli_shape.CONFIG_RUNTIME: CONFIG_RUNTIME,
            check_cli_shape.SETTINGS_KEYS: SETTINGS_KEYS,
            check_cli_shape.ACP_SESSIONS: ACP_SESSIONS,
            check_cli_shape.ACP_SERVER: ACP_SERVER,
            check_cli_shape.MAIN: MAIN,
            check_cli_shape.COMMAND_SPECS: COMMAND_SPECS,
            check_cli_shape.LIBFX_TYPES: LIBFX_TYPES,
            "src/env.zig": ENV,
        }
        self.registry = registry()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_check(self) -> list[check_cli_shape.Problem]:
        for path, text in self.files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        registry_path = self.root / check_cli_shape.REGISTRY
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        registry_path.write_text(json.dumps(self.registry))
        return check_cli_shape.Checker(self.root).run()

    def edit(self, path: str, old: str, new: str) -> None:
        self.assertIn(old, self.files[path])
        self.files[path] = self.files[path].replace(old, new, 1)

    def assertOnly(self, problems: list[check_cli_shape.Problem], check: str, fragment: str) -> None:
        self.assertEqual(1, len(problems), [problem.render() for problem in problems])
        self.assertEqual(check, problems[0].check)
        self.assertIn(fragment, problems[0].message)

    def test_clean_tree_passes_and_test_blocks_are_ignored(self) -> None:
        self.assertEqual([], self.run_check())

    def test_unregistered_env_var_fails(self) -> None:
        self.files["src/env.zig"] += 'const extra = io_mod.getenv("FX_FAST_DIFF");\n'
        problems = self.run_check()
        self.assertOnly(problems, "env", "FX_FAST_DIFF is not in")
        self.assertEqual(("src/env.zig", 3), (problems[0].path, problems[0].number))

    def test_env_name_read_through_a_constant_still_counts(self) -> None:
        self.files["src/env.zig"] += 'const name = "FX_HIDDEN";\nconst value = io_mod.getenv(name);\n'
        self.assertOnly(self.run_check(), "env", "FX_HIDDEN is not in")

    def test_not_env_literal_is_accepted_and_stale_entries_fail(self) -> None:
        self.files["src/env.zig"] += 'const service = "FX_KEYCHAIN_SERVICE";\n'
        self.registry["not_env"] = {"FX_KEYCHAIN_SERVICE": "keychain service name"}
        self.assertEqual([], self.run_check())
        self.registry["not_env"]["FX_GONE"] = "no longer used"
        self.assertOnly(self.run_check(), "env", "not_env lists FX_GONE")

    def test_stale_and_malformed_env_entries_fail(self) -> None:
        self.registry["env"]["FX_TEST_GONE"] = {"job": "test", "stability": "internal"}
        self.assertOnly(self.run_check(), "env", "FX_TEST_GONE is registered but no longer appears")
        del self.registry["env"]["FX_TEST_GONE"]
        self.registry["env"]["FX_MODEL"]["job"] = "setting"
        self.assertOnly(self.run_check(), "env", "FX_MODEL has job 'setting'")

    def test_test_hooks_and_only_test_hooks_use_the_test_prefix(self) -> None:
        self.files["src/env.zig"] += 'const hook = io_mod.getenv("FX_E2E_GATEWAY_CHAT_URL");\n'
        self.registry["env"]["FX_E2E_GATEWAY_CHAT_URL"] = {"job": "test", "stability": "internal"}
        self.assertOnly(self.run_check(), "env", "FX_E2E_GATEWAY_CHAT_URL has job 'test'")
        self.files["src/env.zig"] = self.files["src/env.zig"].replace("FX_E2E_", "FX_TEST_")
        self.registry["env"]["FX_TEST_GATEWAY_CHAT_URL"] = self.registry["env"].pop("FX_E2E_GATEWAY_CHAT_URL")
        self.assertEqual([], self.run_check())
        self.registry["env"]["FX_TEST_GATEWAY_CHAT_URL"]["job"] = "integration"
        self.assertOnly(self.run_check(), "env", "FX_TEST_GATEWAY_CHAT_URL has job 'integration'")

    def test_unprefixed_env_var_fails_unless_listed(self) -> None:
        self.files["src/env.zig"] += 'const legacy = io_mod.getenv("FLASH_SYNC_UPDATES");\n'
        self.assertOnly(self.run_check(), "env", "FLASH_SYNC_UPDATES is read but is neither")
        self.registry["external_env"].append("FLASH_SYNC_UPDATES")
        self.assertEqual([], self.run_check())
        self.registry["external_env"].append("NOT_READ")
        self.assertOnly(self.run_check(), "env", "external_env lists NOT_READ")

    def test_flag_names_must_be_kebab_case(self) -> None:
        self.edit(check_cli_shape.COMMANDS, '"--model <id>", .description', '"--noColor", .description')
        self.assertOnly(self.run_check(), "flags", '"--noColor" must be kebab-case')

    def test_value_inside_flag_name_fails_until_excepted_and_exception_goes_stale(self) -> None:
        self.edit(
            check_cli_shape.COMMANDS,
            '.usage = "--fast, --no-fast"',
            '.usage = "--fast, --no-fast, --resume-<id>"',
        )
        self.assertOnly(self.run_check(), "flags", '"--resume-<id>" must be kebab-case')
        self.registry["exceptions"]["flag_names"]["--resume-<id>"] = "being removed"
        self.assertEqual([], self.run_check())
        self.edit(check_cli_shape.COMMANDS, ", --resume-<id>", "")
        self.assertOnly(self.run_check(), "registry", 'flag_names "--resume-<id>" no longer matches')

    def test_hand_parsed_flag_fails_until_listed(self) -> None:
        self.edit(
            check_cli_shape.CLI_SURFACE,
            "    _ = &parser;\n",
            '    _ = &parser;\n    if (std.mem.startsWith(u8, args[0], "--verbose=")) {}\n',
        )
        problems = self.run_check()
        self.assertOnly(problems, "parsing", "--verbose= is compared with an argument by hand")
        self.assertEqual((check_cli_shape.CLI_SURFACE, 4), (problems[0].path, problems[0].number))
        self.registry["hand_parsed_flags"]["--verbose="] = "a listed reason"
        self.assertEqual([], self.run_check())

    def test_hand_compare_is_found_in_either_order_and_through_constants(self) -> None:
        self.edit(
            check_cli_shape.CLI_SURFACE,
            "    _ = &parser;\n",
            '    _ = &parser;\n    if (std.mem.eql(u8, "--verbose", args[0])) {}\n',
        )
        self.assertOnly(self.run_check(), "parsing", "--verbose is compared with an argument by hand")
        self.edit(
            check_cli_shape.CLI_SURFACE,
            '    if (std.mem.eql(u8, "--verbose", args[0])) {}\n',
            '    const quiet_flag = "--quiet";\n    if (std.mem.eql(u8, args[0], quiet_flag)) {}\n',
        )
        self.assertOnly(self.run_check(), "parsing", "--quiet is compared with an argument by hand")

    def test_hand_compare_outside_the_cli_folder_fails_until_its_file_is_listed(self) -> None:
        path = "src/core/other/parse.zig"
        (self.root / "src/core/other").mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text('fn parse(arg: []const u8) bool {\n    return std.mem.eql(u8, arg, "--dry-run");\n}\n')
        self.assertOnly(self.run_check(), "parsing", "--dry-run is compared with an argument by hand")
        self.registry.setdefault("hand_parsed_files", {})[path] = "reads another program's flags"
        self.assertEqual([], self.run_check())

    def test_stale_hand_parsed_file_fails(self) -> None:
        self.registry.setdefault("hand_parsed_files", {})["src/core/gone.zig"] = "no longer compares"
        self.assertOnly(self.run_check(), "registry", 'hand_parsed_files lists "src/core/gone.zig"')

    def test_stale_hand_parsed_entry_fails(self) -> None:
        self.registry["hand_parsed_flags"]["--gone"] = "no longer compared"
        self.assertOnly(self.run_check(), "registry", 'hand_parsed_flags lists "--gone"')

    def test_settings_keys_must_be_snake_case(self) -> None:
        self.edit(
            check_cli_shape.SETTINGS_KEYS,
            '.{ .name = "model", .where = .profile },\n',
            '.{ .name = "model", .where = .profile },\n    .{ .name = "statusLine", .where = .profile },\n',
        )
        self.edit(
            check_cli_shape.CONFIG_RUNTIME,
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n',
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n    _ = root.object.get("statusLine");\n',
        )
        self.assertOnly(self.run_check(), "settings", '"statusLine" must be snake_case')
        self.registry["exceptions"]["setting_keys"]["statusLine"] = "being renamed"
        self.assertEqual([], self.run_check())

    def test_profile_only_key_without_project_warning_fails(self) -> None:
        self.edit(
            check_cli_shape.CONFIG_RUNTIME,
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n',
            'fn parseProfileOnlyFields(root: std.json.Value) void {\n    _ = root.object.get("auto_compact_percent");\n',
        )
        problems = self.run_check()
        self.assertOnly(problems, "warnings", '"auto_compact_percent" is profile-only')
        self.assertEqual((check_cli_shape.CONFIG_RUNTIME, 2), (problems[0].path, problems[0].number))

    def test_project_safe_keys_need_no_profile_warning(self) -> None:
        self.edit(check_cli_shape.CONFIG_RUNTIME, '"max_agent_steps"', '"max_tool_result_bytes"')
        self.edit(check_cli_shape.SETTINGS_KEYS, '"max_agent_steps"', '"max_tool_result_bytes"')
        self.assertEqual([], self.run_check())

    def test_project_safe_read_missing_from_the_list_fails(self) -> None:
        self.edit(
            check_cli_shape.CONFIG_RUNTIME,
            'fn parseProjectSafeFields(root: std.json.Value) void {\n',
            'fn parseProjectSafeFields(root: std.json.Value) void {\n    _ = root.object.get("provider_strict");\n',
        )
        self.assertOnly(self.run_check(), "settings", 'may set "provider_strict"')

    def test_project_safe_entry_the_parser_does_not_read_fails(self) -> None:
        self.edit(
            check_cli_shape.SETTINGS_KEYS,
            '.{ .name = "model", .where = .profile },\n',
            '.{ .name = "model", .where = .profile },\n    .{ .name = "provider_order", .where = .project_safe },\n',
        )
        problems = self.run_check()
        self.assertOnly(problems, "settings", 'marks "provider_order" project-safe')
        self.assertEqual(check_cli_shape.SETTINGS_KEYS, problems[0].path)

    def test_missing_settings_list_is_a_source_error(self) -> None:
        self.files[check_cli_shape.SETTINGS_KEYS] = "pub const keys = [_]Key{};\n"
        with self.assertRaises(check_cli_shape.ShapeSourceError):
            self.run_check()

    def test_missing_parser_is_a_source_error(self) -> None:
        self.edit(check_cli_shape.CONFIG_RUNTIME, "fn parseProfileOnlyFields(", "fn parseProfileRenamed(")
        self.run_check_files_only()
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = check_cli_shape.main(["--root", str(self.root)])
        self.assertEqual(2, code)
        self.assertIn("cannot find fn parseProfileOnlyFields", stderr.getvalue())

    def run_check_files_only(self) -> None:
        try:
            self.run_check()
        except check_cli_shape.ShapeSourceError:
            pass

    def test_real_tree_passes(self) -> None:
        problems = check_cli_shape.Checker(REPO_ROOT).run()
        self.assertEqual([], [problem.render() for problem in problems])

    def test_acp_config_option_needs_a_run_options_row(self) -> None:
        self.edit(
            check_cli_shape.ACP_SESSIONS,
            "}\n",
            '}\n\nfn writeFastOption(w: *std.Io.Writer) !void {\n    try w.writeAll("{\\\"id\\\":\\\"fast\\\",\\\"name\\\":\\\"Fast\\\"}");\n}\n',
        )
        self.assertOnly(self.run_check(), "names", 'ACP config option "fast" needs a run_options row')

    def test_old_spellings_must_go_once_fx_reaches_their_removal(self) -> None:
        self.edit(check_cli_shape.MAIN, '"0.0.14"', '"0.0.17"')
        self.assertOnly(self.run_check(), "removal", "fx 0.0.17 drops the old spellings")

    def test_acp_set_config_option_id_needs_a_run_options_row(self) -> None:
        self.edit(check_cli_shape.ACP_SERVER, '"model")) {}\n', '"model")) {}\n    if (std.mem.eql(u8, config_id, "fast")) {}\n')
        self.assertOnly(self.run_check(), "names", 'ACP set_config_option takes "fast"')

    def test_libfx_options_are_read_from_their_own_interface(self) -> None:
        text = "export interface FxEvent {\n  provider?: string;\n}\ninterface FxGatewayProvider<T> {\n  apiKey?: string;\n}\n"
        self.assertEqual({"apiKey"}, check_cli_shape.interface_fields(text, "FxGatewayProvider"))
        self.assertEqual({"provider"}, check_cli_shape.interface_fields(text, "FxEvent"))
        self.assertIsNone(check_cli_shape.interface_fields(text, "FxCustomProvider"))

    def test_libfx_model_option_needs_a_run_options_row(self) -> None:
        self.edit(check_cli_shape.LIBFX_TYPES, "  id: string;\n", "  id: string;\n  fast?: boolean;\n")
        self.assertOnly(self.run_check(), "names", 'libfx model option "fast" needs a run_options row')

    def test_run_options_row_must_name_a_listed_flag(self) -> None:
        self.registry["run_options"]["model"]["flag"] = "--modle"
        self.assertOnly(self.run_check(), "names", "names flag --modle")

    def test_run_options_row_must_name_a_setting_override_variable(self) -> None:
        self.registry["env"]["FX_MODEL"]["job"] = "internal"
        self.assertOnly(self.run_check(), "names", "names FX_MODEL, which the registry doesn't list as a setting-override")


if __name__ == "__main__":
    unittest.main()
