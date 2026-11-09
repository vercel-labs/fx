// Runs the real fx binary along tests/tla/session/TurnStream.tla: one agent
// turn of `fx ask` against a local gateway fixture, which answers each
// request with the tool calls of the scenario's next step until it ends the
// turn. fx's session trace names every stream and commit decision
// (`sessions_v2_stream`), and the session log it leaves holds the live
// turn's tool results and any superseded marker. TLC replays both through
// the model as the adapter is designed now (TurnStreamTrace.tla), in which
// a rebuild that changed nothing needs no parsing.
//
// The scenarios cover one result per step, parallel calls, failed calls,
// output full of escapes and non-ASCII text, unchanged output, file writes
// and edits, a turn that compacts in the middle, and a long turn
// (FX_TLA_STRESS_STEPS, default 200). Every saved result's stamp must fall
// between when the fixture sent its call and when fx wrote its line.
// Random walks fuzz the binary along the model: FX_TLA_WALKS turns (default
// 3) of FX_TLA_WALK_STEPS steps (default 10) from FX_TLA_SEED (default 1),
// each step one to three calls of every kind above, and about one walk in
// three with a window small enough to compact. Planted changes to a kept run
// must be rejected, and a run without decisions is no evidence at all. With
// FX_TLA_BASE_BIN set, the long turn and the compacting turn also run on that
// binary, untraced: the report compares the CPU time both spent, and both
// must leave the same log.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, testEnvironment } from "../lib/context";
import { writeJson } from "../lib/tlc";
import { checkTrace, decisions, diskObservation, diskTurn, sessionFolder, type Observation } from "./stream-bridge";

const TIMEOUT = 900_000;
const DONE = "TURN_STREAM_COMPLETE";
const MODEL = "openai/gpt-5.5";
const STRESS_STEPS = Number(process.env.FX_TLA_STRESS_STEPS ?? "200");
const WALKS = Number(process.env.FX_TLA_WALKS ?? "3");
const WALK_STEPS = Number(process.env.FX_TLA_WALK_STEPS ?? "10");
const SEED = Number(process.env.FX_TLA_SEED ?? "1");

type Call = { name: string; input: Record<string, unknown>; fails?: boolean };

/// A turn the fixture plays: the tool calls it answers request `n` (from 1)
/// with, or null to end the turn. `prepare` writes the files they read.
type Scenario = {
  name: string;
  steps: number;
  /// The model's context window. A small one makes fx compact mid-turn,
  /// since the fixture reports a request's size as its input tokens.
  contextWindow?: number;
  /// Past `steps`, the turn goes on until a request shrinks, which means fx
  /// just compacted, and this many more steps follow it, up to `steps` more.
  /// The final request then comes while the context is small, so no last cut
  /// empties the live turn, however large each request is.
  settle?: number;
  prepare(workspace: string): void;
  step(n: number, workspace: string): Call[];
};

const read = (path: string, fails = false): Call => ({ name: "read_file", input: { path }, fails });

/// Text that encodes with every kind of JSON escape and multi-byte UTF-8.
const TRICKY = [
  "quotes \" and \\backslashes\\ and /slashes/",
  "tab\tand\rreturn and \u0001 \u001f controls",
  "caf\u00e9 \u4e2d\u6587 \u{1F600} \u{10FFFF}",
  "{\"created_at_ms\":1,\"nested\":{\"created_at_ms\":2}}",
].join("\n");

