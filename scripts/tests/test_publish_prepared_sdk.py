from __future__ import annotations

import io
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.publish_prepared_sdk import PUBLICATION_POLLS, archive_integrity, publish
from scripts.release_delivery import TransientDeliveryError


class PreparedSdkPublicationTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.archive = pathlib.Path(directory) / "libfx-package.tgz"
        self.archive.write_bytes(b"the exact prepared SDK archive")
        self.version = "0.0.10"
        self.metadata = {"name": "libfx", "version": self.version, "dist": {
            "integrity": archive_integrity(self.archive),
            "tarball": "https://registry.npmjs.org/libfx/-/libfx-0.0.10.tgz"}}
        self.versions = [self.metadata]
        self.tags = [{"latest": self.version}]
        self.registry = self.enterContext(mock.patch("scripts.publish_prepared_sdk.registry_json", side_effect=self.registry_response))
        self.command = self.enterContext(mock.patch("scripts.publish_prepared_sdk.command"))
        self.sleep = self.enterContext(mock.patch("scripts.publish_prepared_sdk.time.sleep"))
        self.download = self.enterContext(mock.patch("scripts.publish_prepared_sdk.urllib.request.urlopen",
                                                     side_effect=lambda *args, **kwargs: io.BytesIO(self.archive.read_bytes())))

    def registry_response(self, path, **kwargs):
        values = self.tags if path.endswith("dist-tags") else self.versions
        return values.pop(0) if len(values) > 1 else values[0]

    def test_existing_matching_archive_and_tag_do_not_publish_again(self):
        publish(self.archive, self.version, "latest")
        self.command.assert_not_called()
        self.sleep.assert_not_called()
        self.download.assert_called_once()

    def test_uncertain_publish_waits_for_both_metadata_and_tag_without_republishing(self):
        self.versions = [None, None, self.metadata]
        self.tags = [{"latest": "0.0.9"}] * 3 + [{"latest": self.version}]
        self.command.side_effect = TransientDeliveryError("response lost after acceptance")
        publish(self.archive, self.version, "latest")
        self.command.assert_called_once()
        self.assertEqual(["npm", "publish"], self.command.call_args.args[0][:2])
        self.assertEqual(2, self.sleep.call_count)

    def test_existing_version_with_persistent_old_tag_stops_without_tag_mutation(self):
        self.tags = [{"latest": "0.0.9"}]
        with self.assertRaisesRegex(ValueError, "trusted publishing cannot repair distribution tags"):
            publish(self.archive, self.version, "latest")
        self.command.assert_not_called()
        self.download.assert_not_called()
        self.assertEqual(PUBLICATION_POLLS - 1, self.sleep.call_count)

    def test_uncertain_publish_that_never_appears_stops_without_a_second_write(self):
        self.versions = [None]
        self.tags = [{"latest": "0.0.9"}]
        self.command.side_effect = TransientDeliveryError("request outcome unknown")
        with self.assertRaisesRegex(ValueError, "preserve this archive"):
            publish(self.archive, self.version, "latest")
        self.command.assert_called_once()
        self.download.assert_not_called()

    def test_newer_tag_or_different_package_bytes_stop_immediately(self):
        self.tags = [{"latest": "0.0.11"}]
        with self.assertRaisesRegex(ValueError, "backwards"):
            publish(self.archive, self.version, "latest")
        self.tags = [{"latest": self.version}]
        self.metadata["dist"]["integrity"] = "sha512-another-package"
        with self.assertRaisesRegex(ValueError, "different package bytes"):
            publish(self.archive, self.version, "latest")
        self.command.assert_not_called()
        self.sleep.assert_not_called()

    def test_registry_download_must_equal_the_prepared_archive(self):
        self.download.side_effect = lambda *args, **kwargs: io.BytesIO(b"different bytes")
        with self.assertRaisesRegex(ValueError, "differs from the prepared archive"):
            publish(self.archive, self.version, "latest")


if __name__ == "__main__":
    unittest.main()
