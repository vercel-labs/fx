// Drives the real fx binary with every shell call the TLA+ model covers and
// records what fx actually did. No model calls: a local fake Gateway serves
// exact argument bytes, so shapes such as invalid JSON reach fx unchanged.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ObservedCall, ObservedTurn } from "./bridge";

export interface Emission { intent: string; shape: string }
export interface TurnSpec { name: string; calls: Emission[] }
export interface RunContext {
  binary: string;
  /** The target worktree's tests/e2e/tmux-helpers.ts module. */
  helpers: any;
  /** Parent directory for fixtures; they are kept as evidence. */
  artifacts: string;
  concurrency?: number;
}

const SESSION_INTENTS = new Set(["type", "observe", "stop"]);
// Prints which shell ran the command. Kept free of quotes so every encoding carries it unchanged.
const MARK = "echo FXT:${BASH_VERSION:+bash}${ZSH_VERSION:+zsh}";
// Bash-style text that zsh treats differently: an unmatched glob, a =word, and ${arr[0]}.
const EQ = "echo before; ls *.fxt-nomatch 2>/dev/null; echo =====; arr=(a b); echo ${arr[0]}; echo after";
const EQ_BASH_LINES = ["before", "=====", "a", "after"];
const TYPED = "FXT_TYPED\n";
const BASH = { kind: "executable", path: "/bin/bash" };

/** fx's current advertised fields, with action. */
function today(intent: string, sid: string): Record<string, unknown> {
  switch (intent) {
    case "run": return { action: "run", command: MARK };
    case "run_eq": return { action: "run", command: EQ };
    case "run_bash": return { action: "run", command: MARK, shell: BASH };
    case "run_bash_tty": return { action: "run", command: MARK, shell: BASH, tty: true, yield_time_ms: 2000 };
    case "type": return { action: "interact", session_id: sid, chars: TYPED, yield_time_ms: 1000 };
    case "observe": return { action: "interact", session_id: sid };
    case "stop": return { action: "stop", session_id: sid };
  }
  throw new Error(`unknown intent ${intent}`);
}

/** The proposed flat form: no action, nothing nested. */
function plan(intent: string, sid: string): Record<string, unknown> {
  switch (intent) {
    case "run": return { command: MARK };
    case "run_eq": return { command: EQ };
    case "run_bash": return { command: MARK, shell: "bash" };
    case "run_bash_tty": return { command: MARK, shell: "bash", interactive: true, wait: 2 };
    case "type": return { session_id: sid, input: TYPED, wait: 1 };
    case "observe": return { session_id: sid, wait: 1 };
    case "stop": return { session_id: sid, stop: true };
  }
  throw new Error(`unknown intent ${intent}`);
}

/** The current field names without action. */
function legacy(intent: string, sid: string): Record<string, unknown> {
  switch (intent) {
    case "run": return { command: MARK, yield_time_ms: 30_000 };
    case "run_eq": return { command: EQ, yield_time_ms: 30_000 };
    case "run_bash": return { command: MARK, shell: BASH };
    case "run_bash_tty": return { command: MARK, shell: BASH, tty: true, yield_time_ms: 2000 };
    case "type": return { session_id: sid, chars: TYPED, yield_time_ms: 1000 };
    case "observe": return { session_id: sid, yield_time_ms: 1000 };
    case "stop": return { session_id: sid, force: true };
  }
  throw new Error(`unknown intent ${intent}`);
}

/** The proposed flat form plus one default-valued field that does not apply. */
function irrelevant(intent: string, sid: string): Record<string, unknown> {
  const base = plan(intent, sid);
  if (intent === "observe") return { ...base, cwd: "." };
  if (intent === "stop") return { ...base, profile: "user" };
  return { ...base, force: false };
}

/** Exact argument text for one modeled call. */
export function encode(e: Emission, sid: string): string {
  switch (e.shape) {
    case "flat_new": return JSON.stringify(plan(e.intent, sid));
    case "flat_action": return JSON.stringify(today(e.intent, sid));
    case "wrapped": return JSON.stringify({ request: today(e.intent, sid) });
    case "wrapped_string": return JSON.stringify({ request: JSON.stringify(today(e.intent, sid)) });
    // A string request whose JSON is cut off before its closing quote and brace.
    case "wrapped_broken": return JSON.stringify({ request: JSON.stringify(today(e.intent, sid)).slice(0, -2) });
    // Unescaped quotes inside a string: the whole argument text is not JSON.
    case "invalid_json": return `${JSON.stringify(today(e.intent, sid)).slice(0, -1)},"note":"say "hi""}`;
    case "legacy_names": return JSON.stringify(legacy(e.intent, sid));
    case "with_irrelevant": return JSON.stringify(irrelevant(e.intent, sid));
    case "both_input": return JSON.stringify({ command: MARK, session_id: sid, input: TYPED, wait: 1 });
    case "both_bare": return JSON.stringify({ command: MARK, session_id: sid });
  }
  throw new Error(`unknown shape ${e.shape}`);
}