const scenarios: Scenario[] = [
  {
    name: "sequential",
    steps: 12,
    prepare() {},
    step(n, workspace) {
      writeFileSync(join(workspace, "evidence.txt"), `${n} ${"x".repeat(1024)}\n`);
      return [read("evidence.txt")];
    },
  },
  {
    name: "parallel",
    steps: 5,
    prepare(workspace) {
      for (const name of ["a", "b", "c"]) writeFileSync(join(workspace, `${name}.txt`), `${name}\n`);
    },
    step: () => [read("a.txt"), read("b.txt"), read("c.txt")],
  },
  {
    name: "failures",
    steps: 8,
    prepare(workspace) {
      writeFileSync(join(workspace, "present.txt"), "present\n");
    },
    step: (n) => [n % 2 === 0 ? read(`missing-${n}.txt`, true) : read("present.txt")],
  },
  {
    name: "escapes",
    steps: 6,
    prepare(workspace) {
      writeFileSync(join(workspace, "tricky.txt"), TRICKY);
      // Past the preview limit, so the piece holds no preview.
      writeFileSync(join(workspace, "large.txt"), `${TRICKY}\n`.repeat(4096));
    },
    step: (n) => [read(n % 2 === 0 ? "large.txt" : "tricky.txt")],
  },
  {
    name: "unchanged",
    steps: 8,
    prepare(workspace) {
      writeFileSync(join(workspace, "same.txt"), "the same output every time\n");
    },
    step: () => [read("same.txt")],
  },
  {
    // A write or an edit is a committed file result, which enters the turn
    // apart from every other tool result.
    name: "files",
    steps: 6,
    prepare(workspace) {
      writeFileSync(join(workspace, "notes.txt"), "line 0\n");
    },
    step: (n) => n % 2 === 1
      ? [{ name: "write_file", input: { path: `new-${n}.txt`, content: `file ${n}\n` } }, read("notes.txt")]
      : [{ name: "edit_file", input: { path: "notes.txt", old_string: `line ${n - 2}`, new_string: `line ${n}` } }],
  },
];

/// Large reads against a small window, so fx compacts in the middle of the turn.
const compaction: Scenario = {
  name: "compaction",
  steps: 80,
  contextWindow: 24_000,
  settle: 2,
  prepare() {},
  step(n, workspace) {
    writeFileSync(join(workspace, "evidence.txt"), `${n} ${"y".repeat(8 * 1024)}\n`);
    return [read("evidence.txt")];
  },
};

const stress: Scenario = {
  name: "stress",
  steps: STRESS_STEPS,
  prepare() {},
  step(n, workspace) {
    writeFileSync(join(workspace, "evidence.txt"), `${n} ${"x".repeat(1024)}\n`);
    return [read("evidence.txt")];
  },
};

/// A small seeded generator, so a failing walk can be run again.
function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Walk `walk` from `seed`: its whole plan is drawn up front, so each
/// request's answer depends only on the request's number.
function randomWalk(seed: number, walk: number): Scenario {
  const random = mulberry32(seed * 1000 + walk);
  const compacting = random() < 1 / 3;
  const steps = compacting ? Math.max(WALK_STEPS, 40) : WALK_STEPS;
  const kinds = ["changing", "same", "tricky", "large", "missing"] as const;
  const plan = Array.from({ length: steps }, () =>
    Array.from({ length: 1 + Math.floor(random() * 3) }, () => kinds[Math.floor(random() * kinds.length)]!));
  return {
    name: `walk-${seed}-${walk}`,
    steps,
    contextWindow: compacting ? 24_000 : undefined,
    prepare(workspace) {
      writeFileSync(join(workspace, "same.txt"), "the same output every time\n");
      writeFileSync(join(workspace, "tricky.txt"), TRICKY);
      writeFileSync(join(workspace, "large.txt"), `${TRICKY}\n`.repeat(4096));
    },
    step(n, workspace) {
      return plan[n - 1]!.map((kind, index) => {
        if (kind === "changing") {
          writeFileSync(join(workspace, `changing-${index}.txt`), `${n} ${"x".repeat(compacting ? 8 * 1024 : 1024)}\n`);
          return read(`changing-${index}.txt`);
        }
        if (kind === "missing") return read(`missing-${n}-${index}.txt`, true);
        return read(`${kind}.txt`);
      });
    },
  };
}

