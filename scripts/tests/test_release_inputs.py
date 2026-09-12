import copy
import pathlib
import unittest
from unittest import mock

from scripts.release_inputs import select_preparation, require_current_preparation
from scripts.publish_prepared_sdk import check_registry_identity, check_channel_advance


class PreparationInputTests(unittest.TestCase):
    def test_prepare_release_is_the_single_stable_entrypoint(self):
        workflows = pathlib.Path(__file__).resolve().parents[2] / ".github/workflows"
        release = (workflows / "release.yml").read_text()
        triggers = release.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("  workflow_dispatch:", triggers)
        self.assertNotIn("  push:", triggers)
        self.assertIn("gh workflow run release.yml --ref main", (workflows / "prepare-release.yml").read_text())

    def test_newer_ready_candidate_invalidates_an_old_approval(self):
        responses = [{"workflow_runs": [{"id": 124, "display_title": "Prepare release new"}]},
                     {"total_count": 1, "artifacts": [{"name": "fx-release-ready", "expired": False}]}]
        with mock.patch("scripts.release_inputs.github", side_effect=responses), self.assertRaisesRegex(ValueError, "superseded by preparation run 124"):
            require_current_preparation(123)

    def test_rehearsals_and_noop_pushes_do_not_invalidate_an_approval(self):
        responses = [{"workflow_runs": [{"id": 126, "display_title": "Prepare rehearsal old"},
                                        {"id": 125, "display_title": "Prepare release new"}, {"id": 123}]},
                     {"total_count": 0, "artifacts": []}]
        with mock.patch("scripts.release_inputs.github", side_effect=responses) as api:
            require_current_preparation(123)
        self.assertEqual(2, api.call_count)

    def test_expired_newer_candidate_still_invalidates_old_approval(self):
        responses = [{"workflow_runs": [{"id": 124}]},
                     {"total_count": 1, "artifacts": [{"name": "fx-release-ready", "expired": True}]}]
        with mock.patch("scripts.release_inputs.github", side_effect=responses), self.assertRaisesRegex(ValueError, "superseded"):
            require_current_preparation(123)

    def test_incomplete_freshness_evidence_fails_closed(self):
        responses = [{"workflow_runs": [{"id": 124}]}, {"total_count": 101, "artifacts": []}]
        with mock.patch("scripts.release_inputs.github", side_effect=responses), self.assertRaisesRegex(ValueError, "incomplete"):
            require_current_preparation(123)

    def setUp(self):
        self.run = {"id": 123, "path": ".github/workflows/release.yml", "head_repository": {"full_name": "vercel-labs/fx"}, "head_branch": "main", "head_sha": "a" * 40, "event": "push", "status": "completed", "conclusion": "success"}
        self.artifact = {"id": 456, "name": "fx-release-ready", "expired": False}

    def test_resolves_one_exact_artifact_id_not_a_mutable_name(self):
        self.assertEqual({"artifact_id": 456, "run_id": 123, "workflow_sha": "a" * 40}, select_preparation(self.run, [self.artifact], 123))
        self.assertIsNone(select_preparation(self.run, [], 123))

    def test_wrong_workflow_fork_and_failed_run_are_rejected(self):
        for changes in ({"path": ".github/workflows/ci.yml"}, {"head_repository": {"full_name": "other/fx"}}, {"head_branch": "feature"}, {"event": "pull_request"}, {"conclusion": "failure"}, {"status": "in_progress"}):
            with self.assertRaises(ValueError):
                select_preparation({**self.run, **changes}, [self.artifact], 123)

    def test_expired_or_duplicate_artifacts_fail_closed(self):
        for artifacts in ([{**self.artifact, "expired": True}], [self.artifact, self.artifact]):
            with self.assertRaises(ValueError):
                select_preparation(self.run, artifacts, 123)

    def test_registry_retry_requires_identical_bytes(self):
        metadata = {"name": "libfx", "version": "0.0.10", "dist": {"integrity": "sha512-expected"}}
        check_registry_identity(metadata, "0.0.10", "sha512-expected")
        with self.assertRaises(ValueError):
            check_registry_identity(metadata, "0.0.10", "sha512-other")

    def test_channels_cannot_move_backwards_before_publication(self):
        check_channel_advance("0.0.9", "0.0.10")
        check_channel_advance("0.0.10", "0.0.10")
        with self.assertRaises(ValueError):
            check_channel_advance("0.0.11", "0.0.10")
        with self.assertRaises(ValueError):
            check_channel_advance("0.0.10-dev.20.gaaaaaaaaaaaa", "0.0.10-dev.19.gaaaaaaaaaaaa")


if __name__ == "__main__":
    unittest.main()
