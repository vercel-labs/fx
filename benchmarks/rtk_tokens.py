"""Count captured RTK text with tiktoken 0.12.0; run in a container or VM.

Feed stdout from `bun test benchmarks/rtk.test.ts` on stdin. Counts of the
serialized prompt and tools are a context proxy, not provider billing usage.
"""
import json
import re
import sys

import tiktoken


def compare(before, after, encoding):
    counts = [len(encoding.encode(text, disallowed_special=())) for text in (before, after)]
    return {
        "before": counts[0],
        "after": counts[1],
        "saved": counts[0] - counts[1],
        "saved_percent": round(100 * (counts[0] - counts[1]) / counts[0], 2) if counts[0] else 0,
    }


def test_counts(text):
    passed = (
        re.search(r"^\s*(\d+) pass$", text, re.MULTILINE)
        or re.search(r"All (\d+) tests passed", text)
    )
    if passed is None:
        return None
    failed = re.search(r"^\s*(\d+) fail$", text, re.MULTILINE)
    return {"passed": int(passed[1]), "failed": int(failed[1]) if failed else 0}


rows = []
expected_cases = None
encodings = {name: tiktoken.get_encoding(name) for name in ("o200k_base", "cl100k_base")}
for line in sys.stdin:
    # Bun also writes a version banner to stdout.
    if not line.startswith("{"):
        continue
    case = json.loads(line)
    if expected_cases is None:
        expected_cases = case["expected_cases"]
    if case["expected_cases"] != expected_cases:
        raise SystemExit("inconsistent corpus size")
    output = case["output"]
    rows.append({
        "name": case["name"],
        "command": case["command"],
        "exit_code": case["exit_code"],
        "output_truncated": case["output_truncated"],
        "tests": test_counts(output["before"]),
        "output_bytes": {side: len(output[side].encode("utf-8")) for side in ("before", "after")},
        "tokens": {name: {
            field: compare(case[field]["before"], case[field]["after"], encoding)
            for field in ("output", "request")
        } for name, encoding in encodings.items()},
    })
if not rows or len(rows) != expected_cases:
    raise SystemExit(f"expected {expected_cases} benchmark cases, received {len(rows)}")
print(json.dumps({"tiktoken_version": tiktoken.__version__, "cases": rows}, indent=2))
