// Walks fx's provider compaction along tests/tla/compaction/ProviderCompaction.tla.
//
// TLC simulates behaviors of DriveSpec (provider-compaction-drive.cfg), and
// each one runs on the built fx against tests/e2e/provider-compaction-gateway.ts,
// one `fx ask --resume last` per turn with the turn's model (m1 is
// anthropic/claude-fable-5.2, m2 openai/gpt-6.1-sol). Every AddStep is one
// agent request: a shell call, or the turn's final answer. The driver makes a
// step large when a later compaction must cut right after it, and runs a turn
// that compacts at FX_AUTO_COMPACT_PERCENT=10 and every other turn at 80, so
// fx compacts exactly where the behavior does. The provider answers each
// compaction with its block, a failure (an error status, a reply without a
// block, an empty or cut-off stream, an oversized block), or never; then the
// driver kills fx, as a crash before the commit.
//
// Spec to binary: every agent request must send what the model state sends
// at that AddStep, and every compaction request what the model's compaction
// sends to the provider. Binary to spec: TLC replays every request fx sent
// through ProviderCompactionTrace.tla, and the run passes only when it stops
// on ReplayIncomplete. A behavior the driver cannot force on fx is skipped
// with its reason.
//
//   FX_TLA_TRACES  behaviors to simulate (default 12)
//   FX_TLA_DEPTH   steps per behavior (default 40)
//   FX_TLA_SEED    TLC's seed (default 1)
//   FX_TLA_FILES   comma-separated behavior files to replay instead
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TLA_ROOT, runTlc, tlcToolchain } from "../lib/tlc";
import { artifacts, binary, targetModule, testEnvironment } from "../lib/context";
import { parseBehavior, type State, type Value } from "./behavior";

const provider = await targetModule("provider-compaction-gateway.ts");
const SPECS = join(TLA_ROOT, "compaction");
const MODELS: Record<string, string> = { m1: "anthropic/claude-fable-5.2", m2: "openai/gpt-6.1-sol" };
const OWNER: Record<string, string> = { anthropic: "m1", openai: "m2" };
const BIG = "Detail that the next compaction folds away. ".repeat(4_000);
const FAILURES = [
  { kind: "status", status: 529 },
  { kind: "no_block" },
  { kind: "empty" },
  { kind: "status", status: 400 },
  { kind: "cut" },
  { kind: "oversized" },
] as const;

type Rec = { k: string; n: number; m: string; covers: Value[] };
type Item = { k: string; n: number; m: string; b: number };
type Agent = { step: number; owner: string; final: boolean; big: boolean; expected: Item[] | null };
type Compaction = { answer: { kind: string; status?: number }; expected: Item[] };
type Turn = { turn: number; model: string; low: boolean; crash: boolean };
type Plan = { agents: Agent[]; compactions: Compaction[]; turns: Turn[]; first: string };

const item = (k: string, n = 0, m = "none", b = 0): Item => ({ k, n, m, b });

/** What fx sends for the model's saved items to `model` (ProviderCompaction Wire). */
function wire(ctx: Value[], model: string): Item[] {
  return (ctx as Rec[]).map((saved) => {
    if (saved.k === "block") return saved.m === model ? item("block", 0, saved.m) : item("fx");
    if (saved.k === "step") return saved.m === model ? item("step", saved.n, saved.m) : item("text", saved.n, saved.m);
    if (saved.k === "text") return item("text", saved.n, saved.m);
    if (saved.k === "fx") return item("fx");
    if (saved.k === "note") return item("note");
    return item("user", saved.n);
  });
}

/** The fields two items must share to count as the same. */
function shape(items: Item[]): string[] {
  return items.map((one) => {
    if (one.k === "user") return `user ${one.n}`;
    if (one.k === "step") return `step ${one.n} ${one.m}`;
    if (one.k === "text") return `text ${one.n}`;
    if (one.k === "block") return `block ${one.m}`;
    return one.k;
  });
}

