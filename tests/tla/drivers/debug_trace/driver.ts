// Runs the built fx-term.wasm along tests/tla/debug_trace/TraceIds.tla and has
// TLC check every session it observes (TraceIdsTrace.tla).
//
// Each session is a fresh fx-term.wasm in a headless xterm, the way
// sdk/node/test-term-*.mjs run it, with a mock fetch for the gateway, a fake
// key, and a workspace whose shell answers every command. The mock serves a
// script of replies per turn: tool steps with one or more shell calls, with or
// without text before or after the calls, sent as bare tool-call events or
// with their input streamed (tool-input-start), and then a final answer. fx's
// own trace lines (FX_TRACE_STDERR) give the id of each turn and each step.
//
// The driver reads, under each prompt, the texts and tool blocks the screen
// shows and which calls each block holds. TLC replays the sessions through the
// model's own actions and compares the screen and which ids are equal.
// --self-check also replays them through the model of fx-term.wasm before the
// fix (Bug = "wasi_constant"), which must reject what a fixed build shows; on
// the build before the fix it accepts them while the design rejects them.
//
// The fixed set holds every turn of up to two tool steps with one or two calls
// and every mix of text and streaming, 24 turns to a session. --fuzz N adds N
// seeded random sessions of up to 6 turns, 4 tool steps, and 3 calls; a
// session the model rejects is saved with its seed. --stress N adds one
// session of N turns with 4 tool steps each, text before every step.
//
// Usage (from the repository root, after zig build fx-term-wasm
// -Dwasm-surface=term and npm ci --prefix sdk/node):
//   bun tests/tla/drivers/debug_trace/driver.ts
//   bun tests/tla/drivers/debug_trace/driver.ts --self-check
//   bun tests/tla/drivers/debug_trace/driver.ts --fixed 0 --fuzz 40 --seed 7
//   bun tests/tla/drivers/debug_trace/driver.ts --fixed 0 --stress 60
//   bun tests/tla/drivers/debug_trace/driver.ts --wasm /path/to/fx-term.wasm
//
// Exit codes: 0 every session accepted (and the self-check rejected), 1 a
// session the model cannot produce, 2 a toolchain, build, or harness failure.
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { REPO_ROOT, TLA_ROOT, outDir, tlcToolchain, writeJson } from "../lib/tlc";

type Step = { final: boolean; n: number; before: boolean; after: boolean; streamed: boolean };
type Item = { kind: "text" | "block" | "unknown"; turn: number; step: number; where: string; calls: number[][] };
type Session = {
  id: string;
  script: Step[][];
  screen: Item[][];
  turnIds: number[];
  stepIds: number[];
  posts: number;
  seconds: number;
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const tlaDir = join(TLA_ROOT, "debug_trace");
const MODEL = "test/debug-trace-model";

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

function stringOption(name: string): string | null {
  const at = process.argv.indexOf(name);
  return at < 0 ? null : (process.argv[at + 1] ?? null);
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  fixed: option("--fixed", 1),
  fuzz: option("--fuzz", 0),
  seed: option("--seed", 1),
  stress: option("--stress", 0),
  wasm: resolve(stringOption("--wasm") ?? process.env.FX_TERM_WASM ?? join(REPO_ROOT, "zig-out", "bin", "fx-term.wasm")),
};

// mulberry32: a small seeded generator, so a failing fuzz session replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const FINAL: Step = { final: true, n: 0, before: false, after: false, streamed: false };

function toolSteps(calls: number[]): Step[] {
  const steps: Step[] = [];
  for (const n of calls) {
    for (const before of [false, true]) {
      for (const after of [false, true]) {
        for (const streamed of [false, true]) steps.push({ final: false, n, before, after, streamed });
      }
    }
  }
  return steps;
}

// Every turn of up to two tool steps with one or two calls each.
function fixedTurns(): Step[][] {
  const kinds = toolSteps([1, 2]);
  const turns: Step[][] = [[FINAL]];
  for (const a of kinds) turns.push([a, FINAL]);
  for (const a of kinds) for (const b of kinds) turns.push([a, b, FINAL]);
  return turns;
}

function chunk<T>(values: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let at = 0; at < values.length; at += size) out.push(values.slice(at, at + size));
  return out;
}