type Run = {
  scenario: string;
  code: number;
  stdout: string;
  stderr: string;
  result: any;
  /// Each call the fixture issued, and when it sent it.
  issued: Array<{ id: string; fails: boolean; at: number }>;
  /// Summary requests the fixture answered.
  summaries: number;
  /// At each model request: the decisions fx had traced and the calls the
  /// fixture had issued, which bounds the results any decision can count.
  progress: Array<{ decisions: number; issued: number }>;
  trace: string;
  folder: string;
  cpuMs: number;
  wallMs: number;
};

/// A streamed model reply: `events`, then the finish that ends it.
function sse(events: unknown[], reason: string, inputTokens = 3): Response {
  const all = [...events, { type: "finish", finishReason: { unified: reason, raw: reason }, usage: { inputTokens: { total: inputTokens }, outputTokens: { total: 5 } } }];
  const body = all.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "Content-Type": "text/event-stream" } });
}

/// One `fx ask` turn of `scenario` on `bin`, in a fresh profile and
/// workspace. `traced` turns on fx's session trace.
async function runTurn(scenario: Scenario, bin: string, traced: boolean): Promise<Run> {
  const root = mkdtempSync(join(artifacts, `${scenario.name}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  // Titles off: a title request would take a fixture answer.
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ provider: "gateway", model: MODEL, max_agent_steps: 0, session_titles: false }));
  scenario.prepare(workspace);

  const issued: Run["issued"] = [];
  let requests = 0;
  let summaries = 0;
  // Each step's request grows the last; one that shrank followed a
  // compaction. `sinceCut` counts the steps after the last such cut past
  // `steps`, or is null until one comes.
  let lastTokens = 0;
  let sinceCut: number | null = null;
  const progress: Run["progress"] = [];
  const tracePath = join(root, "session-trace.log");
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (request.method === "GET") {
        return Response.json({ object: "list", data: [{ id: MODEL, type: "language", tags: ["tool-use"], context_window: scenario.contextWindow ?? 1_000_000 }] });
      }
      // fx writes each decision before its next request, so the trace so far
      // holds every decision made before this one.
      if (traced) {
        const sofar = existsSync(tracePath) ? decisions(readFileSync(tracePath, "utf8")).length : 0;
        progress.push({ decisions: sofar, issued: issued.length });
      }
      const text = await request.text();
      const sent = JSON.parse(text);
      // About four bytes a token, as a provider would count the request.
      const inputTokens = Math.ceil(text.length / 4);
      // A compaction asks for a summary with no tools; it is not a step.
      if (sent.tools?.length === 0 && sent.toolChoice?.type === "none") {
        summaries += 1;
        return sse([{ type: "text-delta", id: "summary", delta: `Summary ${summaries}: the files were read.` }], "stop", inputTokens);
      }
      requests += 1;
      if (sinceCut !== null) sinceCut += 1;
      if (inputTokens < lastTokens && requests > scenario.steps) sinceCut = 0;
      lastTokens = inputTokens;
      const more = requests <= scenario.steps ||
        (scenario.settle !== undefined && (sinceCut === null || sinceCut < scenario.settle) && requests <= 2 * scenario.steps);
      const calls = more ? scenario.step(requests, workspace) : [];
      // Every rebuild then runs in a new millisecond, the costly case.
      await Bun.sleep(2);
      const at = Date.now();
      const events: unknown[] = calls.map((call, index) => {
        const id = `call_${requests}_${index + 1}`;
        issued.push({ id, fails: call.fails ?? false, at });
        return { type: "tool-call", toolCallId: id, toolName: call.name, input: call.input };
      });
      if (calls.length === 0) events.push({ type: "text-delta", id: "answer", delta: DONE });
      return sse(events, calls.length > 0 ? "tool-calls" : "stop", inputTokens);
    },
  });
  const base = `http://127.0.0.1:${server.port}`;
  const env = testEnvironment({
    HOME: home,
    AI_GATEWAY_API_KEY: "fixture-key",
    FX_GATEWAY_BASE_URL: base,
    FX_TEST_GATEWAY_CHAT_URL: `${base}/chat`,
    FX_TEST_GATEWAY_MODELS_URL: `${base}/coding-agent/v1/models`,
    FX_MODEL: MODEL,
    FX_MAX_AGENT_STEPS: "0",
    ...(traced ? { FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "session" } : {}),
  });
  const started = performance.now();
  const proc = Bun.spawn([bin, "ask", "--json", "--yolo", "Read the files until the fixture finishes."], {
    cwd: workspace, env, stdout: "pipe", stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill("SIGKILL"), TIMEOUT - 60_000);
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);
  const wallMs = Math.round(performance.now() - started);
  const usage = proc.resourceUsage();
  server.stop(true);
  // Microseconds of user and system time.
  const cpuMs = usage ? Math.round((Number(usage.cpuTime.user) + Number(usage.cpuTime.system)) / 1000) : -1;
  let result: any = null;
  try {
    result = JSON.parse(stdout);
  } catch {}
  const trace = traced ? readFileSync(tracePath, "utf8") : "";
  const run: Run = { scenario: scenario.name, code, stdout, stderr, result, issued, summaries, progress, trace, folder: sessionFolder(home), cpuMs, wallMs };
  writeJson(join(root, "run.json"), { ...run, trace: undefined, stdout: undefined });
  return run;
}

/// What every turn must show, whatever the scenario: fx finished the turn,
/// ran every call the fixture issued, and kept them all, once, in order.
function expectFinishedTurn(run: Run) {
  expect(run.code).toBe(0);
  expect(run.stderr).not.toMatch(/panic|reached unreachable|Segmentation fault|error\(/);
  expect(run.result?.final_output).toBe(DONE);
  // `fx ask --json` names no call ids, and lists a step's parallel calls in
  // its own order, so its statuses are compared as counts; the log's order
  // is checked by call id below.
  const calls = run.result?.tool_calls ?? [];
  expect(calls.length).toBe(run.issued.length);
  const failed = (list: boolean[]) => list.filter(Boolean).length;
  expect(failed(calls.map((call: any) => call.status === "error"))).toBe(failed(run.issued.map((call) => call.fails)));
  const disk = diskTurn(run.folder);
  expect(disk.ended).toBe(true);
  expect(disk.superseded).toBe(0);
  expect(disk.calls).toEqual(run.issued.map((call) => call.id));
  expectStampsAreMadeTimes(run);
}

/// Each saved result's stamp is a time fx made it: after the fixture sent
/// its call, and before fx wrote the result's line.
function expectStampsAreMadeTimes(run: Run) {
  const sent = new Map(run.issued.map((call) => [call.id, call.at]));
  const disk = diskTurn(run.folder);
  disk.calls.forEach((id, index) => {
    const at = sent.get(id);
    expect(at).toBeDefined();
    expect({ id, stamp: disk.stamps[index]! >= at! }).toEqual({ id, stamp: true });
    expect({ id, stamp: disk.stamps[index]! <= disk.written[index]! }).toEqual({ id, stamp: true });
  });
}

/// What a turn's log holds, for comparing two binaries on the same turn.
function logShape(run: Run) {
  const disk = diskTurn(run.folder);
  const compacted = readFileSync(join(run.folder, "log.jsonl"), "utf8").split("\n").filter((line) => line.includes('"kind":"compacted"')).length;
  return { superseded: disk.superseded, calls: disk.calls, ended: disk.ended, compacted, summaries: run.summaries, tools: run.result?.tool_calls?.length, final: run.result?.final_output };
}

/// The run's decisions, then the session log fx left. fx sends a request
/// only after every call issued before it has its result, so a decision made
/// after a request counts at least those results (`least`), and at most the
/// calls issued before the request that followed it (`arrived`).
function observationsOf(run: Run): Observation[] {
  const decided = decisions(run.trace).map((decision, index) => ({
    ...decision,
    least: Math.max(0, ...run.progress.filter((point) => point.decisions <= index).map((point) => point.issued)),
    arrived: run.progress.find((point) => point.decisions > index)?.issued ?? run.issued.length,
  }));
  const disk = diskObservation(run.folder);
  return [...decided, { ...disk, least: 0, arrived: run.issued.length }];
}

const kept = new Map<string, { observations: Observation[]; order: string[] }>();

for (const scenario of scenarios) {
  test(`${scenario.name}: the turn is a behavior of TurnStream, and no rebuild reparses`, async () => {
    const run = await runTurn(scenario, binary, true);
    expectFinishedTurn(run);
    const observations = observationsOf(run);
    const order = run.issued.map((call) => call.id);
    kept.set(scenario.name, { observations, order });
    const verdict = await checkTrace(observations, order, join(artifacts, `${scenario.name}-tlc`));
    expect({ verdict: verdict.verdict, detail: verdict.detail }).toMatchObject({ verdict: "ACCEPTED" });
    expect(observations.reduce((sum, o) => sum + o.reparsed, 0)).toBe(0);
  }, TIMEOUT);
}

test("planted changes to a kept run are rejected, and no decisions are no evidence", async () => {
  const run = kept.get("sequential");
  expect(run).toBeDefined();
  const { observations, order } = run!;
  const decided = observations.filter((o) => o.phase !== "disk");
  const middle = decided.findIndex((o, index) => index > 2 && o.phase === "stream" && o.results > 0);
  expect(middle).toBeGreaterThan(0);
  const disk = observations.length - 1;
  const commit = observations.findIndex((o) => o.phase === "commit");
  const plant = (name: string, change: (copy: Observation[]) => Observation[]) => ({
    name,
    observations: change(observations.map((o) => ({ ...o, calls: [...o.calls] }))),
  });
  const planted = [
    plant("a rebuild that needed the parser", (copy) => (copy[middle]!.reparsed = 1, copy)),
    plant("a stream that did not stand", (copy) => (copy[middle]!.stood = false, copy)),
    plant("a result that never arrived", (copy) => (copy[middle]!.results += order.length, copy)),
    plant("a superseded marker on disk", (copy) => (copy[disk]!.superseded = 1, copy)),
    plant("two results swapped on disk", (copy) => {
      const calls = copy[disk]!.calls;
      [calls[0], calls[1]] = [calls[1]!, calls[0]!];
      return copy;
    }),
    plant("a result missing on disk", (copy) => (copy[disk]!.calls.pop(), copy)),
    plant("no commit", (copy) => copy.filter((_, index) => index !== commit)),
  ];
  const verdicts: Record<string, string> = {};
  for (const { name, observations: changed } of planted) {
    const verdict = await checkTrace(changed, order, join(artifacts, `planted-${name.replaceAll(" ", "-")}`));
    verdicts[name] = verdict.verdict;
  }
  writeJson(join(artifacts, "planted.json"), verdicts);
  for (const name of Object.keys(verdicts)) expect(`${name}: ${verdicts[name]}`).toBe(`${name}: REJECTED`);

  const empty = await checkTrace([observations[disk]!], order, join(artifacts, "planted-empty"));
  expect(empty.verdict).toBe("TOOL_ERROR");
}, TIMEOUT);

test(`a ${STRESS_STEPS}-step turn is a behavior of TurnStream, and no rebuild reparses`, async () => {
  const run = await runTurn(stress, binary, true);
  expectFinishedTurn(run);
  const observations = observationsOf(run);
  const order = run.issued.map((call) => call.id);
  const verdict = await checkTrace(observations, order, join(artifacts, "stress-tlc"));
  expect({ verdict: verdict.verdict, detail: verdict.detail }).toMatchObject({ verdict: "ACCEPTED" });
  expect(observations.reduce((sum, o) => sum + o.reparsed, 0)).toBe(0);

  const report: Record<string, unknown> = { steps: STRESS_STEPS };
  const untraced = await runTurn(stress, binary, false);
  expectFinishedTurn(untraced);
  report.candidate = { binary, cpuMs: untraced.cpuMs, wallMs: untraced.wallMs };
  const baseBin = process.env.FX_TLA_BASE_BIN;
  if (baseBin) {
    const base = await runTurn(stress, baseBin, false);
    expectFinishedTurn(base);
    report.base = { binary: baseBin, cpuMs: base.cpuMs, wallMs: base.wallMs };
    report.cpuRatio = Number((untraced.cpuMs / base.cpuMs).toFixed(3));
    report.wallRatio = Number((untraced.wallMs / base.wallMs).toFixed(3));
  }
  writeJson(join(artifacts, "stress.json"), report);
  console.log(JSON.stringify(report));
}, TIMEOUT);

// A turn that compacts: TLC replays it with each compaction as a hidden
// step, and fx's own trace must also show that a stream stops standing only
// right after a compaction cut the turn's tool steps, each of those leaves one
// superseded marker, the live turn holds the newest results in order, and
// nothing is reparsed. With FX_TLA_BASE_BIN set, that binary must leave the
// same log.
test("a turn that compacts mid-turn supersedes only where a cut shifted it, and never reparses", async () => {
  const run = await runTurn(compaction, binary, true);
  expect(run.code).toBe(0);
  expect(run.stderr).not.toMatch(/panic|reached unreachable|Segmentation fault|error\(/);
  expect(run.result?.final_output).toBe(DONE);
  let cut = false;
  let cuts = 0;
  let mismatches = 0;
  for (const line of run.trace.split("\n")) {
    if (line.includes("event=sessions_v2_compaction_cut")) {
      cut = true;
      cuts += 1;
    }
    const [decision] = decisions(line);
    if (!decision) continue;
    if (!decision.stood) {
      mismatches += 1;
      expect(cut).toBe(true);
    }
    expect(decision.reparsed).toBe(0);
    cut = false;
  }
  expect(cuts).toBeGreaterThan(0);
  const shape = logShape(run);
  expect(shape.ended).toBe(true);
  expect(shape.compacted).toBeGreaterThan(0);
  expect(shape.superseded).toBe(mismatches);
  const ids = run.issued.map((call) => call.id);
  expect(shape.calls.length).toBeGreaterThan(0);
  expect(ids.slice(ids.length - shape.calls.length)).toEqual(shape.calls);
  expectStampsAreMadeTimes(run);
  const verdict = await checkTrace(observationsOf(run), ids, join(artifacts, "compaction-tlc"));
  expect({ verdict: verdict.verdict, detail: verdict.detail }).toMatchObject({ verdict: "ACCEPTED" });
  writeJson(join(artifacts, "compaction.json"), { cuts, mismatches, shape });

  const baseBin = process.env.FX_TLA_BASE_BIN;
  if (baseBin) {
    const base = await runTurn(compaction, baseBin, false);
    expect(base.code).toBe(0);
    expect(logShape(base)).toEqual(shape);
  }
}, TIMEOUT);

for (let walk = 1; walk <= WALKS; walk++) {
  const scenario = randomWalk(SEED, walk);
  test(`random walk ${walk} from seed ${SEED} is a behavior of TurnStream, and no rebuild reparses`, async () => {
    const run = await runTurn(scenario, binary, true);
    expect(run.code).toBe(0);
    expect(run.stderr).not.toMatch(/panic|reached unreachable|Segmentation fault|error\(/);
    expect(run.result?.final_output).toBe(DONE);
    // A compacting walk may lose the call that was running at a compaction.
    if (scenario.contextWindow === undefined) expectFinishedTurn(run);
    else expectStampsAreMadeTimes(run);
    const observations = observationsOf(run);
    expect(observations.reduce((sum, o) => sum + o.reparsed, 0)).toBe(0);
    const verdict = await checkTrace(observations, run.issued.map((call) => call.id), join(artifacts, `${scenario.name}-tlc`));
    writeJson(join(artifacts, `${scenario.name}.json`), { compacting: scenario.contextWindow !== undefined, steps: scenario.steps, summaries: run.summaries, verdict: verdict.verdict });
    expect({ verdict: verdict.verdict, detail: verdict.detail }).toMatchObject({ verdict: "ACCEPTED" });
  }, TIMEOUT);
}
