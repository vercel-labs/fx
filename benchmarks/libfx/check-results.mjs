#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { sampleStats } from "./workload.mjs";

const args = process.argv.slice(2);
const dirIndex = args.indexOf("--dir");
if (dirIndex < 0 || !args[dirIndex + 1]) throw new Error("usage: check-results.mjs --dir <results-directory>");
const dir = resolve(args[dirIndex + 1]);
const failures = [];

const read = async (name) => JSON.parse(await readFile(resolve(dir, name), "utf8"));
const check = (condition, message) => { if (!condition) failures.push(message); };
const validNumber = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0;

for (const runtime of ["node", "bun"]) {
  const label = runtime === "node" ? "Node" : "Bun";
  const nativeRuntime = await read(`runtime-${runtime}-native.json`);
  const wasmRuntime = await read(`runtime-${runtime}-wasm.json`);
  for (const [backend, report] of [["native", nativeRuntime], ["wasm", wasmRuntime]]) {
    check(report.warm?.prompt_to_first_text_ms?.count >= 100, `${label} ${backend} warm benchmark needs 100 samples`);
    check(report.streams?.length === 3 && report.streams.every((item) => item.samples >= 30), `${label} ${backend} stream benchmark needs 30 samples per case`);
  }
  const nativeWarm = nativeRuntime.warm.prompt_to_first_text_ms.p50;
  const wasmWarm = wasmRuntime.warm.prompt_to_first_text_ms.p50;
  if (!validNumber(nativeWarm) || !validNumber(wasmWarm)) throw new Error(`${label} warm timings are invalid`);
  check(nativeWarm <= wasmWarm + 1, `${label} native warm p50 ${nativeWarm.toFixed(3)}ms exceeds Wasm by more than 1ms`);

  const nativeBridge = await read(`bridge-${runtime}-native.json`);
  const wasmBridge = await read(`bridge-${runtime}-wasm.json`);
  check(nativeBridge.samples?.length >= 100, `${label} native bridge benchmark needs 100 samples`);
  check(wasmBridge.samples?.length >= 100, `${label} Wasm bridge benchmark needs 100 samples`);
  const nativeBridgeP50 = sampleStats(nativeBridge.samples.map((sample) => sample.tool_round_trip_ms)).p50;
  const wasmBridgeP50 = sampleStats(wasmBridge.samples.map((sample) => sample.tool_round_trip_ms)).p50;
  check(nativeBridgeP50 <= wasmBridgeP50 + 1.5, `${label} native bridge p50 ${nativeBridgeP50.toFixed(3)}ms exceeds Wasm by more than 1.5ms`);

  for (const backend of ["native", "wasm"]) {
    const capacity = await read(`capacity-${runtime}-${backend}.json`);
    const baseline = capacity.snapshots?.find((snapshot) => snapshot.stage === "baseline");
    const created = capacity.snapshots?.find((snapshot) => snapshot.stage === "created");
    const prompted = capacity.snapshots?.find((snapshot) => snapshot.stage === "prompted");
    const closing = capacity.snapshots?.find((snapshot) => snapshot.stage === "closing");
    const released = capacity.snapshots?.find((snapshot) => snapshot.stage === "closed");
    const closed = capacity.snapshots?.find((snapshot) => snapshot.stage === "server_closed");
    check(capacity.count === 25, `${label} ${backend} capacity benchmark needs 25 Agents`);
    check(capacity.failures?.length === 0, `${label} ${backend} capacity benchmark reported failures`);
    check(baseline && created && prompted && closing && released && closed, `${label} ${backend} capacity snapshots are incomplete`);
    if (!baseline || !created || !prompted || !closing || !released || !closed) continue;
    if (baseline.descriptor_count !== null && closed.descriptor_count !== null) {
      check(closed.descriptor_count <= baseline.descriptor_count + 1, `${label} ${backend} retained descriptors after close`);
    }
    if (baseline.active_handles !== null && closed.active_handles !== null) {
      check(closed.active_handles <= baseline.active_handles, `${label} ${backend} retained active handles after close`);
    }
    if (backend === "native" && closing.thread_count !== null && released.thread_count !== null) {
      check(closing.thread_count - released.thread_count >= capacity.count, `${label} native retained Agent threads after close`);
    }
    if (backend === "wasm" && baseline.external_bytes !== null && closed.external_bytes !== null) {
      check(closed.external_bytes <= baseline.external_bytes + 8 * 1024 * 1024, `${label} Wasm retained Agent external memory after close`);
    }
  }

  const competitive = await read(`competitive-${runtime}.json`);
  check(competitive.rounds?.length === 3, `${label} native versus Pi benchmark needs three rounds`);
  const expectedOrder = [["libfx", "pi"], ["pi", "libfx"], ["libfx", "pi"]];
  check(competitive.rounds?.every((round, index) => JSON.stringify(round.order) === JSON.stringify(expectedOrder[index])), `${label} native versus Pi benchmark order is not alternating`);
  check(competitive.rounds?.every((round) => round.libfx_request_count === 103 && round.pi_request_count === 103), `${label} native versus Pi benchmark made unexpected inference requests`);
  const libfxCompetitive = competitive.libfx?.prompt_to_first_text_ms;
  const piCompetitive = competitive.pi?.prompt_to_first_text_ms;
  check(libfxCompetitive?.count === 300 && piCompetitive?.count === 300, `${label} native versus Pi benchmark needs 300 samples per harness`);
  if (libfxCompetitive && piCompetitive) {
    for (const timings of [libfxCompetitive, piCompetitive]) {
      if (![timings.p50, timings.p95, timings.p99].every(validNumber)) throw new Error(`${label} competitor timings are invalid`);
    }
    if (runtime === "node") {
      console.log(`Node native versus Pi (report only): p50 ${libfxCompetitive.p50.toFixed(3)}ms / ${piCompetitive.p50.toFixed(3)}ms; p95 ${libfxCompetitive.p95.toFixed(3)}ms / ${piCompetitive.p95.toFixed(3)}ms; p99 ${libfxCompetitive.p99.toFixed(3)}ms / ${piCompetitive.p99.toFixed(3)}ms`);
    } else {
      check(libfxCompetitive.p50 <= piCompetitive.p50, `${label} native versus Pi p50 failed: ${libfxCompetitive.p50.toFixed(3)}ms > ${piCompetitive.p50.toFixed(3)}ms`);
      check(libfxCompetitive.p95 <= piCompetitive.p95 + 0.25, `${label} native versus Pi p95 failed: ${libfxCompetitive.p95.toFixed(3)}ms > ${(piCompetitive.p95 + 0.25).toFixed(3)}ms`);
    }
    check(Number.isFinite(libfxCompetitive.p99) && Number.isFinite(piCompetitive.p99), `${label} native versus Pi benchmark omitted p99`);
  }
}

if (failures.length) {
  for (const failure of failures) process.stderr.write(`libfx benchmark failed: ${failure}\n`);
  process.exit(1);
}
console.log("libfx deterministic performance contracts passed");