const textOf = (value: any): string =>
  typeof value === "string" ? value
    : Array.isArray(value) ? value.map(textOf).join("\n")
      : value && typeof value === "object" ? textOf(value.text ?? value.value ?? value.content ?? "") : "";

function parts(body: string): any[] {
  const prompt = JSON.parse(body).prompt ?? [];
  return prompt.flatMap((m: any) => Array.isArray(m.content) ? m.content : []);
}

/** What fx did, read from the tool result body. */
export function interpret(body: string, sid: string | null): Pick<ObservedCall, "executed" | "decoded" | "outcome"> {
  let value: any;
  try { value = JSON.parse(body); } catch { return { executed: null, decoded: "unknown", outcome: "unknown" }; }
  const error = value?.error;
  if (error?.code === "invalid_shell_request" && error.executed === false) {
    return { executed: false, decoded: "none", outcome: "rejected" };
  }
  if (error?.type === "tool_execution_failed" && /did not run/.test(String(error.message))) {
    return { executed: false, decoded: "none", outcome: "rejected" };
  }
  if (!value || typeof value.state !== "string") return { executed: null, decoded: "unknown", outcome: "unknown" };
  if (sid && value.session_id === sid) {
    const decoded = value.state === "stopped" ? "stop" : (value.accepted_bytes ?? 0) > 0 ? "type" : "observe";
    return { executed: true, decoded, outcome: "ok" };
  }
  const output = String(value.output_delta ?? "").replaceAll("\r", "");
  const lines = output.split("\n").filter(Boolean);
  if (lines[0] === "before") {
    const same = lines.length === EQ_BASH_LINES.length && lines.every((line, i) => line === EQ_BASH_LINES[i]);
    return { executed: true, decoded: "run_eq", outcome: same ? "bash_equivalent" : "zsh_divergent" };
  }
  const shell = /FXT:(bash|zsh)\b/.exec(output)?.[1];
  if (!shell) return { executed: true, decoded: "unknown", outcome: "ok" };
  // Inside a fx TTY run the command's stdout is not a terminal, so read the backend.
  const tty = value.backend === "tty";
  const decoded = shell === "bash" ? (tty ? "run_bash_tty" : "run_bash") : (tty ? "run_tty" : "run");
  return { executed: true, decoded, outcome: "ok" };
}

function sessionResults(home: string): Map<string, string> {
  const results = new Map<string, string>();
  const root = join(home, ".fx", "sessions");
  for (const id of existsSync(root) ? readdirSync(root) : []) {
    const events = join(root, id, "events.jsonl");
    if (!existsSync(events)) continue;
    for (const line of readFileSync(events, "utf8").split("\n").filter(Boolean)) {
      const result = JSON.parse(line).event?.tool_result;
      if (!result?.call_id) continue;
      const artifact = result.artifact_ref ? join(root, id, "tool-results", result.artifact_ref) : "";
      results.set(result.call_id, artifact && existsSync(artifact) ? readFileSync(artifact, "utf8") : String(result.preview ?? ""));
    }
  }
  return results;
}

const LOOP_STOP = "Repeated shell validation failures stopped the tool loop";

