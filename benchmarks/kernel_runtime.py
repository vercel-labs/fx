#!/usr/bin/env python3
"""Compare persistent IPython and Julia control-kernel costs.

Both workers use the same line-framed protocol over stdio. Each request is a
base64-encoded cell; each response contains status, stdout, stderr, and the
cell result as base64 fields. This compares equivalent persistent-worker
behavior rather than fx's production length-prefixed JSON framing. Resident
RSS is read from Linux /proc and is reported as unavailable elsewhere.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import math
import statistics
import subprocess
import time
from pathlib import Path


IPYTHON_WORKER = r'''
import base64
import contextlib
import io
import sys
from IPython.core.interactiveshell import InteractiveShell

shell = InteractiveShell.instance()
for encoded in sys.stdin:
    code = base64.b64decode(encoded.strip()).decode("utf-8")
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = "ok"
    value = ""
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            execution = shell.run_cell(code, store_history=False, silent=False)
        if not execution.success:
            status = "error"
        elif execution.result is not None:
            value = repr(execution.result)
    except BaseException as error:
        status = "error"
        stderr.write(f"{type(error).__name__}: {error}")
    fields = (status, stdout.getvalue(), stderr.getvalue(), value)
    print("\t".join([fields[0], *(
        base64.b64encode(field.encode("utf-8")).decode("ascii")
        for field in fields[1:]
    )]), flush=True)
'''


JULIA_WORKER = r'''
using Base64

module FxKernel
end

for encoded in eachline(stdin)
    code = String(base64decode(encoded))
    stdout_pipe = Pipe()
    stderr_pipe = Pipe()
    Base.link_pipe!(stdout_pipe; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(stderr_pipe; reader_supports_async=true, writer_supports_async=true)
    stdout_task = @async read(stdout_pipe, String)
    stderr_task = @async read(stderr_pipe, String)
    status = "ok"
    value = ""
    error_text = ""
    try
        result = redirect_stdout(stdout_pipe) do
            redirect_stderr(stderr_pipe) do
                Core.eval(FxKernel, Meta.parseall(code))
            end
        end
        if result !== nothing
            value = repr(result)
        end
    catch error_value
        status = "error"
        error_text = sprint(showerror, error_value, catch_backtrace())
    end
    close(stdout_pipe.in)
    close(stderr_pipe.in)
    stdout_text = fetch(stdout_task)
    stderr_text = fetch(stderr_task) * error_text
    close(stdout_pipe)
    close(stderr_pipe)
    fields = (
        status,
        base64encode(stdout_text),
        base64encode(stderr_text),
        base64encode(value),
    )
    println(join(fields, '\t'))
    flush(stdout)
end
'''


@dataclasses.dataclass(frozen=True)
class Response:
    status: str
    stdout: str
    stderr: str
    result: str


class KernelWorker:
    def __init__(self, name: str, argv: list[str]) -> None:
        self.name = name
        self.process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    def execute(self, code: str) -> Response:
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        encoded = base64.b64encode(code.encode("utf-8")).decode("ascii")
        self.process.stdin.write(encoded + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            diagnostic = ""
            if self.process.stderr is not None:
                diagnostic = self.process.stderr.read()
            raise RuntimeError(
                f"{self.name} worker exited with {self.process.poll()}: {diagnostic}"
            )
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 4:
            raise RuntimeError(f"{self.name} returned an invalid frame: {line!r}")
        return Response(
            status=fields[0],
            stdout=base64.b64decode(fields[1]).decode("utf-8"),
            stderr=base64.b64decode(fields[2]).decode("utf-8"),
            result=base64.b64decode(fields[3]).decode("utf-8"),
        )

    def rss_mib(self) -> float:
        status_path = Path(f"/proc/{self.process.pid}/status")
        if not status_path.exists():
            return float("nan")
        for line in status_path.read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
        return float("nan")

    def close(self) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)

    def __enter__(self) -> KernelWorker:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


@dataclasses.dataclass(frozen=True)
class Runtime:
    name: str
    argv: list[str]
    assignment: str
    increment: str
    workload_setup: str
    workload: str
    workload_result: str
    output: str


def percentile(samples: list[float], quantile: float) -> float:
    ordered = sorted(samples)
    index = min(len(ordered) - 1, round((len(ordered) - 1) * quantile))
    return ordered[index]


def require_ok(runtime: Runtime, response: Response) -> None:
    if response.status != "ok":
        raise RuntimeError(
            f"{runtime.name} cell failed:\nstdout={response.stdout}\n"
            f"stderr={response.stderr}"
        )


def measure_startup(runtime: Runtime, runs: int) -> list[float]:
    samples: list[float] = []
    for _ in range(runs):
        started = time.perf_counter()
        with KernelWorker(runtime.name, runtime.argv) as worker:
            response = worker.execute(runtime.assignment)
            require_ok(runtime, response)
            samples.append((time.perf_counter() - started) * 1000)
    return samples


def measure_persistent(
    runtime: Runtime, warm_runs: int, workload_runs: int
) -> tuple[list[float], list[float], float, float, float]:
    with KernelWorker(runtime.name, runtime.argv) as worker:
        require_ok(runtime, worker.execute(runtime.assignment))
        latencies: list[float] = []
        for _ in range(warm_runs):
            started = time.perf_counter_ns()
            response = worker.execute(runtime.increment)
            latencies.append((time.perf_counter_ns() - started) / 1_000)
            require_ok(runtime, response)
        state_result = response.result
        expected = str(41 + warm_runs)
        if state_result != expected:
            raise RuntimeError(
                f"{runtime.name} did not retain state: expected {expected}, got {state_result!r}"
            )
        workload_latencies: list[float] = []
        first_workload_ms = 0.0
        require_ok(runtime, worker.execute(runtime.workload_setup))
        for index in range(workload_runs):
            started = time.perf_counter_ns()
            workload_response = worker.execute(runtime.workload)
            elapsed_us = (time.perf_counter_ns() - started) / 1_000
            require_ok(runtime, workload_response)
            if workload_response.result != runtime.workload_result:
                raise RuntimeError(
                    f"{runtime.name} workload returned {workload_response.result!r}"
                )
            if index == 0:
                first_workload_ms = elapsed_us / 1_000
            else:
                workload_latencies.append(elapsed_us)
        rss_mib = worker.rss_mib()
        started = time.perf_counter()
        output_response = worker.execute(runtime.output)
        output_ms = (time.perf_counter() - started) * 1000
        require_ok(runtime, output_response)
        if len(output_response.stdout) != 1_000_001:
            raise RuntimeError(
                f"{runtime.name} output length was {len(output_response.stdout)}"
            )
        return latencies, workload_latencies, first_workload_ms, rss_mib, output_ms


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", required=True, help="Python with IPython installed")
    parser.add_argument("--julia", required=True)
    parser.add_argument("--startup-runs", type=int, default=10)
    parser.add_argument("--warm-runs", type=int, default=200)
    parser.add_argument("--workload-runs", type=int, default=100)
    args = parser.parse_args()
    if args.startup_runs < 1:
        parser.error("--startup-runs must be at least 1")
    if args.warm_runs < 1:
        parser.error("--warm-runs must be at least 1")
    if args.workload_runs < 2:
        parser.error("--workload-runs must be at least 2")

    runtimes = (
        Runtime(
            name="ipython",
            argv=[args.python, "-u", "-c", IPYTHON_WORKER],
            assignment="value = 41",
            increment="value += 1\nvalue",
            workload_setup=(
                "def square_sum(count):\n"
                "    return sum(item * item for item in range(count))"
            ),
            workload="square_sum(100_000)",
            workload_result="333328333350000",
            output="print('x' * 1_000_000)",
        ),
        Runtime(
            name="julia",
            argv=[
                args.julia,
                "--startup-file=no",
                "--history-file=no",
                "--quiet",
                "-e",
                JULIA_WORKER,
            ],
            assignment="value = 41",
            increment="value += 1\nvalue",
            workload_setup="square_sum(count) = sum(abs2, 0:count-1)",
            workload="square_sum(100_000)",
            workload_result="333328333350000",
            output="print(\"x\" ^ 1_000_000); println()",
        ),
    )

    print(
        f"persistent protocol benchmark: startup_runs={args.startup_runs} "
        f"warm_runs={args.warm_runs}"
    )
    for runtime in runtimes:
        startup = measure_startup(runtime, args.startup_runs)
        warm, workload, first_workload_ms, rss_mib, output_ms = measure_persistent(
            runtime, args.warm_runs, args.workload_runs
        )
        rss_text = "unavailable" if math.isnan(rss_mib) else f"{rss_mib:.1f}"
        print(
            f"{runtime.name}: startup_to_first_cell_median_ms={statistics.median(startup):.1f} "
            f"startup_p95_ms={percentile(startup, 0.95):.1f} "
            f"warm_cell_median_us={statistics.median(warm):.1f} "
            f"warm_cell_p95_us={percentile(warm, 0.95):.1f} "
            f"first_workload_ms={first_workload_ms:.1f} "
            f"warm_workload_median_us={statistics.median(workload):.1f} "
            f"resident_rss_mib={rss_text} output_1mb_ms={output_ms:.1f}"
        )


if __name__ == "__main__":
    main()
