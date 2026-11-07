// Runs the built fx binary along tests/tla/agent_runtime/RequestWrapper.tla and
// has TLC check every tool call it observes (RequestWrapperTrace.tla).
//
// Each case is one `fx ask` against a local fake gateway that sends one call to
// shell, read_tool_result, or subagent, shaped as the model's arguments can be:
// flat, wrapped in `request` as an object or as its JSON text, as text longer
// than the 64 KiB bound, as text that names no object, or as a wrapper with a
// field beside it. For each call it records whether the tool ran it (the shell
// command wrote its marker, the saved output was read, the delegation returned
// ok) and how the next request replayed it: as the flat call, or as sent. TLC
// replays the calls through the model's own actions. --self-check also replays
// them through the model of fx before the change (Bug = "today"), which must
// reject them. --stress N adds one reply with N shell calls sent as JSON text,
// one with text exactly at the bound and one a byte past it, and prints the
// wall time and the binary's peak memory; every one of those calls is checked
// by TLC as well.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/request-wrapper.ts
//   bun tests/tla/drivers/agent_runtime/request-wrapper.ts --self-check
//   bun tests/tla/drivers/agent_runtime/request-wrapper.ts --stress 200
//
// Exit codes: 0 every call accepted (and the self-check rejected), 1 a call the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Tool = "shell" | "read_tool_result" | "subagent";
type Shape =
  | "flat"
  | "object"
  | "text"
  | "text_oversized"
  | "text_not_object"
  | "object_sibling"
  | "text_sibling";
type Replay = "flat" | "as_sent" | "unknown";
type Observation = {
  id: string;
  tool: Tool;
  shape: Shape;
  ran: boolean;
  replay: Replay;
  evidence: { exit: number; requests: number; result: string; replayed: unknown; tail: string };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const TOOLS: Tool[] = ["shell", "read_tool_result", "subagent"];
const SHAPES: Shape[] = ["flat", "object", "text", "text_oversized", "text_not_object", "object_sibling", "text_sibling"];
const MODEL = "openai/gpt-5.5";
// tool_args.max_request_text_bytes in src/core/tooling/tool_args.zig.
const BOUND = 64 * 1024;
const NEEDLE = "REQUEST_WRAPPER_NEEDLE";
const tlaDir = join(TLA_ROOT, "agent_runtime");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  stress: option("--stress", 0),
};

/// The JSON text of `inner`, padded with trailing spaces to `length` bytes.
/// Trailing whitespace keeps it the same JSON value.
function padded(inner: object, length: number): string {
  const text = JSON.stringify(inner);
  if (text.length > length) throw new Error(`padding ${text.length} bytes to ${length}`);
  return text + " ".repeat(length - text.length);
}

/// The arguments the model sends for `shape`, around the flat call `inner`.
/// `sibling` is a field the tool takes, sent beside the wrapper.
function shaped(shape: Shape, inner: Record<string, unknown>, sibling: Record<string, unknown>): Record<string, unknown> {
  switch (shape) {
    case "flat":
      return inner;
    case "object":
      return { request: inner };
    case "text":
      return { request: JSON.stringify(inner) };
    case "text_oversized":
      return { request: padded(inner, BOUND + 1) };
    case "text_not_object":
      return { request: "run" };
    case "object_sibling":
      return { request: inner, ...sibling };
    case "text_sibling":
      return { request: JSON.stringify(inner), ...sibling };
  }
}

type Part = Record<string, unknown>;

function parts(body: string): Part[] {
  const prompt = JSON.parse(body).prompt as Array<{ content?: unknown }>;
  return prompt.flatMap((message) => (Array.isArray(message.content) ? (message.content as Part[]) : []));
}

function text(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(text).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [text(value.text), text(value.value)].join("");
  }
  return "";
}

function toolResult(body: string, id: string): string | null {
  const part = parts(body).find((p) => p.type === "tool-result" && p.toolCallId === id);
  return part ? text(part.output) : null;
}

