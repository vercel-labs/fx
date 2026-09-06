#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "linux_abi", Path(__file__).resolve().parents[1] / "scripts/check-linux-abi.py"
)
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)


class LinuxAbiTest(unittest.TestCase):
    def test_baseline_and_older_symbols(self):
        self.assertEqual(abi.check_versions("GLIBC_2.2.5 GLIBC_2.9 GLIBC_2.34"), "2.34")
        self.assertEqual(abi.check_versions("GLIBC_2.34.0"), "2.34.0")

    def test_newer_symbols_are_rejected(self):
        for version in ["2.35", "2.36", "2.40", "3.0"]:
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "maximum supported"):
                abi.check_versions(f"GLIBC_2.34 GLIBC_{version}")

    def test_missing_or_private_requirements_are_rejected(self):
        for report in ["", "GLIBCXX_3.4", "GLIBC_2.34 GLIBC_PRIVATE"]:
            with self.subTest(report=report), self.assertRaises(ValueError):
                abi.check_versions(report)


if __name__ == "__main__":
    unittest.main()
