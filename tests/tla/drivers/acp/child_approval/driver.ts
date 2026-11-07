// Runtime driver: runs the real `fx acp` binary in ask mode through plans in
// which subagents need approval, plays the ACP client, records what the client
// sees, and asks TLC whether each run is a behavior of
// tests/tla/acp/AcpChildApproval.tla (through AcpChildApprovalTrace.tla).
//
//   bun tests/tla/drivers/acp/child_approval/driver.ts                  # every plan
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans ordering # two at once, cancel, closed gate, parent stop and failure
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans faults   # error, garbage, cancelled answers
//   bun tests/tla/drivers/acp/child_approval/driver.ts --repeat 10      # run each plan ten times
//
// It first checks that TLC rejects three planted runs, so the trace check can
// say no.
//
// No model calls: the parent and its subagents talk to the fake Gateway in
// tests/e2e/tmux-helpers.ts, and each fx process gets its own home and a
// minimal environment. Run `zig build` first; FX_BIN picks another binary. A
// binary built with -Dsanitize-thread=true fails a plan on any race report.
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT, fxBin, outDir, runTlc, writeJson } from "../../lib/tlc";

const helpers = await import(join(REPO_ROOT, "tests", "e2e", "tmux-helpers.ts"));
const { startDynamicFakeGateway, fakeGatewaySse, fakeGatewayToolCall, fakeGatewayFinalText, FAKE_GATEWAY_MODEL } = helpers;

const WAIT_MS = Number(process.env.FX_CHILD_APPROVAL_WAIT_MS ?? 20_000);
const SPEC_DIR = join(REPO_ROOT, "tests", "tla", "acp");
// Model subagents, in the order the plans name them.
const MODEL: Record<string, string> = { alpha: "c1", beta: "c2" };

type Answer = "allow" | "reject" | "garbage" | "error";
type Obs =
  | { op: "request" | "stop"; c: string }
  | { op: "answer" | "late"; c: string; a: Answer }
  | { op: "cancel" | "promptEnd" | "promptStart" }
  | { op: "final"; results: Record<string, "ran" | "denied" | "none"> };

// ------------------------------------------------------------- ACP client --

type PermissionRequest = { id: number; name: string | null; params: any; withdrawn: boolean; answered: boolean };

class Client {
  private buffer = "";
  private nextId = 100;
  private pending = new Map<number, (message: any) => void>();
  readonly log: any[] = [];
  readonly permissions: PermissionRequest[] = [];
  stderr = "";
  exited = false;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>) {
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        this.buffer += decoder.decode(chunk);
        const parts = this.buffer.split("\n");
        this.buffer = parts.pop() ?? "";
        for (const line of parts) if (line.trim()) this.receive(JSON.parse(line));
      }
      this.exited = true;
    })();
    (async () => {
      const decoder = new TextDecoder();
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += decoder.decode(chunk);
    })();
  }

  private receive(message: any) {
    this.log.push({ at: Date.now(), dir: "in", message });
    if (message.method === "session/request_permission" && message.id !== undefined) {
      const meta = message.params?._meta?.fx?.subagent;
      const path = String(message.params?.toolCall?.rawInput?.path ?? "");
      const name = typeof meta?.name === "string" ? meta.name : /^(\w+)\.txt$/.exec(path)?.[1] ?? null;
      this.permissions.push({ id: message.id, name, params: message.params, withdrawn: false, answered: false });
      return;
    }
    if (message.method === "$/cancel_request") {
      const request = this.permissions.find((entry) => entry.id === message.params?.requestId);
      if (request) request.withdrawn = true;
      return;
    }
    if (message.method === undefined && typeof message.id === "number") this.pending.get(message.id)?.(message);
  }

  send(message: object) {
    this.log.push({ at: Date.now(), dir: "out", message });
    (this.proc.stdin as any).write(`${JSON.stringify(message)}\n`);
    (this.proc.stdin as any).flush?.();
  }

  request(method: string, params: object): Promise<any> {
    const id = this.nextId++;
    const response = new Promise<any>((resolve) => this.pending.set(id, resolve));
    this.send({ jsonrpc: "2.0", id, method, params });
    return response;
  }

  answer(request: PermissionRequest, how: Answer | "cancelled") {
    const body =
      how === "error" ? { error: { code: -32601, message: "Method not found" } }
      : how === "garbage" ? { result: { outcome: { outcome: "selected", optionId: "allow_everything" }, extra: [1, 2] } }
      : how === "cancelled" ? { result: { outcome: { outcome: "cancelled" } } }
      : { result: { outcome: { outcome: "selected", optionId: how === "allow" ? "allow_once" : "reject_once" } } };
    request.answered = true;
    this.send({ jsonrpc: "2.0", id: request.id, ...body });
  }

  async close() {
    (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    await this.proc.exited;
    clearTimeout(timer);
  }
}