function replayedInput(body: string, id: string): unknown {
  return parts(body).find((p) => p.type === "tool-call" && p.toolCallId === id)?.input;
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function replayOf(replayed: unknown, inner: object, sent: object): Replay {
  if (sameJson(replayed, sent) && !sameJson(sent, inner)) return "as_sent";
  if (sameJson(replayed, inner)) return "flat";
  return "unknown";
}

function shellOk(result: string): boolean {
  try {
    const parsed = JSON.parse(result) as { state?: string; exit_code?: number };
    return parsed.state === "completed" && parsed.exit_code === 0;
  } catch {
    return false;
  }
}

function delegated(result: string): boolean {
  try {
    return (JSON.parse(result) as { ok?: boolean }).ok === true;
  } catch {
    return false;
  }
}

// requests counts what the local fake gateway served; a turn it served
// nothing ran somewhere else and proves nothing.
type Turn = { exit: number; requests: number; tail: string; workspace: string };

async function runAsk(helpers: any, id: string, scratch: string, respond: (body: string) => Response, prepare?: (workspace: string) => void): Promise<Turn & { cleanup: () => void }> {
  const gateway = helpers.startDynamicFakeGateway(respond, {
    classifierDecision: "clear",
    models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
  });
  const root = mkdtempSync(join(scratch, `${id}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, "fx-profile", "skills"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  prepare?.(workspace);
  try {
    const child = Bun.spawn([binary, "ask", "--json", "--yolo", "Use the tool once."], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        FX_HOME: join(home, "fx-profile"),
        AI_GATEWAY_API_KEY: "fake-request-wrapper-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: MODEL,
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 120_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const maxRss = child.resourceUsage()?.maxRSS ?? null;
    return {
      exit,
      requests: gateway.requests.length,
      tail: `${stdout}\n${stderr}`.slice(-400) + (maxRss === null ? "" : `\nmax_rss_bytes=${maxRss}`),
      workspace,
      cleanup: () => rmSync(root, { recursive: true, force: true }),
    };
  } finally {
    gateway.stop();
  }
}

async function shellCase(helpers: any, id: string, shape: Shape, scratch: string): Promise<Observation> {
  const { fakeGatewayToolCall, fakeGatewayFinalText } = helpers;
  const inner = { action: "run", command: "printf ran > marker.txt", profile: "clean" };
  const sent = shaped(shape, inner, { cwd: "." });
  let result = "";
  let replayed: unknown = null;
  let step = 0;
  const turn = await runAsk(helpers, id, scratch, (body) => {
    if (step++ === 0) return fakeGatewayToolCall("wrapped", "shell", sent);
    result = toolResult(body, "wrapped") ?? "";
    replayed = replayedInput(body, "wrapped");
    return fakeGatewayFinalText("REQUEST_WRAPPER_DONE");
  });
  try {
    const marked = existsSync(join(turn.workspace, "marker.txt"));
    return {
      id, tool: "shell", shape,
      ran: marked && shellOk(result),
      replay: replayOf(replayed, inner, sent),
      evidence: { exit: turn.exit, requests: turn.requests, result: result.slice(0, 400), replayed, tail: turn.tail },
    };
  } finally {
    turn.cleanup();
  }
}

async function readResultCase(helpers: any, id: string, shape: Shape, scratch: string): Promise<Observation> {
  const { fakeGatewayToolCall, fakeGatewayFinalText } = helpers;
  let inner: Record<string, unknown> = {};
  let sent: Record<string, unknown> = {};
  let result = "";
  let replayed: unknown = null;
  let step = 0;
  const turn = await runAsk(helpers, id, scratch, (body) => {
    switch (step++) {
      case 0:
        return fakeGatewayToolCall("large_read", "read_file", { path: "large.txt" });
      case 1: {
        const handle = /<tool_result_handle>([^<]+)<\/tool_result_handle>/.exec(toolResult(body, "large_read") ?? "")?.[1] ?? "";
        inner = { handle, query: NEEDLE };
        sent = shaped(shape, inner, { query: "other" });
        return fakeGatewayToolCall("wrapped", "read_tool_result", sent);
      }
      default:
        result = toolResult(body, "wrapped") ?? "";
        replayed = replayedInput(body, "wrapped");
        return fakeGatewayFinalText("REQUEST_WRAPPER_DONE");
    }
  }, (workspace) => {
    const lines = Array.from({ length: 500 }, (_, i) => `fixture line ${i}: ${"x".repeat(72)}`);
    lines[300] = NEEDLE;
    writeFileSync(join(workspace, "large.txt"), `${lines.join("\n")}\n`);
  });
  try {
    if (!("handle" in inner) || inner.handle === "") throw new Error(`${id}: read_file returned no handle: ${turn.tail}`);
    return {
      id, tool: "read_tool_result", shape,
      ran: result.includes(NEEDLE) && result.includes("<tool_result_query"),
      replay: replayOf(replayed, inner, sent),
      evidence: { exit: turn.exit, requests: turn.requests, result: result.slice(0, 400), replayed, tail: turn.tail },
    };
  } finally {
    turn.cleanup();
  }
}

async function subagentCase(helpers: any, id: string, shape: Shape, scratch: string): Promise<Observation> {
  const { fakeGatewayToolCall, fakeGatewayFinalText } = helpers;
  const inner = { action: "message", agent: "worker", message: "Report done." };
  const sent = shaped(shape, inner, { agent: "worker" });
  let issued = false;
  let answered = false;
  let result = "";
  let replayed: unknown = null;
  const turn = await runAsk(helpers, id, scratch, (body) => {
    // The child has no subagent tool.
    if (!body.includes('"name":"subagent"')) return fakeGatewayFinalText("CHILD_DONE");
    if (!issued) {
      issued = true;
      return fakeGatewayToolCall("wrapped", "subagent", sent);
    }
    if (!answered) {
      answered = true;
      result = toolResult(body, "wrapped") ?? "";
      replayed = replayedInput(body, "wrapped");
      return fakeGatewayFinalText("DELEGATION_SENT");
    }
    // The child's report starts another turn of the parent.
    return fakeGatewayFinalText("REPORT_READ");
  });
  try {
    return {
      id, tool: "subagent", shape,
      ran: delegated(result),
      replay: replayOf(replayed, inner, sent),
      evidence: { exit: turn.exit, requests: turn.requests, result: result.slice(0, 400), replayed, tail: turn.tail },
    };
  } finally {
    turn.cleanup();
  }
}

/// One reply with `count` shell calls sent as JSON text, then one at the bound
/// and one a byte past it. Every call is one observation.
async function stressCase(helpers: any, count: number, scratch: string): Promise<{ observations: Observation[]; seconds: number; tail: string }> {
  const { fakeGatewaySse, fakeGatewayFinalText } = helpers;
  const calls: Array<{ id: string; shape: Shape; inner: object; sent: object }> = [];
  for (let i = 0; i < count; i++) {
    const inner = { action: "run", command: `printf '%s\\n' ${i} >> stress.txt`, profile: "clean" };
    calls.push({ id: `stress_${i}`, shape: "text", inner, sent: { request: JSON.stringify(inner) } });
  }
  const atBound = { action: "run", command: "printf ran > at-bound.txt", profile: "clean" };
  calls.push({ id: "at_bound", shape: "text", inner: atBound, sent: { request: padded(atBound, BOUND) } });
  const pastBound = { action: "run", command: "printf ran > past-bound.txt", profile: "clean" };
  calls.push({ id: "past_bound", shape: "text_oversized", inner: pastBound, sent: { request: padded(pastBound, BOUND + 1) } });
  let body2 = "";
  let step = 0;
  const started = performance.now();
  const turn = await runAsk(helpers, "stress", scratch, (body) => {
    if (step++ === 0) {
      return fakeGatewaySse([
        ...calls.map((call) => ({ type: "tool-call", toolCallId: call.id, toolName: "shell", input: call.sent })),
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
      ]);
    }
    if (!body2) body2 = body;
    return fakeGatewayFinalText("STRESS_DONE");
  });
  const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
  try {
    const lines = existsSync(join(turn.workspace, "stress.txt"))
      ? new Set(readFileSync(join(turn.workspace, "stress.txt"), "utf8").split("\n").filter(Boolean))
      : new Set<string>();
    const observations = calls.map((call, index): Observation => {
      const result = body2 ? toolResult(body2, call.id) ?? "" : "";
      const replayed = body2 ? replayedInput(body2, call.id) : null;
      let wrote = false;
      if (call.id === "at_bound") wrote = existsSync(join(turn.workspace, "at-bound.txt"));
      else if (call.id === "past_bound") wrote = existsSync(join(turn.workspace, "past-bound.txt"));
      else wrote = lines.has(String(index));
      return {
        id: call.id, tool: "shell", shape: call.shape,
        ran: wrote && shellOk(result),
        replay: replayOf(replayed, call.inner, call.sent),
        evidence: { exit: turn.exit, requests: turn.requests, result: result.slice(0, 200), replayed: null, tail: "" },
      };
    });
    return { observations, seconds, tail: turn.tail };
  } finally {
    turn.cleanup();
  }
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Observation[]): string {
  const value = (o: Observation) =>
    `[tool |-> ${str(o.tool)}, shape |-> ${str(o.shape)}, ran |-> ${o.ran ? "TRUE" : "FALSE"}, replay |-> ${str(o.replay)}]`;
  return [
    "------------------------ MODULE RequestWrapperObserved ------------------------",
    "(* Generated by tests/tla/drivers/agent_runtime/request-wrapper.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], bug: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${bug}-`));
  writeFileSync(join(dir, "RequestWrapperObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Bug = ${str(bug)}`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "RequestWrapperTrace.tla", "trace.cfg", ["RequestWrapper.tla", "RequestWrapperTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) return { verdict: "REJECTED", dir };
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], bug: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), bug, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("request_wrapper");
  const scratch = join(out, "calls");
  mkdirSync(scratch, { recursive: true });
  const started = performance.now();
  const cases = TOOLS.flatMap((tool) => SHAPES.map((shape) => ({ tool, shape })));
  const observations = await Promise.all(cases.map(({ tool, shape }) => {
    const id = `${tool}-${shape}`;
    if (tool === "shell") return shellCase(helpers, id, shape, scratch);
    if (tool === "read_tool_result") return readResultCase(helpers, id, shape, scratch);
    return subagentCase(helpers, id, shape, scratch);
  }));
  if (options.stress > 0) {
    const stress = await stressCase(helpers, options.stress, scratch);
    const ran = stress.observations.filter((o) => o.ran).length;
    console.log(`stress: ${options.stress} JSON-text shell calls plus one at the bound and one past it in one reply, ` +
      `${ran} ran, ${stress.seconds}s, ${stress.tail.split("\n").at(-1)}`);
    observations.push(...stress.observations);
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  console.log(`${observations.length} calls of ${binary} in ${seconds}s`);
  for (const o of observations.slice(0, cases.length)) {
    console.log(`  ${o.tool.padEnd(16)} ${o.shape.padEnd(16)} ran=${o.ran} replay=${o.replay}`);
  }
  console.log(`observations: ${join(out, "observations.json")}`);

  const unserved = observations.find((o) => o.evidence.requests < 2);
  if (unserved) {
    console.log(`TOOL_ERROR: call ${unserved.id} did not run against the local gateway: ${JSON.stringify(unserved.evidence)}`);
    return 2;
  }
  const unknown = observations.find((o) => o.replay === "unknown");
  if (unknown) {
    console.log(`REJECTED: call ${unknown.id} replayed in a form the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }

  const design = await runTrace(observations, "none", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "none", out);
    console.log(`first call the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, the model of fx before the change: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
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
