#!/usr/bin/env python3
"""Build and exercise the standalone agent-cast foundation with owned fixtures."""

import argparse
import datetime
import hashlib
import json
import platform
import re
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "experiments" / "agent_cast"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_report(report, content, mode):
    expected_modes = ["disabled", "enabled"] if mode == "compare" else [mode]
    if report["mode"] != mode or report["logical_call_count"] != 10:
        raise ValueError("wrong logical workload or execution mode")
    if report["fixture_contract_verified"] is not True:
        raise ValueError("binary did not verify the useful fixture workload")
    if report["immutable_input_sha256"] != hashlib.sha256(content).hexdigest():
        raise ValueError("binary did not capture the actual supplied fixture")
    if report["immutable_input_bytes"] != len(content):
        raise ValueError("wrong captured input length")
    if [run["mode"] for run in report["runs"]] != expected_modes:
        raise ValueError("wrong execution reports")
    logical_results = []
    for run in report["runs"]:
        if run["logical_call_count"] != 10 or run["receipt_count"] != 10:
            raise ValueError("logical calls or receipts disappeared")
        if run["physical_reads"] != (4 if run["mode"] == "enabled" else 8):
            raise ValueError("wrong actual backing read count")
        receipts = run["receipts"]
        if len(receipts) != 10:
            raise ValueError("wrong result array size")
        result = []
        for index, receipt in enumerate(receipts):
            if receipt["logical_id"] != index + 1:
                raise ValueError("logical identity changed")
            if receipt["principal_domain"] != "fixture-operator" or receipt["task_id"] != "fixture-task":
                raise ValueError("admitted principal or task changed")
            if index < 8:
                expected = content[(index // 2) * 64:((index // 2) + 1) * 64]
                agent = "agent-a" if index % 2 == 0 else "agent-b"
                if receipt["agent_id"] != agent:
                    raise ValueError("agent identity changed")
                if receipt["admission_status"] != "admitted" or receipt["status"] != "success":
                    raise ValueError("allowed read failed")
                expected_group = index // 2 if run["mode"] == "enabled" else index
                if receipt["physical_group"] != expected_group:
                    raise ValueError("successful read has the wrong backing work identity")
            else:
                expected = b""
                admission = "denied" if index == 8 else "stale_authority"
                if receipt["agent_id"] != ("denied-agent" if index == 8 else "stale-agent"):
                    raise ValueError("rejected agent identity changed")
                if receipt["admission_status"] != admission or receipt["status"] != "admission_rejected":
                    raise ValueError("rejected call executed")
                if receipt["physical_group"] is not None:
                    raise ValueError("rejected call entered a backing group")
            if bytes.fromhex(receipt["output_hex"]) != expected:
                raise ValueError("result bytes differ from the independent fixture")
            if receipt["output_bytes"] != len(expected):
                raise ValueError("wrong output length")
            if receipt["output_sha256"] != hashlib.sha256(expected).hexdigest():
                raise ValueError("wrong output digest")
            result.append({key: value for key, value in receipt.items() if key != "physical_group"})
        logical_results.append(result)
    if mode == "compare":
        if report["parity"] is not True or logical_results[0] != logical_results[1]:
            raise ValueError("enabled and disabled logical results differ")
    elif report["parity"] is not None:
        raise ValueError("single-mode run claims comparative parity")


def verify_cache_report(report, content):
    if report["fixture_verified"] is not True or report["logical_call_count"] != 11:
        raise ValueError("cache demo did not retain its useful logical workload")
    if report["immutable_input_sha256"] != hashlib.sha256(content).hexdigest() or report["immutable_input_bytes"] != len(content):
        raise ValueError("cache demo did not capture the actual supplied fixture")
    limits, stats = report["limits"], report["cache"]
    # These caps are independently specified by this qualification workload.
    # A binary cannot authorize a larger budget by reporting matching counters.
    if limits != {"max_entries": 8, "max_bytes": 32768}:
        raise ValueError("cache changed the independent workload limits")
    if not 0 < stats["metadata_bytes"] <= stats["retained_bytes"] <= limits["max_bytes"]:
        raise ValueError("cache retained byte accounting exceeds its stated limits")
    if stats["entries"] != 4 or stats["entries"] > limits["max_entries"]:
        raise ValueError("cache did not retain four independent actual values")
    if (stats["hits"], stats["misses"], stats["backing_reads"], stats["rejected"]) != (4, 4, 4, 3):
        raise ValueError("cache reported incorrect physical work or rejected consumers")
    if report["batch_limits"] != {"max_result_bytes": 4096}:
        raise ValueError("cache changed the independent aggregate output reservation")
    names = ["cold-agent-a", "completed-values-agent-b", "rejected-consumers"]
    if [batch["name"] for batch in report["batches"]] != names:
        raise ValueError("wrong independent cache batches")
    next_id = 1
    for index, batch in enumerate(report["batches"]):
        expected_count = 3 if index == 2 else 4
        if batch["logical_calls"] != expected_count or len(batch["receipts"]) != expected_count:
            raise ValueError("cache logical calls disappeared")
        expected_counts = [(0, 4, 4), (4, 0, 0), (0, 0, 0)][index]
        if (batch["cache_hits"], batch["cache_misses"], batch["backing_reads"]) != expected_counts:
            raise ValueError("wrong batch provenance counters")
        for window, call in enumerate(batch["receipts"]):
            if call["logical_id"] != next_id:
                raise ValueError("cache changed per-logical identity")
            next_id += 1
            if call["principal_domain"] != "fixture-operator" or call["task_id"] != "cache-fixture-task":
                raise ValueError("cache changed the admitted task or principal")
            if index < 2:
                expected = content[window * 64:(window + 1) * 64]
                if call["agent_id"] != ("agent-a" if index == 0 else "agent-b"):
                    raise ValueError("cache changed consumer identity")
                if call["admission_status"] != "admitted" or call["status"] != "success":
                    raise ValueError("cache allowed read did not succeed")
                if (call["source"], call["cache_hit"], call["cache_miss"], call["backing_reads"]) != [("backing", False, True, 1), ("cache", True, False, 0)][index]:
                    raise ValueError("cache hit or backing provenance is incorrect")
            else:
                expected = b""
                admission = ["denied", "stale_authority", "binding_mismatch"][window]
                agent = ["denied-agent", "stale-agent", "mismatched-agent"][window]
                if call["admission_status"] != admission or call["agent_id"] != agent or call["status"] != "admission_rejected":
                    raise ValueError("rejected cache consumer changed identity or received admission")
                if (call["source"], call["cache_hit"], call["cache_miss"], call["backing_reads"]) != ("rejected", False, False, 0):
                    raise ValueError("rejected consumer performed cache or backing work")
            if bytes.fromhex(call["output_hex"]) != expected or call["output_bytes"] != len(expected) or call["output_sha256"] != hashlib.sha256(expected).hexdigest():
                raise ValueError("cache output differs from actual independently supplied bytes")


def qualify(zig, output):
    checks = []
    receipt = {
        "schema_version": 1,
        "recorded_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "local foundation/cache correctness and subscriber/framing unit checks; logical agents in one process; no broker or isolation qualification",
        "platform": platform.platform(),
        "machine": platform.machine(),
        "source_sha256": {str(p.relative_to(ROOT)): digest(p) for p in sorted(PROJECT.rglob("*.zig")) if "zig-out" not in p.parts and ".zig-cache" not in p.parts},
        "checks": checks,
        "ci_status": "not_run",
        "performance_claim": None,
        "ok": False,
    }

    def run(name, argv, cwd=PROJECT, expected_exit=0):
        start = time.monotonic()
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=300)
        (output / f"{name}.stdout").write_text(result.stdout)
        (output / f"{name}.stderr").write_text(result.stderr)
        check = {"name": name, "argv": [str(a) for a in argv], "cwd": str(cwd), "exit_code": result.returncode, "seconds": time.monotonic() - start, "stdout": f"{name}.stdout", "stderr": f"{name}.stderr"}
        checks.append(check)
        if result.returncode != expected_exit:
            raise RuntimeError(f"{name} failed: {result.stderr[-2000:]}")
        return result

    try:
        version = run("zig-version", [zig, "version"]).stdout.strip()
        if version != "0.16.0":
            raise ValueError(f"expected pinned Zig0.16.0, got {version}")
        receipt["zig_version"] = version
        run("format", [zig, "fmt", "--check", "src/", "build.zig"])
        run("build", [zig, "build", "-Doptimize=ReleaseSafe", "-j1"])
        unit = run("unit", [zig, "build", "test", "-Doptimize=ReleaseSafe", "-j1", "--summary", "all"])
        counts = re.search(r"(\d+)/(\d+) tests passed", unit.stderr)
        if not counts or counts[1] != counts[2] or int(counts[1]) < 30:
            raise ValueError("unit receipt does not prove the nonempty foundation/cache test owner ran")
        receipt["unit_tests_passed"] = int(counts[1])
        binary = PROJECT / "zig-out" / "bin" / "agent-cast-demo"
        receipt["binary_sha256"] = digest(binary)
        help_result = run("help", [binary, "--help"])
        if help_result.stderr or "--fixture" not in help_result.stdout:
            raise ValueError("built CLI help interaction failed")
        cache_binary = PROJECT / "zig-out" / "bin" / "agent-cast-cache-demo"
        receipt["cache_binary_sha256"] = digest(cache_binary)
        cache_help = run("cache-help", [cache_binary, "--help"])
        if cache_help.stderr or "--fixture" not in cache_help.stdout:
            raise ValueError("built cache CLI help failed")
        fixtures = []
        for fixture_index in range(2):
            content = b"".join(f"fixture-{fixture_index}-window-{i:02d}".encode().ljust(64, bytes([65 + fixture_index + i])) for i in range(16))
            if len({content[i:i + 64] for i in range(0, 256, 64)}) != 4:
                raise ValueError("fixture windows are degenerate")
            path = output / f"fixture-{fixture_index}.bin"
            path.write_bytes(content)
            result = run(f"compare-{fixture_index}", [binary, "--fixture", path, "--mode", "compare"])
            if result.stderr:
                raise ValueError("built comparison wrote unexpected stderr")
            report = json.loads(result.stdout)
            verify_report(report, content, "compare")
            cached = run(f"cache-{fixture_index}", [cache_binary, "--fixture", path])
            if cached.stderr:
                raise ValueError("built cache interaction wrote unexpected stderr")
            verify_cache_report(json.loads(cached.stdout), content)
            fixtures.append({"sha256": digest(path), "bytes": len(content), "comparison": f"compare-{fixture_index}.stdout", "cache_comparison": f"cache-{fixture_index}.stdout", "logical_receipts_per_mode": 10, "cache_logical_receipts": 11, "disabled_backing_reads": report["runs"][0]["physical_reads"], "enabled_backing_reads": report["runs"][1]["physical_reads"]})
        if fixtures[0]["sha256"] == fixtures[1]["sha256"]:
            raise ValueError("the independent fixtures have identical content")
        receipt["fixtures"] = fixtures
        content = (output / "fixture-0.bin").read_bytes()
        for mode in ["enabled", "disabled"]:
            result = run(mode, [binary, "--fixture", output / "fixture-0.bin", "--mode", mode])
            if result.stderr:
                raise ValueError("single-mode interaction wrote unexpected stderr")
            verify_report(json.loads(result.stdout), content, mode)
        tiny = output / "too-small.bin"
        tiny.write_bytes(b"actual-invalid-input")
        rejected = run("cache-too-small", [cache_binary, "--fixture", tiny], expected_exit=1)
        if rejected.stdout or rejected.stderr != "agent-cast-cache-demo: FixtureTooSmall; see --help\n":
            raise ValueError("invalid cache input did not produce the expected ordinary error")
        receipt["ok"] = True
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError, KeyError) as error:
        receipt["error"] = str(error)
    finally:
        (output / "qualification.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig", help="verified Zig0.16.0 executable")
    parser.add_argument("--output", type=Path, help="new output directory; existing paths are rejected")
    args = parser.parse_args()
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="agent-cast-qualification-"))
    receipt = qualify(args.zig, output)
    print(json.dumps({"ok": receipt["ok"], "receipt": str(output / "qualification.json"), "checks": len(receipt["checks"]), "error": receipt.get("error")}, indent=2))
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
