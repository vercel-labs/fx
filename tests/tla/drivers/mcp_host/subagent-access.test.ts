// SubagentAccess: a real subagent's `fx mcp call`. The fake model starts a
// subagent with a profile, and the subagent's shell command runs the call
// (tests/e2e/mcp-rules-paths.ts scripts it through a fake gateway, against a
// small stdio server a and a large HTTP server b). Each call's answer is
// recorded as a trace, and TLC checks it against SubagentAccess.tla: a call
// runs exactly when the subagent's view and the deny rules of its mode allow
// the tool, whether or not the tool's list was loaded before.
import { expect, test } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetModule } from "../lib/context";
import { save } from "./driver";
import { checkTrace, type TraceRecord, type Value } from "./trace";

const { LARGE_TOOL, OTHER_TOOL, SMALL_TOOL, runPaths, seen } = await targetModule("mcp-rules-paths.ts");

const TOOL: Record<string, { server: string; n: number }> = {
  [SMALL_TOOL]: { server: "a", n: 1 },
  [LARGE_TOOL]: { server: "b", n: 1 },
  [OTHER_TOOL]: { server: "b", n: 2 },
};
const SERVER_LETTER: Record<string, string> = { fixture: "a", big: "b" };
const MODEL: Record<string, Value> = { ObsServers: ["a", "b"], ObsMaxRuns: 1, ObsMaxViews: 1, ObsBridge: true, ObsDeniedFirst: ["a"] };

interface Scenario {
  /** The servers the subagent's profile limits it to (default: both). */
  childServers?: string[];
  /** The mode its profile sets; the host is in full access. */
  childMode?: "auto";
  /** The tools whose `fx mcp call` its command runs, in order. */
  calls: string[];
  /** What the parent ran before it started the subagent, as built-in steps. */
  parentFirst?: string[];
  /** The servers whose lists that loaded. */
  loaded?: string[];
}

async function trace(label: string, s: Scenario): Promise<TraceRecord[]> {
  const result = await runPaths({
    bin: binary, mode: "full", childMode: s.childMode, agent: "child",
    rules: { [SMALL_TOOL]: "deny" }, childServers: s.childServers,
    only: s.calls.map((tool) => `bridge_call:${tool}`), parentFirst: s.parentFirst, label,
  });
  expect([result.code, result.stderr.slice(-200)]).toEqual([0, result.stderr.slice(-200)]);
  const scope = (s.childServers ?? ["fixture", "big"]).map((name) => SERVER_LETTER[name]!);
  const mode = s.childMode ?? "full";
  return [
    { event: "init", data: { usable: ["a", "b"] } },
    ...(s.loaded ?? []).map((server): TraceRecord => ({ event: "load", data: { server } })),
    { event: "create", data: { scope, mode } },
    ...s.calls.map((tool): TraceRecord => {
      const text = seen(result, "bridge_call", tool).text;
      // Exit 5 is fx mcp call's refusal. Another exit (the host's own access check ends a call with 1) is "other", which the model does not take.
      const answer = text.includes("exit=0") ? "ran" : text.includes("exit=5") ? "refused" : "other";
      return { event: "bridge", data: { scope, mode, server: TOOL[tool]!.server, n: TOOL[tool]!.n, answer } };
    }),
  ];
}

async function check(name: string, records: TraceRecord[]) {
  const dir = join(artifacts, name);
  mkdirSync(dir, { recursive: true });
  save(join(dir, "records.json"), records);
  return await checkTrace({ module: "SubagentAccess", records, constants: MODEL, dir });
}

const accepted = async (name: string, s: Scenario) => {
  const verdict = await check(name, await trace(name, s));
  expect([verdict.verdict, verdict.broken, verdict.firstBad]).toEqual(["ACCEPTED", undefined, undefined]);
};

test("a subagent limited to the large server is refused the small server's tool and runs the large one, its list never loaded (trace ACCEPTED)", async () => {
  await accepted("outside-unloaded", { childServers: ["big"], calls: [SMALL_TOOL, LARGE_TOOL] });
}, 900_000);

test("the same, with the small server's list loaded before the subagent started (trace ACCEPTED)", async () => {
  await accepted("outside-loaded", {
    childServers: ["big"], calls: [SMALL_TOOL, LARGE_TOOL], parentFirst: [`open_small:${SMALL_TOOL}`], loaded: ["a"],
  });
}, 900_000);

test("a subagent whose profile lists no server is refused both tools (trace ACCEPTED)", async () => {
  await accepted("no-servers", { childServers: [], calls: [SMALL_TOOL, LARGE_TOOL], parentFirst: [`open_small:${SMALL_TOOL}`], loaded: ["a"] });
}, 900_000);

test("a deny rule applies in the mode the subagent runs in: it is refused the tool the rule names and runs another (trace ACCEPTED)", async () => {
  await accepted("deny-in-auto", { childMode: "auto", calls: [SMALL_TOOL, OTHER_TOOL], parentFirst: [`bridge_call:${SMALL_TOOL}`], loaded: ["a"] });
}, 900_000);

test("a subagent's first call, with no list loaded before, runs (trace ACCEPTED)", async () => {
  await accepted("first-call", { calls: [SMALL_TOOL] });
}, 900_000);

test("control: a call outside the subagent's profile that ran is REJECTED by the model", async () => {
  const records: TraceRecord[] = [
    { event: "init", data: { usable: ["a", "b"] } },
    { event: "create", data: { scope: ["b"], mode: "full" } },
    { event: "bridge", data: { scope: ["b"], mode: "full", server: "a", n: 1, answer: "ran" } },
  ];
  const verdict = await check("control-outside", records);
  expect([verdict.verdict, verdict.firstBad?.index]).toEqual(["REJECTED", 2]);
}, 300_000);

test("control: a call the view and the rules allow that was refused only because its list was not loaded is REJECTED by the model", async () => {
  const records: TraceRecord[] = [
    { event: "init", data: { usable: ["a", "b"] } },
    { event: "create", data: { scope: ["a", "b"], mode: "full" } },
    { event: "bridge", data: { scope: ["a", "b"], mode: "full", server: "a", n: 1, answer: "refused" } },
  ];
  const verdict = await check("control-unloaded", records);
  expect([verdict.verdict, verdict.firstBad?.index]).toEqual(["REJECTED", 2]);
}, 300_000);
