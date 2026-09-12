import unittest

from scripts.release_preparation import REQUIRED_CHECKS, checks_pass, verify_version_only_change


class PreparationTests(unittest.TestCase):
    def test_only_version_and_notes_may_change_on_preparation_branch(self):
        before = 'pub const version = "0.0.9";\nconst body = 1;\n'
        after = before.replace('"0.0.9"', '"0.0.10"')
        changes = {"src/main.zig", "CHANGELOG.md"}
        verify_version_only_change(before, after, changes, "0.0.10")
        for text, paths, version in (
            (after + 'run_secret_command();\n', changes, "0.0.10"),
            (after, changes | {".github/workflows/release.yml"}, "0.0.10"),
            (before, changes, "0.0.9"),
        ):
            with self.assertRaises(ValueError):
                verify_version_only_change(before, text, paths, version)

    def test_all_native_lanes_and_benchmark_must_pass(self):
        checks = [{"name": name, "id": i, "status": "completed", "conclusion": "success"} for i, name in enumerate(REQUIRED_CHECKS)]
        self.assertTrue(checks_pass(checks))
        self.assertFalse(checks_pass(checks[:-1]))
        self.assertFalse(checks_pass(checks + [{"name": "new required test", "id": 99, "status": "in_progress", "conclusion": None}]))
        with self.assertRaises(ValueError):
            checks_pass(checks + [{"name": "security", "id": 100, "status": "completed", "conclusion": "failure"}])

    def test_required_checks_cannot_be_skipped_or_neutral(self):
        checks = [{"name": name, "status": "completed", "conclusion": "success"} for name in REQUIRED_CHECKS]
        for index, check in enumerate(checks):
            for conclusion in ("skipped", "neutral"):
                with self.subTest(name=check["name"], conclusion=conclusion):
                    changed = [dict(row) for row in checks]
                    changed[index]["conclusion"] = conclusion
                    self.assertFalse(checks_pass(changed))
        self.assertTrue(checks_pass(checks + [{"name": "Optional lane", "status": "completed", "conclusion": "skipped"}]))


if __name__ == "__main__":
    unittest.main()
