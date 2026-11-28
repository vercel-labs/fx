// Runs the built fx binary along tests/tla/auto_classifier/ReviewPacket.tla and
// has TLC check every automatic permission review it observes
// (ReviewPacketTrace.tla).
//
// Each run is one `fx ask --json` in auto mode. The main model answers with
// reasoning and an `rm` shell call, which fx sends to review. Chat Completions
// runs use a local openai-chat-completions server in one of three modes:
//
//   deepseek_restore  DeepSeek's thinking-mode rule: an assistant message in a
//                     request that carries tools must carry its reasoning; a
//                     missing one is restored from its tool-call ID, so the
//                     reviewer's context gets the main agent's reasoning
//   deepseek_reject   the same rule, answering 400 with DeepSeek's message
//   plain             no rule
//
// Gateway runs use the fake Gateway from tests/e2e/tmux-helpers.ts. Every run
// follows a reviewer script: clear; caution then a confirming caution; caution
// then a clear confirmation.
//
// For each reviewed call the driver records the shape of the review request
// (each message's role and whether it carries reasoning), the endpoint's
// verdict on each review request, the reviewer's answers, what the reviewer's
// context held (the normalized action, the root request, a tool-call ID, the
// placeholder result, the main agent's reasoning), and whether the action ran
// or was held. TLC replays the observations through the model with Design =
// "text_only". --self-check also replays them through Design = "today", which
// must reject them. Every review must also carry the exact target call ID as
// text in its instruction.
//
// Modes:
//   (default)        9 Chat Completions runs (3 server modes x 3 reviewer
//                    scripts) and 2 Gateway runs
//   --fuzz N         N Chat Completions runs with seeded random call IDs
//                    (quotes, backslashes, newlines, markup, non-ASCII),
//                    random reasoning text in either reasoning field, and a
//                    random server mode and reviewer script; --seed S picks
//                    the seed (default 1). Failing cases are saved to
//                    fuzz-failures.json in the output folder, and the same
//                    flags replay them.
//   --stress N       one turn with N distinct reviewed `rm` calls against the
//                    deepseek_reject server
//   --parallel N     FX_TLA_REPEAT turns (default 1), each with one assistant
//                    message of N `rm` calls that fx admits as a parallel
//                    batch, cycling the three server modes; run it against a
//                    `zig build -Dsanitize-thread=true` binary through FX_BIN
//                    to check the batch under ThreadSanitizer
//
// Every fx process gets its own HOME and FX_HOME, FX_SOUND=0, and
// FX_DISABLE_KEYCHAIN=1, and talks only to the local fakes.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/auto_classifier/driver.ts
//   bun tests/tla/drivers/auto_classifier/driver.ts --self-check
//   bun tests/tla/drivers/auto_classifier/driver.ts --fuzz 24 --seed 1449
//   bun tests/tla/drivers/auto_classifier/driver.ts --stress 40
//   FX_TLA_REPEAT=12 bun tests/tla/drivers/auto_classifier/driver.ts --parallel 6
//
// Exit codes: 0 every run accepted (and the self-check rejected), 1 a run the
// model cannot produce or a review without its target call ID, 2 a toolchain,
// build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, repetitions, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc } from "../lib/tlc";

type Answer = "clear" | "caution";
type Verdict = "accepted" | "restored" | "rejected";
type Mode = "deepseek_restore" | "deepseek_reject" | "plain";
type Reasoning = "none" | "empty" | "real";
type Msg = { role: string; reasoning: Reasoning };
type Outcome = "ran" | "held_caution" | "held_unavailable" | "unknown";
type Observation = {
  id: string;
  provider: "chat" | "gateway";
  endpoint: "deepseek" | "plain";
  packet: Msg[];
  served: Verdict[];
  answers: Answer[];
  context: string[];
  outcome: Outcome;
  evidence: { call_id: string; exit: number; reviews: number; consistent: boolean; target_text: boolean; tool_result: string; tail: string };
};
type TraceVerdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Call = { id: string; command: string; reasoning: string; field: "reasoning_content" | "reasoning" };
// `batch` sends every call in one assistant message instead of one per step.
type ChatCase = { id: string; mode: Mode; script: Answer[]; calls: Call[]; victims: string[]; batch?: boolean };
type Run = { observations: Observation[]; harness: string[] };

