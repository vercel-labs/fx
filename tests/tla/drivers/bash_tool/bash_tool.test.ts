// `bun test ./tests/tla/drivers/bash_tool/`: the bash tool's result store, checked
// on the real files, bash results, and program output, and its planted bugs. The
// test runs the gate in verify.ts. FX_TLA_BASH_TOOL_QUICK=1 runs its quick settings.
// A full run walks every step of the model on the real store.
import { expect, test } from "bun:test";
import { runGate } from "./verify.ts";

test("the real result store follows ResultStore's rules and catches its planted bugs", async () => {
  const report = await runGate({ quick: process.env.FX_TLA_BASH_TOOL_QUICK === "1" });
  expect(report.failures).toEqual([]);
}, 3_600_000);