function plan(states: State[]): Plan | { skip: string } {
  const agents: Agent[] = [];
  const compactions: Compaction[] = [];
  const turns: Turn[] = [];
  const big = new Set<number>();
  // The steps each compaction that keeps turns keeps.
  const keptSteps: number[][] = [];
  let failures = 0;
  for (let i = 1; i < states.length; i += 1) {
    const before = states[i - 1]!;
    const after = states[i]!;
    switch (after.last) {
      case "NewTurn":
        turns.push({ turn: after.open as number, model: after.model as string, low: false, crash: false });
        break;
      case "AddStep":
        agents.push({ step: before.nextStep as number, owner: before.model as string, final: false, big: false, expected: wire(before.ctx as Value[], before.model as string) });
        break;
      case "EndTurn":
        agents.at(-1)!.final = true;
        break;
      case "KeepCompaction":
      case "WholeCompaction": {
        const pending = after.pending as Record<string, Value>;
        const older = pending.older as Rec[];
        const next = states[i + 1];
        const answer = !next || next.last === "Crash"
          ? { kind: "hold" }
          : (next.pending as Record<string, Value>).state === "block" ? { kind: "block" } : FAILURES[failures++ % FAILURES.length]!;
        compactions.push({ answer, expected: wire(older, after.model as string) });
        const turn = turns.at(-1)!;
        turn.low = true;
        if (answer.kind === "hold") turn.crash = true;
        // fx's window cuts right after the newest step that does not fit,
        // so that step is the one made large.
        const last = older.at(-1);
        if (!last || last.k !== "step") return { skip: "the cut follows no step" };
        big.add(last.n);
        if (after.last === "KeepCompaction") keptSteps.push((pending.kept as Rec[]).filter((kept) => kept.k === "step").map((kept) => kept.n));
        break;
      }
    }
  }
  // fx can't stop inside a turn: a behavior that ends with its turn open and
  // no compaction asked gets one more request, the turn's final reply, sent
  // as the model would send its next step. After a reply the model has not
  // committed yet, that request goes unchecked.
  const end = states.at(-1)!;
  const ending = (end.pending as Record<string, Value>).state;
  if ((end.open as number) !== 0 && ending !== "asked") {
    agents.push({
      step: end.nextStep as number, owner: end.model as string, final: true, big: false,
      expected: ending === "none" ? wire(end.ctx as Value[], end.model as string) : null,
    });
  }
  // fx's window never keeps a large step, even one a later compaction made
  // large.
  if (keptSteps.some((steps) => steps.some((one) => big.has(one)))) return { skip: "a large step would be kept" };
  for (const agent of agents) agent.big = big.has(agent.step);
  // A turn that compacts at 10 % would compact early if a large step were
  // still saved before its planned compaction.
  let at = 0;
  for (let i = 1; i < states.length; i += 1) {
    const after = states[i]!;
    if (after.last !== "AddStep") continue;
    const agent = agents[at++]!;
    const before = states[i - 1]!;
    const turn = turns.find((one) => one.turn === before.open)!;
    if (!turn.low) continue;
    const saved = (before.ctx as Rec[]).filter((one) => (one.k === "step" || one.k === "text") && big.has(one.n));
    if (saved.length > 0) return { skip: `step ${agent.step} would be sent with a large step still saved` };
  }
  if (agents.length === 0) return { skip: "no step" };
  return { agents, compactions, turns, first: states[0]!.model as string };
}

function simulate(dir: string, traces: number, depth: number, seed: number): string[] {
  const { java, jar } = tlcToolchain();
  const run = Bun.spawnSync([
    java, "-XX:+UseParallelGC", `-Djava.io.tmpdir=${dir}`, "-cp", jar, "tlc2.TLC",
    "-config", join(SPECS, "provider-compaction-drive.cfg"), "-metadir", join(dir, ".tlc-states"), "-deadlock",
    "-simulate", `file=${join(dir, "t")},num=${traces}`, "-depth", String(depth), "-seed", String(seed),
    join(SPECS, "ProviderCompaction.tla"),
  ], { cwd: dir, stdout: "pipe", stderr: "pipe" });
  if (run.exitCode !== 0) throw new Error(`TLC simulation failed (${run.exitCode}):\n${run.stdout.toString()}\n${run.stderr.toString()}`);
  return readdirSync(dir).filter((name) => name.startsWith("t_")).sort().map((name) => join(dir, name));
}

/** The model's view of one request fx sent: its items after the instructions. */
function abstract(request: any, stepOf: Map<number, number>, ownerOf: Map<number, string>, blockAt: Map<string, number>): Item[] {
  const prompt = request.body.prompt as Array<{ role: string; content: unknown }>;
  const items: Item[] = [];
  for (let i = provider.leadingSystem(prompt); i < prompt.length; i += 1) {
    const message = prompt[i]!;
    if (message.role === "tool") continue;
    const text = JSON.stringify(message.content);
    if (message.role === "system") {
      items.push(item("system"));
      continue;
    }
    if (message.role === "user") {
      const turn = text.match(/TURN (\d+)/);
      items.push(text.includes("compacted_conversation") ? item("fx") : turn ? item("user", Number(turn[1])) : item("note"));
      continue;
    }
    const key = provider.blockKeyOf(message);
    if (key !== null) {
      items.push(item("block", 0, OWNER[key.endsWith("_openai") ? "openai" : "anthropic"]!, blockAt.get(key) ?? 0));
      continue;
    }
    const label = text.match(/SIG_s(\d+)|call_s(\d+)|done s(\d+)/);
    const step = label ? stepOf.get(Number(label[1] ?? label[2] ?? label[3])) : undefined;
    if (step === undefined) {
      items.push(item("note"));
      continue;
    }
    const sent = item(provider.signaturesOf(message).length > 0 ? "step" : "text", step, ownerOf.get(step)!);
    // One reply can reach the request as more than one message.
    const previous = items.at(-1);
    if (previous && previous.n === step && (previous.k === "step" || previous.k === "text")) {
      if (sent.k === "step") previous.k = "step";
      continue;
    }
    items.push(sent);
  }
  return items;
}

