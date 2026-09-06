from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.pgso.model import PgsoError
from scripts.pgso.pipeline import PipelinePaths
from scripts.pgso.profile_supplement import MappedProfile, ProfileSupplement
from scripts.pgso.qualify import (
    BENCHMARK_PLANS,
    STARTUP_COMMANDS,
    BenchmarkPair,
    EvidenceRecorder,
    _read_hyperfine_samples,
    build_benchmark_pair,
    build_profile_linked_benchmarks,
    compare_samples,
    measure_alternating,
    measure_heavy_workloads,
    measure_startup,
    percentile,
    profile_linked_benchmark_evidence,
    relink_profile_linked_benchmarks,
    select_benchmark_plans,
    select_startup_commands,
)
from scripts.pgso.runner import CommandResult


class PgsoQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-qualify-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def fake_startup_runner(
        self,
        *,
        hyperfine: pathlib.Path,
        control: pathlib.Path,
        candidate: pathlib.Path,
    ):
        calls: list[tuple[str, ...]] = []

        def fake_run(argv, **_kwargs):
            command = tuple(str(argument) for argument in argv)
            calls.append(command)
            if command[0] != str(hyperfine):
                return CommandResult(command, 0, "output\n", "", 0.01)

            export_path = pathlib.Path(
                command[command.index("--export-json") + 1]
            )
            runs = int(command[command.index("--runs") + 1])
            results = []
            for index, argument in enumerate(command):
                if argument != "--command-name":
                    continue
                label = command[index + 1]
                binary = command[index + 2].split(" ", 1)[0]
                if label == "control":
                    self.assertEqual(str(control), binary)
                    times = [1.0] * runs
                else:
                    self.assertEqual("candidate", label)
                    self.assertEqual(str(candidate), binary)
                    times = [0.9] * runs
                results.append({"command": label, "times": times})
            export_path.parent.mkdir(parents=True, exist_ok=True)
            export_path.write_text(json.dumps({"results": results}))
            return CommandResult(command, 0, "", "", 0.01)

        return calls, fake_run

    def write_hyperfine_export(self, results) -> pathlib.Path:
        path = self.root / "hyperfine.json"
        path.write_text(json.dumps({"results": results}))
        return path

    def test_percentile_uses_nearest_rank(self) -> None:
        samples = tuple(float(value) for value in range(1, 101))

        self.assertEqual(50.0, percentile(samples, 0.50))
        self.assertEqual(95.0, percentile(samples, 0.95))

    def test_production_plans_cover_five_startup_and_six_heavy_workloads(self) -> None:
        self.assertEqual(5, len(STARTUP_COMMANDS))
        workload_names = tuple(
            workload.name
            for plan in BENCHMARK_PLANS
            for workload in plan.workloads
        )
        self.assertEqual(
            (
                "file-index-100k",
                "ui-activity",
                "approval-transcript",
                "approval-diff",
                "approval-combined",
                "approval-payload",
            ),
            workload_names,
        )
        self.assertEqual(
            ("file_index", "ui_activity", "approval_review"),
            tuple(plan.selector for plan in BENCHMARK_PLANS),
        )
        self.assertEqual(
            (
                "file-index-bench",
                "ui-activity-progress-bench",
                "approval-review-bench",
            ),
            tuple(plan.profile_module for plan in BENCHMARK_PLANS),
        )
        self.assertTrue(all(plan.function_prefixes for plan in BENCHMARK_PLANS))

    def test_startup_selection_returns_only_the_assigned_command(self) -> None:
        selected = select_startup_commands(("doctor",))

        self.assertEqual((("doctor", ("doctor", "--json")),), selected)

    def test_startup_selection_rejects_an_unknown_command(self) -> None:
        with self.assertRaisesRegex(PgsoError, "unknown startup command: missing"):
            select_startup_commands(("missing",))

    def test_heavy_selection_keeps_only_the_assigned_workload(self) -> None:
        selected = select_benchmark_plans(("approval-diff",))

        self.assertEqual(1, len(selected))
        self.assertEqual("approval_review", selected[0].selector)
        self.assertEqual(("approval-diff",), tuple(item.name for item in selected[0].workloads))

    def test_heavy_selection_rejects_duplicate_assignments(self) -> None:
        with self.assertRaisesRegex(PgsoError, "duplicate heavy workload"):
            select_benchmark_plans(("ui-activity", "ui-activity"))

    def test_comparison_requires_fifty_samples_per_artifact(self) -> None:
        with self.assertRaisesRegex(PgsoError, "at least 50"):
            compare_samples((1.0,) * 49, (1.0,) * 50)

    def test_comparison_accepts_the_boundary_and_rejects_either_regression(self) -> None:
        boundary = compare_samples((10.0,) * 50, (11.0,) * 50)
        self.assertTrue(boundary.passed)

        p50_regression = compare_samples((10.0,) * 50, (11.01,) * 50)
        self.assertFalse(p50_regression.passed)

        p95_candidate = (10.0,) * 47 + (20.0,) * 3
        p95_regression = compare_samples((10.0,) * 50, p95_candidate)
        self.assertFalse(p95_regression.passed)

    def test_measurement_alternates_ab_and_ba_order(self) -> None:
        order: list[tuple[str, int]] = []

        def sample_runner(label, binary, argv, sample_index):
            order.append((label, sample_index))
            return 1.0 if label == "control" else 0.9

        result = measure_alternating(
            name="startup-help",
            control_binary=self.root / "control",
            candidate_binary=self.root / "candidate",
            argv=("help",),
            samples=50,
            sample_runner=sample_runner,
        )

        self.assertEqual(
            [
                ("control", 0),
                ("candidate", 0),
                ("candidate", 1),
                ("control", 1),
            ],
            order[:4],
        )
        self.assertEqual(0, result.control_failures)
        self.assertEqual(0, result.candidate_failures)
        self.assertTrue(result.passed)
        self.assertIsNotNone(result.comparison)

    def test_measurement_counts_failures_without_replacement(self) -> None:
        def sample_runner(label, binary, argv, sample_index):
            if label == "candidate" and sample_index == 3:
                raise PgsoError("candidate failed")
            return 1.0

        result = measure_alternating(
            name="startup-help",
            control_binary=self.root / "control",
            candidate_binary=self.root / "candidate",
            argv=("help",),
            samples=50,
            sample_runner=sample_runner,
        )

        self.assertEqual(0, result.control_failures)
        self.assertEqual(1, result.candidate_failures)
        self.assertFalse(result.passed)
        self.assertIsNone(result.comparison)
        self.assertEqual(49, len(result.candidate_samples))

    def test_startup_measurement_executes_immutable_artifacts_directly(self) -> None:
        control = self.root / "control" / "fx"
        candidate = self.root / "candidate" / "fx"
        hyperfine = self.root / "tools" / "hyperfine"
        canonical = self.root / "zig-out" / "bin" / "fx"
        for path, contents in (
            (control, b"control"),
            (candidate, b"candidate"),
            (hyperfine, b"hyperfine"),
            (canonical, b"canonical"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)

        calls, fake_run = self.fake_startup_runner(
            hyperfine=hyperfine,
            control=control,
            candidate=candidate,
        )

        with mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run):
            results = measure_startup(
                repo_root=self.root,
                control_binary=control,
                candidate_binary=candidate,
                hyperfine_binary=hyperfine,
                output_dir=self.root / "measurements",
                samples=50,
                timeout_s=10,
            )

        self.assertTrue(all(result.passed for result in results))
        self.assertEqual(b"canonical", canonical.read_bytes())
        self.assertEqual(
            [
                (str(control), "help"),
                (str(candidate), "help"),
            ],
            calls[:2],
        )
        self.assertNotIn(str(canonical), {command[0] for command in calls})

    def test_startup_measurement_runs_only_the_assigned_command(self) -> None:
        control = self.root / "control" / "fx"
        candidate = self.root / "candidate" / "fx"
        hyperfine = self.root / "tools" / "hyperfine"
        for path in (control, candidate, hyperfine):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"executable")
        calls, fake_run = self.fake_startup_runner(
            hyperfine=hyperfine,
            control=control,
            candidate=candidate,
        )

        with mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run):
            results = measure_startup(
                repo_root=self.root,
                control_binary=control,
                candidate_binary=candidate,
                hyperfine_binary=hyperfine,
                output_dir=self.root / "measurements",
                samples=50,
                timeout_s=10,
                command_names=("doctor",),
            )

        self.assertEqual(("startup-doctor",), tuple(item.name for item in results))
        self.assertEqual(100, sum(command[0] == str(hyperfine) for command in calls))

    def test_startup_measurement_uses_one_thousand_samples_in_balanced_blocks(self) -> None:
        control = self.root / "control" / "fx"
        candidate = self.root / "candidate" / "fx"
        hyperfine = self.root / "tools" / "hyperfine"
        for path in (control, candidate, hyperfine):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"executable")

        calls, fake_run = self.fake_startup_runner(
            hyperfine=hyperfine,
            control=control,
            candidate=candidate,
        )
        with mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run):
            results = measure_startup(
                repo_root=self.root,
                control_binary=control,
                candidate_binary=candidate,
                hyperfine_binary=hyperfine,
                output_dir=self.root / "measurements",
                samples=50,
                timeout_s=10,
            )

        hyperfine_calls = [
            command for command in calls if command[0] == str(hyperfine)
        ]
        self.assertEqual(500, len(hyperfine_calls))
        for command_start in range(0, len(hyperfine_calls), 100):
            command_rounds = hyperfine_calls[command_start : command_start + 100]
            for round_index, command in enumerate(command_rounds):
                self.assertIn("--shell=none", command)
                self.assertEqual("10", command[command.index("--warmup") + 1])
                self.assertEqual("10", command[command.index("--runs") + 1])
                expected_order = (
                    ["control", "candidate"]
                    if round_index % 2 == 0
                    else ["candidate", "control"]
                )
                self.assertEqual(
                    expected_order,
                    [
                        command[index + 1]
                        for index, value in enumerate(command)
                        if value == "--command-name"
                    ],
                )
        self.assertTrue(all(result.requested_samples == 1_000 for result in results))
        self.assertTrue(all(len(result.control_samples) == 1_000 for result in results))
        self.assertTrue(all(len(result.candidate_samples) == 1_000 for result in results))

    def test_startup_measurement_caps_large_campaign_blocks_at_ten_runs(self) -> None:
        control = self.root / "control" / "fx"
        candidate = self.root / "candidate" / "fx"
        hyperfine = self.root / "tools" / "hyperfine"
        for path in (control, candidate, hyperfine):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"executable")

        calls, fake_run = self.fake_startup_runner(
            hyperfine=hyperfine,
            control=control,
            candidate=candidate,
        )
        with mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run):
            results = measure_startup(
                repo_root=self.root,
                control_binary=control,
                candidate_binary=candidate,
                hyperfine_binary=hyperfine,
                output_dir=self.root / "measurements",
                samples=1_000,
                timeout_s=10,
                command_names=("status",),
            )

        hyperfine_calls = [
            command for command in calls if command[0] == str(hyperfine)
        ]
        self.assertEqual(100, len(hyperfine_calls))
        self.assertTrue(
            all(command[command.index("--runs") + 1] == "10" for command in hyperfine_calls)
        )
        for round_index, command in enumerate(hyperfine_calls):
            expected_order = (
                ["control", "candidate"]
                if round_index % 2 == 0
                else ["candidate", "control"]
            )
            self.assertEqual(
                expected_order,
                [
                    command[index + 1]
                    for index, value in enumerate(command)
                    if value == "--command-name"
                ],
            )
        self.assertEqual((1_000,), tuple(result.requested_samples for result in results))
        self.assertEqual((1_000,), tuple(len(result.control_samples) for result in results))
        self.assertEqual((1_000,), tuple(len(result.candidate_samples) for result in results))

    def test_startup_measurement_disables_external_keychain_reads(self) -> None:
        control = self.root / "control" / "fx"
        candidate = self.root / "candidate" / "fx"
        hyperfine = self.root / "tools" / "hyperfine"
        for path in (control, candidate, hyperfine):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"executable")

        _, base_runner = self.fake_startup_runner(
            hyperfine=hyperfine,
            control=control,
            candidate=candidate,
        )
        environments: list[dict[str, str]] = []

        def fake_run(argv, **kwargs):
            environments.append(kwargs["env"])
            return base_runner(argv, **kwargs)

        with (
            mock.patch.dict(
                os.environ,
                {
                    "FX_DISABLE_KEYCHAIN": "0",
                    "AI_GATEWAY_API_KEY": "must-not-leak",
                    "FX_E2E_REAL_API": "1",
                },
            ),
            mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run),
        ):
            measure_startup(
                repo_root=self.root,
                control_binary=control,
                candidate_binary=candidate,
                hyperfine_binary=hyperfine,
                output_dir=self.root / "measurements",
                samples=50,
                timeout_s=10,
            )

        self.assertTrue(environments)
        self.assertTrue(
            all(environment["FX_DISABLE_KEYCHAIN"] == "1" for environment in environments)
        )
        self.assertTrue(
            all("AI_GATEWAY_API_KEY" not in environment for environment in environments)
        )
        self.assertTrue(
            all("FX_E2E_REAL_API" not in environment for environment in environments)
        )

    def test_startup_measurement_rejects_a_truncated_hyperfine_round(self) -> None:
        path = self.write_hyperfine_export(
            [
                {"command": "control", "times": [1.0] * 50},
                {"command": "candidate", "times": [0.9] * 49},
            ]
        )

        with self.assertRaisesRegex(
            PgsoError,
            "Hyperfine round returned 49 candidate samples; expected 50",
        ):
            _read_hyperfine_samples(path, expected_samples=50)

    def test_startup_measurement_rejects_duplicate_hyperfine_labels(self) -> None:
        path = self.write_hyperfine_export(
            [
                {"command": "control", "times": [1.0] * 50},
                {"command": "control", "times": [0.9] * 50},
            ]
        )

        with self.assertRaisesRegex(
            PgsoError,
            "Hyperfine round contains duplicate label: control",
        ):
            _read_hyperfine_samples(path, expected_samples=50)

    def test_startup_measurement_rejects_nonpositive_hyperfine_time(self) -> None:
        path = self.write_hyperfine_export(
            [
                {"command": "control", "times": [0.0] + [1.0] * 49},
                {"command": "candidate", "times": [0.9] * 50},
            ]
        )

        with self.assertRaisesRegex(
            PgsoError,
            "Hyperfine control sample 0 must be finite and positive",
        ):
            _read_hyperfine_samples(path, expected_samples=50)

    def test_startup_measurement_preserves_hyperfine_diagnostics(self) -> None:
        control = self.root / "control" / "fx"
        candidate = self.root / "candidate" / "fx"
        hyperfine = self.root / "tools" / "hyperfine"
        for path in (control, candidate, hyperfine):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"executable")

        _, base_runner = self.fake_startup_runner(
            hyperfine=hyperfine,
            control=control,
            candidate=candidate,
        )

        def fake_run(argv, **kwargs):
            command = tuple(str(argument) for argument in argv)
            if command[0] == str(hyperfine):
                self.assertFalse(kwargs["require_empty_stderr"])
            return base_runner(argv, **kwargs)

        with mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run):
            results = measure_startup(
                repo_root=self.root,
                control_binary=control,
                candidate_binary=candidate,
                hyperfine_binary=hyperfine,
                output_dir=self.root / "measurements",
                samples=50,
                timeout_s=10,
            )

        self.assertTrue(all(result.passed for result in results))

    def test_heavy_measurement_uses_the_prebuilt_profiled_pair(self) -> None:
        control = self.root / "heavy" / "control"
        candidate = self.root / "heavy" / "candidate"
        for path in (control, candidate):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"executable")
        pair = BenchmarkPair(
            selector="file_index",
            control_binary=control,
            candidate_binary=candidate,
            bitcode_sha256="b" * 64,
            merged_raw_profiles=1,
        )
        calls: list[tuple[str, ...]] = []

        def fake_run(argv, **_kwargs):
            command = tuple(str(argument) for argument in argv)
            calls.append(command)
            elapsed = 1.0 if command[0] == str(control) else 0.9
            return CommandResult(command, 0, "measured\n", "", elapsed)

        with (
            mock.patch(
                "scripts.pgso.qualify.build_benchmark_pair",
                side_effect=AssertionError("must use immutable prebuilt pair"),
            ),
            mock.patch("scripts.pgso.qualify.run_checked", side_effect=fake_run),
        ):
            results = measure_heavy_workloads(
                toolchain=None,
                repo_root=self.root,
                output_dir=self.root / "measurements",
                samples=50,
                timeout_s=10,
                workload_names=("file-index-100k",),
                prebuilt_pairs={"file_index": pair},
            )

        self.assertEqual(("file-index-100k",), tuple(item.name for item in results))
        self.assertEqual(100, len(calls))
        self.assertEqual(str(control), calls[0][0])
        self.assertEqual(str(candidate), calls[1][0])
        self.assertTrue(results[0].passed)

    def test_benchmark_pair_uses_the_external_control_for_minimum_macos(self) -> None:
        plan = BENCHMARK_PLANS[0]
        output = self.root / "pair"
        external = self.root / "fixtures" / "external-control"
        candidate = self.root / "fixtures" / "candidate"
        raw_profile = self.root / "fixtures" / "training.profraw"
        for path in (external, candidate, raw_profile):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"evidence")

        with (
            mock.patch(
                "scripts.pgso.qualify.build_control",
                side_effect=AssertionError("ordinary control build is wasteful"),
                create=True,
            ),
            mock.patch("scripts.pgso.qualify.emit_bitcode", return_value="b" * 64),
            mock.patch(
                "scripts.pgso.qualify.build_external_o2_control",
                return_value=external,
            ),
            mock.patch(
                "scripts.pgso.qualify.read_macos_minos",
                return_value="15.0",
            ) as read_minos,
            mock.patch(
                "scripts.pgso.qualify.build_instrumented",
                return_value=(raw_profile,),
            ) as instrument,
            mock.patch("scripts.pgso.qualify.merge_profile_batch", return_value=1),
            mock.patch("scripts.pgso.qualify.apply_profile"),
            mock.patch("scripts.pgso.qualify.link_candidate", return_value=candidate),
        ):
            pair = build_benchmark_pair(object(), self.root, output, plan)

        self.assertEqual(external, pair.control_binary)
        self.assertEqual(external, read_minos.call_args.args[1])
        self.assertEqual("15.0", instrument.call_args.args[2])

    def test_builds_all_profile_linked_benchmarks_before_candidate_link(self) -> None:
        paths = PipelinePaths.create(self.root / "run")
        paths.merged_profile.write_bytes(b"production profile")
        built_selectors: list[str] = []
        supplement_events: list[str] = []

        def fake_build(_toolchain, _repo_root, output_dir, plan):
            built_selectors.append(plan.selector)
            control = output_dir / "external-control" / plan.profile_module
            candidate = output_dir / "candidate" / plan.profile_module
            profile = output_dir / "profiles" / "merged.profdata"
            ir = output_dir / "ir" / "profile-use.ll"
            for path in (control, candidate, profile, ir):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"evidence")
            return BenchmarkPair(
                selector=plan.selector,
                control_binary=control,
                candidate_binary=candidate,
                bitcode_sha256="b" * 64,
                merged_raw_profiles=1,
                merged_profile=profile,
                profile_use_ir=ir,
            )

        def fake_create(_toolchain, **kwargs):
            supplement_events.append(f"create:{kwargs['output_text'].stem}")
            output_text = kwargs["output_text"]
            output_text.write_text("supplement\n")
            return ProfileSupplement(
                text="supplement\n",
                function_names=("fx;core.output.diff.compute",),
                total_counter_value=8,
            )

        def fake_merge(_toolchain, **kwargs):
            supplement_events.append(
                f"merge:{kwargs['supplement_text'].stem}"
            )

        with (
            mock.patch(
                "scripts.pgso.qualify.build_benchmark_pair",
                side_effect=fake_build,
            ),
            mock.patch(
                "scripts.pgso.qualify.create_profile_supplement",
                side_effect=fake_create,
            ),
            mock.patch(
                "scripts.pgso.qualify.merge_profile_supplement",
                side_effect=fake_merge,
            ) as merge,
        ):
            linked = build_profile_linked_benchmarks(
                object(),
                self.root,
                paths,
            )

        self.assertEqual(
            tuple(plan.selector for plan in BENCHMARK_PLANS),
            tuple(linked),
        )
        self.assertEqual(
            tuple(plan.selector for plan in BENCHMARK_PLANS),
            tuple(built_selectors),
        )
        self.assertEqual(len(BENCHMARK_PLANS), merge.call_count)
        self.assertEqual(
            [
                *(f"create:{plan.selector}" for plan in BENCHMARK_PLANS),
                *(f"merge:{plan.selector}" for plan in BENCHMARK_PLANS),
            ],
            supplement_events,
        )

        def fake_map(_toolchain, **kwargs):
            kwargs["output_text"].write_text("mapped text\n")
            kwargs["output_profile"].write_bytes(b"mapped profile")
            return MappedProfile(
                text="mapped text\n",
                compatible_function_names=("core.output.diff.compute",),
                total_counter_value=16,
            )

        def fake_link(_toolchain, pair_paths, **_kwargs):
            pair_paths.profile_use_ir.write_text("profile-use IR\n")
            return pair_paths.candidate_binary

        with (
            mock.patch(
                "scripts.pgso.qualify.create_mapped_benchmark_profile",
                side_effect=fake_map,
            ),
            mock.patch("scripts.pgso.qualify.apply_profile"),
            mock.patch(
                "scripts.pgso.qualify.link_candidate",
                side_effect=fake_link,
            ),
        ):
            linked = relink_profile_linked_benchmarks(
                object(),
                paths,
                linked,
            )

        with mock.patch(
            "scripts.pgso.qualify.verify_supplement_functions",
            return_value={"core.output.diff.compute": "speed"},
        ):
            evidence = profile_linked_benchmark_evidence(
                linked,
                "production IR",
            )
        self.assertEqual(tuple(linked), tuple(evidence))
        self.assertTrue(
            all(
                item["functions"]
                == {"core.output.diff.compute": "speed"}
                for item in evidence.values()
            )
        )

    def test_evidence_recorder_is_fail_closed_and_writes_atomically(self) -> None:
        manifest = self.root / "manifest.json"
        recorder = EvidenceRecorder(
            manifest,
            command="all",
            configuration={"target": "aarch64-macos", "samples": 50},
        )
        recorder.stage("validate", "passed", {"source_sha": "a" * 40})
        recorder.fail("profile-use", PgsoError("optimizer warning"))

        payload = json.loads(manifest.read_text())
        self.assertEqual(1, payload["schema_version"])
        self.assertEqual("failed", payload["status"])
        self.assertEqual("profile-use", payload["stage"])
        self.assertFalse(payload["eligible"])
        self.assertEqual("optimizer warning", payload["error"])
        self.assertFalse(any(self.root.glob(".manifest.json.*.tmp")))

    def test_evidence_recorder_streams_stage_lifecycle_and_duration(self) -> None:
        stdout = io.StringIO()

        with contextlib.redirect_stdout(stdout):
            recorder = EvidenceRecorder(
                self.root / "manifest.json",
                command="all",
                configuration={"target": "aarch64-macos", "samples": 50},
            )
            recorder.stage("validate", "running")
            recorder.stage("validate", "passed")
            recorder.stage("profile-use", "running")
            recorder.fail("profile-use", PgsoError("optimizer warning"))

        output = stdout.getvalue()
        self.assertIn("[pgso] stage started: validate", output)
        self.assertRegex(
            output,
            r"\[pgso\] stage passed in \d+\.\d{3}s: validate",
        )
        self.assertIn("[pgso] stage started: profile-use", output)
        self.assertRegex(
            output,
            (
                r"\[pgso\] stage failed in \d+\.\d{3}s: "
                r"profile-use: optimizer warning"
            ),
        )
        payload = json.loads((self.root / "manifest.json").read_text())
        passed_stage = payload["stages"][1]
        failed_stage = payload["stages"][3]
        self.assertIn("elapsed_seconds", passed_stage)
        self.assertIn("elapsed_seconds", failed_stage)
        self.assertGreaterEqual(passed_stage["elapsed_seconds"], 0)
        self.assertGreaterEqual(failed_stage["elapsed_seconds"], 0)

    def test_evidence_recorder_cannot_mark_incomplete_work_eligible(self) -> None:
        recorder = EvidenceRecorder(
            self.root / "manifest.json",
            command="all",
            configuration={"target": "aarch64-macos", "samples": 50},
        )
        with self.assertRaisesRegex(PgsoError, "required evidence"):
            recorder.complete()


if __name__ == "__main__":
    unittest.main()
