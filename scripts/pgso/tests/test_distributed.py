from __future__ import annotations

import unittest

import pathlib
import dataclasses

from scripts.pgso.corpus import Corpus, Scenario
from scripts.pgso.distributed import (
    aggregate_measurement_shards,
    aggregate_scenario_shards,
    matrix_payload,
    plan_shards,
    run_plan,
    select_corpus,
    validate_seed_identity,
)
from scripts.pgso.model import BuildIdentity, PgsoError
from scripts.pgso.pipeline import GENERATION_FLAGS


def scenario(name: str, timeout_seconds: float) -> Scenario:
    return Scenario(
        name=name,
        argv=("{binary}", "help"),
        cwd=".",
        env_set=(),
        env_unset=(),
        timeout_seconds=timeout_seconds,
        requires_tmux=False,
        allow_keychain=False,
        test_file=None,
    )


class WorkflowContractTests(unittest.TestCase):
    def test_behavior_workers_install_pinned_zig_without_llvm(self) -> None:
        repo_root = pathlib.Path(__file__).resolve().parents[3]
        action = (repo_root / ".github/actions/setup-pgso/action.yml").read_text()
        workflow = (
            repo_root / ".github/workflows/pgso-macos-arm64.yml"
        ).read_text()
        behavior_job = workflow.split("\n  behavior:\n", 1)[1].split(
            "\n  startup:\n", 1
        )[0]

        self.assertIn("  zig:\n", action)
        self.assertIn(
            "if: inputs.zig == 'true' || inputs.llvm == 'true'",
            action,
        )
        self.assertIn('          zig: "true"', behavior_job)
        self.assertNotIn('          llvm: "true"', behavior_job)

    def test_heavy_workers_measure_candidate_built_profile_pairs(self) -> None:
        repo_root = pathlib.Path(__file__).resolve().parents[3]
        workflow = (
            repo_root / ".github/workflows/pgso-macos-arm64.yml"
        ).read_text()
        candidate_job = workflow.split("\n  candidate:\n", 1)[1].split(
            "\n  behavior:\n", 1
        )[0]
        heavy_job = workflow.split("\n  heavy:\n", 1)[1].split(
            "\n  aggregate:\n", 1
        )[0]

        self.assertIn("profiles/merged.profdata", candidate_job)
        self.assertIn("heavy/file_index/candidate/file-index-bench", candidate_job)
        self.assertIn(
            "heavy/approval_review/candidate/approval-review-bench",
            candidate_job,
        )
        self.assertNotIn('          llvm: "true"', heavy_job)
        self.assertNotIn("--llvm-bin", heavy_job)

    def test_measurement_matrices_are_generated_from_python_definitions(self) -> None:
        repo_root = pathlib.Path(__file__).resolve().parents[3]
        workflow = (
            repo_root / ".github/workflows/pgso-macos-arm64.yml"
        ).read_text()
        startup_job = workflow.split("\n  startup:\n", 1)[1].split(
            "\n  heavy:\n", 1
        )[0]
        heavy_job = workflow.split("\n  heavy:\n", 1)[1].split(
            "\n  aggregate:\n", 1
        )[0]

        self.assertIn("fromJSON(needs.seed.outputs.startup)", startup_job)
        self.assertIn("fromJSON(needs.seed.outputs.heavy)", heavy_job)
        self.assertNotIn("name: [help, version", startup_job)
        self.assertNotIn("- file-index-100k", heavy_job)


