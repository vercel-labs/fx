// SubagentAccess: the real `fx ask`, in which the main agent starts a subagent
// whose shell command makes an `fx mcp call` against a small stdio server
// (tests/e2e/mcp-rules-paths.ts scripts the calls through a fake gateway).
// A tool whose server list the subagent never loaded is not one of its
// integrations, so its command is refused, as the subagent's direct call of it
// would be; after the subagent opens the tool, the list is loaded and the
// command runs. Each run is recorded as a trace, and TLC checks it against
// SubagentAccess.tla. A test named "control:" holds on the code before the fix.
import { expect, test } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetModule } from "../lib/context";
import { save } from "./driver";
import { checkTrace, type TraceRecord } from "./trace";

const { SMALL_TOOL, runPaths } = await targetModule("mcp-rules-paths.ts");

const MODEL = { ObsServers: ["a"], ObsMaxRuns: 1, ObsMaxViews: 1, ObsBridge: true };
const BRIDGE = { path: "bridge_call", tool: SMALL_TOOL };
const OPEN = { path: "open_small", tool: SMALL_TOOL };

/** The records of one run: the child opens the tool first or not, then its command calls the tool. */
async function trace(label: string, opens: boolean): Promise<TraceRecord[]> {
  const result = await runPaths({ bin: binary, mode: "full", agent: "child", rules: {}, label, only: opens ? [OPEN, BRIDGE] : [BRIDGE] });
  expect([label, result.code, result.stderr.slice(-200)]).toEqual([label, 0, result.stderr.slice(-200)]);
  const observed = (path: string) => result.observations.find((o: { path: string }) => o.path === path);
  const bridge = observed("bridge_call");
  expect(bridge, `${label}: the run never reached its command`).toBeDefined();
  const records: TraceRecord[] = [{ event: "init", data: { usable: ["a"] } }, { event: "create" }];
  if (opens) {
    expect(observed("open_small")?.shown, `${label}: the child could not open the tool`).toBe(true);
    records.push({ event: "load", data: { server: "a" } });
  }
  records.push({ event: "shell" }, { event: "bridge", data: { server: "a", n: 1, ran: bridge.shown } }, { event: "end" });
  return records;
}

async function check(name: string, records: TraceRecord[]) {
  const dir = join(artifacts, name);
  mkdirSync(dir, { recursive: true });
  save(join(dir, "records.json"), records);
  return await checkTrace({ module: "SubagentAccess", records, constants: MODEL, dir });
}

test("a subagent's command is refused a tool whose list it never loaded: the trace is ACCEPTED with the fix", async () => {
  const records = await trace("unloaded", false);
  expect(records.find((r) => r.event === "bridge")?.data?.ran).toBe(false);
  const verdict = await check("unloaded", records);
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
}, 600_000);

test("a subagent's command runs a tool after the subagent opened it: the trace is ACCEPTED", async () => {
  const records = await trace("opened", true);
  expect(records.find((r) => r.event === "bridge")?.data?.ran).toBe(true);
  const verdict = await check("opened", records);
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
}, 600_000);

test("control: a command that ran a tool whose list was never loaded is REJECTED by the model (the check catches the old bridge)", async () => {
  const records: TraceRecord[] = [
    { event: "init", data: { usable: ["a"] } },
    { event: "create" },
    { event: "shell" },
    { event: "bridge", data: { server: "a", n: 1, ran: true } },
  ];
  const verdict = await check("control-unloaded", records);
  expect([verdict.verdict, verdict.firstBad?.index]).toEqual(["REJECTED", 3]);
}, 300_000);