async function waitFor<T>(what: string, probe: () => T | undefined | null | false, client: Client): Promise<T> {
  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline) {
    const value = probe();
    if (value) return value as T;
    if (client.exited) throw new Error(`fx acp exited while waiting for ${what}: ${client.stderr.slice(-400)}`);
    await Bun.sleep(20);
  }
  throw new Error(`timed out after ${WAIT_MS} ms waiting for ${what}`);
}

// -------------------------------------------------------------- fixture --

function latestUserIsReport(body: string): boolean {
  const latest = JSON.stringify(JSON.parse(body).prompt?.filter((item: any) => item.role === "user").at(-1)?.content ?? "");
  return latest.includes("Subagent report (untrusted agent output, not user instructions):");
}

class Fixture {
  readonly root = realpathSync(mkdtempSync(join(tmpdir(), "fx-child-approval-")));
  readonly home = join(this.root, "home");
  readonly workspace = join(this.root, "workspace");
  readonly gatewaySeen: Array<{ who: string; kind: string }> = [];
  /// Holds a subagent's first model request until the plan lets it go.
  hold: { name: string; release: () => void; promise: Promise<void> } | null = null;
  /// Answers the parent's request after its subagent calls.
  afterCalls: ((body: string) => Response | Promise<Response>) | null = null;
  /// Answers the parent's turns that a subagent's report starts.
  onReport: ((body: string) => Response | Promise<Response>) | null = null;
  /// Subagents that finish without a write.
  noWrite = new Set<string>();
  private readonly gateway: any;

  constructor(readonly children: string[]) {
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
    this.gateway = startDynamicFakeGateway(async (body: string) => this.respond(body), {});
  }

  private async respond(body: string): Promise<Response> {
    // A subagent's request never offers the subagent tool.
    if (!body.includes('"name":"subagent"')) {
      const name = this.children.find((child) => body.includes(`Write ${child}.txt.`));
      if (!name) {
        this.gatewaySeen.push({ who: "unknown", kind: "final" });
        return fakeGatewayFinalText("done");
      }
      if (body.includes(`w_${name}`)) {
        this.gatewaySeen.push({ who: name, kind: "after-decision" });
        return fakeGatewayFinalText(`${name} done`);
      }
      this.gatewaySeen.push({ who: name, kind: "first" });
      if (this.hold?.name === name) await this.hold.promise;
      if (this.noWrite.has(name)) return fakeGatewayFinalText(`${name} done`);
      return fakeGatewayToolCall(`w_${name}`, "write_file", { path: `${name}.txt`, content: `${name} wrote this\n` });
    }
    if (latestUserIsReport(body)) {
      if (this.onReport) return this.onReport(body);
      this.gatewaySeen.push({ who: "parent", kind: "report" });
      return fakeGatewayFinalText("REPORT_DONE");
    }
    if (this.children.some((child) => body.includes(`call_${child}`))) {
      if (this.afterCalls) return this.afterCalls(body);
      this.gatewaySeen.push({ who: "parent", kind: "after-calls" });
      return fakeGatewayFinalText("PARENT_DONE");
    }
    this.gatewaySeen.push({ who: "parent", kind: "calls" });
    return fakeGatewaySse([
      ...this.children.map((child) => ({
        type: "tool-call",
        toolCallId: `call_${child}`,
        toolName: "subagent",
        input: { request: { action: "message", agent: child, message: `Write ${child}.txt.` } },
      })),
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
    ]);
  }

  holdFirstRequest(name: string) {
    let release = () => {};
    const promise = new Promise<void>((resolve) => { release = resolve; });
    this.hold = { name, release, promise };
  }