const REASONING = "MAIN_REASONING_SENTINEL: I should delete victim.txt.";
const CALL_ID = "call_ds_1";
const GATEWAY_CALL_ID = "call_gw_1";
const COMMAND = "rm victim.txt";
const DEEPSEEK_400 = "The `reasoning_content` in the thinking mode must be passed back to the API.";
const SCRIPTS: Answer[][] = [["clear"], ["caution", "caution"], ["caution", "clear"]];
const MODES: Mode[] = ["deepseek_restore", "deepseek_reject", "plain"];
const tlaDir = join(TLA_ROOT, "auto_classifier");
const args = process.argv.slice(2);
const selfCheck = args.includes("--self-check");

function flag(name: string): number | undefined {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const value = Number(args[i + 1]);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${name} needs a positive integer`);
  return value;
}

function reasoningOf(message: any): Reasoning {
  const value = message.reasoning_content !== undefined ? message.reasoning_content : message.reasoning;
  if (value === undefined) return "none";
  return value === null || value === "" ? "empty" : "real";
}

function isReview(body: any): boolean {
  return (body.tools ?? []).some((tool: any) => tool.function?.name === "permission_decision");
}

// DeepSeek's thinking-mode rule for one Chat Completions request.
function judge(body: any, mode: Mode, reasoningById: Map<string, string>): Verdict {
  if (mode === "plain" || !Array.isArray(body.tools) || body.tools.length === 0) return "accepted";
  const missing = (body.messages ?? []).filter((m: any) => m.role === "assistant" && reasoningOf(m) !== "real");
  if (missing.length === 0) return "accepted";
  const restorable = missing.every((m: any) =>
    (m.tool_calls ?? []).length > 0 && m.tool_calls.every((call: any) => reasoningById.has(call.id)));
  return mode === "deepseek_restore" && restorable ? "restored" : "rejected";
}

function sse(chunks: object[]): Response {
  return new Response(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n", {
    headers: { "content-type": "text/event-stream" },
  });
}

function chatToolCalls(model: string, calls: Array<{ id: string; name: string; input: unknown }>, reasoning?: { field: string; text: string }): Response {
  return sse([
    ...(reasoning ? [{ id: "chat-tool", model, choices: [{ index: 0, delta: { role: "assistant", [reasoning.field]: reasoning.text }, finish_reason: null }] }] : []),
    { id: "chat-tool", model, choices: [{ index: 0, delta: { tool_calls: calls.map((call, index) => ({ index, id: call.id, type: "function", function: { name: call.name, arguments: JSON.stringify(call.input) } })) }, finish_reason: null }] },
    { id: "chat-tool", model, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
  ]);
}

function chatToolCall(model: string, id: string, name: string, input: unknown, reasoning?: { field: string; text: string }): Response {
  return chatToolCalls(model, [{ id, name, input }], reasoning);
}

function chatText(model: string, text: string): Response {
  return sse([
    { id: "chat-text", model, choices: [{ index: 0, delta: { role: "assistant", reasoning_content: "Done thinking." }, finish_reason: null }] },
    { id: "chat-text", model, choices: [{ index: 0, delta: { content: text }, finish_reason: null }] },
    { id: "chat-text", model, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
  ]);
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  return JSON.stringify(content ?? "");
}

// The review instruction: the one string in the request that opens
// <permission_review>.
function instructionOf(body: any): string | undefined {
  const texts: string[] = [];
  const collect = (value: unknown) => {
    if (typeof value === "string") texts.push(value);
    else if (Array.isArray(value)) value.forEach(collect);
    else if (value && typeof value === "object") Object.values(value).forEach(collect);
  };
  collect(body.messages ?? body.prompt ?? []);
  return texts.find((text) => text.includes("<permission_review>"));
}

// The target call ID the instruction names. It writes the ID as a JSON string
// and then XML-escapes the review data (src/core/permissions/auto_classifier.zig
// buildReviewInstruction), so this undoes both.
function reviewTarget(body: any): string | undefined {
  const instruction = instructionOf(body);
  const match = instruction ? /target_tool_call_id: ("(?:[^"\\]|\\.)*")/.exec(instruction) : null;
  if (!match) return undefined;
  try {
    return JSON.parse(match[1]!.replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&amp;", "&"));
  } catch {
    return undefined;
  }
}

// What one accepted review request put in the reviewer's model context.
function contextOf(messages: Array<{ role: string; text: string; reasoning: Reasoning; call: boolean }>, raw: string, reasoning: string, restored: boolean): Set<string> {
  const facts = new Set<string>();
  for (const m of messages) {
    if (m.role === "system" && m.text.includes("<permission_review>") && m.text.includes("\naction: ")) facts.add("action");
    if (m.role === "user" && m.text.includes("trusted_root_context")) facts.add("root");
    if (m.role === "assistant" && m.call) facts.add("call_id");
    if (m.role === "assistant" && m.reasoning === "real") facts.add("reasoning");
    if (m.role === "tool") facts.add("placeholder");
  }
  if (restored || raw.includes(reasoning)) facts.add("reasoning");
  return facts;
}

function outcomeOf(victim: string, toolResult: string): Outcome {
  if (!existsSync(victim)) return "ran";
  if (toolResult.includes("review_unavailable")) return "held_unavailable";
  if (toolResult.includes("review_caution")) return "held_caution";
  return "unknown";
}

async function runFx(home: string, workspace: string, env: Record<string, string>, timeoutMs: number) {
  const child = Bun.spawn([binary, "ask", "--json", "--no-save", "Delete the victim files."], {
    cwd: workspace,
    env: testEnvironment({ HOME: home, FX_HOME: join(home, ".fx"), FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1", NO_COLOR: "1", ...env }),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(9), timeoutMs);
  const [stdout, stderr, exit] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  clearTimeout(timer);
  return { exit, tail: `${stdout}\n${stderr}`.slice(-600) };
}

function newRoot(scratch: string, id: string, victims: string[]) {
  const root = realpathSync(mkdtempSync(join(scratch, `${id}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace);
  for (const victim of victims) writeFileSync(join(workspace, victim), "victim\n");
  return { root, home, workspace: realpathSync(workspace) };
}