function fuzzSessions(count: number, seed: number): Step[][][] {
  const random = generator(seed);
  const pick = (n: number) => Math.floor(random() * n);
  const sessions: Step[][][] = [];
  for (let s = 0; s < count; s += 1) {
    const turns: Step[][] = [];
    for (let t = 0, turnCount = 1 + pick(6); t < turnCount; t += 1) {
      const steps: Step[] = [];
      for (let j = 0, stepCount = pick(5); j < stepCount; j += 1) {
        steps.push({ final: false, n: 1 + pick(3), before: random() < 0.5, after: random() < 0.5, streamed: random() < 0.5 });
      }
      steps.push(FINAL);
      turns.push(steps);
    }
    sessions.push(turns);
  }
  return sessions;
}

function stressSession(turnCount: number): Step[][] {
  const turns: Step[][] = [];
  for (let t = 0; t < turnCount; t += 1) {
    const steps: Step[] = [];
    for (let j = 0; j < 4; j += 1) steps.push({ final: false, n: 2, before: true, after: false, streamed: j % 2 === 1 });
    steps.push(FINAL);
    turns.push(steps);
  }
  return turns;
}

const callLabel = (t: number, j: number, c: number) => `t${t}s${j}c${c}`;
const textLabel = (t: number, j: number, where: string) => `t${t}s${j}-${where}`;

function sse(events: unknown[]): Response {
  return new Response(`${events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join("")}data: [DONE]\n\n`, {
    headers: { "content-type": "text/event-stream" },
  });
}

// The reply for step j (1-based) of turn t. Text ahead of the calls never ends
// a line; text behind them starts one, so the two never share a row.
function reply(t: number, j: number, step: Step): Response {
  if (step.final) {
    return sse([
      { type: "text-delta", delta: textLabel(t, j, "final") },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
    ]);
  }
  const events: unknown[] = [];
  if (step.before) events.push({ type: "text-delta", delta: textLabel(t, j, "before") });
  for (let c = 1; c <= step.n; c += 1) {
    const id = `call-${t}-${j}-${c}`;
    const input = { action: "run", command: `echo ${callLabel(t, j, c)}` };
    if (step.streamed) {
      events.push(
        { type: "tool-input-start", id, toolName: "shell" },
        { type: "tool-input-delta", id, delta: JSON.stringify(input) },
        { type: "tool-input-end", id },
        { type: "tool-call", toolCallId: id, toolName: "shell" },
      );
    } else {
      events.push({ type: "tool-call", toolCallId: id, toolName: "shell", input });
    }
  }
  if (step.after) events.push({ type: "text-delta", delta: `\n${textLabel(t, j, "after")}` });
  events.push({ type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } });
  return sse(events);
}

type Sdk = {
  createFxTerminal: (options: Record<string, unknown>) => Promise<{ write(text: string): void; exited: Promise<number>; abort?: () => void }>;
  supportsJspi: () => boolean;
  xtermAdapter: (terminal: unknown) => unknown;
  Terminal: new (options: Record<string, unknown>) => any;
};

async function loadSdk(): Promise<Sdk> {
  const xtermPath = join(REPO_ROOT, "sdk", "node", "node_modules", "@xterm", "headless", "lib-headless", "xterm-headless.js");
  if (!existsSync(xtermPath)) throw new Error(`missing ${xtermPath}; run npm ci --prefix sdk/node`);
  const sdk = await import(pathToFileURL(join(REPO_ROOT, "sdk", "node.js")).href);
  const xterm = (await import(pathToFileURL(xtermPath).href)).default;
  return { createFxTerminal: sdk.createFxTerminal, supportsJspi: sdk.supportsJspi, xtermAdapter: sdk.xtermAdapter, Terminal: xterm.Terminal };
}

const BLOCK_HEADER = /^● (\d+) tool calls? · /;
const BLOCK_CALL = /^([├└]) Ran echo t(\d+)s(\d+)c(\d+)$/;
const TEXT = /^\s+t(\d+)s(\d+)-(before|after|final)$/;
const TIMING = /\(↑\d+ ↓\d+\)$/;

function unknownItem(t: number, line: string): Item {
  return { kind: "unknown", turn: t, step: 0, where: line.replace(/[^A-Za-z0-9 .:-]/g, "?").slice(0, 80), calls: [] };
}