  /// Every variable the fx process sees: no inherited credentials, its own
  /// home and profile, no sound, no keychain, and only the fake Gateway.
  env(): Record<string, string> {
    return {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      TMPDIR: process.env.TMPDIR ?? "/tmp",
      HOME: this.home,
      FX_HOME: join(this.home, ".fx"),
      NO_COLOR: "1",
      AI_GATEWAY_API_KEY: "fake-child-approval-key",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_DISABLE_KEYCHAIN: "1",
      FX_SOUND: "0",
      FX_TEST_SKIP_ONBOARDING: "1",
      FX_AUTO_UPGRADE: "0",
      FX_E2E_DISABLE_DOTENV: "1",
      FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${this.gateway.baseUrl}/coding-agent/v1/models`,
      FX_TEST_GATEWAY_CHAT_URL: this.gateway.chatUrl,
    };
  }

  async start(): Promise<{ client: Client; sessionId: string }> {
    const client = new Client(Bun.spawn([fxBin(), "acp"], { cwd: this.workspace, env: this.env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    await client.request("initialize", { protocolVersion: 1 });
    const created = await client.request("session/new", { cwd: this.workspace, mcpServers: [] });
    if (created.error) throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
    const sessionId = created.result.sessionId as string;
    const mode = await client.request("session/set_mode", { sessionId, modeId: "ask" });
    if (mode.error) throw new Error(`session/set_mode failed: ${JSON.stringify(mode.error)}`);
    return { client, sessionId };
  }

  wrote(name: string): boolean {
    return existsSync(join(this.workspace, `${name}.txt`));
  }

  count(who: string, kind: string): number {
    return this.gatewaySeen.filter((entry) => entry.who === who && entry.kind === kind).length;
  }

  seen(who: string, kind: string): boolean {
    return this.count(who, kind) > 0;
  }

  dispose() {
    this.gateway.stop();
    rmSync(this.root, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------- plans --

/// `repeat` runs a plan that many times: another subagent's registry writes
/// can land between an approval and its write, and only some runs show it.
type Plan = {
  name: string;
  group: "ordering" | "faults";
  children: string[];
  prompts: number;
  repeat?: number;
  run: (f: Fixture, c: Client, sessionId: string, obs: Obs[]) => Promise<void>;
};

function expect(condition: unknown, what: string) {
  if (!condition) throw new Error(`expected ${what}`);
}

function prompt(client: Client, sessionId: string, text: string) {
  return client.request("session/prompt", { sessionId, prompt: [{ type: "text", text }] });
}

function requestFor(client: Client, name: string) {
  return client.permissions.find((entry) => entry.name === name);
}

function checkMeta(request: PermissionRequest, sessionId: string, name: string) {
  const meta = request.params?._meta?.fx?.subagent;
  expect(request.params?.sessionId === sessionId, `${name}'s request on the parent session`);
  expect(meta?.name === name && typeof meta?.childId === "string" && typeof meta?.workId === "string", `_meta.fx.subagent naming ${name} with its child and work ids, got ${JSON.stringify(meta)}`);
}

/// The fake Gateway saw each subagent's first request once, and its request
/// after the decision once when the subagent went on.
function expectGateway(f: Fixture, firsts: string[], afterDecision: string[]) {
  expect(f.count("parent", "calls") === 1, `one parent request with the subagent calls, got ${f.count("parent", "calls")}`);
  for (const name of firsts) expect(f.count(name, "first") === 1, `one first request from ${name}, got ${f.count(name, "first")}`);
  for (const name of afterDecision) expect(f.count(name, "after-decision") === 1, `one request from ${name} after its decision, got ${f.count(name, "after-decision")}`);
}

const final = (results: Partial<Record<"alpha" | "beta", "ran" | "denied">>): Obs => ({
  op: "final",
  results: { c1: results.alpha ?? "none", c2: results.beta ?? "none" },
});

const PLANS: Plan[] = [
  {
    name: "two-at-once-reverse", group: "ordering", children: ["alpha", "beta"], prompts: 1, repeat: 5,
    async run(f, client, sessionId, obs) {
      const done = prompt(client, sessionId, "Delegate both writes.");
      await waitFor("two subagent requests open at once", () => client.permissions.length >= 2, client);
      for (const request of client.permissions.slice(0, 2)) obs.push({ op: "request", c: MODEL[request.name!]! });
      const alpha = requestFor(client, "alpha")!, beta = requestFor(client, "beta")!;
      checkMeta(alpha, sessionId, "alpha");
      checkMeta(beta, sessionId, "beta");
      expect(alpha.id !== beta.id, "two request ids");
      client.answer(beta, "reject"); obs.push({ op: "answer", c: "c2", a: "reject" });
      client.answer(alpha, "allow"); obs.push({ op: "answer", c: "c1", a: "allow" });
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      obs.push({ op: "promptEnd" });
      expect(f.wrote("alpha") && !f.wrote("beta"), "only alpha.txt written");
      expect(client.permissions.length === 2, `two requests in all, got ${client.permissions.length}`);
      expectGateway(f, ["alpha", "beta"], ["alpha", "beta"]);
      obs.push(final({ alpha: "ran", beta: "denied" }));
    },
  },
  {
    name: "cancel-then-late-allow", group: "ordering", children: ["alpha"], prompts: 2,
    async run(f, client, sessionId, obs) {
      const first = prompt(client, sessionId, "Delegate the write.");
      const request = await waitFor("alpha's request", () => requestFor(client, "alpha"), client);
      obs.push({ op: "request", c: "c1" });
      client.send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } }); obs.push({ op: "cancel" });
      const cancelled = await waitForResponse(first, client);
      expect(cancelled.result?.stopReason === "cancelled", `cancelled, got ${JSON.stringify(cancelled.result ?? cancelled.error)}`);
      await waitFor("$/cancel_request for alpha's request", () => request.withdrawn, client);
      client.answer(request, "allow"); obs.push({ op: "late", c: "c1", a: "allow" });
      await waitFor("alpha's turn after its decision", () => f.seen("alpha", "after-decision"), client);
      obs.push({ op: "promptStart" });
      const second = await waitForResponse(prompt(client, sessionId, "Continue."), client);
      expect(second.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(second.result ?? second.error)}`);
      obs.push({ op: "promptEnd" });
      expect(!f.wrote("alpha"), "alpha.txt not written after a late allow");
      expect(client.permissions.length === 1, "one request in all");
      expectGateway(f, ["alpha"], ["alpha"]);
      obs.push(final({ alpha: "denied" }));
    },
  },
  {
    name: "ask-after-cancel", group: "ordering", children: ["alpha"], prompts: 2,
    async run(f, client, sessionId, obs) {
      f.holdFirstRequest("alpha");
      const first = prompt(client, sessionId, "Delegate the write.");
      await waitFor("alpha's first model request", () => f.seen("alpha", "first"), client);
      client.send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } }); obs.push({ op: "cancel" });
      const cancelled = await waitForResponse(first, client);
      expect(cancelled.result?.stopReason === "cancelled", `cancelled, got ${JSON.stringify(cancelled.result ?? cancelled.error)}`);
      f.hold!.release();
      await waitFor("alpha's turn after its decision", () => f.seen("alpha", "after-decision"), client);
      expect(client.permissions.length === 0, "no request sent once the prompt had closed");
      obs.push({ op: "promptStart" });
      const second = await waitForResponse(prompt(client, sessionId, "Continue."), client);
      expect(second.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(second.result ?? second.error)}`);
      obs.push({ op: "promptEnd" });
      expect(!f.wrote("alpha"), "alpha.txt not written");
      expectGateway(f, ["alpha"], ["alpha"]);
      obs.push(final({ alpha: "denied" }));
    },
  },
  {
    // The parent stops a subagent that waits on the client: the wait ends,
    // the request is withdrawn, and the prompt returns. A subagent's phase
    // write waits for a parent model reply in flight, so no parent reply is
    // held here: beta's report starts the parent's turn that stops alpha,
    // and beta reports only once alpha's request is at the client.
    name: "parent-stop", group: "ordering", children: ["alpha", "beta"], prompts: 1,
    async run(f, client, sessionId, obs) {
      f.noWrite.add("beta");
      f.holdFirstRequest("beta");
      // The first report turn stops alpha; every later parent request ends.
      f.onReport = () => {
        if (f.seen("parent", "stop")) {
          f.gatewaySeen.push({ who: "parent", kind: "after-stop" });
          return fakeGatewayFinalText("PARENT_STOPPED");
        }
        f.gatewaySeen.push({ who: "parent", kind: "stop" });
        obs.push({ op: "stop", c: "c1" });
        return fakeGatewayToolCall("stop_alpha", "subagent", { request: { action: "stop", agent: "alpha" } });
      };
      const done = prompt(client, sessionId, "Delegate the write, then stop it.");
      const request = await waitFor("alpha's request", () => requestFor(client, "alpha"), client);
      obs.push({ op: "request", c: "c1" });
      checkMeta(request, sessionId, "alpha");
      f.hold!.release();
      await waitFor("$/cancel_request for alpha's request", () => request.withdrawn, client);
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      obs.push({ op: "promptEnd" });
      expect(!f.wrote("alpha"), "alpha.txt not written after the stop");
      expect(!request.answered && client.permissions.length === 1, "one request in all, never answered");
      expectGateway(f, ["alpha", "beta"], []);
      expect(f.count("parent", "stop") === 1 && f.count("parent", "after-stop") >= 1, `one stop and a parent request after it, got ${JSON.stringify(f.gatewaySeen)}`);
      obs.push(final({ alpha: "denied" }));
    },
  },
  {
    // The parent's own turn fails right after it sends its subagent. The
    // prompt stays open for the subagent, so its request still reaches the
    // client, and the allowed write runs.
    name: "parent-fails", group: "ordering", children: ["alpha"], prompts: 1,
    async run(f, client, sessionId, obs) {
      f.afterCalls = () => {
        f.gatewaySeen.push({ who: "parent", kind: "failed" });
        return new Response(JSON.stringify({ error: { message: "invalid request", type: "invalid_request_error" } }), {
          status: 400,
          headers: { "content-type": "application/json" },
        });
      };
      const done = prompt(client, sessionId, "Delegate the write.");
      const request = await waitFor("alpha's request", () => requestFor(client, "alpha"), client);
      obs.push({ op: "request", c: "c1" });
      await waitFor("the parent's failure shown", () => client.log.some((entry) =>
        entry.dir === "in" && JSON.stringify(entry.message).includes("HTTP 400")), client);
      expect(!request.withdrawn, "alpha's request still open after the parent's turn failed");
      client.answer(request, "allow"); obs.push({ op: "answer", c: "c1", a: "allow" });
      // The failed turn sets the prompt's stop reason; the prompt still returns.
      const response = await waitForResponse(done, client);
      expect(response.result !== undefined, `a result, got ${JSON.stringify(response.error)}`);
      obs.push({ op: "promptEnd" });
      expect(f.wrote("alpha"), "alpha.txt written after its allow");
      expectGateway(f, ["alpha"], ["alpha"]);
      expect(f.count("parent", "failed") === 1, `one failed parent request, got ${f.count("parent", "failed")}`);
      obs.push(final({ alpha: "ran" }));
    },
  },
  ...(["error", "garbage", "cancelled"] as const).map((how): Plan => ({
    name: `answer-${how}`, group: "faults", children: ["alpha"], prompts: 1,
    async run(f, client, sessionId, obs) {
      const done = prompt(client, sessionId, "Delegate the write.");
      const request = await waitFor("alpha's request", () => requestFor(client, "alpha"), client);
      obs.push({ op: "request", c: "c1" });
      client.answer(request, how);
      // The model's client answers allow, reject, garbage, or error; a
      // cancelled outcome is a reject.
      obs.push({ op: "answer", c: "c1", a: how === "cancelled" ? "reject" : how });
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      obs.push({ op: "promptEnd" });
      expect(!f.wrote("alpha"), `alpha.txt not written after a ${how} answer`);
      expectGateway(f, ["alpha"], ["alpha"]);
      obs.push(final({ alpha: "denied" }));
    },
  })),
];

