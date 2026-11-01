import json
import pathlib
import struct
import tempfile
import unittest
from unittest import mock

from scripts.compare_signed_macos import compare_payloads, main, measurement_record, signature_layout
from scripts.pgso.qualify import MeasurementResult, compare_samples


def fixture(signature_size: int) -> bytes:
    payload = b"the same payload"
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2, 88, 0, 0)
    segment = struct.pack(
        "<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0, 4096,
        120, len(payload) + signature_size, 1, 1, 0, 0,
    )
    signature = struct.pack("<4I", 0x1D, 16, 120 + len(payload), signature_size)
    return header + segment + signature + payload + bytes(signature_size)


class SignedMacosComparisonTests(unittest.TestCase):
    def test_status_calibration_compares_identical_control_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            control, candidate, output = root / "control", root / "candidate", root / "output"
            control.write_bytes(fixture(32))
            candidate.write_bytes(fixture(16))
            details = "Identifier=com.vercel.fx TeamIdentifier=JW6Y669B67 flags=0x10000(runtime) Timestamp=fixture Page size=4096 Page size=16384"
            with mock.patch("sys.argv", ["compare_signed_macos", "--control", str(control), "--candidate", str(candidate), "--output", str(output), "--source-sha", "0" * 40]), \
                 mock.patch("scripts.compare_signed_macos.subprocess.run", return_value=mock.Mock(stderr=details)), \
                 mock.patch("scripts.compare_signed_macos.subprocess.check_output", return_value="fixture\n"), \
                 mock.patch("scripts.compare_signed_macos.platform.platform", return_value="fixture"), \
                 mock.patch("scripts.compare_signed_macos.measure_startup", return_value=()) as measure:
                main()
            self.assertEqual(3, measure.call_count)
            for index, call in enumerate(measure.call_args_list):
                args = call.kwargs
                self.assertEqual(5000, args["samples"])
                self.assertIs(False, args["retry_speed_failures"])
                self.assertEqual(("status",) if index == 2 else None, args["command_names"])
                self.assertEqual(control.read_bytes(), args["control_binary"].read_bytes())
                expected = control if index == 2 else candidate
                self.assertEqual(expected.read_bytes(), args["candidate_binary"].read_bytes())
                self.assertEqual(len(str(args["control_binary"])), len(str(args["candidate_binary"])))
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(2, manifest["calibration"]["cohort"])
            self.assertFalse((output / "control").exists())
            self.assertFalse((output / "candidate").exists())

    def test_measurement_does_not_inherit_pgso_regression_allowance(self):
        control = (1.0,) * 100
        candidate = (1.07,) * 100
        comparison = compare_samples(control, candidate, minimum_samples=100)
        self.assertTrue(comparison.passed)
        result = MeasurementResult(
            name="startup-help", argv=("help",), requested_samples=100,
            control_samples=control, candidate_samples=candidate,
            control_failures=0, candidate_failures=0, errors=(),
            comparison=comparison, passed=True,
        )
        record = measurement_record(result)
        self.assertNotIn("passed", record)
        self.assertNotIn("passed", record["comparison"])
        self.assertEqual(control, record["control_samples"])
        self.assertEqual(candidate, record["candidate_samples"])
        self.assertAlmostEqual(0.07, record["comparison"]["p95_change"])

    def test_accepts_signature_only_size_changes(self):
        result = compare_payloads(fixture(32), fixture(16))
        self.assertEqual(16, result["saving_bytes"])
        self.assertEqual([120, 136], result["payload_range"])

    def test_rejects_changed_application_payload(self):
        changed = bytearray(fixture(16))
        changed[120] ^= 1
        with self.assertRaisesRegex(ValueError, "payload changed"):
            compare_payloads(fixture(32), changed)

    def test_rejects_changed_non_signing_header(self):
        changed = bytearray(fixture(16))
        changed[24] ^= 1
        with self.assertRaisesRegex(ValueError, "header or payload changed"):
            compare_payloads(fixture(32), changed)

    def test_rejects_truncated_header_commands_and_signature(self):
        valid = fixture(32)
        for length in (0, 31, 40, 119, len(valid) - 1):
            with self.subTest(length=length):
                with self.assertRaises(ValueError):
                    signature_layout(valid[:length])

    def test_rejects_other_architectures(self):
        changed = bytearray(fixture(16))
        struct.pack_into("<I", changed, 4, 0x01000007)
        with self.assertRaisesRegex(ValueError, "thin arm64"):
            signature_layout(changed)

    def test_rejects_added_trailing_content(self):
        with self.assertRaisesRegex(ValueError, "trailing data"):
            compare_payloads(fixture(32), fixture(16) + b"extra")


if __name__ == "__main__":
    unittest.main()
