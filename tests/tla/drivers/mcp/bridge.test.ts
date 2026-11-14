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

// The request model's grace for a refused line that names no request (Request.tla RefusedLine and
// GraceExpired). The steps are written by hand, as the Table writes them: a refused line has id 0.
describe("request grace controls", () => {
  const REQUEST_SPEC_DIR = join(ROOT, "tests/tla/mcp");
  const step = (seq: number, event: string, from: string, to: string, data: Record<string, number | boolean | string>): string =>
    JSON.stringify({ v: 1, seq, machine: "request", inst: "grace", event, from, to, effects: [], data });
  const send = (seq: number, id: number) => step(seq, "send", "unused", "inflight", { id, kind: "normal", outcome: "none", delivered: 0, cancel_sent: false, progress: 0 });
  const refused = (seq: number) => step(seq, "refused_line", "unused", "unused", { id: 0 });
  const progress = (seq: number, id: number) => step(seq, "progress_received", "inflight", "inflight", { id, kind: "normal", outcome: "none", delivered: 0, cancel_sent: false, progress: 1 });
  const expired = (seq: number, id: number) => step(seq, "grace_expired", "inflight", "done", { id, kind: "normal", outcome: "malformed", delivered: 1, cancel_sent: true, progress: 0 });
  const idle = (seq: number, id: number) => step(seq, "timer_fired", "inflight", "done", { id, kind: "normal", outcome: "timed_out", delivered: 1, cancel_sent: true, progress: 1 });
  const run = (...lines: string[]): TraceResult => {
    counter += 1;
    const path = handTrace(lines.join("\n") + "\n");
    return checkTrace({ trace: path, machine: "request", specDir: REQUEST_SPEC_DIR, wrapper: "RequestTrace", reportDir: join(work, `report-${counter}`) });
  };

  test("a silent request ends malformed with a cancel when its grace runs out: ACCEPTED", () => {
    expect(run(send(1, 1), refused(2), expired(3, 1)).verdict).toBe("ACCEPTED");
  }, TIMEOUT);

  test("progress for its own token clears the grace, and the request goes on to its own deadline: ACCEPTED", () => {
    expect(run(send(1, 1), refused(2), progress(3, 1), idle(4, 1)).verdict).toBe("ACCEPTED");
  }, TIMEOUT);

  test("a grace that runs out with no refused line before it is REJECTED", () => {
    expect(run(send(1, 1), expired(2, 1)).verdict).toBe("REJECTED");
  }, TIMEOUT);

  test("a grace that runs out after the request's own progress is REJECTED", () => {
    expect(run(send(1, 1), refused(2), progress(3, 1), expired(4, 1)).verdict).toBe("REJECTED");
  }, TIMEOUT);

  test("a request sent after the refused line gets no grace: REJECTED", () => {
    expect(run(refused(1), send(2, 1), expired(3, 1)).verdict).toBe("REJECTED");
  }, TIMEOUT);
});