function tlaItem(one: Item): string {
  return `[k |-> "${one.k}", n |-> ${one.n}, m |-> "${one.m}", b |-> ${one.b}]`;
}

async function replay(file: string, out: string): Promise<{ status: "pass" | "fail" | "skipped"; reasons: string[] }> {
  const states = parseBehavior(readFileSync(file, "utf8"));
  const planned = plan(states);
  if ("skip" in planned) return { status: "skipped", reasons: [planned.skip] };
  const root = mkdtempSync(join(out, "run-"));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ model: MODELS[planned.first], auto_upgrade: false }), { mode: 0o600 });

  const reasons: string[] = [];
  const stepOf = new Map<number, number>();
  const ownerOf = new Map<number, string>(planned.agents.map((agent) => [agent.step, agent.owner]));
  let agentAt = 0, compactionAt = 0;
  // fx retries a compaction request the provider failed with a retryable
  // status or a cut-off stream. A retry is the same request from the same
  // fx process: it gets the same answer and is not another compaction of
  // the model. A later turn may send the same request again after a crash,
  // and that one is the model's next compaction.
  const retries = new Set<number>();
  let previous: { prompt: string; answer: Compaction["answer"] } | null = null;
  let child: ReturnType<typeof Bun.spawn> | null = null;
  let held = false;
  const { gateway, edits, observed } = provider.startProviderGateway({
    models: Object.values(MODELS).map((id) => ({ id, type: "language", tags: ["tool-use", "reasoning"], context_window: 400_000, max_tokens: 8192 })),
    defaultModel: MODELS[planned.first],
    step: (request: any) => {
      const agent = planned.agents[agentAt++];
      if (!agent) {
        reasons.push(`request ${request.index}: no step planned`);
        return { kind: "final", text: `done s${request.index}` };
      }
      stepOf.set(request.index, agent.step);
      return agent.final
        ? { kind: "final", text: `done s${request.index}${agent.big ? ` ${BIG}` : ""}` }
        : { kind: "tool", text: agent.big ? BIG : undefined };
    },
    compaction: (request: any) => {
      const prompt = JSON.stringify(request.body.prompt);
      if (previous && previous.prompt === prompt) {
        retries.add(request.index);
        return previous.answer;
      }
      const compaction = planned.compactions[compactionAt++];
      if (!compaction) {
        reasons.push(`request ${request.index}: no compaction planned`);
        return { kind: "status", status: 500 };
      }
      previous = { prompt, answer: compaction.answer };
      return compaction.answer;
    },
    onHold: () => {
      held = true;
      child?.kill("SIGKILL");
    },
  });
  try {
    let started = false;
    for (const turn of planned.turns) {
      const args = ["ask", "--json", "--full-access", "--model", MODELS[turn.model]!];
      if (started) args.push("--resume", "last");
      args.push(`TURN ${turn.turn}`);
      const log = join(root, `turn-${turn.turn}`);
      previous = null;
      child = Bun.spawn([binary, ...args], {
        cwd,
        env: testEnvironment({
          HOME: home, TMPDIR: root, AI_GATEWAY_API_KEY: "synthetic-provider-compaction",
          FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_AUTO_COMPACT_PERCENT: turn.low ? "10" : "80",
          FX_TRACE_LOG: `${log}.trace`,
        }),
        stdin: "ignore", stdout: Bun.file(`${log}.stdout`), stderr: Bun.file(`${log}.stderr`),
      });
      const timer = setTimeout(() => child?.kill("SIGKILL"), 90_000);
      const code = await child.exited;
      clearTimeout(timer);
      started = true;
      if (turn.crash) {
        if (!held) reasons.push(`turn ${turn.turn}: the compaction was never held`);
        held = false;
      } else if (code !== 0) {
        reasons.push(`turn ${turn.turn}: fx exited ${code}`);
      }
    }
  } finally {
    gateway.stop();
  }

  reasons.push(...edits);
  const agents = observed.filter((request: any) => request.kind === "agent");
  const compactions = observed.filter((request: any) => request.kind === "compaction" && !retries.has(request.index));
  const traced = observed.filter((request: any) => request.kind !== "fx_summary" && !retries.has(request.index));
  const blockAt = new Map<string, number>();
  traced.forEach((request: any, index: number) => { if (request.block) blockAt.set(request.block, index + 1); });
  if (agents.length !== planned.agents.length) reasons.push(`agent requests: ${agents.length}, planned ${planned.agents.length}`);
  if (compactions.length !== planned.compactions.length) reasons.push(`compaction requests: ${compactions.length}, planned ${planned.compactions.length}`);
  planned.agents.forEach((agent, index) => {
    const request = agents[index];
    if (!request || agent.expected === null) return;
    const sent = shape(abstract(request, stepOf, ownerOf, blockAt));
    const wanted = shape(agent.expected);
    if (JSON.stringify(sent) !== JSON.stringify(wanted)) reasons.push(`step ${agent.step} (request ${request.index}) sent [${sent}], the model sends [${wanted}]`);
  });
  planned.compactions.forEach((compaction, index) => {
    const request = compactions[index];
    if (!request) return;
    const sent = shape(abstract(request, stepOf, ownerOf, blockAt));
    const wanted = shape(compaction.expected);
    if (JSON.stringify(sent) !== JSON.stringify(wanted)) reasons.push(`compaction ${index + 1} (request ${request.index}) sent [${sent}], the model sends [${wanted}]`);
  });

  // Binary to spec: TLC replays what fx sent.
  const requests = traced.map((request: any) => {
    const items = abstract(request, stepOf, ownerOf, blockAt);
    const produces = request.kind === "agent" ? stepOf.get(request.index) ?? 0 : 0;
    return `[model |-> "${OWNER[provider.familyOf(request.model).name]}", produces |-> ${produces}, items |-> << ${items.map(tlaItem).join(", ")} >>]`;
  });
  const dir = join(root, "tlc");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "ProviderCompactionObserved.tla"), `---- MODULE ProviderCompactionObserved ----\nRequests == << ${requests.join(",\n  ")} >>\n====\n`);
  writeFileSync(join(dir, "ProviderCompactionTrace.cfg"), "SPECIFICATION Spec\nINVARIANTS\n  NoDroppedReasoning\n  Readable\n  NoForeignReasoning\n  ReplayIncomplete\n");
  const run = await runTlc(dir, "ProviderCompactionTrace", "ProviderCompactionTrace.cfg", ["ProviderCompactionTrace.tla"], SPECS, ["-deadlock"]);
  if (run.violated !== "ReplayIncomplete") reasons.push(`TLC: ${run.violated ?? `exit ${run.exitCode}`} (see ${join(dir, "tlc.log")})`);
  writeFileSync(join(root, "requests.json"), JSON.stringify(observed.map((request: any) => ({ index: request.index, kind: request.kind, model: request.model, block: request.block, body: request.body })), null, 1));
  return { status: reasons.length === 0 ? "pass" : "fail", reasons: [...reasons, `evidence: ${root}`] };
}

