#!/usr/bin/env python3
"""Measure subagent result/status read scratch, RSS, and latency on Linux.

Copies a git revision into a temporary directory and injects the timed portion
of the current memory regression test. Only the production read helpers
are benchmarked: no model, provider latency, or deliberate OOM. The old revision
is expected to fail the test's arena-capacity assertion after emitting metrics.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import statistics
import subprocess
import sys
import tarfile
import tempfile

TEST_NAME = "subagent session reads do not retain scratch in the caller arena"
HOST = Path("src/core/subagent/tool_host.zig")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD")
    parser.add_argument("--output", required=True)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if not sys.platform.startswith("linux") or args.runs < 1:
        parser.error("requires Linux and at least one run")
    repo = Path(__file__).resolve().parent.parent
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(["git", "rev-parse", args.revision + "^{commit}"], cwd=repo, text=True).strip()
    source = (repo / HOST).read_text()
    start = source.index(f'test "{TEST_NAME}"')
    end = source.find('\ntest "', start + 1)
    regression = source[start:end if end != -1 else len(source)]
    # Keep the timed workload identical, excluding later correctness checks
    # which may depend on APIs that did not exist in the baseline revision.
    regression = regression[:regression.index("    // Only the tiny result")]
    regression += "    try std.testing.expect(turn.queryCapacity() < 64 * 1024);\n}\n"
    samples = []
    with tempfile.TemporaryDirectory(prefix="fx-subagent-reads-") as directory:
        root = Path(directory)
        archive = output / "source.tar"
        with archive.open("wb") as stream:
            subprocess.run(["git", "archive", revision], cwd=repo, stdout=stream, check=True)
        with tarfile.open(archive) as stream:
            stream.extractall(root, filter="data")
        archive.unlink()
        host = root / HOST
        original = host.read_text()
        marker = f'test "{TEST_NAME}"'
        if marker in original:
            start = original.index(marker)
            end = original.find('\ntest "', start + 1)
            original = original[:start] + original[end if end != -1 else len(original):]
        host.write_text(original + "\n" + regression + "\n")
        options = root / "bench_options.zig"
        options.write_text('pub const git_commit = "benchmark";\npub const app_version = "0.0.0";\npub const update_channel = "stable";\npub const wasm_surface = enum { none, core, term }.none;\n')
        binary = root / "read-benchmark"
        subprocess.run([
            "zig", "test", "-O", "ReleaseSafe", "-lc", "--dep", "build_options",
            "-Mroot=src/main.zig", f"-Mbuild_options={options}",
            "--test-filter", TEST_NAME, "--test-no-exec", f"-femit-bin={binary}",
        ], cwd=root, check=True, timeout=600)

        def limits():
            resource.setrlimit(resource.RLIMIT_AS, (4 * 1024**3,) * 2)
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

        for index in range(args.runs):
            rss_file = output / f"run-{index}.rss-kib"
            result = subprocess.run(
                ["/usr/bin/time", "-f", "%M", "-o", str(rss_file), str(binary)],
                cwd=root, env={**os.environ, "FX_SUBAGENT_READ_BENCH": "1"},
                capture_output=True, text=True, timeout=60, preexec_fn=limits,
            )
            (output / f"run-{index}.log").write_text(result.stdout + result.stderr)
            match = re.search(r"SUBAGENT_READ_BENCH ([^\n]+)", result.stderr)
            if match is None:
                raise RuntimeError(f"benchmark failed before reporting metrics; see run-{index}.log")
            fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", match[1])}
            fields.update(peak_rss_kib=int(rss_file.read_text().splitlines()[-1]), exit_code=result.returncode)
            if result.returncode != 0 and not (result.returncode == 1 and "1 failed." in result.stderr and "FAIL (TestUnexpectedResult)" in result.stderr and fields["arena_after_16"] >= 64 * 1024):
                raise RuntimeError(f"unexpected test failure; see run-{index}.log")
            samples.append(fields)
    report = {
        "revision": revision, "platform": sys.platform,
        "zig_version": subprocess.check_output(["zig", "version"], text=True).strip(),
        "scope": "16 result reads and 16 status initializations; 1 MiB old assistant turn plus 12-byte selected result",
        "samples": samples,
        "median": {key: statistics.median(sample[key] for sample in samples) for key in samples[0]},
    }
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
