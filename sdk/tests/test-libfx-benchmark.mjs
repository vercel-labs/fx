#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { benchmarkInstructionsBytes, sampleStats } from "../../benchmarks/libfx/workload.mjs";

assert.deepEqual(sampleStats([4, 1, 3, 2]), { count: 4, mean: 2.5, p50: 2, p95: 4, max: 4 });
assert.equal(sampleStats(Array.from({ length: 100 }, (_, index) => index + 1)).p99, 99);
for (const invalid of [[], [NaN], [Infinity], [null], [-1]]) assert.throws(() => sampleStats(invalid), TypeError);

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const benchmark = fileURLToPath(new URL("../../benchmarks/libfx/bench-fx.mjs", import.meta.url));
const runtimeBenchmark = fileURLToPath(new URL("../../benchmarks/libfx/bench-runtime.mjs", import.meta.url));
const capacityBenchmark = fileURLToPath(new URL("../../benchmarks/libfx/bench-capacity.mjs", import.meta.url));
const benchmarkCheck = fileURLToPath(new URL("../../benchmarks/libfx/check-results.mjs", import.meta.url));
const runtime = process.versions.bun ? "bun" : "node";
const command = process.execPath;

for (const backend of ["native", "wasm"]) {
  const args = [benchmark, "--backend", backend, "--samples", "1", "--json"];
  if (runtime === "node" && backend === "wasm") args.unshift("--experimental-wasm-jspi");
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 20_000,
  });
  assert.equal(result.status, 0, `${runtime} ${backend} benchmark failed:\n${result.stderr}`);
  const report = JSON.parse(result.stdout);
  assert.equal(report.runtime, runtime);
  assert.equal(report.backend, backend);
  assert.equal(report.samples.length, 1);
  const sample = report.samples[0];
  assert.equal(sample.text, "hello");
  assert.ok(sample.spawn_to_first_stdout_ms >= 0);
  assert.ok(sample.prompt_to_fetch_ms >= 0);
  assert.ok(sample.first_body_to_first_text_ms >= 0);
  assert.ok(sample.total_ms >= sample.spawn_to_first_stdout_ms);
  assert.equal(sample.non_prompt_fetches, 1, "cold samples must count the model catalog lookup");
  assert.ok(sample.request_bytes > 0);
  assert.equal(sample.system_context_bytes, benchmarkInstructionsBytes);
  assert.equal(sample.system_context_overhead_bytes, 0);

  const runtimeResult = spawnSync(command, [
    ...(runtime === "node" && backend === "wasm" ? ["--experimental-wasm-jspi"] : []),
    runtimeBenchmark,
    "--backend", backend,
    "--warm-samples", "2",
    "--stream-samples", "1",
  ], { cwd: repoRoot, encoding: "utf8", timeout: 20_000 });
  assert.equal(runtimeResult.status, 0, `${runtime} ${backend} runtime benchmark failed:\n${runtimeResult.stderr}`);
  const runtimeReport = JSON.parse(runtimeResult.stdout);
  assert.equal(runtimeReport.backend, backend);
  assert.equal(runtimeReport.first_prompt.text, "hello");
  assert.equal(runtimeReport.non_prompt_fetches, 7, "warm prompts must reuse metadata; each new stream agent resolves it once");
  assert.equal(runtimeReport.warm.prompt_to_first_text_ms.count, 2);
  assert.deepEqual(runtimeReport.streams.map(({ chunks, bytes, samples }) => ({ chunks, bytes, samples })), [
    { chunks: 1, bytes: 1, samples: 1 },
    { chunks: 1000, bytes: 1, samples: 1 },
    { chunks: 16, bytes: 65_536, samples: 1 },
  ]);

  const capacityResult = spawnSync(command, [
    ...(runtime === "node" ? ["--expose-gc"] : []),
    ...(runtime === "node" && backend === "wasm" ? ["--experimental-wasm-jspi"] : []),
    capacityBenchmark,
    "--backend", backend,
    "--count", "2",
  ], { cwd: repoRoot, encoding: "utf8", timeout: 20_000 });
  assert.equal(capacityResult.status, 0, `${runtime} ${backend} capacity benchmark failed:\n${capacityResult.stderr}`);
  const capacityReport = JSON.parse(capacityResult.stdout);
  assert.equal(capacityReport.backend, backend);
  assert.equal(capacityReport.count, 2);
  assert.equal(capacityReport.non_prompt_fetches, 3, "the warmup and two measured agents must each resolve metadata once");
  assert.deepEqual(capacityReport.failures, []);
  assert.deepEqual(capacityReport.snapshots.map(({ stage }) => stage), [
    "baseline", "created", "prompted", "closing", "closed", "server_closed",
  ]);
}

