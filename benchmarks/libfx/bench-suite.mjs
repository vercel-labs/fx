#!/usr/bin/env node
import { execFile } from "node:child_process";
import { randomInt } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index < 0 ? fallback : args[index + 1];
};
const samples = Number(value("--samples", "20"));
const outDir = resolve(value("--out", "benchmarks/results/libfx"));
const piRoot = value("--pi-root", process.env.LIBFX_BENCH_PI_ROOT);
if (!Number.isInteger(samples) || samples < 1 || samples > 1000) throw new Error("samples must be 1..1000");

const cases = [
  { name: "fx-node-native", command: "node", args: ["benchmarks/libfx/bench-fx.mjs", "--backend", "native", "--samples", "1", "--json"] },
  { name: "fx-node-wasm", command: "node", args: ["--experimental-wasm-jspi", "benchmarks/libfx/bench-fx.mjs", "--backend", "wasm", "--samples", "1", "--json"] },
  { name: "fx-bun-native", command: "bun", args: ["benchmarks/libfx/bench-fx.mjs", "--backend", "native", "--samples", "1", "--json"] },
  { name: "fx-bun-wasm", command: "bun", args: ["benchmarks/libfx/bench-fx.mjs", "--backend", "wasm", "--samples", "1", "--json"] },
  ...(piRoot ? [
    { name: "pi-node", command: "node", args: ["benchmarks/libfx/bench-pi.mjs", "--samples", "1", "--json"], env: { LIBFX_BENCH_PI_ROOT: piRoot } },
    { name: "pi-bun", command: "bun", args: ["benchmarks/libfx/bench-pi.mjs", "--samples", "1", "--json"], env: { LIBFX_BENCH_PI_ROOT: piRoot } },
  ] : []),
];
const reports = new Map(cases.map((entry) => [entry.name, null]));
const order = [];

for (let round = 0; round < samples; round++) {
  const shuffled = [...cases];
  for (let index = shuffled.length - 1; index > 0; index--) {
    const swap = randomInt(index + 1);
    [shuffled[index], shuffled[swap]] = [shuffled[swap], shuffled[index]];
  }
  for (const entry of shuffled) {
    order.push(entry.name);
    const { stdout } = await run(entry.command, entry.args, {
      cwd: resolve("."),
      env: { ...process.env, ...entry.env },
      maxBuffer: 4 * 1024 * 1024,
    });
    const sample = JSON.parse(stdout);
    const report = reports.get(entry.name) ?? { ...sample, samples: [] };
    report.samples.push(sample.samples[0]);
    reports.set(entry.name, report);
  }
}

await mkdir(outDir, { recursive: true });
for (const [name, report] of reports) {
  await writeFile(resolve(outDir, `${name}.json`), `${JSON.stringify(report, null, 2)}\n`);
}
await writeFile(resolve(outDir, "sample-order.json"), `${JSON.stringify({ format_version: 1, order }, null, 2)}\n`);
process.stdout.write(`wrote ${reports.size} interleaved reports with ${samples} samples each\n`);
