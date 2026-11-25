// `bun test ./tests/tla/drivers/tool_bridge/`: the bash tool's file-change
// design, checked on the real file path and its planted bugs. The test runs
// the gate in verify.ts, and FX_TLA_TOOL_BRIDGE_QUICK=1 runs its quick
// settings. A full run walks every step of the model on the real harness.
import { expect, test } from "bun:test";
import { runGate } from "./verify.ts";

test("the real file path follows ToolEdit's bridge design and catches its planted bugs", async () => {
  const report = await runGate({ quick: process.env.FX_TLA_TOOL_BRIDGE_QUICK === "1" });
  expect(report.failures).toEqual([]);
}, 3_600_000);
