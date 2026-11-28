// Runs the real fx acp along tests/tla/session/HistoryLoad.tla, design "b"
// (HistoryLoadTrace.tla). One fx saves a chat of 12 turns, about 12 KB each,
// against a local fake provider. A second fx loads it with
// `_meta.fx.historyPages`; once the load answers, the client starts a turn
// whose reply the fake provider holds, asks `_fx/session/history` for older
// pages to the log's start while that turn runs, and then lets the turn end.
// What the client would show after each message is an observation: each turn
// of the newest page, the bottom marker, the load's reply, each page, and the
// live turn. TLC checks the run against the model, with the model's page
// starts taken from where fx started each page (TCut), and checks
// BottomBounded, LoadBounded, TranscriptExact, BottomIsNewest,
// LiveBelowHistory and NoSilentGap on every state on the way.
//
// Planted changes to the kept trace must be rejected, and with
// FX_TLA_BASE_BIN set to an fx built before history pages, its run must break
// BottomBounded: it sends the whole history before the bottom screen.
import { expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetModule, testEnvironment } from "../lib/context";
import { runTlc, sha256File, sha256Text, TLA_ROOT, writeJson } from "../lib/tlc";

const { createConfiguredProviderFixture, completion } = await targetModule("fixtures/chat-completions.ts");

const SPEC_DIR = join(TLA_ROOT, "session");
const SPECS = ["HistoryLoad.tla", "HistoryLoadTrace.tla"];
const TURNS = 12;
const STEP_TIMEOUT_MS = 30_000;
const HISTORY_KINDS = new Set(["user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan"]);

type Observation = { at: string; view: number[]; live: number[]; bottom: boolean; replied: boolean; more: boolean };
type Run = { observations: Observation[]; cut: Array<[number, number]>; advertised: boolean };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type TraceResult = { verdict: Verdict; violated: string | null; length: number; matched: number; detail: string; hashes: Record<string, string> };

/// One `fx acp` process: what it wrote, one parsed message a line, in order.
class Acp {
  readonly lines: any[] = [];
  private readonly proc: ChildProcess;
  private buffer = "";
  private nextId = 1;
  private stderrText = "";
  private readonly exited: Promise<number | null>;

  constructor(bin: string, cwd: string, env: Record<string, string>) {
    this.proc = spawn(bin, ["acp"], { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
    this.proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString("utf8");
      const parts = this.buffer.split("\n");
      this.buffer = parts.pop() ?? "";
      for (const part of parts) if (part.trim()) this.lines.push(JSON.parse(part));
    });
    this.proc.stderr!.on("data", (chunk: Buffer) => (this.stderrText += chunk.toString("utf8")));
    this.exited = new Promise((resolve) => this.proc.on("close", (code) => resolve(code)));
  }

  /// Sends a request and returns its id at once.
  send(method: string, params: object): number {
    const id = this.nextId++;
    this.proc.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return id;
  }

  async answer(id: number, timeoutMs = STEP_TIMEOUT_MS): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const found = this.lines.find((line) => line.id === id && !line.method);
      if (found) {
        if (found.error) throw new Error(`request ${id} failed: ${JSON.stringify(found.error)}\n${this.stderrText}`);
        return found.result;
      }
      if (Date.now() > deadline) throw new Error(`no answer to request ${id} after ${timeoutMs} ms\n${this.stderrText}`);
      await Bun.sleep(5);
    }
  }

  async request(method: string, params: object): Promise<any> {
    return await this.answer(this.send(method, params));
  }

  async close(): Promise<number | null> {
    this.proc.stdin!.end();
    const code = await Promise.race([this.exited, Bun.sleep(STEP_TIMEOUT_MS).then(() => "timeout" as const)]);
    if (code === "timeout") {
      this.proc.kill("SIGKILL");
      throw new Error("fx acp did not exit after its input closed");
    }
    return code;
  }
}

function paragraphs(label: string): string {
  return Array.from({ length: 6 }, (_, i) => `${label} paragraph ${i} ${"x".repeat(2000)}`).join("\n\n");
}