describe("provider compaction along ProviderCompaction.tla", () => {
  test("every simulated behavior runs on fx, and TLC accepts every request fx sent", async () => {
    const out = artifacts;
    const traces = join(out, "traces");
    mkdirSync(traces, { recursive: true });
    const given = process.env.FX_TLA_FILES?.split(",").filter(Boolean);
    const seed = Number(process.env.FX_TLA_SEED ?? "1");
    const files = given ?? simulate(traces, Number(process.env.FX_TLA_TRACES ?? "12"), Number(process.env.FX_TLA_DEPTH ?? "40"), seed);
    const results: Array<{ trace: string; status: string; reasons: string[] }> = [];
    for (const file of files) {
      const result = await replay(file, out);
      results.push({ trace: file, ...result });
      console.log(`${result.status.padEnd(7)} ${file.split("/").pop()}  ${result.status === "pass" ? "" : result.reasons.join(" | ")}`);
    }
    writeFileSync(join(out, "results.json"), JSON.stringify({ seed, results }, null, 1));
    const failed = results.filter((result) => result.status === "fail");
    expect(failed.map((result) => `${result.trace.split("/").pop()}: ${result.reasons.join("; ")}`)).toEqual([]);
    expect(results.filter((result) => result.status === "pass").length).toBeGreaterThanOrEqual(Math.min(3, files.length));
  }, 1_800_000);
});
