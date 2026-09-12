from __future__ import annotations

import copy
import pathlib
import unittest
from unittest import mock

from scripts.release_publication import PublicationTargets, verify_ready, publish_release
from scripts.release_examples import PROJECTS
from scripts.release_delivery import BlobConflictError, TransientDeliveryError


class PublicationContractTests(unittest.TestCase):
    def setUp(self):
        self.candidate = {"source_sha": "a" * 40, "version": "0.0.10"}
        self.digest = "b" * 64
        self.ready = {
            "schema_version": 1,
            "candidate_sha256": self.digest,
            "publication_allowed": True,
            "previous_version": "v0.0.9",
            "examples": [{"id": name, "project_id": project, "source_sha": "a" * 40, "sdk_version": "0.0.8", "validation": "passed", "affected": False, "deployment_id": None, "url": None, "previous_deployment_id": None} for name, project in PROJECTS.items()],
            "website": {
                "base_sha": "c" * 40,
                "source_sha": "d" * 40,
                "pr": 123,
                "deployment_id": "dpl_PreparedWebsite",
                "url": "https://fx-marketing-prepared.labs.vercel.dev",
                "previous_deployment_id": "dpl_PreviousWebsite",
            },
        }
        self.report = {
            "schema_version": 1, "passed": True, "errors": [],
            "candidate_sha256": self.digest,
            "source_sha": self.candidate["source_sha"],
            "version": "0.0.10", "target_origin": self.ready["website"]["url"],
            "checks": [{"route": path, "width": width, "horizontal_overflow": False,
                        **({"synthetic_gateway": True} if path == "/try" and width == 1440 else {}),
                        **({"terminal_version": "v0.0.10", "help_open_close": True} if path != "/changelog" else {})}
                       for width in (375, 1440) for path in ("/", "/try", "/changelog")],
        }

    def test_ready_candidate_accepts_the_complete_staged_evidence(self):
        verify_ready(self.ready, self.candidate, self.digest, self.report)

    def test_rehearsals_and_modified_candidate_are_not_publishable(self):
        for changed in ({"publication_allowed": False}, {"publication_allowed": "true"}, {"candidate_sha256": "e" * 64}):
            with self.subTest(changed=changed):
                with self.assertRaises(ValueError):
                    verify_ready({**self.ready, **changed}, self.candidate, self.digest, self.report)

    def test_wrong_or_incomplete_browser_evidence_stops_publication(self):
        variants = [
            {"passed": False}, {"errors": ["startup failed"]}, {"version": "0.0.9"},
            {"source_sha": "e" * 40}, {"candidate_sha256": "e" * 64},
            {"target_origin": "https://different.vercel.app"},
            {"checks": self.report["checks"][:-1]},
        ]
        for changed in variants:
            with self.subTest(changed=changed):
                with self.assertRaises(ValueError):
                    verify_ready(self.ready, self.candidate, self.digest, {**self.report, **changed})

    def test_wrong_terminal_or_overflow_stops_publication(self):
        for changes in ({"terminal_version": "v0.0.10-dev.1"}, {"help_open_close": False}, {"horizontal_overflow": True}):
            report = copy.deepcopy(self.report)
            report["checks"][0].update(changes)
            with self.assertRaises(ValueError):
                verify_ready(self.ready, self.candidate, self.digest, report)

    def test_ready_record_cannot_redirect_publication(self):
        for field, value in (("url", "https://attacker.example"), ("source_sha", "main"), ("pr", "1; publish"), ("deployment_id", "--prod")):
            ready = copy.deepcopy(self.ready)
            ready["website"][field] = value
            with self.assertRaises(ValueError):
                verify_ready(ready, self.candidate, self.digest, self.report)

    def test_publication_never_promotes_website_before_downloads_exist(self):
        class Targets:
            def __init__(self):
                self.calls = []

            def preflight(self, *args): self.calls.append("preflight")
            def merge_native(self, *args): self.calls.append("native-merge")
            def native_assets(self, *args): self.calls.append("native-assets")
            def merge_website(self, *args): self.calls.append("website-merge"); return "e" * 40
            def advance_channel(self, *args): self.calls.append("cdn-pointer")
            def promote_examples(self, *args): self.calls.append("example-promotion")
            def promote_website(self, *args): self.calls.append("website-promotion")
            def verify(self, *args): self.calls.append("verification")

        targets = Targets()
        publish_release(self.candidate, self.ready, self.digest, self.report, targets)
        self.assertEqual(["preflight", "native-merge", "native-assets", "website-merge", "cdn-pointer", "example-promotion", "website-promotion", "verification"], targets.calls)
        targets.calls.clear()
        with self.assertRaises(ValueError):
            publish_release(self.candidate, {**self.ready, "publication_allowed": False}, self.digest, self.report, targets)
        self.assertEqual([], targets.calls)