function lastUserText(body: any): string {
  const users = (body?.messages ?? []).filter((m: any) => m.role === "user");
  return JSON.stringify(users.at(-1)?.content ?? "");
}

function definedEnv(env: Record<string, string | undefined>): Record<string, string> {
  return testEnvironment(Object.fromEntries(Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined)));
}

/// Saves a chat of TURNS turns with `bin`, loads it again with history pages,
/// pages to the top while a live turn runs, and returns what the client saw.
async function runOnce(bin: string, name: string): Promise<Run> {
  let release: () => void = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  const fixture = createConfiguredProviderFixture((body: any) => {
    if (JSON.stringify(body).includes("short title")) return completion(body.model, "History pages");
    const text = lastUserText(body);
    if (text.includes("history live turn")) return held.then(() => completion(body.model, "the live reply"));
    const turn = /history turn (\d+)/.exec(text);
    if (!turn) return completion(body.model, "unexpected request");
    return completion(body.model, paragraphs(`reply ${turn[1]}`));
  });
  const dir = join(artifacts, name);
  mkdirSync(dir, { recursive: true });
  const env = definedEnv(fixture.env);
  try {
    const writer = new Acp(bin, fixture.workspace, env);
    await writer.request("initialize", { protocolVersion: 1 });
    const created = await writer.request("session/new", { cwd: fixture.workspace, mcpServers: [] });
    const sessionId: string = created.sessionId;
    for (let i = 0; i < TURNS; i++) {
      const done = await writer.request("session/prompt", { sessionId, prompt: [{ type: "text", text: `history turn ${i}` }] });
      expect(done.stopReason).toBe("end_turn");
    }
    expect(await writer.close()).toBe(0);

    const reader = new Acp(bin, fixture.workspace, env);
    const init = await reader.request("initialize", { protocolVersion: 1 });
    const advertised = init.agentCapabilities?._meta?.fx?.historyPages === true;
    const from = reader.lines.length;
    const loadId = reader.send("session/load", { sessionId, cwd: fixture.workspace, mcpServers: [], _meta: { fx: { historyPages: true } } });
    const loaded = await reader.answer(loadId);
    const promptId = reader.send("session/prompt", { sessionId, prompt: [{ type: "text", text: "history live turn" }] });
    const pageIds = new Set<number>();
    let cursor = loaded._meta?.fx?.historyCursor ?? null;
    while (cursor) {
      const id = reader.send("_fx/session/history", { sessionId, cursor });
      pageIds.add(id);
      cursor = (await reader.answer(id)).cursor;
      expect(pageIds.size).toBeLessThan(50);
    }
    release();
    expect((await reader.answer(promptId)).stopReason).toBe("end_turn");
    expect(await reader.close()).toBe(0);
    const lines = reader.lines.slice(from);
    writeFileSync(join(dir, "lines.jsonl"), lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
    const run = { ...observe(lines, loadId, pageIds), advertised };
    writeJson(join(dir, "observations.json"), run);
    return run;
  } finally {
    release();
    fixture.close();
  }
}

/// The turn a history update's user message names: `history turn i` is turn i + 1.
function turnOf(update: any): number {
  const match = /history turn (\d+)/.exec(update.content?.text ?? "");
  if (!match) throw new Error(`a user message of no saved turn: ${JSON.stringify(update)}`);
  return Number(match[1]) + 1;
}

/// The turns a list of history updates holds, in order.
function turnsIn(updates: any[]): number[] {
  return updates.filter((p) => p.update?.sessionUpdate === "user_message_chunk").map((p) => turnOf(p.update));
}

/// What the client shows after each message of the load, its pages and the live turn.
export function observe(lines: any[], loadId: number, pageIds: Set<number>): { observations: Observation[]; cut: Array<[number, number]> } {
  const observations: Observation[] = [];
  const cut: Array<[number, number]> = [];
  let view: number[] = [];
  const live: number[] = [];
  let bottom = false;
  let replied = false;
  let more = false;
  let turn: number | null = null;
  const show = (at: string) => observations.push({ at, view: [...view], live: [...live], bottom, replied, more });
  const endTurn = () => {
    if (turn === null) return;
    view.push(turn);
    turn = null;
    show("turn");
  };
  for (const line of lines) {
    if (line.method === "session/update") {
      const params = line.params;
      if (params._meta?.fx?.historyNewestEnd === true) {
        endTurn();
        bottom = true;
        show("bottom");
        continue;
      }
      const kind = params.update?.sessionUpdate;
      if (!HISTORY_KINDS.has(kind)) continue;
      if (replied) {
        if (live.length === 0) {
          live.push(TURNS + 1);
          show("live");
        }
        continue;
      }
      if (kind === "user_message_chunk") {
        endTurn();
        turn = turnOf(params.update);
      } else if (turn === null) {
        throw new Error(`a history update before any turn's user message: ${JSON.stringify(params)}`);
      }
      continue;
    }
    if (line.method || line.id === undefined) continue;
    if (line.id === loadId) {
      endTurn();
      if (view.length > 0) cut.push([view.at(-1)!, view[0]!]);
      replied = true;
      bottom = true;
      more = Boolean(line.result?._meta?.fx?.historyCursor);
      show("reply");
    } else if (pageIds.has(line.id)) {
      const turns = turnsIn(line.result.updates);
      if (turns.length > 0) cut.push([turns.at(-1)!, turns[0]!]);
      view = [...turns, ...view];
      more = line.result.cursor !== null;
      show("page");
    }
  }
  return { observations, cut };
}

const seq = (items: number[]) => `<<${items.join(", ")}>>`;
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

function observedModule(run: Run): string {
  const cut = run.cut.length === 0 ? "<<>>" : run.cut.map(([end, start]) => `(${end} :> ${start})`).join(" @@ ");
  const values = run.observations.map(
    (o) => `[view |-> ${seq(o.view)}, live |-> ${seq(o.live)}, bottom |-> ${bool(o.bottom)}, replied |-> ${bool(o.replied)}, more |-> ${bool(o.more)}]`,
  );
  return [
    "------------------------- MODULE HistoryLoadObserved -------------------------",
    "(* Generated by tests/tla/drivers/session/history.test.ts from one run. Do not edit. *)",
    "EXTENDS TLC, Sequences",
    `TCut == ${cut}`,
    `Observed == << ${values.join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

const TRACE_CFG = [
  "CONSTANTS",
  `  Turns = ${TURNS}`,
  "  BigTurn = 0",
  "  Big = 2",
  "  Damaged = 0",
  "  Continued = 0",
  // A turn here is about 12 KB, so the newest page's 64 KiB holds about 6 of them.
  "  Budget = 6",
  "  MaxLive = 1",
  "  MaxCrashes = 0",
  "  MaxReloads = 0",
  "  OldClient = FALSE",
  '  Other = "none"',
  "  MaxOther = 0",
  '  Design = "b"',
  '  Mutant = "none"',
  "  Cut <- TCut",
  "INIT TraceInit",
  "NEXT TraceNext",
  "INVARIANT NotAllMatched",
  "INVARIANT TypeOK",
  "INVARIANT BottomBounded",
  "INVARIANT LoadBounded",
  "INVARIANT TranscriptExact",
  "INVARIANT BottomIsNewest",
  "INVARIANT LiveBelowHistory",
  "INVARIANT NoSilentGap",
  "CHECK_DEADLOCK FALSE",
  "",
].join("\n");

async function replay(run: Run, dir: string): Promise<{ verdict: Verdict; violated: string | null; matched: number }> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "HistoryLoadObserved.tla"), observedModule(run));
  writeFileSync(join(dir, "trace.cfg"), TRACE_CFG);
  const tlc = await runTlc(dir, "HistoryLoadTrace.tla", "trace.cfg", SPECS, SPEC_DIR);
  const matched = [...tlc.output.matchAll(/\/\\ k = (\d+)/g)].map((m) => Number(m[1])).at(-1) ?? 0;
  if (tlc.exitCode === 12 && tlc.violated === "NotAllMatched" && matched === run.observations.length) {
    return { verdict: "ACCEPTED", violated: tlc.violated, matched };
  }
  if (tlc.exitCode === 12 && tlc.violated !== null && tlc.violated !== "NotAllMatched") {
    return { verdict: "REJECTED", violated: tlc.violated, matched };
  }
  if (tlc.exitCode === 0 && tlc.output.includes("Model checking completed. No error has been found.")) {
    return { verdict: "REJECTED", violated: null, matched };
  }
  return { verdict: "TOOL_ERROR", violated: tlc.violated, matched };
}

/// Checks a run with TLC. A run the model can't produce is cut down to its
/// longest prefix the model can, to name the first step it can't.
async function checkTrace(run: Run, dir: string): Promise<TraceResult> {
  const hashes = { ...Object.fromEntries(SPECS.map((name) => [name, sha256File(join(SPEC_DIR, name))])), run: sha256Text(JSON.stringify(run)) };
  const length = run.observations.length;
  let result: TraceResult;
  if (length === 0) {
    result = { verdict: "TOOL_ERROR", violated: null, length, matched: 0, detail: "no observations", hashes };
  } else {
    const whole = await replay(run, join(dir, "whole"));
    if (whole.verdict !== "REJECTED" || whole.violated !== null) {
      result = { verdict: whole.verdict, violated: whole.violated, length, matched: whole.matched, detail: `TLC work in ${dir}`, hashes };
    } else {
      let good = 0;
      let bad = length;
      while (bad - good > 1) {
        const mid = Math.floor((good + bad) / 2);
        const prefix = { ...run, observations: run.observations.slice(0, mid) };
        if ((await replay(prefix, join(dir, `prefix-${mid}`))).verdict === "ACCEPTED") good = mid;
        else bad = mid;
      }
      result = {
        verdict: "REJECTED",
        violated: null,
        length,
        matched: good,
        detail: `the model cannot produce step ${good + 1}: ${JSON.stringify(run.observations[good])}`,
        hashes,
      };
    }
  }
  writeJson(join(dir, "verdict.json"), result);
  return result;
}

let kept: Run | null = null;

test("a load with history pages, pages to the top during a live turn, is a behavior of HistoryLoad design b", async () => {
  const run = await runOnce(binary, "branch");
  expect(run.advertised).toBe(true);
  const at = run.observations.map((o) => o.at);
  expect(at.filter((a) => a === "bottom")).toHaveLength(1);
  expect(at.filter((a) => a === "page").length).toBeGreaterThan(0);
  expect(at.filter((a) => a === "live")).toHaveLength(1);
  expect(run.observations.at(-1)!.view).toEqual(Array.from({ length: TURNS }, (_, i) => i + 1));
  const result = await checkTrace(run, join(artifacts, "branch-trace"));
  expect(result.verdict, result.detail).toBe("ACCEPTED");
  kept = run;
}, 240_000);

test("planted changes to the kept trace are rejected", async () => {
  expect(kept).not.toBeNull();
  const run = kept!;
  // The page leaves out the oldest turn.
  const gap = structuredClone(run);
  for (const o of gap.observations) if (o.at === "page" || o.at === "live") o.view = o.view.filter((t) => t !== 1);
  // The bottom marker never comes.
  const noBottom = structuredClone(run);
  noBottom.observations = noBottom.observations.filter((o) => o.at !== "bottom");
  // The live turn shows among the history.
  const liveAbove = structuredClone(run);
  for (const o of liveAbove.observations) if (o.at === "live") o.view = [...o.view, TURNS + 1];
  for (const [name, planted] of [["gap", gap], ["no-bottom", noBottom], ["live-above", liveAbove]] as const) {
    const result = await checkTrace(planted, join(artifacts, `planted-${name}`));
    expect(result.verdict, `${name}: ${result.detail}`).toBe("REJECTED");
  }
}, 240_000);

test.skipIf(!process.env.FX_TLA_BASE_BIN)("fx before history pages sends the whole history before the bottom screen", async () => {
  const run = await runOnce(process.env.FX_TLA_BASE_BIN!, "base");
  expect(run.advertised).toBe(false);
  const result = await checkTrace(run, join(artifacts, "base-trace"));
  expect(result.verdict, result.detail).toBe("REJECTED");
  expect(result.violated).toBe("BottomBounded");
}, 240_000);