// What the screen shows under each prompt, as TraceIds' Screen writes it.
function readScreen(lines: string[], turns: number): Item[][] {
  const screen: Item[][] = Array.from({ length: turns }, () => []);
  let turn = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i]!.trimEnd();
    const prompt = /^┃ turn (\d+) go$/.exec(line);
    if (prompt) {
      turn = Number(prompt[1]);
      continue;
    }
    if (line.startsWith("┃")) {
      turn = 0;
      continue;
    }
    if (turn < 1 || turn > turns || line.trim() === "" || TIMING.test(line)) continue;
    const items = screen[turn - 1]!;
    const header = BLOCK_HEADER.exec(line);
    if (header) {
      const calls: number[][] = [];
      let closed = false;
      while (!closed && i + 1 < lines.length) {
        const call = BLOCK_CALL.exec(lines[i + 1]!.trimEnd());
        if (!call) break;
        i += 1;
        calls.push([Number(call[2]), Number(call[3]), Number(call[4])]);
        closed = call[1] === "└";
      }
      items.push(closed && calls.length === Number(header[1])
        ? { kind: "block", turn, step: 0, where: "", calls }
        : unknownItem(turn, line));
      continue;
    }
    const text = TEXT.exec(line);
    if (text && Number(text[1]) === turn) {
      items.push({ kind: "text", turn, step: Number(text[2]), where: text[3]!, calls: [] });
      continue;
    }
    items.push(unknownItem(turn, line));
  }
  return screen;
}

// The ids fx's trace lines give each turn and step. A trace line leaves out an
// id of 0, so a missing id reads as 0.
function readIds(stderr: string): { turnIds: number[]; stepIds: number[] } {
  const turnIds: number[] = [];
  const stepIds: number[] = [];
  for (const line of stderr.split("\n")) {
    if (line.includes(" event=prompt_start")) turnIds.push(Number(/ turn_id=(\d+)/.exec(line)?.[1] ?? 0));
    if (line.includes(" event=step_begin")) stepIds.push(Number(/ step_id=(\d+)/.exec(line)?.[1] ?? 0));
  }
  return { turnIds, stepIds };
}

