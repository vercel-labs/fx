// U02 request lifecycle, step 6 at the core level: the real Zig core, driven
// by tests/tla/drivers/mcp/labs/request_lab.zig with seeded random events (late, duplicate,
// and unknown-id messages included), must produce traces that TLC accepts as
// behaviors of spec/Request.tla. The planted-bug case is a known-bad control.
// Transport-level u02 scenarios (over stdio) follow once U03 exists.

import type { Scenario } from "../scenario";

const requestTrace = { machine: "request", instance: "lab", specDir: "tests/tla/mcp", wrapper: "RequestTrace" } as const;

const seeded = (seed: number, steps: number, slots: number): Scenario => ({
  name: `u02-core-seed-${seed}`,
  unit: "U02",
  description: `Random core run: seed ${seed}, ${steps} steps, ${slots} slots; the trace is a behavior of Request.tla`,
  needs: ["request_lab"],
  command: (ctx) => [ctx.bin.request_lab, ctx.tracePath, "--seed", String(seed), "--steps", String(steps), "--slots", String(slots)],
  expect: { exit: 0, traces: [{ ...requestTrace, verdict: "ACCEPTED" }] },
});

export const scenarios: Scenario[] = [
  seeded(1, 200, 4),
  seeded(2, 200, 4),
  seeded(3, 300, 2),
  seeded(4, 300, 8),
  seeded(5, 500, 4),
  {
    name: "u02-core-planted-late-delivery",
    unit: "U02",
    description: "Known-bad control: a late response is reported as delivered again",
    needs: ["request_lab"],
    command: (ctx) => [ctx.bin.request_lab, ctx.tracePath, "--seed", "1", "--steps", "200", "--plant-bug", "late-delivery"],
    expect: { exit: 0, traces: [{ ...requestTrace, verdict: "REJECTED" }] },
  },
];