export async function runTurn(ctx: RunContext, spec: TurnSpec): Promise<ObservedTurn> {
  const { helpers } = ctx;
  const slug = spec.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase();
  const root = mkdtempSync(join(ctx.artifacts, `${slug}-`));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd);
  const needsSession = spec.calls.some((c) => SESSION_INTENTS.has(c.intent) || c.shape.startsWith("both_"));
  const offset = needsSession ? 1 : 0;
  const requests: string[] = [];
  const sent: string[] = [];
  let sid = "";
  const toolCall = (id: string, input: string) => helpers.fakeGatewaySse([
    { type: "tool-call", toolCallId: id, toolName: "shell", input },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
  const gateway = helpers.startDynamicFakeGateway((body: string) => {
    requests.push(body);
    const index = requests.length - 1;
    if (needsSession && index === 0) {
      return toolCall("setup", JSON.stringify({ action: "run", command: "cat", tty: true, yield_time_ms: 500 }));
    }
    const j = index - offset;
    if (needsSession && j === 0) {
      const setup = parts(body).find((p) => p.type === "tool-result" && p.toolCallId === "setup");
      sid = /"session_id"\s*:\s*"([^"]+)"/.exec(textOf(setup?.output))?.[1] ?? "fxt-missing-session";
    }
    if (j < spec.calls.length) {
      sent[j] = encode(spec.calls[j]!, sid);
      return toolCall(`c${j + 1}`, sent[j]!);
    }
    return helpers.fakeGatewayFinalText("FIXTURE_DONE");
  });
  const env = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HOME: home, TMPDIR: root, SHELL: "/bin/zsh", LANG: "en_US.UTF-8",
    AI_GATEWAY_API_KEY: "synthetic-shell-contract", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TRACE_LOG: join(root, "trace.log"), FX_TRACE_SCOPES: "tool,terminal",
  };
  const child = Bun.spawn([ctx.binary, "ask", "--json", "--full-access", "fixture"], {
    cwd, env, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  let expired = false;
  const timer = setTimeout(() => { expired = true; child.kill("SIGKILL"); }, 90_000);
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
  ]);
  clearTimeout(timer);
  gateway.stop();

  const stored = sessionResults(home);
  const calls: ObservedCall[] = sent.map((text, j) => {
    const id = `c${j + 1}`;
    const next = requests[offset + j + 1];
    const fromRequest = next ? parts(next).find((p) => p.type === "tool-result" && p.toolCallId === id) : undefined;
    const resultBody = fromRequest ? textOf(fromRequest.output) : stored.get(id) ?? "";
    const replayed = next ? parts(next).find((p) => p.type === "tool-call" && p.toolCallId === id) : undefined;
    return {
      id, intent: spec.calls[j]!.intent, shape: spec.calls[j]!.shape, sent: text,
      ...interpret(resultBody, needsSession ? sid : null),
      history: next ? { observed: true, input: replayed ? replayed.input : "fxt-missing-from-history" } : { observed: false },
      resultBody,
    } as ObservedCall;
  });
  // final: fx asked again after the last served call and got the final text.
  // guard: fx stopped after the last served call and reported its loop guard.
  const askedAfterLast = requests.length > offset + sent.length;
  // fx ask --json reports the stop as a stderr notice.
  const guardReported = stderr.includes(LOOP_STOP) || stdout.includes(LOOP_STOP) ||
    existsSync(join(home, ".fx", "sessions")) && readdirSync(join(home, ".fx", "sessions")).some((id) => {
      const events = join(home, ".fx", "sessions", id, "events.jsonl");
      return existsSync(events) && readFileSync(events, "utf8").includes(LOOP_STOP);
    });
  const ended: ObservedTurn["ended"] = expired || exitCode === null ? "unknown"
    : askedAfterLast ? "final" : guardReported ? "guard" : "unknown";
  const turn: ObservedTurn = { name: spec.name, calls, ended };
  writeFileSync(join(root, "observation.json"), JSON.stringify({
    spec, sid, exitCode, expired, requests: requests.length, ended, calls,
    stderrTail: stderr.slice(-2000), stdoutTail: stdout.slice(-2000),
  }, null, 2), { mode: 0o600 });
  if (ended === "unknown" || calls.some((c) => c.executed === null || c.decoded === "unknown")) {
    writeFileSync(join(root, "requests.jsonl"), requests.join("\n") + "\n", { mode: 0o600 });
  }
  return turn;
}

/** One turn per modeled emission, plus multi-call turns for the loop guard. */
export function turnSpecs(emits: string[]): TurnSpec[] {
  const single = emits.map((key) => {
    const [intent, shape] = key.split("/") as [string, string];
    return { name: `${intent} ${shape}`, calls: [{ intent, shape }] };
  });
  return [
    ...single,
    // These shapes are rejected in both designs, so the guard is exercised either way.
    { name: "guard same rejected call repeated", calls: Array(3).fill({ intent: "run", shape: "wrapped_broken" }) },
    { name: "no guard after accepted repeats", calls: Array(2).fill({ intent: "run", shape: "flat_action" }) },
    { name: "no guard for different rejected calls",
      calls: [{ intent: "run", shape: "wrapped_broken" }, { intent: "observe", shape: "both_bare" }] },
  ];
}

export async function collectObservations(ctx: RunContext, specs: TurnSpec[]): Promise<ObservedTurn[]> {
  mkdirSync(ctx.artifacts, { recursive: true, mode: 0o700 });
  const results: ObservedTurn[] = new Array(specs.length);
  let next = 0;
  const worker = async () => {
    while (next < specs.length) {
      const index = next++;
      results[index] = await runTurn(ctx, specs[index]!);
    }
  };
  await Promise.all(Array.from({ length: Math.min(ctx.concurrency ?? 6, specs.length) }, worker));
  return results;
}
