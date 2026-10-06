"""Negative controls for the agent-cast receipt oracles."""

import copy
import hashlib
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "docs" / "agent-cast" / "evidence" / "m2-2026-10-06"
SPEC = importlib.util.spec_from_file_location("qualify_agent_cast", ROOT / "scripts" / "qualify_agent_cast.py")
QUALIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QUALIFIER)


def read_report(name):
    return json.loads((EVIDENCE / name).read_text(encoding="utf-8"))


def receipt_hash(content):
    return hashlib.sha256(content).hexdigest()


def replace_output(receipt, content):
    receipt["output_hex"] = content.hex()
    receipt["output_bytes"] = len(content)
    receipt["output_sha256"] = receipt_hash(content)


class AgentCastQualificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.content = (EVIDENCE / "fixture-0.bin").read_bytes()
        cls.compare = read_report("compare-0.stdout")
        cls.cache = read_report("cache-0.stdout")

    def assert_compare_rejected(self, report, content=None):
        with self.assertRaises((ValueError, KeyError, TypeError)):
            QUALIFIER.verify_report(report, self.content if content is None else content, "compare")

    def assert_cache_rejected(self, report, content=None):
        with self.assertRaises((ValueError, KeyError, TypeError)):
            QUALIFIER.verify_cache_report(report, self.content if content is None else content)

    def test_receipt_backed_positive_controls(self):
        QUALIFIER.verify_report(copy.deepcopy(self.compare), self.content, "compare")
        QUALIFIER.verify_cache_report(copy.deepcopy(self.cache), self.content)

    def test_compare_rejects_skipped_receipt_and_empty_or_pinned_outputs(self):
        skipped = copy.deepcopy(self.compare)
        skipped["runs"][0]["logical_call_count"] = 9
        self.assert_compare_rejected(skipped)

        empty = copy.deepcopy(self.compare)
        for run in empty["runs"]:
            for receipt in run["receipts"][:8]:
                replace_output(receipt, b"")
        self.assert_compare_rejected(empty)

        pinned = copy.deepcopy(self.compare)
        for run in pinned["runs"]:
            for receipt in run["receipts"][:8]:
                replace_output(receipt, b"P" * 64)
        self.assert_compare_rejected(pinned)

    def test_compare_rejects_wrong_fixture_digest_length_and_logical_mismatch(self):
        wrong_digest = copy.deepcopy(self.compare)
        wrong_digest["immutable_input_sha256"] = "0" * 64
        self.assert_compare_rejected(wrong_digest)

        wrong_length = copy.deepcopy(self.compare)
        wrong_length["immutable_input_bytes"] += 1
        self.assert_compare_rejected(wrong_length)

        mismatch = copy.deepcopy(self.compare)
        mismatch["runs"][1]["receipts"][0]["task_id"] = "other-task"
        self.assert_compare_rejected(mismatch)

    def test_compare_rejects_consistent_but_wrong_authority_and_identity(self):
        changed = copy.deepcopy(self.compare)
        for run in changed["runs"]:
            for receipt in run["receipts"]:
                receipt["principal_domain"] = "unauthorized-principal"
                receipt["task_id"] = "wrong-task"
        self.assert_compare_rejected(changed)

    def test_compare_rejects_changed_logical_identity(self):
        changed_id = copy.deepcopy(self.compare)
        for run in changed_id["runs"]:
            run["receipts"][0]["logical_id"] = 99
        self.assert_compare_rejected(changed_id)

    def test_cache_rejects_wrong_input_and_changed_principal_or_task(self):
        wrong_digest = copy.deepcopy(self.cache)
        wrong_digest["immutable_input_sha256"] = "0" * 64
        self.assert_cache_rejected(wrong_digest)
        wrong_length = copy.deepcopy(self.cache)
        wrong_length["immutable_input_bytes"] += 1
        self.assert_cache_rejected(wrong_length)

        changed = copy.deepcopy(self.cache)
        for batch in changed["batches"]:
            for receipt in batch["receipts"]:
                receipt["principal_domain"] = "unauthorized-principal"
                receipt["task_id"] = "wrong-task"
        self.assert_cache_rejected(changed)

    def test_cache_rejects_unauthorized_result_and_invented_counters(self):
        unauthorized = copy.deepcopy(self.cache)
        receipt = unauthorized["batches"][2]["receipts"][0]
        receipt["source"] = "cache"
        receipt["cache_hit"] = True
        receipt["cache_miss"] = False
        receipt["backing_reads"] = 0
        replace_output(receipt, self.content[:64])
        self.assert_cache_rejected(unauthorized)

        invented_hits = copy.deepcopy(self.cache)
        invented_hits["cache"]["hits"] += 1
        self.assert_cache_rejected(invented_hits)
        invented_reads = copy.deepcopy(self.cache)
        invented_reads["batches"][0]["backing_reads"] += 1
        self.assert_cache_rejected(invented_reads)

    def test_cache_rejects_unbounded_accounting(self):
        unbounded = copy.deepcopy(self.cache)
        unbounded["limits"]["max_bytes"] = 10**12
        unbounded["cache"]["retained_bytes"] = 10**12
        unbounded["cache"]["metadata_bytes"] = 5 * 10**11
        self.assert_cache_rejected(unbounded)


if __name__ == "__main__":
    unittest.main()