async function waitForResponse(response: Promise<any>, client: Client): Promise<any> {
  let settled: any = null;
  response.then((value) => { settled = value; });
  return waitFor("the prompt's response", () => settled, client);
}

// ------------------------------------------------------------------ TLC --

function obsModule(obs: Obs[]): string {
  const s = (value: string) => JSON.stringify(value);
  const record = (o: Obs) => {
    switch (o.op) {
      case "request": case "stop": return `[op |-> ${s(o.op)}, c |-> ${s(o.c)}, a |-> "none", results |-> NoResults]`;
      case "answer": case "late": return `[op |-> ${s(o.op)}, c |-> ${s(o.c)}, a |-> ${s(o.a)}, results |-> NoResults]`;
      case "final": return `[op |-> "final", c |-> "none", a |-> "none", results |-> [c1 |-> ${s(o.results.c1!)}, c2 |-> ${s(o.results.c2!)}]]`;
      default: return `[op |-> ${s(o.op)}, c |-> "none", a |-> "none", results |-> NoResults]`;
    }
  };
  return [
    "---------------------- MODULE AcpChildApprovalObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    'TChildren == {"c1", "c2"}',
    'NoResults == [c1 |-> "none", c2 |-> "none"]',
    "TraceLog == <<",
    obs.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

async function validate(obs: Obs[], prompts: number, dir: string) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpChildApprovalObs.tla"), obsModule(obs));
  writeFileSync(join(dir, "AcpChildApprovalTrace.cfg"), [
    "CONSTANTS",
    "    Children <- TChildren",
    '    Route = "host"',
    "    AtomicGate = TRUE",
    "    StopCancelsWait = TRUE",
    `    MaxPrompts = ${prompts}`,
    "INIT TraceInit",
    "NEXT TraceNext",
    "INVARIANT NotDone",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "AcpChildApprovalTrace.tla", "AcpChildApprovalTrace.cfg", ["AcpChildApproval.tla", "AcpChildApprovalTrace.tla"], SPEC_DIR);
  // TLC reports the NotDone sentinel violated once every observation matched.
  const accepted = run.exitCode === 12 && run.violated === "NotDone";
  return { accepted, exitCode: run.exitCode, violated: run.violated };
}

// ----------------------------------------------------------------- main --

function argument(flag: string): string | null {
  const at = process.argv.indexOf(flag);
  return at >= 0 ? process.argv[at + 1] ?? null : null;
}

const group = argument("--plans") ?? "all";
const only = argument("--only");
const repeatAll = Number(argument("--repeat") ?? "1");
const plans = PLANS.filter((plan) => (group === "all" || plan.group === group) && (only === null || plan.name === only));
if (plans.length === 0) throw new Error(`no plans in group ${group}`);
const out = outDir("child-approval");
console.log(`binary: ${fxBin()}\noutput: ${out}`);
let failed = 0;
let plantedFailed = 0;

// The trace check must be able to say no: TLC must reject each planted run.
const PLANTED: Array<{ name: string; prompts: number; obs: Obs[] }> = [
  { name: "request-after-cancel", prompts: 1, obs: [{ op: "cancel" }, { op: "request", c: "c1" }] },
  { name: "late-allow-ran", prompts: 2, obs: [{ op: "request", c: "c1" }, { op: "cancel" }, { op: "late", c: "c1", a: "allow" }, { op: "promptStart" }, { op: "promptEnd" }, { op: "final", results: { c1: "ran", c2: "none" } }] },
  { name: "rejected-write-ran", prompts: 1, obs: [{ op: "request", c: "c1" }, { op: "request", c: "c2" }, { op: "answer", c: "c2", a: "reject" }, { op: "answer", c: "c1", a: "allow" }, { op: "promptEnd" }, { op: "final", results: { c1: "ran", c2: "ran" } }] },
];
for (const planted of PLANTED) {
  const tlc = await validate(planted.obs, planted.prompts, join(out, "planted", planted.name));
  const rejected = !tlc.accepted && tlc.exitCode === 0;
  if (!rejected) plantedFailed += 1;
  console.log(`${rejected ? "ok  " : "FAIL"}  planted ${planted.name}: ${rejected ? "TLC rejected it" : `TLC exit ${tlc.exitCode}, accepted ${tlc.accepted}`}`);
}
let runs = 0;
const expanded = plans.flatMap((plan) => {
  const times = (plan.repeat ?? 1) * repeatAll;
  return Array.from({ length: times }, (_, n) => ({ ...plan, name: times > 1 ? `${plan.name}-${n + 1}` : plan.name }));
});
for (const plan of expanded) {
  runs += 1;
  const fixture = new Fixture(plan.children);
  const obs: Obs[] = [];
  let client: Client | null = null;
  let verdict = "ok";
  try {
    const started = await fixture.start();
    client = started.client;
    await plan.run(fixture, client, started.sessionId, obs);
    const tlc = await validate(obs, plan.prompts, join(out, plan.name));
    if (!tlc.accepted) verdict = `TLC rejected the run (exit ${tlc.exitCode}, violated ${tlc.violated})`;
    if (client.stderr.includes("ThreadSanitizer")) verdict = "ThreadSanitizer reported a race (see run.json)";
  } catch (err) {
    verdict = (err as Error).message;
  } finally {
    writeJson(join(out, plan.name, "run.json"), { plan: plan.name, verdict, obs, gateway: fixture.gatewaySeen, acp: client?.log ?? [], stderr: client?.stderr.slice(-20000) ?? "" });
    if (client) {
      client.send({ jsonrpc: "2.0", method: "session/cancel", params: {} });
      await client.close();
    }
    fixture.dispose();
  }
  if (verdict !== "ok") failed += 1;
  console.log(`${verdict === "ok" ? "ok  " : "FAIL"}  ${plan.name}: ${verdict === "ok" ? `TLC accepted ${obs.length} observations` : verdict}`);
}
console.log(`${runs - failed}/${runs} plan runs passed, ${PLANTED.length - plantedFailed}/${PLANTED.length} planted runs rejected`);
process.exit(failed === 0 && plantedFailed === 0 ? 0 : 1);