async function chatRun(helpers: any, scratch: string, c: ChatCase, timeoutMs: number, extraEnv: Record<string, string> = {}): Promise<Run> {
  const { root, home, workspace } = newRoot(scratch, c.id, c.victims);
  const reviews: Array<{ body: any; raw: string; verdict: Verdict; target: string | undefined }> = [];
  const answers: Answer[] = [];
  const reasoningById = new Map<string, string>();
  const toolResults = new Map<string, string>();
  let mainRequests = 0;
  let mainRejected = false;
  let unexpected = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname !== "/v1/chat/completions" || request.method !== "POST") {
        unexpected++;
        return new Response("unexpected endpoint", { status: 500 });
      }
      const raw = await request.text();
      const body = JSON.parse(raw);
      const review = isReview(body);
      const verdict = judge(body, c.mode, reasoningById);
      if (review) reviews.push({ body, raw, verdict, target: reviewTarget(body) });
      else mainRequests++;
      if (verdict === "rejected") {
        if (!review) mainRejected = true;
        return Response.json({ error: { message: DEEPSEEK_400, type: "invalid_request_error" } }, { status: 400 });
      }
      if (review) {
        const answer = c.script[answers.length] ?? "clear";
        answers.push(answer);
        return chatToolCall(body.model, `review_${reviews.length}`, "permission_decision", answer === "clear"
          ? { decision: "clear" }
          : { decision: "caution", category: "system_harm", evidence: helpers.reviewedActionEvidence(raw) });
      }
      const tools = (body.messages ?? []).filter((m: any) => m.role === "tool");
      for (const tool of tools) toolResults.set(String(tool.tool_call_id), textOf(tool.content));
      if (c.batch) {
        if (tools.length > 0) return chatText(body.model, "Finished.");
        for (const call of c.calls) reasoningById.set(call.id, call.reasoning);
        const calls = c.calls.map((call) => ({ id: call.id, name: "shell", input: { request: { action: "run", command: call.command } } }));
        return chatToolCalls(body.model, calls, { field: "reasoning_content", text: c.calls[0]!.reasoning });
      }
      const next = c.calls[tools.length];
      if (!next) return chatText(body.model, "Finished.");
      reasoningById.set(next.id, next.reasoning);
      return chatToolCall(body.model, next.id, "shell", { request: { action: "run", command: next.command } }, { field: next.field, text: next.reasoning });
    },
  });
  try {
    writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
      provider: "local",
      auto_upgrade: false,
      permission_mode: "auto",
      providers: {
        local: {
          protocol: "openai-chat-completions",
          base_url: `http://127.0.0.1:${server.port}/v1`,
          auth: { type: "none" },
          model_metadata: { "deepseek-thinking": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } },
        },
      },
      models: { local: "deepseek-thinking" },
    }), { mode: 0o600 });
    const elsewhere = `http://127.0.0.1:${server.port}/unexpected-gateway`;
    const run = await runFx(home, workspace, {
      AI_GATEWAY_API_KEY: "fake-review-packet-driver-key",
      FX_GATEWAY_BASE_URL: elsewhere,
      FX_GATEWAY_CHAT_URL: elsewhere,
      ...extraEnv,
    }, timeoutMs);
    const harness: string[] = [];
    if (reviews.length === 0) harness.push(`${c.id}: the fake counted no review request\n${run.tail}`);
    const expectedMain = c.batch ? 2 : c.calls.length + 1;
    if (mainRequests !== expectedMain) harness.push(`${c.id}: the fake counted ${mainRequests} main requests, expected ${expectedMain}\n${run.tail}`);
    if (unexpected > 0) harness.push(`${c.id}: the fake counted ${unexpected} requests to another endpoint`);
    const single = c.calls.length === 1;
    const observations = c.calls.map((call, index): Observation => {
      const mine = reviews.filter((r) => (single ? true : r.target === call.id));
      const shapes = mine.map((r) => (r.body.messages ?? []).map((m: any) => ({ role: m.role, reasoning: reasoningOf(m) })));
      const consistent = shapes.every((shape) => JSON.stringify(shape) === JSON.stringify(shapes[0]));
      const context = new Set<string>();
      for (const r of mine) {
        if (r.verdict === "rejected") continue;
        const messages = (r.body.messages ?? []).map((m: any) => ({
          role: m.role, text: textOf(m.content), reasoning: reasoningOf(m), call: (m.tool_calls ?? []).length > 0,
        }));
        for (const fact of contextOf(messages, r.raw, call.reasoning, r.verdict === "restored")) context.add(fact);
      }
      // Answers belong to the reviews in order; a rejected review got none.
      const accepted = reviews.filter((r) => r.verdict !== "rejected");
      const myAnswers = mine.filter((r) => r.verdict !== "rejected").map((r) => answers[accepted.indexOf(r)]!);
      const toolResult = toolResults.get(call.id) ?? "";
      let outcome = outcomeOf(join(workspace, c.victims[index]!), toolResult);
      if (!consistent || mainRejected || run.exit !== 0) outcome = "unknown";
      const targetText = mine.every((r) => r.target === call.id);
      return {
        id: single ? c.id : `${c.id}-${index}`,
        provider: "chat",
        endpoint: c.mode === "plain" ? "plain" : "deepseek",
        packet: shapes[0] ?? [],
        served: mine.map((r) => r.verdict),
        answers: myAnswers,
        context: [...context].sort(),
        outcome,
        evidence: { call_id: call.id, exit: run.exit, reviews: mine.length, consistent, target_text: targetText, tool_result: toolResult.slice(0, 300), tail: run.tail },
      };
    });
    return { observations, harness };
  } finally {
    server.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

function gatewayShape(body: any) {
  return (body.prompt ?? []).map((m: any) => {
    const parts = Array.isArray(m.content) ? m.content : [];
    const reasoningParts = parts.filter((p: any) => p.type === "reasoning");
    const reasoning: Reasoning = reasoningParts.length === 0
      ? "none"
      : reasoningParts.some((p: any) => (p.text ?? "") !== "") ? "real" : "empty";
    return { role: m.role, text: textOf(m.content), reasoning, call: parts.some((p: any) => p.type === "tool-call") };
  });
}

async function gatewayRun(helpers: any, scratch: string, script: Answer[], id: string): Promise<Run> {
  const { root, home, workspace } = newRoot(scratch, id, ["victim.txt"]);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  let toolResult = "";
  const gateway = helpers.startFakeGateway([
    helpers.fakeGatewaySse([
      { type: "reasoning-start", id: "r1" },
      { type: "reasoning-delta", id: "r1", delta: REASONING },
      { type: "reasoning-end", id: "r1" },
      { type: "tool-call", toolCallId: GATEWAY_CALL_ID, toolName: "shell", input: { request: { action: "run", command: COMMAND } } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]),
    (body: string) => {
      toolResult = JSON.stringify((JSON.parse(body).prompt ?? []).filter((m: any) => m.role === "tool"));
      return helpers.fakeGatewayFinalText("Finished.");
    },
  ], {
    classifierResponses: [script[0] === "clear" ? helpers.fakeGatewayPermissionDecision("clear") : helpers.fakeGatewayHeldDecision()],
  });
  try {
    const run = await runFx(home, workspace, {
      AI_GATEWAY_API_KEY: "fake-review-packet-driver-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: "openai/gpt-5",
      FX_PERMISSION_MODE: "auto",
    }, 90_000);
    const bodies: string[] = [...gateway.classifierRequests, ...gateway.confirmationRequests].map((r: any) => r.body);
    const harness: string[] = [];
    if (bodies.length === 0) harness.push(`${id}: the fake Gateway counted no review request\n${run.tail}`);
    if (gateway.requests.length !== 2) harness.push(`${id}: the fake Gateway counted ${gateway.requests.length} main requests, expected 2\n${run.tail}`);
    const shapes = bodies.map((body) => gatewayShape(JSON.parse(body)));
    const consistent = shapes.every((shape) =>
      JSON.stringify(shape.map((m: any) => [m.role, m.reasoning])) === JSON.stringify(shapes[0]!.map((m: any) => [m.role, m.reasoning])));
    const context = new Set<string>();
    for (const [index, shape] of shapes.entries()) for (const fact of contextOf(shape, bodies[index]!, REASONING, false)) context.add(fact);
    let outcome = outcomeOf(join(workspace, "victim.txt"), toolResult);
    if (!consistent || run.exit !== 0) outcome = "unknown";
    const answers: Answer[] = script[0] === "clear" ? ["clear"] : bodies.map(() => "caution");
    const targetText = bodies.every((body) => reviewTarget(JSON.parse(body)) === GATEWAY_CALL_ID);
    return {
      observations: [{
        id,
        provider: "gateway",
        endpoint: "plain",
        packet: (shapes[0] ?? []).map((m: any) => ({ role: m.role, reasoning: m.reasoning })),
        served: bodies.map(() => "accepted"),
        answers,
        context: [...context].sort(),
        outcome,
        evidence: { call_id: GATEWAY_CALL_ID, exit: run.exit, reviews: bodies.length, consistent, target_text: targetText, tool_result: toolResult.slice(0, 300), tail: run.tail },
      }],
      harness,
    };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

// mulberry32: a small seeded generator, so a fuzz run replays from its seed.
function generator(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const ID_PIECES = ["a", "b", "x", "z", "0", "7", "-", "_", ".", ":", "/", " ", "\"", "\\", "'", "<", ">", "&", "\n", "\t", "\u00e9", "\u6f22", "call_", "functions.shell:"];
const WORDS = ["delete", "victim", "file", "the", "user", "asked", "remove", "it", "now", "check", "safe", "plan"];

function fuzzCases(count: number, seed: number): ChatCase[] {
  const rand = generator(seed);
  const pick = <T>(items: T[]): T => items[Math.floor(rand() * items.length)]!;
  return Array.from({ length: count }, (_, i) => {
    let id = "";
    const pieces = 1 + Math.floor(rand() * 24);
    for (let p = 0; p < pieces; p++) id += pick(ID_PIECES);
    const words = Array.from({ length: 1 + Math.floor(rand() * 30) }, () => pick(WORDS)).join(" ");
    return {
      id: `fuzz-${seed}-${i}`,
      mode: pick(MODES),
      script: pick(SCRIPTS),
      calls: [{ id, command: COMMAND, reasoning: `FUZZ_REASONING_${seed}_${i}: ${words}`, field: pick(["reasoning_content", "reasoning"] as const) }],
      victims: ["victim.txt"],
    };
  });
}

function stressCase(count: number): ChatCase {
  return {
    id: `stress-${count}`,
    mode: "deepseek_reject",
    script: [],
    calls: Array.from({ length: count }, (_, k) => ({
      id: `call_stress_${k}`,
      command: `rm victim_${k}.txt`,
      reasoning: `STRESS_REASONING_${k}: delete victim_${k}.txt.`,
      field: "reasoning_content" as const,
    })),
    victims: Array.from({ length: count }, (_, k) => `victim_${k}.txt`),
  };
}

// One assistant message with `count` calls, which fx admits as one parallel
// batch. Every call shares the message's reasoning.
function parallelCase(count: number, round: number): ChatCase {
  const reasoning = `PARALLEL_REASONING_${round}: delete all ${count} victims at once.`;
  return {
    id: `parallel-${count}-${round}`,
    mode: MODES[round % MODES.length]!,
    script: [],
    batch: true,
    calls: Array.from({ length: count }, (_, k) => ({
      id: `call_batch_${round}_${k}`,
      command: `rm victim_${k}.txt`,
      reasoning,
      field: "reasoning_content" as const,
    })),
    victims: Array.from({ length: count }, (_, k) => `victim_${k}.txt`),
  };
}

const str = (value: string) => JSON.stringify(value);
const seq = (values: string[]) => `<<${values.map(str).join(", ")}>>`;

function observedModule(observations: Observation[]): string {
  const msg = (m: Msg) => `[role |-> ${str(m.role)}, reasoning |-> ${str(m.reasoning)}]`;
  const value = (o: Observation) =>
    `[provider |-> ${str(o.provider)}, endpoint |-> ${str(o.endpoint)}, packet |-> <<${o.packet.map(msg).join(", ")}>>, ` +
    `served |-> ${seq(o.served)}, answers |-> ${seq(o.answers)}, context |-> {${o.context.map(str).join(", ")}}, outcome |-> ${str(o.outcome)}]`;
  return [
    "------------------------ MODULE ReviewPacketObserved ------------------------",
    "(* Generated by tests/tla/drivers/auto_classifier/driver.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], design: string, parent: string): Promise<TraceVerdict> {
  const dir = mkdtempSync(join(parent, `trace-${design}-`));
  writeFileSync(join(dir, "ReviewPacketObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    '  Providers = {"gateway", "codex", "grok", "chat"}',
    '  ChatEndpoints = {"deepseek", "plain"}',
    "  RestoreChoices = {TRUE, FALSE}",
    "  EmptyChoices = {FALSE}",
    `  Design = ${str(design)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const result = await runTlc(dir, "ReviewPacketTrace.tla", "trace.cfg", ["ReviewPacket.tla", "ReviewPacketTrace.tla"], tlaDir);
  if (result.violated === "NotAllMatched") return "ACCEPTED";
  if (result.exitCode === 0 && result.output.includes("No error has been found")) return "REJECTED";
  console.error(result.output.slice(-2000));
  return "TOOL_ERROR";
}

async function main(): Promise<number> {
  if (!existsSync(binary)) {
    console.error(`missing ${binary}; run zig build first or set FX_BIN`);
    return 2;
  }
  const fuzz = flag("--fuzz");
  const seed = flag("--seed") ?? 1;
  const stress = flag("--stress");
  const parallel = flag("--parallel");
  const helpers = await targetHelpers();
  const out = outDir("auto_classifier");
  const scratch = join(out, "runs");
  mkdirSync(scratch, { recursive: true });
  const cases: Array<() => Promise<Run>> = [];
  let fuzzed: ChatCase[] = [];
  if (fuzz !== undefined) {
    console.log(`fuzz: ${fuzz} runs, seed ${seed}`);
    fuzzed = fuzzCases(fuzz, seed);
    for (const c of fuzzed) cases.push(() => chatRun(helpers, scratch, c, 90_000));
  } else if (stress !== undefined) {
    console.log(`stress: one turn with ${stress} reviewed calls against deepseek_reject`);
    cases.push(() => chatRun(helpers, scratch, stressCase(stress), 600_000, { FX_MAX_AGENT_STEPS: String(stress + 5) }));
  } else if (parallel !== undefined) {
    console.log(`parallel: ${repetitions} turns, each one batch of ${parallel} reviewed calls, cycling the server modes`);
    for (let round = 0; round < repetitions; round++) cases.push(() => chatRun(helpers, scratch, parallelCase(parallel, round), 120_000));
  } else {
    for (const mode of MODES) for (const [i, script] of SCRIPTS.entries()) {
      cases.push(() => chatRun(helpers, scratch, { id: `chat-${mode}-${i}`, mode, script, calls: [{ id: CALL_ID, command: COMMAND, reasoning: REASONING, field: "reasoning_content" }], victims: ["victim.txt"] }, 90_000));
    }
    for (const [i, script] of SCRIPTS.slice(0, 2).entries()) cases.push(() => gatewayRun(helpers, scratch, script, `gateway-${i}`));
  }
  const observations: Observation[] = [];
  const harness: string[] = [];
  for (const run of cases) {
    const result = await run();
    observations.push(...result.observations);
    harness.push(...result.harness);
  }
  writeFileSync(join(out, "observations.json"), JSON.stringify(observations, null, 2));
  for (const o of observations) {
    if (fuzz !== undefined) console.log(`${o.id}: call id ${JSON.stringify(o.evidence.call_id)}`);
    console.log(`${o.id}: packet ${o.packet.map((m) => m.reasoning === "none" ? m.role : `${m.role}+${m.reasoning}`).join(",")} ` +
      `served ${o.served.join(",") || "-"} answers ${o.answers.join(",") || "-"} context ${o.context.join(",")} outcome ${o.outcome}`);
  }
  if (harness.length > 0) {
    for (const line of harness) console.error(line);
    return 2;
  }
  const missingTarget = observations.filter((o) => !o.evidence.target_text);
  for (const o of missingTarget) console.log(`  review without its exact target_tool_call_id text: ${o.id}`);
  const design = await runTrace(observations, "text_only", out);
  console.log(`text_only model: ${design}`);
  if (design === "TOOL_ERROR") return 2;
  const failing: Observation[] = [];
  if (design === "REJECTED") {
    for (const o of observations) {
      const one = await runTrace([o], "text_only", out);
      if (one !== "ACCEPTED") {
        failing.push(o);
        console.log(`  not a text_only behavior: ${o.id} (${one})`);
      }
    }
  }
  if (fuzz !== undefined && (failing.length > 0 || missingTarget.length > 0)) {
    const bad = new Set([...failing, ...missingTarget].map((o) => o.id));
    writeFileSync(join(out, "fuzz-failures.json"), JSON.stringify({ seed, runs: fuzz, cases: fuzzed.filter((c) => bad.has(c.id)) }, null, 2));
    console.log(`saved failing inputs: ${join(out, "fuzz-failures.json")} (replay: --fuzz ${fuzz} --seed ${seed})`);
  }
  if (selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, today model: ${today}`);
    if (today === "TOOL_ERROR") return 2;
    if (design === "ACCEPTED" && today !== "REJECTED") return 1;
  }
  console.log(`output: ${out}`);
  return design === "ACCEPTED" && missingTarget.length === 0 ? 0 : 1;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
