from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.pgso.corpus import (
    Corpus,
    CorpusRunError,
    Scenario,
    load_corpus,
    run_behavior_corpus,
    run_corpus,
)
from scripts.pgso.model import PgsoError
from scripts.pgso.runner import CommandResult


TRAINING_E2E_TESTS = (
    "cli.test.ts",
    "ask-presentation.test.ts",
    "config-persistence.test.ts",
    "prompt-history.test.ts",
    "auth-refresh.test.ts",
    "file-tool-paths.test.ts",
    "file-tool-permissions.test.ts",
    "gateway-stream-lifecycle.test.ts",
    "web-fetch-fake-network.test.ts",
    "web-search-fake-gateway.test.ts",
    "vision-route-fake-gateway.test.ts",
    "acp.test.ts",
    "mcp-http.test.ts",
    "mcp-legacy-remote.test.ts",
    "mcp-stdio.test.ts",
    "mcp-auth.test.ts",
    "session-recovery.test.ts",
    "terminal-host.test.ts",
    "tui-startup.test.ts",
    "permission-errors.test.ts",
    "tui-resize.test.ts",
    "tui-render-stress.test.ts",
    "tui-full-transcript-brutal.test.ts",
    "tui-resume-brutal.test.ts",
    "tui-permissions.test.ts",
    "tui-interrupt-recovery.test.ts",
    "tui-subagent-manager.test.ts",
    "tui-terminal-tool.test.ts",
    "tui-native-clear-recovery.test.ts",
    "tui-gateway-stream-lifecycle.test.ts",
)

VERIFICATION_E2E_TESTS = (
    "auto-mode-reliability.test.ts",
    "oauth-keychain-migration.test.ts",
    "tui-auth-source-selection.test.ts",
    "tui-composer-edit-contracts.test.ts",
    "tui-cost.test.ts",
    "tui-decision-prompts.test.ts",
    "tui-file-picker.test.ts",
    "tui-input-line-delete.test.ts",
    "tui-input-navigation.test.ts",
    "tui-render-replay.test.ts",
    "tui-resume.test.ts",
    "tui-slash-commands.test.ts",
    "tui-slash-extra.test.ts",
    "tui-slash-menu.test.ts",
    "web-fetch-permission-progress.test.ts",
    "web-search-permission-progress.test.ts",
    "yolo-permission-mode.test.ts",
)

EXCLUDED_E2E_TESTS = (
    "ci-shards.test.ts",
    "context-limits-live.test.ts",
    "notifications.test.ts",
    "tmux-helpers.test.ts",
    "tui-agent.test.ts",
    "tui-command-permissions.test.ts",
    "tui-direct-write-audit.test.ts",
    "tui-keybindings.test.ts",
    "tui-render-lab.test.ts",
    "tui-render-live-stress.test.ts",
    "web-fetch-live.test.ts",
    "web-search-live.test.ts",
)


class PgsoCorpusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-corpus-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        (self.root / "tests" / "e2e").mkdir(parents=True)
        for test_file in (
            "notifications.test.ts",
            "tui-agent.test.ts",
            "tui-command-permissions.test.ts",
        ):
            (self.root / "tests" / "e2e" / test_file).write_text("test")
        self.manifest_path = self.root / "corpus.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def direct_scenarios(self) -> list[dict[str, object]]:
        commands = (
            ("direct-help", ("help",)),
            ("direct-version", ("--version",)),
            ("direct-status", ("status", "--json")),
            ("direct-background", ("background", "--json")),
            ("direct-doctor", ("doctor", "--json")),
            ("direct-sessions", ("sessions", "--json")),
        )
        return [
            {
                "name": name,
                "argv": ["{binary}", *arguments],
                "cwd": ".",
                "env_set": {"FX_SOUND": "0"},
                "env_unset": [],
                "timeout_seconds": 30,
                "requires_tmux": False,
            }
            for name, arguments in commands
        ]

    def manifest(self) -> dict[str, object]:
        return {
            "version": 1,
            "intentional_exclusions": {
                "notifications.test.ts": "sound-related",
                "tui-agent.test.ts": "requires a real model credential",
                "tui-command-permissions.test.ts": "contains a sound scenario",
            },
            "scenarios": self.direct_scenarios(),
            "verification_scenarios": [],
        }

    def write_manifest(self, payload: dict[str, object]) -> pathlib.Path:
        self.manifest_path.write_text(json.dumps(payload))
        return self.manifest_path

    def e2e_scenario(self, test_file: str) -> dict[str, object]:
        return {
            "name": f"e2e-{test_file.removesuffix('.test.ts')}",
            "argv": ["bun", "test", "--max-concurrency", "1", f"./{test_file}"],
            "cwd": "tests/e2e",
            "env_set": {"FX_SOUND": "0"},
            "env_unset": ["AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"],
            "timeout_seconds": 60,
            "requires_tmux": True,
            "test_file": test_file,
        }

    def test_load_rejects_duplicate_names(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.append(dict(scenarios[0]))

        with self.assertRaisesRegex(PgsoError, "duplicate scenario name"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_separates_training_and_verification_scenarios(self) -> None:
        test_file = "new-feature.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        verification = payload["verification_scenarios"]
        assert isinstance(verification, list)
        verification.append(self.e2e_scenario(test_file))

        corpus = load_corpus(self.write_manifest(payload), repo_root=self.root)

        self.assertEqual(6, len(corpus.scenarios))
        self.assertEqual(
            ("e2e-new-feature",),
            tuple(scenario.name for scenario in corpus.verification_scenarios),
        )
        self.assertEqual(7, len(corpus.candidate_scenarios))

    def test_load_rejects_duplicate_test_files_across_phases(self) -> None:
        test_file = "shared.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        verification = payload["verification_scenarios"]
        assert isinstance(scenarios, list)
        assert isinstance(verification, list)
        scenarios.append(self.e2e_scenario(test_file))
        duplicate = self.e2e_scenario(test_file)
        duplicate["name"] = "e2e-shared-verification"
        verification.append(duplicate)

        with self.assertRaisesRegex(PgsoError, "duplicate corpus test file"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_unclassified_e2e_files(self) -> None:
        test_file = "forgotten-feature.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")

        with self.assertRaisesRegex(
            PgsoError,
            "unclassified E2E test file: forgotten-feature.test.ts",
        ):
            load_corpus(self.write_manifest(self.manifest()), repo_root=self.root)

    def test_load_rejects_stale_exclusions(self) -> None:
        payload = self.manifest()
        exclusions = payload["intentional_exclusions"]
        assert isinstance(exclusions, dict)
        exclusions["removed.test.ts"] = "removed from the suite"

        with self.assertRaisesRegex(
            PgsoError,
            "excluded E2E test file does not exist: removed.test.ts",
        ):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_multiple_classifications(self) -> None:
        test_file = "classified-twice.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        exclusions = payload["intentional_exclusions"]
        assert isinstance(scenarios, list)
        assert isinstance(exclusions, dict)
        scenarios.append(self.e2e_scenario(test_file))
        exclusions[test_file] = "also excluded"

        with self.assertRaisesRegex(PgsoError, "multiple corpus classifications"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_path_traversal(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios[0]["cwd"] = "../outside"

        with self.assertRaisesRegex(PgsoError, "cwd escapes repository"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_a_missing_test_file(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.append(self.e2e_scenario("missing.test.ts"))

        with self.assertRaisesRegex(PgsoError, "test file does not exist"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_binds_each_test_file_to_its_exact_bun_command(self) -> None:
        test_file = "cli.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenario = self.e2e_scenario(test_file)
        scenario["argv"] = ["bun", "test", "./different.test.ts"]
        scenarios.append(scenario)

        with self.assertRaisesRegex(PgsoError, "test command mismatch"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_an_empty_command_or_nonpositive_timeout(self) -> None:
        cases = (("argv", []), ("timeout_seconds", 0))
        for field, value in cases:
            with self.subTest(field=field):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[0][field] = value
                with self.assertRaises(PgsoError):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_invalid_profile_runs(self) -> None:
        for value in (True, 0, 101, 1.5):
            with self.subTest(value=value):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[-1]["profile_runs"] = value
                with self.assertRaisesRegex(PgsoError, "profile_runs"):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_profile_runs_for_e2e_scenarios(self) -> None:
        test_file = "profile-repeat.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenario = self.e2e_scenario(test_file)
        scenario["profile_runs"] = 2
        scenarios.append(scenario)

        with self.assertRaisesRegex(PgsoError, "profile_runs"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_sound_and_nondeterministic_test_files(self) -> None:
        for test_file in (
            "notifications.test.ts",
            "tui-agent.test.ts",
            "tui-command-permissions.test.ts",
            "web-search-live.test.ts",
        ):
            with self.subTest(test_file=test_file):
                (self.root / "tests" / "e2e" / test_file).write_text("test")
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios.append(self.e2e_scenario(test_file))
                with self.assertRaisesRegex(PgsoError, "forbidden corpus test"):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_requires_every_direct_command(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.pop()

        with self.assertRaisesRegex(PgsoError, "missing required direct command"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_environment_keys_owned_by_the_runner(self) -> None:
        for key in (
            "HOME",
            "LLVM_PROFILE_FILE",
            "TMUX",
            "TMUX_TMPDIR",
            "AI_GATEWAY_API_KEY",
            "FX_TRACE_LOG",
            "FX_TRACE_SCOPES",
        ):
            with self.subTest(key=key):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[0]["env_set"] = {key: "unsafe"}
                with self.assertRaisesRegex(PgsoError, "reserved environment key"):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_skipped_scenarios(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios[0]["skip_reason"] = "not applicable"

        with self.assertRaisesRegex(PgsoError, "cannot be skipped"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_production_manifest_classifies_every_e2e_file(self) -> None:
        repo_root = pathlib.Path(__file__).resolve().parents[3]
        corpus = load_corpus(
            repo_root / "scripts" / "pgso" / "corpus.json",
            repo_root=repo_root,
        )

        self.assertEqual(TRAINING_E2E_TESTS, corpus.training_test_files)
        self.assertEqual(VERIFICATION_E2E_TESTS, corpus.verification_test_files)
        self.assertEqual(
            EXCLUDED_E2E_TESTS,
            tuple(test_file for test_file, _ in corpus.intentional_exclusions),
        )
        self.assertEqual(36, len(corpus.scenarios))
        self.assertEqual(53, len(corpus.candidate_scenarios))
        self.assertEqual(
            100,
            next(
                scenario.profile_runs
                for scenario in corpus.scenarios
                if scenario.name == "direct-sessions"
            ),
        )
        self.assertEqual(
            ("e2e-cli", "e2e-mcp-auth"),
            tuple(
                scenario.name
                for scenario in corpus.scenarios
                if scenario.allow_keychain
            ),
        )
        self.assertEqual(
            ("verify-oauth-keychain-migration",),
            tuple(
                scenario.name
                for scenario in corpus.verification_scenarios
                if scenario.allow_keychain
            ),
        )

        discovered = tuple(
            sorted(
                path.name
                for path in (repo_root / "tests" / "e2e").glob("*.test.ts")
            )
        )
        self.assertEqual(
            discovered,
            tuple(sorted((*corpus.test_files, *EXCLUDED_E2E_TESTS))),
        )

    def test_behavior_corpus_adds_verification_only_scenarios(self) -> None:
        training = self.make_scenario("training")
        verification = self.make_scenario("verification")
        corpus = Corpus(
            repo_root=self.root,
            manifest_path=self.manifest_path,
            manifest_sha256="a" * 64,
            scenarios=(training,),
            verification_scenarios=(verification,),
            intentional_exclusions=(
                ("notifications.test.ts", "sound-related"),
                ("tui-agent.test.ts", "requires a real model credential"),
                ("tui-command-permissions.test.ts", "contains sound"),
            ),
        )
        binary = self.root / "candidate-fx"
        binary.write_bytes(b"candidate")
        calls: list[str] = []

        def command_runner(argv, **kwargs):
            calls.append(argv[1])
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.2,
            )

        result = run_behavior_corpus(
            corpus,
            binary,
            self.root / "behavior-output",
            command_runner=command_runner,
        )

        self.assertEqual(["training", "verification"], calls)
        self.assertEqual(2, result.passed)

    def test_training_corpus_omits_verification_only_scenarios(self) -> None:
        training = self.make_scenario("training")
        verification = self.make_scenario("verification")
        corpus = Corpus(
            repo_root=self.root,
            manifest_path=self.manifest_path,
            manifest_sha256="a" * 64,
            scenarios=(training,),
            verification_scenarios=(verification,),
            intentional_exclusions=(
                ("notifications.test.ts", "sound-related"),
                ("tui-agent.test.ts", "requires a real model credential"),
                ("tui-command-permissions.test.ts", "contains sound"),
            ),
        )

        result, calls, _, _, _ = self.run_fixture(corpus)

        self.assertEqual(1, result.passed)
        self.assertEqual(["training"], [call["argv"][1] for call in calls])

    def make_scenario(
        self,
        name: str,
        *,
        requires_tmux: bool = False,
    ) -> Scenario:
        return Scenario(
            name=name,
            argv=("{binary}", name),
            cwd=".",
            env_set=(("FX_SOUND", "0"),),
            env_unset=("PGSO_UNSET_ME",),
            timeout_seconds=5,
            requires_tmux=requires_tmux,
            allow_keychain=False,
            test_file=None,
        )

    def make_corpus(self, *scenarios: Scenario) -> Corpus:
        return Corpus(
            repo_root=self.root,
            manifest_path=self.manifest_path,
            manifest_sha256="a" * 64,
            scenarios=tuple(scenarios),
            intentional_exclusions=(
                ("notifications.test.ts", "sound-related"),
                ("tui-agent.test.ts", "requires a real model credential"),
                ("tui-command-permissions.test.ts", "contains sound"),
            ),
        )

    def run_fixture(
        self,
        corpus: Corpus,
        *,
        fail_scenario: str | None = None,
        omit_profile_for: str | None = None,
    ):
        output = self.root / "output"
        profile_dir = output / "profiles" / "raw"
        profile_dir.mkdir(parents=True, exist_ok=True)
        merged_profile = output / "profiles" / "merged.profdata"
        binary = self.root / "instrumented-fx"
        binary.write_bytes(b"instrumented")
        calls: list[dict[str, object]] = []
        merges: list[tuple[str, ...]] = []

        def command_runner(argv, **kwargs):
            environment = kwargs["env"]
            scenario_name = argv[1]
            calls.append(
                {
                    "argv": tuple(argv),
                    "env": dict(environment),
                    "cwd": kwargs["cwd"],
                }
            )
            if scenario_name == fail_scenario:
                raise PgsoError(f"failed scenario: {scenario_name}")
            if scenario_name != omit_profile_for:
                pattern = environment["LLVM_PROFILE_FILE"]
                raw = pathlib.Path(
                    pattern.replace("%m", "module")
                    .replace("%p", str(len(calls)))
                    .replace("%c", "")
                )
                raw.write_bytes(scenario_name.encode())
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.25,
            )

        def profile_merger(toolchain, raw_profiles, merged, log_path):
            merges.append(tuple(path.name for path in raw_profiles))
            merged.write_bytes(b"merged")
            for raw in raw_profiles:
                raw.unlink()
            return len(raw_profiles)

        result = run_corpus(
            corpus,
            binary,
            profile_dir,
            merged_profile,
            toolchain=object(),
            command_runner=command_runner,
            profile_merger=profile_merger,
        )
        return result, calls, merges, binary, merged_profile

    def test_run_uses_a_hermetic_environment_and_owns_per_scenario_profiles(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("first"),
            self.make_scenario("second"),
        )
        with mock.patch.dict(
            os.environ,
            {
                "PGSO_INHERITED": "yes",
                "PGSO_UNSET_ME": "remove",
                "TMUX": "/tmp/user-tmux,1,0",
                "TMUX_PANE": "%1",
                "FX_TRACE_LOG": "/tmp/user-fx-trace.log",
                "FX_TRACE_SCOPES": "user-scope",
            },
            clear=False,
        ):
            result, calls, merges, binary, merged = self.run_fixture(corpus)

        self.assertEqual(2, result.passed)
        self.assertEqual(0, result.skipped)
        self.assertEqual(0, result.failed)
        self.assertEqual(2, result.merged_raw_profiles)
        self.assertFalse((self.root / "zig-out" / "bin" / "fx").exists())
        self.assertTrue(merged.is_file())
        self.assertEqual(2, len(calls))
        self.assertNotIn("PGSO_INHERITED", calls[0]["env"])
        self.assertNotIn("PGSO_UNSET_ME", calls[0]["env"])
        self.assertNotIn("TMUX", calls[0]["env"])
        self.assertNotIn("TMUX_PANE", calls[0]["env"])
        self.assertNotIn("FX_TRACE_LOG", calls[0]["env"])
        self.assertNotIn("FX_TRACE_SCOPES", calls[0]["env"])
        self.assertEqual("1", calls[0]["env"]["FX_E2E_DISABLE_DOTENV"])
        self.assertEqual(os.environ["PATH"], calls[0]["env"]["PATH"])
        self.assertEqual(
            str(self.root / "output" / "profiles" / "home" / "first"),
            calls[0]["env"]["HOME"],
        )
        self.assertEqual(
            "set-option -g history-limit 100000\n",
            (
                self.root
                / "output"
                / "profiles"
                / "home"
                / "first"
                / ".tmux.conf"
            ).read_text(),
        )
        patterns = [call["env"]["LLVM_PROFILE_FILE"] for call in calls]
        self.assertNotEqual(patterns[0], patterns[1])
        self.assertTrue(all("%m-%p-%c.profraw" in pattern for pattern in patterns))
        self.assertEqual(("first-module-1-.profraw",), merges[0])
        self.assertEqual(("second-module-2-.profraw",), merges[1])

    def test_training_profile_runs_repeat_one_direct_scenario(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios[-1]["profile_runs"] = 3
        loaded = load_corpus(self.write_manifest(payload), repo_root=self.root)
        corpus = self.make_corpus(loaded.scenarios[-1])

        result, calls, merges, _, _ = self.run_fixture(corpus)

        self.assertEqual(1, result.passed)
        self.assertEqual(0.75, result.results[0].elapsed_seconds)
        self.assertEqual(3, result.merged_raw_profiles)
        self.assertEqual(3, len(calls))
        self.assertEqual(
            (
                "direct-sessions-module-1-.profraw",
                "direct-sessions-module-2-.profraw",
                "direct-sessions-module-3-.profraw",
            ),
            merges[0],
        )

    def test_behavior_corpus_ignores_training_profile_runs(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios[-1]["profile_runs"] = 3
        loaded = load_corpus(self.write_manifest(payload), repo_root=self.root)
        corpus = self.make_corpus(loaded.scenarios[-1])
        binary = self.root / "candidate-fx"
        binary.write_bytes(b"candidate")
        calls: list[tuple[str, ...]] = []

        def command_runner(argv, **kwargs):
            calls.append(tuple(argv))
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.2,
            )

        result = run_behavior_corpus(
            corpus,
            binary,
            self.root / "behavior-output",
            command_runner=command_runner,
        )

        self.assertEqual(1, result.passed)
        self.assertEqual(1, len(calls))

    def test_run_cleans_the_isolated_tmux_server(self) -> None:
        marker = self.root / "tmux-cleaned"
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        tmux = fake_bin / "tmux"
        tmux.write_text(
            "#!/bin/sh\nprintf '%s' \"$TMUX_TMPDIR\" > \"$PGSO_TMUX_MARKER\"\n"
        )
        tmux.chmod(0o755)
        scenario = dataclasses_replace_env(
            self.make_scenario("tui", requires_tmux=True),
            ("PGSO_TMUX_MARKER", str(marker)),
        )
        corpus = self.make_corpus(scenario)

        with mock.patch.dict(
            os.environ,
            {"PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}"},
            clear=False,
        ):
            self.run_fixture(corpus)

        tmux_tmp = pathlib.Path(marker.read_text())
        self.assertEqual(pathlib.Path("/tmp"), tmux_tmp.parent)
        self.assertTrue(tmux_tmp.name.startswith("fxp-tmux-"))
        self.assertLess(len(f"{tmux_tmp}/tmux-501/default".encode()), 104)
        self.assertFalse(tmux_tmp.exists())

    def test_keychain_access_is_scoped_to_the_declared_scenario_home(self) -> None:
        host_home = self.root / "host-home"
        host_keychains = host_home / "Library" / "Keychains"
        host_keychains.mkdir(parents=True)
        scenario = dataclasses_replace_allow_keychain(
            self.make_scenario("keychain")
        )

        with mock.patch.object(pathlib.Path, "home", return_value=host_home):
            self.run_fixture(self.make_corpus(scenario))

        link = (
            self.root
            / "output"
            / "profiles"
            / "home"
            / "keychain"
            / "Library"
            / "Keychains"
        )
        self.assertTrue(link.is_symlink())
        self.assertEqual(host_keychains.resolve(), link.resolve())

    def test_run_stops_and_records_a_failed_scenario(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("first"),
            self.make_scenario("broken"),
            self.make_scenario("never-runs"),
        )

        with self.assertRaises(CorpusRunError) as raised:
            self.run_fixture(corpus, fail_scenario="broken")

        self.assertEqual(1, raised.exception.result.passed)
        self.assertEqual(1, raised.exception.result.failed)
        self.assertEqual(2, len(raised.exception.result.results))

    def test_run_stops_when_a_successful_scenario_writes_no_profile(self) -> None:
        corpus = self.make_corpus(self.make_scenario("missing-profile"))

        with self.assertRaisesRegex(CorpusRunError, "produced no raw profile"):
            self.run_fixture(corpus, omit_profile_for="missing-profile")

    def test_behavior_corpus_restores_the_previous_canonical_binary(self) -> None:
        corpus = self.make_corpus(self.make_scenario("first"))
        canonical = self.root / "zig-out" / "bin" / "fx"
        canonical.parent.mkdir(parents=True)
        canonical.write_bytes(b"stale")
        stale_inode = canonical.stat().st_ino
        binary = self.root / "candidate-fx"
        binary.write_bytes(b"candidate")

        def command_runner(argv, **kwargs):
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.2,
            )

        run_behavior_corpus(
            corpus,
            binary,
            self.root / "behavior-output",
            command_runner=command_runner,
        )

        self.assertEqual(b"stale", canonical.read_bytes())
        self.assertEqual(stale_inode, canonical.stat().st_ino)

    def test_interruption_cleans_tmux_and_restores_the_canonical_binary(self) -> None:
        corpus = self.make_corpus(self.make_scenario("first", requires_tmux=True))
        canonical = self.root / "zig-out" / "bin" / "fx"
        canonical.parent.mkdir(parents=True)
        canonical.write_bytes(b"original")
        binary = self.root / "candidate-fx"
        binary.write_bytes(b"candidate")

        def interrupted_runner(*_args, **_kwargs):
            raise KeyboardInterrupt()

        with (
            mock.patch("scripts.pgso.corpus._cleanup_tmux") as cleanup,
            self.assertRaises(KeyboardInterrupt),
        ):
            run_behavior_corpus(
                corpus,
                binary,
                self.root / "behavior-output",
                command_runner=interrupted_runner,
            )

        cleanup.assert_called_once()
        self.assertEqual(b"original", canonical.read_bytes())

    def test_behavior_corpus_runs_the_exact_binary_without_profile_output(self) -> None:
        corpus = self.make_corpus(
            self.make_scenario("first"),
            self.make_scenario("second"),
        )
        binary = self.root / "candidate-fx"
        binary.write_bytes(b"candidate")
        calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

        def command_runner(argv, **kwargs):
            calls.append((tuple(argv), dict(kwargs["env"])))
            return CommandResult(
                argv=tuple(argv),
                returncode=0,
                stdout="ok\n",
                stderr="",
                elapsed_seconds=0.2,
            )

        result = run_behavior_corpus(
            corpus,
            binary,
            self.root / "behavior-output",
            command_runner=command_runner,
        )

        canonical = self.root / "zig-out" / "bin" / "fx"
        self.assertEqual(2, result.passed)
        self.assertEqual(0, result.failed)
        self.assertEqual(0, result.merged_raw_profiles)
        self.assertTrue(all(call[0][0] == str(canonical) for call in calls))
        self.assertTrue(all("LLVM_PROFILE_FILE" not in call[1] for call in calls))
        self.assertTrue(all("FX_TRACE_SCOPES" not in call[1] for call in calls))
        self.assertEqual(
            {
                str(
                    self.root
                    / "behavior-output"
                    / "traces"
                    / "first.log"
                ),
                str(
                    self.root
                    / "behavior-output"
                    / "traces"
                    / "second.log"
                ),
            },
            {call[1]["FX_TRACE_LOG"] for call in calls},
        )
        self.assertTrue(
            all(
                call[1]["HOME"]
                == str(self.root / "behavior-output" / "home" / call[0][1])
                for call in calls
            )
        )
        self.assertEqual(
            "set-option -g history-limit 100000\n",
            (
                self.root
                / "behavior-output"
                / "home"
                / "first"
                / ".tmux.conf"
            ).read_text(),
        )


def dataclasses_replace_env(
    scenario: Scenario,
    item: tuple[str, str],
) -> Scenario:
    import dataclasses

    return dataclasses.replace(scenario, env_set=(*scenario.env_set, item))


def dataclasses_replace_allow_keychain(scenario: Scenario) -> Scenario:
    import dataclasses

    return dataclasses.replace(scenario, allow_keychain=True)


if __name__ == "__main__":
    unittest.main()
