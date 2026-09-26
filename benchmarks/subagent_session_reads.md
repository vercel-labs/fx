# Subagent session reads

This Linux microbenchmark calls the production `managedResultText` and
`startStatusPublisher` helpers 16 times each with a parent-style arena. The saved
child has a 1 MiB old assistant turn and a 12-byte result for the selected work ID.
Each run starts a fresh process and temporary profile. No model or credentials
are needed. It bounds the test process to 4 GiB of address space and 60 seconds.

With Zig 0.16, Python 3.12+, and GNU time installed, run from the repository:

```sh
python3 benchmarks/subagent_session_reads.py --revision c95fcc66 --output /tmp/subagent-before
python3 benchmarks/subagent_session_reads.py --revision c6ebf4e9 --output /tmp/subagent-lifetime
python3 benchmarks/subagent_session_reads.py --revision HEAD --output /tmp/subagent-after
```

The second revision contains only the scratch-lifetime fix; the final version
also uses metadata for status initialization. The script archives the requested
revision without changing the checkout, injects the same timed portion of the
current regression test, and compiles just that test plus Zig import checks.
The old revision is expected to fail the caller-arena capacity assertion; other
failures stop the benchmark.

Each output directory contains raw test logs and `summary.json` with three
samples and medians. `arena_after_1` and `arena_after_16` are retained caller-arena
backing bytes, **not RSS**. `peak_rss_kib` is the kernel high-water mark of the
whole test process, including fixture setup.
`result_ns` and `status_ns` time only the 16 respective helper calls, excluding
setup, compilation, model requests, and child execution. RSS and allocator
capacity are different measurements; this reduced workload does not reproduce
the reported 60 GB incident or prove that every source of turn memory growth is
fixed.

The ordinary regression runs in Full CI without the benchmark environment
variable. It checks bounded caller retention, selected result ownership,
persisted model/effort changes, capability-resolution scratch, absent results,
metadata fallback, and copy-out allocation failures. The existing Gateway E2E
suite exercises actual one-off and persistent subagent calls using the freshly
built binary.