const checkDir = await mkdtemp(resolve(tmpdir(), "libfx-benchmark-check-"));
try {
  const write = (name, value) => writeFile(resolve(checkDir, name), `${JSON.stringify(value)}\n`);
  for (const runtimeName of ["node", "bun"]) {
    for (const [backend, warmP50, bridgeMs] of [["native", 0.6, 0.5], ["wasm", 0.4, 0.3]]) {
      await write(`runtime-${runtimeName}-${backend}.json`, {
        warm: { prompt_to_first_text_ms: { count: 100, p50: warmP50 } },
        streams: [{ samples: 30 }, { samples: 30 }, { samples: 30 }],
      });
      await write(`bridge-${runtimeName}-${backend}.json`, {
        samples: Array.from({ length: 100 }, () => ({ tool_round_trip_ms: bridgeMs })),
      });
      await write(`capacity-${runtimeName}-${backend}.json`, {
        count: 25,
        failures: [],
        snapshots: [
          { stage: "baseline", thread_count: 8, descriptor_count: 14, active_handles: 2, external_bytes: 4_000_000 },
          { stage: "created", external_bytes: backend === "wasm" ? 50_000_000 : 4_000_000 },
          { stage: "prompted", thread_count: backend === "native" ? 33 : 12 },
          { stage: "closing", thread_count: backend === "native" ? 33 : 12 },
          { stage: "closed", thread_count: backend === "native" ? 8 : 12 },
          { stage: "server_closed", thread_count: backend === "native" ? 8 : 12, descriptor_count: 13, active_handles: 1, external_bytes: 5_000_000 },
        ],
      });
    }
    await write(`competitive-${runtimeName}.json`, {
      rounds: [
        { order: ["libfx", "pi"], libfx_request_count: 103, pi_request_count: 103 },
        { order: ["pi", "libfx"], libfx_request_count: 103, pi_request_count: 103 },
        { order: ["libfx", "pi"], libfx_request_count: 103, pi_request_count: 103 },
      ],
      libfx: { prompt_to_first_text_ms: { count: 300, p50: 0.5, p95: 0.8, p99: 1.2 } },
      pi: { prompt_to_first_text_ms: { count: 300, p50: 0.7, p95: 1.0, p99: 1.5 } },
    });
  }
  const passed = spawnSync(command, [benchmarkCheck, "--dir", checkDir], { encoding: "utf8" });
  assert.equal(passed.status, 0, passed.stderr || passed.stdout);

  await write("runtime-node-native.json", {
    warm: { prompt_to_first_text_ms: { count: 100, p50: 5 } },
    streams: [{ samples: 30 }, { samples: 30 }, { samples: 30 }],
  });
  const failed = spawnSync(command, [benchmarkCheck, "--dir", checkDir], { encoding: "utf8" });
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr, /Node native warm p50/);

  await write("runtime-node-native.json", {
    warm: { prompt_to_first_text_ms: { count: 100, p50: 0.6 } },
    streams: [{ samples: 30 }, { samples: 30 }, { samples: 30 }],
  });
  const slowerCompetitor = {
    rounds: [
      { order: ["libfx", "pi"], libfx_request_count: 103, pi_request_count: 103 },
      { order: ["pi", "libfx"], libfx_request_count: 103, pi_request_count: 103 },
      { order: ["libfx", "pi"], libfx_request_count: 103, pi_request_count: 103 },
    ],
    libfx: { prompt_to_first_text_ms: { count: 300, p50: 1.1, p95: 1.4, p99: 1.8 } },
    pi: { prompt_to_first_text_ms: { count: 300, p50: 0.7, p95: 1.0, p99: 1.5 } },
  };
  await write("competitive-node.json", slowerCompetitor);
  const nodeReport = spawnSync(command, [benchmarkCheck, "--dir", checkDir], { encoding: "utf8" });
  assert.equal(nodeReport.status, 0, nodeReport.stderr);
  assert.match(nodeReport.stdout, /Node native versus Pi \(report only\)/);
  assert.match(nodeReport.stdout, /p50 1\.100ms \/ 0\.700ms/);
  assert.match(nodeReport.stdout, /p95 1\.400ms \/ 1\.000ms/);
  assert.match(nodeReport.stdout, /p99 1\.800ms \/ 1\.500ms/);

  for (const [timings, error] of [
    [{ count: 299, p50: 1.1, p95: 1.4, p99: 1.8 }, /needs 300 samples/],
    [{ count: 300, p50: null, p95: 1.4, p99: 1.8 }, /competitor timings are invalid/],
  ]) {
    await write("competitive-node.json", { ...slowerCompetitor, libfx: { prompt_to_first_text_ms: timings } });
    const invalid = spawnSync(command, [benchmarkCheck, "--dir", checkDir], { encoding: "utf8" });
    assert.notEqual(invalid.status, 0);
    assert.match(invalid.stderr, error);
  }
  await write("competitive-node.json", slowerCompetitor);
  await write("competitive-bun.json", slowerCompetitor);
  const bunFailed = spawnSync(command, [benchmarkCheck, "--dir", checkDir], { encoding: "utf8" });
  assert.notEqual(bunFailed.status, 0);
  assert.match(bunFailed.stderr, /Bun native versus Pi p50/);
  assert.match(bunFailed.stderr, /Bun native versus Pi p95/);
} finally {
  await rm(checkDir, { recursive: true, force: true });
}

console.log(`${runtime} libfx benchmark integration passed`);