async function runSession(sdk: Sdk, wasm: Uint8Array, id: string, script: Step[][]): Promise<Session> {
  const started = performance.now();
  const home = mkdtempSync(join(tmpdir(), "fx-debug-trace-home-"));
  const terminal = new sdk.Terminal({ cols: 120, rows: 40, allowProposedApi: true, scrollback: 200_000 });
  const catalog = {
    object: "list",
    data: [{ id: MODEL, type: "language", released: 1, tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }],
  };
  const config = new Map([["model", MODEL], ["mode", "auto"]]);
  const decoder = new TextDecoder();
  let posts = 0;
  let stderr = "";
  const fetch = async (_url: string, init: { method?: string; body?: Uint8Array } = {}) => {
    if ((init.method || "GET") === "GET") {
      return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
    }
    posts += 1;
    const body = JSON.parse(decoder.decode(init.body));
    const prompt: { role: string; content: unknown }[] = body.prompt ?? [];
    let lastUser = -1;
    for (let i = prompt.length - 1; i >= 0; i -= 1) {
      if (prompt[i]!.role === "user") {
        lastUser = i;
        break;
      }
    }
    const t = Number(/turn (\d+) go/.exec(JSON.stringify(prompt[lastUser]?.content ?? ""))?.[1]);
    const j = prompt.slice(lastUser + 1).filter((m) => m.role === "assistant").length + 1;
    const step = script[t - 1]?.[j - 1];
    if (!step) throw new Error(`${id}: no reply scripted for turn ${t} step ${j}`);
    return reply(t, j, step);
  };
  const runtime = await sdk.createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: sdk.xtermAdapter(terminal),
    env: {
      AI_GATEWAY_API_KEY: "fake-debug-trace-key",
      FX_HOME: home,
      FX_SOUND: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
      FX_TRACE_STDERR: "1",
      FX_TRACE_SCOPES: "agent",
    },
    fetch,
    stderr(chunk: Uint8Array) {
      stderr += decoder.decode(chunk, { stream: true });
    },
    configStore: { get(key: string) { return config.get(key) ?? null; }, set(key: string, value: string) { config.set(key, value); } },
    workspace: {
      info: { version: 1, root: "/workspace", cwd: "/workspace", home: "/home/visitor", gitAvailable: false, ephemeral: true },
      permission: "allow-sandboxed",
      exec({ command }: { command: string }) {
        return { stdout: `${command} done\n`, stderr: "", exitCode: 0 };
      },
    },
  });
  const flush = () => new Promise<void>((done) => terminal.write("", done));
  const lines = () => {
    const out: string[] = [];
    for (let row = 0; row < terminal.buffer.active.length; row += 1) {
      out.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    }
    return out;
  };
  const waitFor = async (predicate: () => boolean, label: string) => {
    const deadline = performance.now() + 20_000;
    while (!predicate()) {
      await flush();
      if (performance.now() >= deadline) throw new Error(`${id}: timed out waiting for ${label}:\n${lines().slice(-40).join("\n")}`);
      await new Promise((done) => setTimeout(done, 5));
    }
  };
  try {
    await waitFor(() => lines().some((line) => line.includes("Run /help for commands")), "startup");
    for (let t = 1; t <= script.length; t += 1) {
      runtime.write(`turn ${t} go\r`);
      const final = textLabel(t, script[t - 1]!.length, "final");
      // The turn has ended when its answer and the timing line under it show.
      await waitFor(() => {
        const shown = lines();
        const at = shown.findIndex((line) => line.trim() === final);
        return at >= 0 && shown.slice(at + 1).some((line) => TIMING.test(line.trimEnd()));
      }, `turn ${t}`);
    }
    await flush();
    const screen = readScreen(lines(), script.length);
    const ids = readIds(stderr);
    runtime.write("/exit\r");
    await Promise.race([runtime.exited, new Promise((done) => setTimeout(done, 5000))]);
    return { id, script, screen, ...ids, posts, seconds: Math.round(performance.now() - started) / 1000 };
  } finally {
    terminal.dispose?.();
    rmSync(home, { recursive: true, force: true });
  }
}

const bool = (value: boolean) => (value ? "TRUE" : "FALSE");
const str = (value: string) => JSON.stringify(value);
const seq = (values: string[]) => `<<${values.join(", ")}>>`;

function stepValue(step: Step): string {
  return `[final |-> ${bool(step.final)}, n |-> ${step.n}, before |-> ${bool(step.before)}, after |-> ${bool(step.after)}, streamed |-> ${bool(step.streamed)}]`;
}

function itemValue(item: Item): string {
  return `[kind |-> ${str(item.kind)}, turn |-> ${item.turn}, step |-> ${item.step}, where |-> ${str(item.where)}, calls |-> ${seq(item.calls.map((call) => seq(call.map(String))))}]`;
}