class PublicationEligibilityTests(unittest.TestCase):
    def setUp(self):
        fixture = PublicationContractTests()
        fixture.setUp()
        self.candidate, self.ready = fixture.candidate, fixture.ready
        self.digest, self.report = fixture.digest, fixture.report
        self.targets = PublicationTargets(pathlib.Path("/unused"))
        self.pr = {"head": {"sha": self.ready["website"]["source_sha"]}, "base": {"ref": "main"},
                   "state": "open", "merged": False, "draft": False, "mergeable": True, "mergeable_state": "clean"}
        self.checks = {"headRefOid": self.ready["website"]["source_sha"], "state": "OPEN", "isDraft": False,
                       "reviewDecision": "", "statusCheckRollup": [
                           {"name": name, "conclusion": "SUCCESS"} for name in ("Marketing build", "Installer", "CDN build")]}
        self.tree = "f" * 40
        self.merge_tree = self.tree
        self.merge_sha = "e" * 40
        self.main_sha = self.ready["website"]["base_sha"]
        self.github = self.enterContext(mock.patch("scripts.release_publication.github", side_effect=self.github_response))
        self.enterContext(mock.patch("scripts.release_publication.website_check_snapshot", side_effect=lambda _: self.checks))
        self.enterContext(mock.patch("scripts.release_publication.preflight_examples"))
        self.vercel = self.enterContext(mock.patch("scripts.release_publication.vercel", side_effect=self.vercel_response))
        self.enterContext(mock.patch.object(self.targets.blob, "read", return_value=b"v0.0.9"))

    def github_response(self, path, **kwargs):
        if "/git/ref/tags/" in path:
            return None
        if path == "repos/vercel-labs/fx/commits/main":
            return {"sha": self.candidate["source_sha"]}
        if path == "repos/vercel-labs/fx-web/commits/main":
            return {"sha": self.main_sha}
        if path == f"repos/vercel-labs/fx-web/pulls/{self.ready['website']['pr']}/merge":
            self.main_sha = self.merge_sha
            return {"merged": True, "sha": self.merge_sha}
        if path.startswith("repos/vercel-labs/fx-web/pulls/"):
            return self.pr
        if path == f"repos/vercel-labs/fx-web/git/commits/{self.ready['website']['source_sha']}":
            return {"tree": {"sha": self.tree}}
        if path == f"repos/vercel-labs/fx-web/git/commits/{self.merge_sha}":
            return {"tree": {"sha": self.merge_tree}}
        raise AssertionError(path)

    def vercel_response(self, path):
        if "/deployments/" in path:
            return {"projectId": "prj_rIMZjpSjEoVhPtOV7y2v35UIDWQK", "readyState": "READY",
                    "url": self.ready["website"]["url"].removeprefix("https://")}
        return {"targets": {"production": {"id": self.ready["website"]["previous_deployment_id"]}}}

    def test_closed_draft_or_unmergeable_pr_stops_before_publication(self):
        for changed in ({"state": "closed"}, {"draft": True}, {"mergeable": None}, {"mergeable": False},
                        {"mergeable_state": "blocked"}, {"mergeable_state": "dirty"}, {"mergeable_state": "behind"},
                        {"mergeable_state": "unstable"}, {"mergeable_state": "unknown"}, {"mergeable_state": None}):
            with self.subTest(changed=changed), mock.patch.dict(self.pr, changed):
                with self.assertRaisesRegex(ValueError, "website preparation PR is not eligible"):
                    self.targets.preflight(self.candidate, self.ready)
        self.vercel.assert_not_called()
        self.assertTrue(all(call.kwargs.get("method", "GET") == "GET" for call in self.github.call_args_list))

    def test_new_required_review_or_unfinished_check_stops_final_preflight(self):
        self.targets.preflight(self.candidate, self.ready)
        for decision in ("REVIEW_REQUIRED", "CHANGES_REQUESTED"):
            with mock.patch.dict(self.checks, reviewDecision=decision), self.assertRaises(ValueError):
                self.targets.preflight(self.candidate, self.ready)
        self.checks["statusCheckRollup"][0]["conclusion"] = "SKIPPED"
        with self.assertRaisesRegex(ValueError, "required checks have not passed"):
            self.targets.preflight(self.candidate, self.ready)

    def test_concurrent_base_change_stops_channel_and_promotion_after_merge(self):
        # The API merge guard protects the PR head, so the merge may include a newer base tree.
        self.merge_tree = "1" * 40
        with mock.patch.object(self.targets, "merge_native"), mock.patch.object(self.targets, "native_assets"), \
                mock.patch.object(self.targets, "advance_channel") as advance, \
                mock.patch.object(self.targets, "promote_website") as promote:
            with self.assertRaisesRegex(ValueError, "merged website tree differs"):
                publish_release(self.candidate, self.ready, self.digest, self.report, self.targets)
            advance.assert_not_called()
            promote.assert_not_called()

    def test_retry_checks_the_tree_of_an_already_merged_pr(self):
        self.pr.update(merged=True, state="closed", merge_commit_sha=self.merge_sha)
        self.main_sha = self.merge_sha
        self.targets.preflight(self.candidate, self.ready)
        self.assertEqual(self.merge_sha, self.targets.merge_website(self.ready))
        self.merge_tree = "1" * 40
        with self.assertRaisesRegex(ValueError, "merged website tree differs"):
            self.targets.preflight(self.candidate, self.ready)
        self.assertTrue(all(call.kwargs.get("method", "GET") == "GET" for call in self.github.call_args_list))


