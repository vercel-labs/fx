// Driver plumbing scenarios: a real Zig binary writes its trace to
// MCPV2_TRACE, and the driver checks it through the bridge. The second case is
// a known-bad control that must be REJECTED.

import type { Scenario } from "../scenario";

const selftestTrace = { machine: "selftest", specDir: "tests/tla/mcp/selftest", wrapper: "SelftestTrace" } as const;

export const scenarios: Scenario[] = [
  {
    name: "selftest-follows-model",
    unit: "S05",
    description: "Cancel a pending request; the trace is a behavior of Selftest.tla",
    needs: ["trace_demo"],
    command: (ctx) => [ctx.bin.trace_demo, ctx.tracePath, "cancel_requested", "response_received"],
    expect: { exit: 0, traces: [{ ...selftestTrace, verdict: "ACCEPTED" }] },
  },
  {
    name: "selftest-planted-late-delivery",
    unit: "S05",
    description: "Known-bad control: the binary delivers a response after a cancel",
    needs: ["trace_demo"],
    command: (ctx) => [ctx.bin.trace_demo, ctx.tracePath, "--allow-late-delivery", "cancel_requested", "response_received"],
    expect: { exit: 0, traces: [{ ...selftestTrace, verdict: "REJECTED" }] },
  },
];
