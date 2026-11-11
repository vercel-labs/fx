// McpRules: the real `fx ask`, in full access, auto and ask, with a deny rule
// on MCP tools, against a small stdio server and a large HTTP server
// (tests/e2e/mcp-rules-paths.ts scripts the model's calls through a fake
// gateway). Each path's answer for each tool is recorded as a trace, and
// TLC checks it against McpRules.tla: in full access no path hides a tool
// the access allows, in ask and auto every path hides a denied one, and all
// paths agree. A test named "control:" holds on the code before the fix.
import { expect, test } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetModule } from "../lib/context";
import { save } from "./driver";
import { checkTrace, type TraceRecord, type Value } from "./trace";

const { LARGE_TOOL, OTHER_TOOL, SMALL_TOOL, runPaths } = await targetModule("mcp-rules-paths.ts");

const LETTER: Record<string, string> = { [SMALL_TOOL]: "a", [LARGE_TOOL]: "b", [OTHER_TOOL]: "c" };
const MODEL: Record<string, Value> = { ObsTools: ["a", "b", "c"], ObsOwnRules: [] };

type Mode = "full" | "auto" | "ask";
const MODE_NAME: Record<Mode, string> = { full: "full", auto: "auto", ask: "ask" };

/** `childMode` is the mode a subagent runs in: its profile's, else `mode`. */
interface Run { mode: Mode; childMode?: Mode; agent: "main" | "child"; rules: Record<string, unknown>; denied: string[]; view: string[]; childServers?: string[]; readOnly?: boolean }

async function trace(label: string, runs: Run[]): Promise<TraceRecord[]> {
  const records: TraceRecord[] = [];
  let previous: Mode | null = null;
  let previousChild: Mode | null = null;
  for (const run of runs) {
    const result = await runPaths({ bin: binary, mode: run.mode, childMode: run.childMode, agent: run.agent, rules: run.rules, childServers: run.childServers, readOnly: run.readOnly, label });
    expect([run.mode, run.agent, result.code, result.stderr.slice(-200)]).toEqual([run.mode, run.agent, 0, result.stderr.slice(-200)]);
    if (previous === null) records.push({ event: "init", data: { mode: MODE_NAME[run.mode], childMode: MODE_NAME[run.childMode ?? run.mode], denied: run.denied, view: run.view } });
    else if (previous !== run.mode) records.push({ event: "mode", data: { mode: MODE_NAME[run.mode] } });
    // A new subagent in another mode than the last one.
    const childMode = run.childMode ?? run.mode;
    if (run.agent === "child" && previousChild !== null && previousChild !== childMode) records.push({ event: "child", data: { mode: MODE_NAME[childMode] } });
    previous = run.mode;
    if (run.agent === "child") previousChild = childMode;
    else if (previousChild === null) previousChild = run.childMode ?? run.mode;
    for (const o of result.observations as Array<{ path: string; tool: string; shown: boolean }>) {
      records.push({ event: "ask", data: { path: o.path, agent: run.agent, tool: LETTER[o.tool]!, answer: o.shown ? "shown" : "hidden" } });
    }
  }
  return records;
}

async function check(name: string, records: TraceRecord[]) {
  const dir = join(artifacts, name);
  mkdirSync(dir, { recursive: true });
  save(join(dir, "records.json"), records);
  return await checkTrace({ module: "McpRules", records, constants: MODEL, dir });
}

const DENY_AB = { [SMALL_TOOL]: "deny", [LARGE_TOOL]: "deny" };
const ALL = ["a", "b", "c"];

test("the main agent in full access, then auto, then ask: every path follows the model (trace ACCEPTED with the fix)", async () => {
  const records = await trace("main", [
    { mode: "full", agent: "main", rules: DENY_AB, denied: ["a", "b"], view: ALL },
    { mode: "auto", agent: "main", rules: DENY_AB, denied: ["a", "b"], view: ALL },
    { mode: "ask", agent: "main", rules: DENY_AB, denied: ["a", "b"], view: ALL, readOnly: true },
  ]);
  const verdict = await check("main", records);
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
}, 900_000);

test("a subagent in full access, then auto: every path follows the model, the integrations list included (trace ACCEPTED with the fix)", async () => {
  const records = await trace("child", [
    { mode: "full", agent: "child", rules: DENY_AB, denied: ["a", "b"], view: ALL },
    { mode: "auto", agent: "child", rules: DENY_AB, denied: ["a", "b"], view: ALL },
  ]);
  const verdict = await check("child", records);
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
}, 900_000);

test("a subagent limited to the large server, in full access: its access holds and only the rule goes (trace ACCEPTED with the fix)", async () => {
  const records = await trace("limited", [
    { mode: "full", agent: "child", rules: { [SMALL_TOOL]: "deny", [LARGE_TOOL]: "deny" }, denied: ["a", "b"], view: ["b", "c"], childServers: ["big"] },
  ]);
  const verdict = await check("limited", records);
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
}, 900_000);

test("a subagent whose profile sets its own mode: the host's list follows the mode the child runs in (trace ACCEPTED with the fix)", async () => {
  // The host in auto and the child in full access, then the host in full access and the child in auto.
  const records = await trace("mixed", [
    { mode: "auto", childMode: "full", agent: "child", rules: DENY_AB, denied: ["a", "b"], view: ALL },
  ]);
  const verdict = await check("mixed-up", records);
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
  const down = await trace("mixed-down", [
    { mode: "full", childMode: "auto", agent: "child", rules: DENY_AB, denied: ["a", "b"], view: ALL },
  ]);
  const downVerdict = await check("mixed-down", down);
  expect([downVerdict.verdict, downVerdict.broken, downVerdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
}, 900_000);

test("control: a path that hides a tool in full access is REJECTED by the model (the check catches the old split)", async () => {
  const records: TraceRecord[] = [
    { event: "init", data: { mode: "full", childMode: "full", denied: ["a"], view: ALL } },
    { event: "ask", data: { path: "search", agent: "main", tool: "a", answer: "shown" } },
    { event: "ask", data: { path: "run", agent: "main", tool: "a", answer: "hidden" } },
  ];
  const verdict = await check("control-split", records);
  expect([verdict.verdict, verdict.firstBad?.index]).toEqual(["REJECTED", 2]);
}, 300_000);

test("control: a denied tool shown in auto is REJECTED by the model", async () => {
  const records: TraceRecord[] = [
    { event: "init", data: { mode: "auto", childMode: "auto", denied: ["a"], view: ALL } },
    { event: "ask", data: { path: "bridge_call", agent: "main", tool: "a", answer: "shown" } },
  ];
  const verdict = await check("control-auto", records);
  expect([verdict.verdict, verdict.firstBad?.index]).toEqual(["REJECTED", 1]);
}, 300_000);