class CachedChannelStore:
    def __init__(self):
        self.value = b"v0.0.9"
        self.etag = '"version-1"'
        self.cached = (self.value, self.etag)
        self.cache_reads = 0
        self.lag_after_write = 2
        self.lose_response = False
        self.concurrent_version = None
        self.writes = []

    def snapshot(self, path):
        if self.cache_reads:
            self.cache_reads -= 1
            return self.cached
        return self.value, self.etag

    def origin_etag(self):
        return self.etag

    def change_origin(self, value):
        self.cached = (self.value, self.etag)
        self.value = value
        self.etag = f'"{value.decode()}"'
        self.cache_reads = self.lag_after_write

    def write(self, path, data, *, mutable, if_match):
        if self.concurrent_version is not None:
            self.change_origin(self.concurrent_version)
            self.concurrent_version = None
        if if_match != self.etag:
            raise BlobConflictError("storage ETag changed")
        self.writes.append((path, data, if_match))
        self.change_origin(data)
        if self.lose_response:
            self.lose_response = False
            raise TransientDeliveryError("storage accepted the write but its response was lost")
        return self.etag


class ChannelPublicationTests(unittest.TestCase):
    def setUp(self):
        self.targets = PublicationTargets(pathlib.Path("/unused"))
        self.store = CachedChannelStore()
        self.targets.blob = self.store
        self.candidate = {"version": "0.0.10"}
        self.ready = {"previous_version": "v0.0.9"}
        self.sleep = self.enterContext(mock.patch("scripts.release_publication.time.sleep"))

    def test_success_waits_for_cached_pointer_to_match_origin(self):
        self.targets.advance_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.10", self.store.value)
        self.assertEqual(self.store.etag, self.targets.channel_etag)
        self.assertEqual(2, self.sleep.call_count)
        self.assertEqual(1, len(self.store.writes))

    def test_lost_write_response_reconciles_origin_without_a_second_write(self):
        self.store.lose_response = True
        self.targets.advance_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.10", self.store.value)
        self.assertEqual(1, len(self.store.writes))
        self.assertEqual(self.store.etag, self.targets.channel_etag)

    def test_rollback_uses_write_acknowledgment_even_when_cache_shows_previous_release(self):
        self.targets.advance_channel(self.candidate, self.ready)
        self.store.cached = (b"v0.0.9", '"version-1"')
        self.store.cache_reads = 2
        self.targets.restore_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.9", self.store.value)
        self.assertEqual([b"v0.0.10", b"v0.0.9"], [data for _, data, _ in self.store.writes])
        self.assertIsNone(self.targets.channel_etag)

    def test_rollback_refuses_to_replace_a_newer_pointer(self):
        self.targets.advance_channel(self.candidate, self.ready)
        self.store.change_origin(b"v0.0.11")
        with self.assertRaises(BlobConflictError):
            self.targets.restore_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.11", self.store.value)
        self.assertEqual(1, len(self.store.writes))

    def test_uncertain_rollback_waits_for_storage_and_does_not_repeat_the_write(self):
        self.targets.advance_channel(self.candidate, self.ready)
        self.store.lose_response = True
        self.targets.restore_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.9", self.store.value)
        self.assertEqual(2, len(self.store.writes))

    def test_concurrent_release_wins_against_a_stale_precondition(self):
        self.store.concurrent_version = b"v0.0.11"
        with self.assertRaisesRegex(ValueError, "another release"):
            self.targets.advance_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.11", self.store.value)
        self.assertEqual([], self.store.writes)

    def test_permanent_cache_lag_is_bounded_and_retains_the_acknowledged_write(self):
        self.store.lag_after_write = 1000
        with self.assertRaisesRegex(TransientDeliveryError, "cache did not converge"):
            self.targets.advance_channel(self.candidate, self.ready)
        self.assertEqual(b"v0.0.10", self.store.value)
        self.assertEqual(self.store.etag, self.targets.channel_etag)
        self.assertEqual(1, len(self.store.writes))
        self.assertEqual(15, self.sleep.call_count)


if __name__ == "__main__":
    unittest.main()
