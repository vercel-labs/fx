"""Exercise the ledger CLI against corrupt state and dependency gates."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "scripts" / "agent_cast_ledger.py"


def sample_ledger():
    task = {
        "id": "AC-1", "milestone": "M0", "title": "Establish contracts",
        "status": "planned", "depends_on": [],
        "owner": {"role": "implementation", "model": "gpt-6.1-sol", "reasoning_effort": "medium"},
        "scope": ["src/contracts.zig"], "acceptance": ["Exact binding is preserved"],
        "evidence": [], "usage": {"input_tokens": None, "output_tokens": None, "source": None},
    }
    dependent = copy.deepcopy(task)
    dependent.update(id="AC-2", title="Implement reader", depends_on=["AC-1"])
    return {
        "schema_version": 1,
        "project": {"name": "agent-cast", "objective": "Preserve logical calls"},
        "milestones": [{"id": "M0", "title": "Foundation", "depends_on": [], "acceptance": ["Contracts verified"]}],
        "tasks": [task, dependent],
    }


class LedgerCliTests(unittest.TestCase):
    def run_cli(self, data, command="validate", expect_ok=True):
        with tempfile.TemporaryDirectory(prefix="agent-cast-ledger-test-") as directory:
            path = Path(directory) / "tasks.json"
            payload = json.dumps(data).encode()
            path.write_bytes(payload)
            result = subprocess.run(
                [sys.executable, str(CLI), command, "--ledger", str(path), "--json"],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            self.assertEqual(path.read_bytes(), payload, "read-only CLI mutated the ledger")
        self.assertEqual(result.returncode, 0 if expect_ok else 1, result.stderr)
        self.assertEqual(result.stderr, "", "JSON mode must return structured failures without a traceback")
        output = json.loads(result.stdout)
        self.assertEqual(output["ok"], expect_ok)
        return output

    def test_canonical_ledger_validates_without_mutation(self):
        path = ROOT / "docs" / "agent-cast" / "tasks.json"
        before = hashlib.sha256(path.read_bytes()).digest()
        self.run_cli(json.loads(path.read_text()))
        self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)

    def test_next_preserves_ownership_and_dependency_gate(self):
        data = sample_ledger()
        output = self.run_cli(data, "next")
        self.assertEqual(output["tasks"], [data["tasks"][0]])
        first = data["tasks"][0]
        first.update(status="verified_local", evidence=["local-test-receipt.json"])
        output = self.run_cli(data, "next")
        self.assertEqual(output["tasks"], [data["tasks"][1]])
        self.assertEqual(output["done_task_ids"], [])
        self.assertIn("not live CI", output["verification_note"])
        first["status"] = "ci_pending"
        output = self.run_cli(data, "next")
        self.assertEqual(output["tasks"], [])
        self.assertEqual(output["ci_pending"], ["AC-1"])

    def test_show_retains_full_task_records(self):
        data = sample_ledger()
        self.assertEqual(self.run_cli(data, "show")["tasks"], data["tasks"])

    def test_corrupt_field_types_return_diagnostics(self):
        cases = [
            ("id", [], "nonempty id"), ("milestone", {}, "unknown milestone"),
            ("status", [], "invalid status"), ("depends_on", [None], "depends_on"),
            ("acceptance", [], "acceptance"), ("scope", "src", "scope"),
            ("owner", None, "owner"), ("evidence", [1], "evidence"),
        ]
        for field, value, diagnostic in cases:
            with self.subTest(field=field):
                data = sample_ledger()
                data["tasks"][0][field] = value
                output = self.run_cli(data, expect_ok=False)
                self.assertTrue(any(diagnostic in item for item in output["errors"]), output)

    def test_bool_is_not_a_schema_version_or_token_count(self):
        data = sample_ledger()
        data["schema_version"] = True
        self.assertIn("schema_version must be 1", self.run_cli(data, expect_ok=False)["errors"])
        data = sample_ledger()
        data["tasks"][0]["usage"]["input_tokens"] = True
        self.assertIn("token counts", " ".join(self.run_cli(data, expect_ok=False)["errors"]))

    def test_cycles_and_missing_dependencies_are_rejected(self):
        data = sample_ledger()
        data["tasks"][0]["depends_on"] = ["AC-2"]
        self.assertIn("dependency cycle", " ".join(self.run_cli(data, expect_ok=False)["errors"]))
        data["tasks"][0]["depends_on"] = ["AC-missing"]
        self.assertIn("unknown dependency", " ".join(self.run_cli(data, expect_ok=False)["errors"]))
        data = sample_ledger()
        data["milestones"][0]["depends_on"] = ["M0"]
        self.assertIn("milestone dependency cycle", " ".join(self.run_cli(data, expect_ok=False)["errors"]))

    def test_duplicate_ids_are_rejected(self):
        data = sample_ledger()
        data["tasks"][1]["id"] = "AC-1"
        self.assertIn("tasks IDs must be unique", self.run_cli(data, expect_ok=False)["errors"])

    def test_verified_status_requires_evidence_and_done_dependencies(self):
        data = sample_ledger()
        data["tasks"][0]["status"] = "verified_local"
        self.assertIn("requires evidence", " ".join(self.run_cli(data, expect_ok=False)["errors"]))
        data["tasks"][0]["evidence"] = ["proof.json"]
        data["tasks"][1].update(status="done", evidence=["ci.json"])
        self.assertIn("requires dependency", " ".join(self.run_cli(data, expect_ok=False)["errors"]))
        data["tasks"][0]["status"] = "done"
        self.assertEqual(self.run_cli(data)["done_task_ids"], ["AC-1", "AC-2"])

    def test_usage_requires_a_receipt_reference(self):
        data = sample_ledger()
        data["tasks"][0]["usage"]["input_tokens"] = 100
        self.assertIn("source must be nonempty", " ".join(self.run_cli(data, expect_ok=False)["errors"]))
        data["tasks"][0]["usage"]["source"] = "provider-receipt.json"
        self.run_cli(data)

    def test_invalid_json_returns_structured_failure(self):
        with tempfile.TemporaryDirectory(prefix="agent-cast-ledger-test-") as directory:
            path = Path(directory) / "tasks.json"
            path.write_text("{")
            result = subprocess.run(
                [sys.executable, str(CLI), "--ledger", str(path), "--json"],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")
        self.assertFalse(json.loads(result.stdout)["ok"])


if __name__ == "__main__":
    unittest.main()
