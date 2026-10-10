from __future__ import annotations

import dataclasses
import json
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.pgso.__main__ import (
    _runtime_versions,
    ensure_fresh_output,
    load_read_only_manifest,
    parse_args,
    run_command,
)
from scripts.pgso.model import PgsoError
from scripts.pgso.pipeline import PipelinePaths
from scripts.pgso.runner import CommandResult


class PgsoCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-cli-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def required_arguments(self, command: str = "all") -> list[str]:
        return [
            command,
            "--llvm-bin",
            "/opt/llvm/bin",
            "--output-dir",
            str(self.root / "output"),
        ]

    def test_all_command_exposes_the_production_defaults(self) -> None:
        arguments = parse_args(self.required_arguments())

        self.assertEqual("all", arguments.command)
        self.assertEqual("aarch64-macos", arguments.target)
        self.assertEqual("stable", arguments.update_channel)
        self.assertEqual(50, arguments.samples)
        self.assertGreater(arguments.timeout_seconds, 0)
        self.assertTrue(str(arguments.corpus).endswith("scripts/pgso/corpus.json"))
        self.assertEqual("bun", arguments.bun)
        self.assertEqual("hyperfine", arguments.hyperfine)

    def test_every_mutating_command_requires_toolchain_and_output(self) -> None:
        for command in ("build", "train", "all"):
            with self.subTest(command=command):
                with self.assertRaises(SystemExit):
                    parse_args([command])

    def test_qualification_rejects_fewer_than_fifty_samples(self) -> None:
        for command in ("all",):
            with self.subTest(command=command):
                with self.assertRaises(SystemExit):
                    parse_args([*self.required_arguments(command), "--samples", "49"])

    def test_redundant_qualify_alias_is_not_exposed(self) -> None:
        with self.assertRaises(SystemExit):
            parse_args(self.required_arguments("qualify"))

    def test_fresh_output_rejects_nonempty_state(self) -> None:
        output = self.root / "output"
        output.mkdir()
        (output / "stale.profdata").write_bytes(b"stale")

        with self.assertRaisesRegex(PgsoError, "not empty"):
            ensure_fresh_output(output)

    def test_read_only_reporting_requires_an_existing_complete_manifest(self) -> None:
        output = self.root / "output"
        output.mkdir()
        manifest = output / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "status": "passed",
                    "stage": "complete",
                    "eligible": True,
                    "evidence": {
                        "identity": {},
                        "runtime": {},
                        "artifacts": {},
                        "profile": {},
                        "corpus": {},
                        "startup": [],
                        "heavy_workloads": [],
                    },
                }
            )
        )

        payload = load_read_only_manifest(output)

        self.assertTrue(payload["eligible"])
        self.assertEqual("passed", payload["status"])

    def test_read_only_reporting_rejects_failed_or_incomplete_evidence(self) -> None:
        output = self.root / "output"
        output.mkdir()
        (output / "manifest.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "status": "failed",
                    "stage": "profile-use",
                    "eligible": False,
                }
            )
        )

        with self.assertRaisesRegex(PgsoError, "not eligible"):
            load_read_only_manifest(output)

    def test_driver_records_validation_failure_before_returning(self) -> None:
        arguments = parse_args(self.required_arguments())
        with mock.patch(
            "scripts.pgso.__main__.Toolchain.discover",
            side_effect=PgsoError("wrong LLVM version"),
        ):
            with self.assertRaisesRegex(PgsoError, "wrong LLVM version"):
                run_command(arguments)

        payload = json.loads(
            (arguments.output_dir / "manifest.json").read_text()
        )
        self.assertEqual("failed", payload["status"])
        self.assertEqual("validate", payload["stage"])
        self.assertFalse(payload["eligible"])
        self.assertEqual("wrong LLVM version", payload["error"])

    def test_driver_marks_the_manifest_failed_when_interrupted(self) -> None:
        arguments = parse_args(self.required_arguments())
        with mock.patch(
            "scripts.pgso.__main__.Toolchain.discover",
            side_effect=KeyboardInterrupt(),
        ):
            with self.assertRaises(KeyboardInterrupt):
                run_command(arguments)

        payload = json.loads(
            (arguments.output_dir / "manifest.json").read_text()
        )
        self.assertEqual("failed", payload["status"])
        self.assertEqual("validate", payload["stage"])
        self.assertFalse(payload["eligible"])

    def test_all_command_supplies_hyperfine_to_heavy_measurement(self) -> None:
        @dataclasses.dataclass(frozen=True)
        class ToolchainInfo:
            host_arch: str = "arm64"
            target: str = "aarch64-macos"
            zig_version: str = "0.17.0"
            llvm_version: str = "22.1.8"

        @dataclasses.dataclass(frozen=True)
        class CorpusInfo:
            manifest_path: pathlib.Path
            manifest_sha256: str
            intentional_exclusions: tuple[str, ...] = ()

        @dataclasses.dataclass(frozen=True)
        class CorpusResult:
            merged_raw_profiles: int = 0

        @dataclasses.dataclass(frozen=True)
        class ArtifactInfo:
            preferred_headroom_met: bool = True

        @dataclasses.dataclass(frozen=True)
        class MetadataInfo:
            architecture: str = "arm64"
            min_macos: str = "15.0"
            signature_valid: bool = True

        @dataclasses.dataclass(frozen=True)
        class CandidateInfo:
            sha256: str
            artifact: ArtifactInfo
            metadata: MetadataInfo
            version_output: str = "0.0.9"

        arguments = parse_args(self.required_arguments())
        control = self.root / "control"
        control.write_bytes(b"control")
        hyperfine = self.root / "hyperfine"
        heavy_kwargs: list[dict[str, object]] = []

        def merge_profile(_toolchain, _profiles, output, _log):
            output.write_bytes(b"profile")
            return 0

        def write_profile_use_ir(_toolchain, paths, _sha):
            paths.profile_use_ir.write_text("ir\n", encoding="utf-8")

        def link_candidate(_toolchain, paths):
            (paths.logs / "candidate-layout.json").write_text(
                json.dumps({"linker": "test"}),
                encoding="utf-8",
            )

        def capture_heavy(**kwargs):
            heavy_kwargs.append(kwargs)
            return ()

        toolchain = ToolchainInfo()
        corpus = CorpusInfo(self.root / "corpus.json", "c" * 64)
        linked: dict[str, object] = {}
        candidate = CandidateInfo("d" * 64, ArtifactInfo(), MetadataInfo())
        with mock.patch.multiple(
            "scripts.pgso.__main__",
            Toolchain=mock.DEFAULT,
            _runtime_versions=mock.Mock(
                return_value=(self.root / "bun", hyperfine, {"runtime": "ok"})
            ),
            load_corpus=mock.Mock(return_value=corpus),
            _git_output=mock.Mock(side_effect=["a" * 40, ""]),
            build_control=mock.Mock(return_value=control),
            read_macos_minos=mock.Mock(return_value="15.0"),
            sha256_file=mock.Mock(return_value="s" * 64),
            emit_bitcode=mock.Mock(return_value="b" * 64),
            build_instrumented=mock.Mock(return_value=()),
            merge_profile_batch=mock.Mock(side_effect=merge_profile),
            profile_evidence=mock.Mock(return_value={}),
            run_corpus=mock.Mock(return_value=CorpusResult()),
            _profile_summary=mock.Mock(return_value={}),
            build_profile_linked_benchmarks=mock.Mock(return_value=linked),
            apply_profile=mock.Mock(side_effect=write_profile_use_ir),
            link_candidate=mock.Mock(side_effect=link_candidate),
            relink_profile_linked_benchmarks=mock.Mock(return_value=linked),
            verify_candidate=mock.Mock(return_value=candidate),
            profile_linked_benchmark_evidence=mock.Mock(return_value={}),
            run_behavior_corpus=mock.Mock(return_value=CorpusResult()),
            measure_startup=mock.Mock(return_value=()),
            measure_heavy_workloads=mock.Mock(side_effect=capture_heavy),
        ) as mocks:
            mocks["Toolchain"].discover.return_value = toolchain
            manifest_path = run_command(arguments)

        self.assertEqual(
            (arguments.output_dir / "manifest.json").resolve(),
            manifest_path.resolve(),
        )
        self.assertEqual(1, len(heavy_kwargs))
        self.assertIs(hyperfine, heavy_kwargs[0].get("hyperfine_binary"))
        payload = json.loads(manifest_path.read_text())
        self.assertEqual("passed", payload["status"])
        self.assertTrue(payload["eligible"])

    def test_runtime_validation_rejects_the_wrong_bun_version(self) -> None:
        arguments = parse_args(self.required_arguments())
        paths = PipelinePaths.create(self.root / "runtime-output")
        executable = self.root / "bun"
        executable.write_bytes(b"fake")
        executable.chmod(0o755)
        result = CommandResult(
            argv=(str(executable), "--version"),
            returncode=0,
            stdout="1.3.12\n",
            stderr="",
            elapsed_seconds=0.01,
        )

        with mock.patch(
            "scripts.pgso.__main__._resolve_runtime_executable",
            return_value=executable,
        ), mock.patch(
            "scripts.pgso.__main__.run_checked",
            return_value=result,
        ):
            with self.assertRaisesRegex(PgsoError, "requires Bun 1.3.14"):
                _runtime_versions(arguments, paths)

    def test_runtime_validation_rejects_the_wrong_hyperfine_version(self) -> None:
        arguments = parse_args(self.required_arguments())
        paths = PipelinePaths.create(self.root / "runtime-output")
        executables = {
            name: self.root / name for name in ("bun", "hyperfine", "tmux")
        }
        for executable in executables.values():
            executable.write_bytes(b"fake")
            executable.chmod(0o755)

        def resolve(_command, label):
            return executables[label.lower()]

        def fake_run(argv, **_kwargs):
            command = tuple(str(argument) for argument in argv)
            if command[0] == str(executables["bun"]):
                stdout = "1.3.14\n"
            elif command[0] == str(executables["hyperfine"]):
                stdout = "hyperfine 1.19.0\n"
            else:
                stdout = "tmux 3.6a\n"
            return CommandResult(command, 0, stdout, "", 0.01)

        with mock.patch(
            "scripts.pgso.__main__._resolve_runtime_executable",
            side_effect=resolve,
        ), mock.patch(
            "scripts.pgso.__main__.run_checked",
            side_effect=fake_run,
        ):
            with self.assertRaisesRegex(PgsoError, "requires Hyperfine 1.20.0"):
                _runtime_versions(arguments, paths)


if __name__ == "__main__":
    unittest.main()
