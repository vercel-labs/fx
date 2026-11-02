// Bridge self-test. Real Zig traces from labs/trace_demo.zig plus hand-written
// controls, all checked by real TLC against tests/tla/mcp/selftest/Selftest.tla.
//
//   bun test ./tests/tla/drivers/mcp/bridge.test.ts

import { beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { checkTrace, type TraceResult } from "./bridge";

const ROOT = resolve(import.meta.dir, "../../../..");
const SPEC_DIR = join(ROOT, "tests/tla/mcp/selftest");
const TIMEOUT = 60_000;

let work: string;
let demo: string;
let counter = 0;

beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), "mcpv2-bridge-test-"));
  demo = join(work, "trace_demo");
  const build = Bun.spawnSync(
    ["zig", "build-exe", "--dep", "mcp", "-Mroot=tests/tla/drivers/mcp/labs/trace_demo.zig", "-Mmcp=src/mcp/mcp.zig", "--name", "trace_demo", `-femit-bin=${demo}`],
    { cwd: ROOT, stdout: "pipe", stderr: "pipe" },
  );
  if (build.exitCode !== 0) throw new Error(`zig build-exe failed: ${build.stderr.toString()}`);
});

function check(trace: string, machine = "selftest", wrapper = "SelftestTrace"): TraceResult {
  counter += 1;
  return checkTrace({ trace, machine, specDir: SPEC_DIR, wrapper, reportDir: join(work, `report-${counter}`) });
}

function zigTrace(...args: string[]): string {
  counter += 1;
  const path = join(work, `zig-${counter}.jsonl`);
  const run = Bun.spawnSync([demo, path, ...args], { stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) throw new Error(`trace_demo failed: ${run.stderr.toString()}`);
  return path;
}

function line(seq: number, event: string, from: string, to: string, outcomes: number): string {
  return JSON.stringify({ v: 1, seq, machine: "selftest", inst: "demo", event, from, to, effects: [], data: { outcomes } });
}

function handTrace(contents: string): string {
  counter += 1;
  const path = join(work, `hand-${counter}.jsonl`);
  writeFileSync(path, contents);
  return path;
}

describe("real Zig traces", () => {
  test("a run that follows the model is ACCEPTED", () => {
    const result = check(zigTrace("cancel_requested"));
    expect(result.verdict).toBe("ACCEPTED");
    expect(result.matched).toBe(1);
  }, TIMEOUT);

  test("events the machine refuses leave no step, and the rest is ACCEPTED", () => {
    const result = check(zigTrace("response_received", "cancel_requested"));
    expect(result.verdict).toBe("ACCEPTED");
    expect(result.steps).toBe(1);
  }, TIMEOUT);

  test("the planted late-delivery bug is REJECTED at the bad step", () => {
    const result = check(zigTrace("--allow-late-delivery", "cancel_requested", "response_received"));
    expect(result.verdict).toBe("REJECTED");
    expect(result.steps).toBe(2);
    expect(result.matched).toBe(1);
    expect(result.reason).toContain("step 2 (response_received: cancelled -> done)");
  }, TIMEOUT);
});

describe("controls", () => {
  test("an empty trace is INCONCLUSIVE", () => {
    expect(check(handTrace("")).verdict).toBe("INCONCLUSIVE");
  });

  test("a sequence gap is INCONCLUSIVE", () => {
    const result = check(handTrace(`${line(1, "cancel_requested", "pending", "cancelled", 1)}\n${line(3, "response_received", "cancelled", "done", 2)}\n`));
    expect(result.verdict).toBe("INCONCLUSIVE");
    expect(result.reason).toContain("seq 3");
  });

  test("a torn last line is INCONCLUSIVE", () => {
    expect(check(handTrace(line(1, "cancel_requested", "pending", "cancelled", 1))).verdict).toBe("INCONCLUSIVE");
  });

  test("a trace with no steps for the machine is INCONCLUSIVE", () => {
    expect(check(handTrace(`${line(1, "cancel_requested", "pending", "cancelled", 1)}\n`), "other").verdict).toBe("INCONCLUSIVE");
  });

  test("a wrong projected value is REJECTED", () => {
    const result = check(handTrace(`${line(1, "cancel_requested", "pending", "cancelled", 5)}\n`));
    expect(result.verdict).toBe("REJECTED");
    expect(result.matched).toBe(0);
  }, TIMEOUT);

  test("an unknown event is REJECTED", () => {
    expect(check(handTrace(`${line(1, "teleported", "pending", "done", 1)}\n`)).verdict).toBe("REJECTED");
  }, TIMEOUT);

  test("a missing trace wrapper is TOOL_ERROR", () => {
    expect(check(handTrace(`${line(1, "cancel_requested", "pending", "cancelled", 1)}\n`), "selftest", "NoSuchTrace").verdict).toBe("TOOL_ERROR");
  });
});
