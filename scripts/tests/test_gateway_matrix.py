from __future__ import annotations

import json
import unittest

from scripts.gateway_matrix.proxy import describe_prompt, describe_response
from scripts.gateway_matrix.runner import MatrixResult, TurnResult, format_table, requests_for_tag, summarize


class DescribePromptTests(unittest.TestCase):
    def test_counts_leading_and_total_system_messages(self) -> None:
        body = json.dumps(
            {
                "prompt": [
                    {"role": "system", "content": "a"},
                    {"role": "system", "content": "b"},
                    {"role": "user", "content": "hi"},
                    {"role": "assistant", "content": "ok"},
                ],
                "tools": [{"type": "function", "name": "read_file"}],
            }
        ).encode()
        record = describe_prompt(body)
        self.assertEqual(record["roles"], ["system", "system", "user", "assistant"])
        self.assertEqual(record["system_count"], 2)
        self.assertEqual(record["leading_system_count"], 2)
        self.assertEqual(record["tools"], 1)

    def test_all_system_prompt_counts_every_message_as_leading(self) -> None:
        body = json.dumps({"prompt": [{"role": "system", "content": "only"}]}).encode()
        self.assertEqual(describe_prompt(body)["leading_system_count"], 1)

    def test_invalid_json_is_reported_not_raised(self) -> None:
        self.assertIn("parse_error", describe_prompt(b"{not json"))


class DescribeResponseTests(unittest.TestCase):
    def test_error_status_keeps_body(self) -> None:
        record = describe_response(400, "jinja template rendering failed.")
        self.assertEqual(record["error_body"], "jinja template rendering failed.")

    def test_routing_is_extracted_from_finish_event(self) -> None:
        finish = {
            "type": "finish",
            "providerMetadata": {
                "gateway": {
                    "routing": {
                        "finalProvider": "fireworks",
                        "fallbacksAvailable": ["fireworks"],
                        "modelAttempts": [
                            {
                                "providerAttempts": [
                                    {"provider": "fireworks", "statusCode": 400, "error": "System message must be at the beginning."}
                                ]
                            }
                        ],
                    }
                }
            },
        }
        text = 'data: {"type":"tool-call","toolCallId":"x"}\n' + "data: " + json.dumps(finish) + "\n"
        record = describe_response(200, text)
        self.assertEqual(record["tool_calls"], 1)
        routing = record["routing"]
        self.assertIsInstance(routing, dict)
        assert isinstance(routing, dict)
        self.assertEqual(routing["final_provider"], "fireworks")
        self.assertEqual(routing["attempts"][0]["status"], 400)
        self.assertIn("beginning", routing["attempts"][0]["error"])


class SummarizeTests(unittest.TestCase):
    def _result(self) -> MatrixResult:
        result = MatrixResult()
        result.turns.append(
            TurnResult("main", "alibaba/qwen3.8-max", 2, "main__alibaba_qwen3.8-max__t2", 0, 1200, "sid", "OK", [], None, "")
        )
        result.requests = [
            {
                "tag": "main__alibaba_qwen3.8-max__t2",
                "model_header": "alibaba/qwen3.8-max",
                "leading_system_count": 7,
                "status": 400,
                "error_body": "jinja template rendering failed. System message must be at the beginning.",
            },
            {
                "tag": "main__alibaba_qwen3.8-max__t2",
                "model_header": "openai/title-model",
                "leading_system_count": 1,
                "status": 200,
            },
        ]
        return result

    def test_side_requests_for_other_models_are_excluded(self) -> None:
        result = self._result()
        matching = requests_for_tag(result.requests, "main__alibaba_qwen3.8-max__t2", "alibaba/qwen3.8-max")
        self.assertEqual(len(matching), 1)

    def test_summary_rows_and_table(self) -> None:
        rows = summarize(self._result())
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["requests"], 1)
        self.assertEqual(row["leading_systems"], [7])
        self.assertEqual(row["statuses"], [400])
        self.assertTrue(str(row["errors"][0]).startswith("jinja"))
        table = format_table(rows)
        self.assertIn("alibaba/qwen3.8-max | 2 | 1 | 7 | 400 |", table)


if __name__ == "__main__":
    unittest.main()