function observedModule(sessions: Session[]): string {
  const value = (s: Session) =>
    `[script |-> ${seq(s.script.map((turn) => seq(turn.map(stepValue))))},\n   screen |-> ${seq(s.screen.map((turn) => seq(turn.map(itemValue))))},\n   turnIds |-> ${seq(s.turnIds.map(String))}, stepIds |-> ${seq(s.stepIds.map(String))}]`;
  return [
    "--------------------------- MODULE TraceIdsObserved ---------------------------",
    "(* Generated by tests/tla/drivers/debug_trace/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${sessions.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(sessions: Session[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  for (const file of ["TraceIds.tla", "TraceIdsTrace.tla"]) copyFileSync(join(tlaDir, file), join(dir, file));
  writeFileSync(join(dir, "TraceIdsObserved.tla"), observedModule(sessions));
  const turns = Math.max(1, ...sessions.map((s) => s.script.length));
  const steps = Math.max(1, ...sessions.flatMap((s) => s.script.map((turn) => turn.length)));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Turns = ${turns}`,
    `  Steps = ${steps}`,
    "  Calls = 3",
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const child = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss16m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "TraceIdsTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return { verdict: "ACCEPTED", dir };
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first session the model cannot produce: the shortest rejected prefix.
async function firstMismatch(sessions: Session[], bug: string, parent: string): Promise<Session | null> {
  let low = 1;
  let high = sessions.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(sessions.slice(0, middle), bug, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return sessions[low - 1] ?? null;
}

async function main(): Promise<number> {
  if (!existsSync(options.wasm)) {
    console.log(`TOOL_ERROR: missing ${options.wasm}; run zig build fx-term-wasm -Dwasm-surface=term`);
    return 2;
  }
  const sdk = await loadSdk();
  if (!sdk.supportsJspi()) {
    console.log("TOOL_ERROR: this runtime has no JavaScript Promise Integration");
    return 2;
  }
  const wasm = readFileSync(options.wasm);
  const out = outDir("debug_trace");
  const cases: { id: string; script: Step[][] }[] = [];
  if (options.fixed) chunk(fixedTurns(), 24).forEach((script, i) => cases.push({ id: `fixed${i}`, script }));
  fuzzSessions(options.fuzz, options.seed).forEach((script, i) => cases.push({ id: `fuzz${options.seed}.${i}`, script }));
  if (options.stress > 0) cases.push({ id: `stress${options.stress}`, script: stressSession(options.stress) });
  if (cases.length === 0) {
    console.log("TOOL_ERROR: no sessions to run");
    return 2;
  }

  const started = performance.now();
  const sessions: Session[] = [];
  for (const { id, script } of cases) {
    const session = await runSession(sdk, wasm, id, script);
    const steps = script.reduce((sum, turn) => sum + turn.length, 0);
    // A session the gateway did not see whole says nothing about the ids.
    if (session.posts !== steps || session.turnIds.length !== script.length || session.stepIds.length !== steps) {
      console.log(`TOOL_ERROR: ${id}: gateway saw ${session.posts} of ${steps} requests, trace gave ` +
        `${session.turnIds.length} of ${script.length} turn ids and ${session.stepIds.length} of ${steps} step ids`);
      writeJson(join(out, "harness-failure.json"), session);
      return 2;
    }
    sessions.push(session);
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  const turns = sessions.reduce((sum, s) => sum + s.script.length, 0);
  const posts = sessions.reduce((sum, s) => sum + s.posts, 0);
  writeJson(join(out, "sessions.json"), sessions);
  console.log(`${sessions.length} sessions, ${turns} turns, ${posts} gateway requests of ${options.wasm} in ${seconds}s`);
  if (options.fuzz > 0) console.log(`fuzz: ${options.fuzz} sessions from seed ${options.seed}`);
  if (options.stress > 0) {
    const stress = sessions.at(-1)!;
    console.log(`stress: ${stress.script.length} turns, ${stress.posts} requests, ${stress.screen.flat().filter((i) => i.kind === "block").length} blocks, ` +
      `${stress.seconds}s, last turn id ${stress.turnIds.at(-1)}, last step id ${stress.stepIds.at(-1)}`);
  }
  console.log(`sessions: ${join(out, "sessions.json")}`);

  const unknown = sessions.find((s) => s.screen.flat().some((item) => item.kind === "unknown"));
  if (unknown) console.log(`note: ${unknown.id} shows a line the driver cannot read; the model rejects it`);

  const design = await runTrace(sessions, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  // The model of fx-term.wasm before the fix must reject what a fixed build
  // shows, and accept what the build before the fix shows.
  const before = options.selfCheck ? await runTrace(sessions, "wasi_constant", out) : null;
  if (before) console.log(`self-check, the model of fx-term.wasm before the fix: ${before.verdict} (TLC work ${before.dir})`);
  if (before?.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(sessions, "none", out);
    if (mismatch) {
      writeJson(join(out, "first-mismatch.json"), mismatch);
      console.log(`first session the model cannot produce (${join(out, "first-mismatch.json")}): ${mismatch.id}`);
      console.log(`  turn ids ${JSON.stringify(mismatch.turnIds)}, step ids ${JSON.stringify(mismatch.stepIds)}`);
      if (mismatch.id.startsWith("fuzz")) console.log(`  replay: bun tests/tla/drivers/debug_trace/driver.ts --fixed 0 --fuzz ${options.fuzz} --seed ${options.seed}`);
    }
    console.log("REJECTED");
    return 1;
  }
  if (before && before.verdict !== "REJECTED") {
    console.log("REJECTED: the model of fx-term.wasm before the fix also accepts these sessions");
    return 1;
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
