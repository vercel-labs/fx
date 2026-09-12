from __future__ import annotations

import base64
import hashlib
import io
import json
import pathlib
import tarfile
import tempfile
import unittest

from scripts.release_candidate import build_candidate, verify_candidate


SOURCE = "a" * 40
VERSION = "0.0.10"
NOTES = "**A release summary.**\n\n### Improvements\n\n- Keep running tasks visible.\n"
PREPARED_AT = "2026-09-12T15:00:00Z"


def archive(path: pathlib.Path, members: dict[str, bytes]) -> None:
    with tarfile.open(path, "w:gz") as output:
        for name, body in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(body)
            info.mode = 0o755 if name == "fx" else 0o644
            output.addfile(info, io.BytesIO(body))


class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.notes = self.root / "CHANGELOG.md"
        self.notes.write_text(
            f"# fx\n\n## {VERSION}\n\n<!-- release:start -->\n{NOTES}<!-- release:end -->\n"
        )
        self.platforms = ("linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64")
        for index, platform in enumerate(self.platforms):
            name = f"fx-{platform}.tar.gz"
            archive(self.root / name, {"fx": bytes(index + 100), "LICENSE": b"license"})
            self.checksum(name)
        self.package = self.root / "libfx-package.tgz"
        self.make_sdk(VERSION)

    def checksum(self, name: str) -> None:
        digest = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
        (self.root / (name + ".sha256")).write_text(f"{digest}  {name}\n")

    def make_sdk(self, version: str) -> None:
        archive(self.package, {
            "package/package.json": json.dumps({"name": "libfx", "version": version, "type": "module"}).encode(),
            "package/fx-term.wasm": b"\0asm" + b"fx/" + version.encode() + b"\0",
            "package/fx-core.wasm": b"\0asm" + b"fx/" + version.encode() + b"\0",
        })
        self.checksum(self.package.name)

    def create(self) -> dict:
        return build_candidate(self.root, self.notes, VERSION, SOURCE, 1234, PREPARED_AT)

    def test_candidate_measures_executable_not_compressed_archive(self) -> None:
        result = self.create()
        self.assertEqual(1, result["schema_version"])
        self.assertEqual(VERSION, result["version"])
        self.assertEqual(SOURCE, result["source_sha"])
        self.assertEqual(1234, result["prepared_run_id"])
        self.assertEqual(NOTES, result["changelog"])
        self.assertEqual(102, result["binaries"]["macos-aarch64"]["size_bytes"])
        self.assertNotEqual(result["binaries"]["macos-aarch64"]["archive_bytes"], 102)

    def test_sdk_record_binds_the_exact_stable_archive(self) -> None:
        result = self.create()
        data = self.package.read_bytes()
        self.assertEqual(VERSION, result["sdk"]["version"])
        self.assertEqual(hashlib.sha256(data).hexdigest(), result["sdk"]["sha256"])
        self.assertEqual("sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode(), result["sdk"]["integrity"])
        self.assertTrue(result["sdk"]["tarball_url"].endswith(f"/{result['sdk']['sha256']}/libfx-{VERSION}.tgz"))
        verify_candidate(result, self.root, SOURCE)

    def test_rejects_dev_sdk_and_version_mismatch(self) -> None:
        for version in ("0.0.10-dev.1", "0.0.9"):
            with self.subTest(version=version):
                self.make_sdk(version)
                with self.assertRaisesRegex(ValueError, "SDK version"):
                    self.create()

    def test_rejects_replaced_artifact_even_with_new_checksum(self) -> None:
        result = self.create()
        archive(self.root / "fx-linux-x86_64.tar.gz", {"fx": b"replacement"})
        self.checksum("fx-linux-x86_64.tar.gz")
        with self.assertRaisesRegex(ValueError, "artifact identity"):
            verify_candidate(result, self.root, SOURCE)

    def test_rejects_stale_source_and_modified_notes(self) -> None:
        result = self.create()
        with self.assertRaisesRegex(ValueError, "source"):
            verify_candidate(result, self.root, "b" * 40)
        result["changelog"] += "- Not approved.\n"
        with self.assertRaisesRegex(ValueError, "changelog"):
            verify_candidate(result, self.root, SOURCE)

    def test_rejects_missing_platform_and_bad_checksum(self) -> None:
        name = "fx-linux-x86_64.tar.gz"
        (self.root / (name + ".sha256")).write_text("0" * 64 + "  " + name + "\n")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.create()
        self.checksum(name)
        (self.root / name).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.create()

    def test_rejects_duplicate_or_wrong_release_markers(self) -> None:
        original = self.notes.read_text()
        for text in (original.replace(f"## {VERSION}", "## 0.0.9"), original + "<!-- release:start -->\n"):
            self.notes.write_text(text)
            with self.assertRaisesRegex(ValueError, "release notes"):
                self.create()

    def test_rejects_links_in_native_archives(self) -> None:
        path = self.root / "fx-macos-aarch64.tar.gz"
        with tarfile.open(path, "w:gz") as output:
            link = tarfile.TarInfo("fx")
            link.type = tarfile.SYMTYPE
            link.linkname = "/etc/passwd"
            output.addfile(link)
        self.checksum(path.name)
        with self.assertRaisesRegex(ValueError, "regular"):
            self.create()

    def test_rejects_wasm_that_disagrees_with_package_version(self) -> None:
        archive(self.package, {
            "package/package.json": json.dumps({"name": "libfx", "version": VERSION}).encode(),
            "package/fx-term.wasm": b"\0asmfx/0.0.9\0",
            "package/fx-core.wasm": b"\0asmfx/0.0.9\0",
        })
        self.checksum(self.package.name)
        with self.assertRaisesRegex(ValueError, "WebAssembly"):
            self.create()

    def test_rejects_unsafe_version_and_source_inputs(self) -> None:
        for version, source in (("../escape", SOURCE), ("0.0.10-dev", SOURCE), (VERSION, "main")):
            with self.subTest(version=version, source=source):
                with self.assertRaises(ValueError):
                    build_candidate(self.root, self.notes, version, source, 1234, PREPARED_AT)

    def test_preparation_date_is_fixed_and_validated(self) -> None:
        self.assertEqual(PREPARED_AT, self.create()["prepared_at"])
        self.assertEqual(self.create(), self.create())
        with self.assertRaisesRegex(ValueError, "preparation time"):
            build_candidate(self.root, self.notes, VERSION, SOURCE, 1234, "2026-02-30T15:00:00Z")


if __name__ == "__main__":
    unittest.main()