class ShardPlanningTests(unittest.TestCase):
    def test_measurement_plans_come_from_the_authoritative_definitions(self) -> None:
        missing_corpus = pathlib.Path("/does/not/need/to/exist.json")

        self.assertEqual(
            {
                "include": [
                    {"name": name}
                    for name in ("help", "version", "status", "doctor", "sessions")
                ]
            },
            run_plan("startup", missing_corpus, 20),
        )
        self.assertEqual(
            {
                "include": [
                    {"name": name}
                    for name in (
                        "file-index-100k",
                        "ui-activity",
                        "approval-transcript",
                        "approval-diff",
                        "approval-combined",
                        "approval-payload",
                    )
                ]
            },
            run_plan("heavy", missing_corpus, 20),
        )

    def test_plan_assigns_every_scenario_exactly_once(self) -> None:
        scenarios = tuple(
            scenario(f"scenario-{index:02d}", float(index + 1))
            for index in range(36)
        )

        shards = plan_shards(scenarios, maximum_shards=20, prefix="training")

        assigned = [name for shard in shards for name in shard.scenario_names]
        self.assertEqual(20, len(shards))
        self.assertEqual(sorted(item.name for item in scenarios), sorted(assigned))
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertTrue(all(shard.scenario_names for shard in shards))

    def test_plan_is_deterministic_and_weight_balanced(self) -> None:
        scenarios = (
            scenario("slow", 100.0),
            scenario("medium", 50.0),
            scenario("quick-a", 1.0),
            scenario("quick-b", 1.0),
        )

        first = plan_shards(scenarios, maximum_shards=2, prefix="verify")
        second = plan_shards(scenarios, maximum_shards=2, prefix="verify")

        self.assertEqual(first, second)
        self.assertEqual(("slow",), first[0].scenario_names)
        self.assertEqual(
            ("medium", "quick-a", "quick-b"),
            first[1].scenario_names,
        )

    def test_plan_uses_one_nonempty_shard_per_scenario_when_below_limit(self) -> None:
        scenarios = (scenario("one", 1.0), scenario("two", 1.0))

        shards = plan_shards(scenarios, maximum_shards=20, prefix="training")

        self.assertEqual(2, len(shards))
        self.assertEqual(("one",), shards[0].scenario_names)
        self.assertEqual(("two",), shards[1].scenario_names)

    def test_matrix_payload_is_compact_and_contains_no_empty_jobs(self) -> None:
        shards = plan_shards(
            (scenario("one", 1.0), scenario("two", 2.0)),
            maximum_shards=20,
            prefix="training",
        )

        payload = matrix_payload(shards)

        self.assertEqual(
            {
                "include": [
                    {"id": "training-01", "scenarios": "two"},
                    {"id": "training-02", "scenarios": "one"},
                ]
            },
            payload,
        )


class CorpusSelectionTests(unittest.TestCase):
    def make_corpus(self) -> Corpus:
        return Corpus(
            repo_root=pathlib.Path("/tmp/repo"),
            manifest_path=pathlib.Path("/tmp/repo/scripts/pgso/corpus.json"),
            manifest_sha256="c" * 64,
            scenarios=(scenario("train-a", 1.0), scenario("train-b", 2.0)),
            intentional_exclusions=(),
            verification_scenarios=(scenario("verify-only", 3.0),),
        )

    def test_select_training_rejects_names_outside_training_set(self) -> None:
        with self.assertRaisesRegex(PgsoError, "unknown training scenario"):
            select_corpus(self.make_corpus(), "training", ("verify-only",))

    def test_select_behavior_can_mix_training_and_verification_scenarios(self) -> None:
        selected = select_corpus(
            self.make_corpus(),
            "behavior",
            ("verify-only", "train-a"),
        )

        self.assertEqual(
            ("train-a", "verify-only"),
            tuple(item.name for item in selected.candidate_scenarios),
        )

    def test_select_rejects_duplicate_assignments(self) -> None:
        with self.assertRaisesRegex(PgsoError, "duplicate assigned scenario"):
            select_corpus(
                self.make_corpus(),
                "training",
                ("train-a", "train-a"),
            )


class ShardAggregationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.identity = BuildIdentity(
            source_sha="a" * 40,
            target="aarch64-macos",
            host_arch="arm64",
            zig_version="0.16.0",
            llvm_version="21.1.8",
            bitcode_sha256="b" * 64,
            corpus_sha256="c" * 64,
            update_channel="stable",
            generation_flags=GENERATION_FLAGS,
        )

    def shard(self, shard_id: str, names: tuple[str, ...]) -> dict[str, object]:
        return {
            "schema_version": 1,
            "status": "passed",
            "phase": "training",
            "shard_id": shard_id,
            "identity": dataclasses.asdict(self.identity),
            "artifact_sha256": "d" * 64,
            "assigned_scenarios": list(names),
            "result": {
                "passed": len(names),
                "skipped": 0,
                "failed": 0,
                "merged_raw_profiles": len(names),
                "results": [
                    {
                        "name": name,
                        "status": "passed",
                        "elapsed_seconds": 1.0,
                        "raw_profiles": 1,
                        "error": None,
                    }
                    for name in names
                ],
            },
        }

    def test_aggregate_requires_exactly_once_passing_coverage(self) -> None:
        result = aggregate_scenario_shards(
            (self.shard("training-01", ("one",)), self.shard("training-02", ("two",))),
            phase="training",
            expected_names=("one", "two"),
            expected_identity=self.identity,
            expected_artifact_sha256="d" * 64,
        )

        self.assertEqual(2, result["passed"])
        self.assertEqual(2, result["merged_raw_profiles"])
        self.assertEqual(["one", "two"], [item["name"] for item in result["results"]])

    def test_aggregate_rejects_duplicate_scenario_across_shards(self) -> None:
        with self.assertRaisesRegex(PgsoError, "duplicate training scenario"):
            aggregate_scenario_shards(
                (self.shard("training-01", ("one",)), self.shard("training-02", ("one",))),
                phase="training",
                expected_names=("one",),
                expected_identity=self.identity,
                expected_artifact_sha256="d" * 64,
            )

    def test_aggregate_rejects_missing_scenario(self) -> None:
        with self.assertRaisesRegex(PgsoError, "missing training scenario: two"):
            aggregate_scenario_shards(
                (self.shard("training-01", ("one",)),),
                phase="training",
                expected_names=("one", "two"),
                expected_identity=self.identity,
                expected_artifact_sha256="d" * 64,
            )

    def test_aggregate_rejects_identity_mismatch(self) -> None:
        shard = self.shard("training-01", ("one",))
        identity = dict(shard["identity"])
        identity["source_sha"] = "f" * 40
        shard["identity"] = identity

        with self.assertRaisesRegex(PgsoError, "identity mismatch: source_sha"):
            aggregate_scenario_shards(
                (shard,),
                phase="training",
                expected_names=("one",),
                expected_identity=self.identity,
                expected_artifact_sha256="d" * 64,
            )

    def test_aggregate_rejects_artifact_hash_mismatch(self) -> None:
        shard = self.shard("training-01", ("one",))
        shard["artifact_sha256"] = "e" * 64

        with self.assertRaisesRegex(PgsoError, "training artifact hash mismatch"):
            aggregate_scenario_shards(
                (shard,),
                phase="training",
                expected_names=("one",),
                expected_identity=self.identity,
                expected_artifact_sha256="d" * 64,
            )

    def test_aggregate_rejects_a_failed_shard_manifest(self) -> None:
        shard = self.shard("training-01", ("one",))
        shard["status"] = "failed"

        with self.assertRaisesRegex(PgsoError, "training shard did not pass"):
            aggregate_scenario_shards(
                (shard,),
                phase="training",
                expected_names=("one",),
                expected_identity=self.identity,
                expected_artifact_sha256="d" * 64,
            )

    def test_seed_identity_requires_the_pinned_production_contract(self) -> None:
        validate_seed_identity(self.identity)

        with self.assertRaisesRegex(PgsoError, "stable update channel"):
            validate_seed_identity(dataclasses.replace(self.identity, update_channel="dev"))
        with self.assertRaisesRegex(PgsoError, "profile generation flags"):
            validate_seed_identity(
                dataclasses.replace(self.identity, generation_flags=("--different",))
            )

    def measurement(self, name: str, passed: bool = True) -> dict[str, object]:
        return {
            "schema_version": 1,
            "status": "passed" if passed else "failed",
            "phase": "startup",
            "shard_id": name,
            "identity": dataclasses.asdict(self.identity),
            "artifact_sha256": "e" * 64,
            "measurement": {
                "name": name,
                "argv": ["help"],
                "requested_samples": 1_000,
                "control_samples": [1.0] * 1_000,
                "candidate_samples": [0.9] * 1_000,
                "control_failures": 0,
                "candidate_failures": 0,
                "errors": [],
                "comparison": {
                    "control_samples": [1.0] * 1_000,
                    "candidate_samples": [0.9] * 1_000,
                    "control_p50": 1.0,
                    "control_p95": 1.0,
                    "candidate_p50": 0.9,
                    "candidate_p95": 0.9,
                    "p50_change": -0.1,
                    "p95_change": -0.1,
                    "passed": passed,
                },
                "passed": passed,
            },
        }

    def test_measurement_aggregate_requires_all_passing_gates(self) -> None:
        measurements = aggregate_measurement_shards(
            (self.measurement("startup-help"), self.measurement("startup-doctor")),
            phase="startup",
            expected_names=("startup-help", "startup-doctor"),
            expected_identity=self.identity,
            expected_artifact_sha256="e" * 64,
        )

        self.assertEqual(
            ["startup-help", "startup-doctor"],
            [item["name"] for item in measurements],
        )

    def test_measurement_aggregate_rejects_failed_gate(self) -> None:
        with self.assertRaisesRegex(PgsoError, "startup measurement shard did not pass"):
            aggregate_measurement_shards(
                (self.measurement("startup-help", passed=False),),
                phase="startup",
                expected_names=("startup-help",),
                expected_identity=self.identity,
                expected_artifact_sha256="e" * 64,
            )

    def test_heavy_aggregate_requires_production_profile_linkage(self) -> None:
        document = self.measurement("file-index-100k")
        document["phase"] = "heavy"
        measurement = dict(document["measurement"])
        measurement["requested_samples"] = 50
        measurement["control_samples"] = [1.0] * 50
        measurement["candidate_samples"] = [0.9] * 50
        document["measurement"] = measurement
        linkage = {
            "production_profile_sha256": "p" * 64,
            "benchmark_profile_sha256": "b" * 64,
            "supplement_sha256": "s" * 64,
            "selector": "file_index",
        }
        document["profile_linkage"] = linkage

        result = aggregate_measurement_shards(
            (document,),
            phase="heavy",
            expected_names=("file-index-100k",),
            expected_identity=self.identity,
            expected_artifact_sha256="e" * 64,
            expected_profile_linkage={"file-index-100k": linkage},
        )

        self.assertEqual("file-index-100k", result[0]["name"])

        document["profile_linkage"] = {**linkage, "supplement_sha256": "x" * 64}
        with self.assertRaisesRegex(PgsoError, "profile linkage mismatch"):
            aggregate_measurement_shards(
                (document,),
                phase="heavy",
                expected_names=("file-index-100k",),
                expected_identity=self.identity,
                expected_artifact_sha256="e" * 64,
                expected_profile_linkage={"file-index-100k": linkage},
            )

    def test_measurement_aggregate_rejects_truncated_samples(self) -> None:
        document = self.measurement("startup-help")
        measurement = dict(document["measurement"])
        measurement["candidate_samples"] = [0.9] * 999
        document["measurement"] = measurement

        with self.assertRaisesRegex(PgsoError, "requires exactly 1000 samples"):
            aggregate_measurement_shards(
                (document,),
                phase="startup",
                expected_names=("startup-help",),
                expected_identity=self.identity,
                expected_artifact_sha256="e" * 64,
            )


if __name__ == "__main__":
    unittest.main()
