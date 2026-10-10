from __future__ import annotations

import dataclasses
import pathlib
import tempfile
import unittest

from scripts.pgso.model import (
    BuildIdentity,
    PgsoError,
    bytes_to_mib,
    profile_evidence,
    require_empty_stderr,
    sha256_file,
    size_gate,
    verify_identity,
)


class PgsoModelTests(unittest.TestCase):
    def identity(self) -> BuildIdentity:
        return BuildIdentity(
            source_sha="a" * 40,
            target="aarch64-macos",
            host_arch="arm64",
            zig_version="0.17.0",
            llvm_version="22.1.8",
            bitcode_sha256="b" * 64,
            corpus_sha256="c" * 64,
            update_channel="stable",
            generation_flags=("--disable-vp",),
        )

    def test_build_identity_is_immutable_and_equal_by_value(self) -> None:
        expected = self.identity()

        self.assertEqual(expected, dataclasses.replace(expected))
        with self.assertRaises(dataclasses.FrozenInstanceError):
            expected.target = "x86_64-macos"  # type: ignore[misc]

    def test_verify_identity_rejects_every_mismatching_field(self) -> None:
        expected = self.identity()
        changed_values = {
            "source_sha": "d" * 40,
            "target": "x86_64-macos",
            "host_arch": "x86_64",
            "zig_version": "0.17.1",
            "llvm_version": "21.1.9",
            "bitcode_sha256": "e" * 64,
            "corpus_sha256": "f" * 64,
            "update_channel": "dev",
            "generation_flags": ("--different",),
        }

        verify_identity(expected, dataclasses.replace(expected))
        for field, value in changed_values.items():
            with self.subTest(field=field):
                with self.assertRaisesRegex(
                    PgsoError,
                    f"identity mismatch: {field}",
                ):
                    verify_identity(
                        expected,
                        dataclasses.replace(expected, **{field: value}),
                    )

    def test_sha256_file_hashes_the_exact_contents(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-model-") as tmp:
            path = pathlib.Path(tmp) / "artifact"
            path.write_bytes(b"abc")

            self.assertEqual(
                "ba7816bf8f01cfea414140de5dae2223"
                "b00361a396177a9cb410ff61f20015ad",
                sha256_file(path),
            )

    def test_profile_evidence_binds_hash_size_and_merged_count(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fx-pgso-model-") as tmp:
            path = pathlib.Path(tmp) / "profile.profdata"
            path.write_bytes(b"profile")

            evidence = profile_evidence(path, merged_raw_profiles=7)

            self.assertEqual(7, evidence["merged_raw_profiles"])
            self.assertEqual(7, evidence["size_bytes"])
            self.assertEqual(sha256_file(path), evidence["sha256"])

    def test_size_gate_reports_exact_mib_and_preferred_headroom(self) -> None:
        evidence = size_gate(7_837_920)

        self.assertEqual(1.0, bytes_to_mib(1_048_576))
        self.assertEqual(7_837_920, evidence.size_bytes)
        self.assertEqual(7.474822998046875, evidence.size_mib)
        self.assertEqual(7.800, evidence.ceiling_mib)
        self.assertEqual(0.3251770019531248, evidence.headroom_mib)
        self.assertEqual(0.250, evidence.preferred_headroom_mib)
        self.assertTrue(evidence.preferred_headroom_met)

    def test_size_gate_enforces_the_integral_byte_boundary(self) -> None:
        self.assertEqual(8_178_892, size_gate(8_178_892).size_bytes)
        with self.assertRaisesRegex(PgsoError, "exceeds 7.800 MiB"):
            size_gate(8_178_893)

    def test_size_gate_records_insufficient_preferred_headroom(self) -> None:
        evidence = size_gate(8_000_000)

        self.assertFalse(evidence.preferred_headroom_met)
        self.assertGreater(evidence.headroom_mib, 0)

    def test_size_gate_rejects_empty_or_negative_artifacts(self) -> None:
        for byte_count in (0, -1):
            with self.subTest(byte_count=byte_count):
                with self.assertRaisesRegex(PgsoError, "artifact is empty"):
                    size_gate(byte_count)

    def test_require_empty_stderr_rejects_unexpected_output(self) -> None:
        require_empty_stderr("profile use", "")

        with self.assertRaisesRegex(
            PgsoError,
            "profile use wrote unexpected stderr: optimizer warning",
        ):
            require_empty_stderr("profile use", "optimizer warning")

if __name__ == "__main__":
    unittest.main()
