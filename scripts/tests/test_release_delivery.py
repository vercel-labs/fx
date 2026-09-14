from __future__ import annotations

import pathlib
import io
import json
import os
import tempfile
import unittest
import urllib.error
from unittest import mock

from scripts.release_delivery import BlobConflictError, BlobStore, PUBLIC_BLOB, TransientDeliveryError, put_immutable, release_branch, website_checks_pass, linked_website, require_website_protection, WEB_PROJECT


class Store:
    def __init__(self, value=None, corrupt=False):
        self.value = value
        self.corrupt = corrupt
        self.writes = []

    def read(self, path):
        return self.value

    def write(self, path, data):
        self.writes.append((path, data))
        self.value = b"corrupted" if self.corrupt else data


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(os.environ, {"FX_RELEASE_VERCEL_TEAM_ID": "team_000000000000000000000000"})
        environment.start()
        self.addCleanup(environment.stop)

    def test_staged_urls_require_protection_without_locking_public_domains(self):
        require_website_protection({"ssoProtection": {"deploymentType": "prod_deployment_urls_and_all_previews"}})
        for policy in (None, {}, {"deploymentType": "all"}, {"deploymentType": "preview"}):
            with self.subTest(policy=policy), self.assertRaisesRegex(ValueError, "Vercel protection"):
                require_website_protection({"ssoProtection": policy})

    def test_website_link_is_scoped_and_cleaned_without_editing_gitignore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / ".gitignore").write_text("existing rules\n")
            with self.assertRaisesRegex(RuntimeError, "staging failure"):
                with linked_website(root):
                    self.assertEqual({"orgId": "team_000000000000000000000000", "projectId": WEB_PROJECT}, json.loads((root / ".vercel/project.json").read_text()))
                    (root / ".vercel/.env.production.local").write_text("test-value")
                    raise RuntimeError("staging failure")
            self.assertFalse((root / ".vercel").exists())
            self.assertEqual("existing rules\n", (root / ".gitignore").read_text())

    def test_existing_website_link_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / ".vercel").mkdir()
            (root / ".vercel/project.json").write_text("user project")
            with self.assertRaisesRegex(ValueError, "existing Vercel link"):
                with linked_website(root):
                    self.fail("existing link accepted")
            self.assertEqual("user project", (root / ".vercel/project.json").read_text())

    def test_website_required_checks_must_succeed_and_review_must_remain_eligible(self):
        snapshot = {"headRefOid": "a" * 40, "state": "OPEN", "isDraft": False, "reviewDecision": "",
                    "statusCheckRollup": [{"name": name, "status": "COMPLETED", "conclusion": "SUCCESS"}
                                          for name in ("Marketing build", "Installer", "CDN build")]}
        self.assertTrue(website_checks_pass(snapshot, "a" * 40))
        for index in range(3):
            for conclusion in ("SKIPPED", "NEUTRAL", ""):
                changed = {**snapshot, "statusCheckRollup": [dict(row) for row in snapshot["statusCheckRollup"]]}
                changed["statusCheckRollup"][index]["conclusion"] = conclusion
                self.assertFalse(website_checks_pass(changed, "a" * 40))
        self.assertTrue(website_checks_pass({**snapshot, "statusCheckRollup": snapshot["statusCheckRollup"] + [
            {"name": "Optional lane", "conclusion": "SKIPPED"}]}, "a" * 40))
        for changed in ({"state": "CLOSED"}, {"isDraft": True}, {"reviewDecision": "CHANGES_REQUESTED"},
                        {"reviewDecision": "REVIEW_REQUIRED"}, {"headRefOid": "b" * 40}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                website_checks_pass({**snapshot, **changed}, "a" * 40)

    def test_first_upload_is_verified_and_retry_reuses_it(self):
        store = Store()
        put_immutable(store, "sdk/archive", b"approved")
        put_immutable(store, "sdk/archive", b"approved")
        self.assertEqual(b"approved", store.value)
        self.assertEqual([("sdk/archive", b"approved")], store.writes)

    def test_existing_different_bytes_are_not_overwritten(self):
        store = Store(b"another release")
        with self.assertRaisesRegex(ValueError, "existing release artifact differs"):
            put_immutable(store, "sdk/archive", b"approved")
        self.assertEqual(b"another release", store.value)
        self.assertEqual([], store.writes)

    def test_failed_verification_stops_preparation(self):
        store = Store(corrupt=True)
        with self.assertRaisesRegex(ValueError, "uploaded release artifact differs"):
            put_immutable(store, "sdk/archive", b"approved")

    def test_uncertain_upload_is_reconciled_before_retrying_write(self):
        class UncertainStore(Store):
            def write(self, path, data):
                super().write(path, data)
                raise TransientDeliveryError("connection closed after storage accepted the file")
        store = UncertainStore()
        with mock.patch("scripts.release_delivery.time.sleep"):
            put_immutable(store, "sdk/archive", b"approved")
        self.assertEqual([("sdk/archive", b"approved")], store.writes)

    def test_retries_share_branch_but_changed_candidate_gets_new_branch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "candidate.json"
            path.write_text("first candidate")
            first = release_branch(path, {"version": "0.0.10"})
            self.assertEqual(first, release_branch(path, {"version": "0.0.10"}))
            path.write_text("changed SDK")
            self.assertNotEqual(first, release_branch(path, {"version": "0.0.10"}))
            self.assertNotEqual(release_branch(path, {"version": "0.0.10"}, "a" * 40), release_branch(path, {"version": "0.0.10"}, "b" * 40))


class BlobChannelTransportTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(mock.patch.dict("os.environ", {"BLOB_READ_WRITE_TOKEN": "vercel_blob_rw_UgiweFobUo4tac0m_test-scoped-credential"}))
        self.metadata = {"pathname": "cli/latest.txt", "url": PUBLIC_BLOB + "cli/latest.txt", "etag": '"version-2"'}
        self.request = self.enterContext(mock.patch("scripts.release_delivery.urllib.request.urlopen",
                                                    side_effect=lambda *args, **kwargs: io.BytesIO(json.dumps(self.metadata).encode())))
        self.store = BlobStore()

    def test_origin_metadata_and_conditional_write_use_the_documented_api(self):
        self.assertEqual('"version-2"', self.store.origin_etag())
        read_request = self.request.call_args.args[0]
        self.assertEqual("GET", read_request.method)
        self.assertIn("?url=https%3A%2F%2F", read_request.full_url)
        self.assertEqual('"version-2"', self.store.write("cli/latest.txt", b"v0.0.10", mutable=True, if_match='"version-1"'))
        request = self.request.call_args.args[0]
        headers = {key.lower(): value for key, value in request.header_items()}
        self.assertEqual("https://blob.vercel-storage.com/?pathname=cli%2Flatest.txt", request.full_url)
        self.assertEqual("PUT", request.method)
        self.assertEqual(b"v0.0.10", request.data)
        self.assertEqual("12", headers["x-api-version"])
        self.assertEqual("UgiweFobUo4tac0m", headers["x-vercel-blob-store-id"])
        self.assertEqual('"version-1"', headers["x-if-match"])
        self.assertEqual("1", headers["x-allow-overwrite"])
        self.assertEqual("public", headers["x-vercel-blob-access"])

    def test_channel_writes_cannot_omit_the_precondition_or_target_another_path(self):
        for kwargs in ({}, {"mutable": True}, {"mutable": True, "if_match": "*"}):
            with self.assertRaises(ValueError):
                self.store.write("cli/latest.txt", b"v0.0.10", **kwargs)
        with self.assertRaises(ValueError):
            self.store.write("cli/v0.0.10/fx-linux-x86_64.tar.gz", b"content", mutable=True, if_match='"version-1"')
        self.request.assert_not_called()

    def test_other_store_credentials_are_rejected_before_request(self):
        with mock.patch.dict("os.environ", {"BLOB_READ_WRITE_TOKEN": "vercel_blob_rw_AnotherStore_secret"}):
            with self.assertRaisesRegex(ValueError, "configured Blob store"):
                self.store.origin_etag()
        self.request.assert_not_called()

    def test_conflict_is_not_retried_as_an_unconditional_write(self):
        self.request.side_effect = urllib.error.HTTPError("https://blob.vercel-storage.com/", 412,
                                                        "test-scoped-credential", {}, None)
        with self.assertRaisesRegex(BlobConflictError, "conditional write") as caught:
            self.store.write("cli/latest.txt", b"v0.0.10", mutable=True, if_match='"version-1"')
        self.assertNotIn("test-scoped-credential", str(caught.exception))
        self.request.assert_called_once()

    def test_missing_write_acknowledgment_is_uncertain_not_successful(self):
        self.metadata.pop("etag")
        with self.assertRaisesRegex(TransientDeliveryError, "acknowledgment is invalid"):
            self.store.write("cli/latest.txt", b"v0.0.10", mutable=True, if_match='"version-1"')


if __name__ == "__main__":
    unittest.main()
