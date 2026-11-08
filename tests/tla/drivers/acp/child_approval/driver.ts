// Runtime driver: runs the real `fx acp` binary in ask mode through plans in
// which subagents need approval, plays the ACP client, records what the client
// sees, and asks TLC whether each run is a behavior of
// tests/tla/acp/AcpChildApproval.tla (through AcpChildApprovalTrace.tla).
//
//   bun tests/tla/drivers/acp/child_approval/driver.ts                  # every plan
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans ordering # two at once, cancel, closed gate, parent stop and failure
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans faults   # error, garbage, cancelled answers
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans cards    # one card per call, ending once; ids unique in the session, a run's repeated call id, every card closed before a cancel's response
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans capacity # 33 subagents, then the parent's own request
//   bun tests/tla/drivers/acp/child_approval/driver.ts --plans gap      # a cancel between a request's insert and its write
//   bun tests/tla/drivers/acp/child_approval/driver.ts --repeat 10      # run each plan ten times
//
// It first checks that TLC rejects the planted runs, one or more per law, so
// the trace check can say no.
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
// Model subagents, in the order the plans name them. Subagents past these are
// anonymous: the model counts their requests.
const MODEL: Record<string, string> = { alpha: "c1", beta: "c2" };
// The registry holds this many entries (`max_pending_outbound` in
// src/acp/server.zig), and a subagent's request finds one fewer.
const CAPACITY = 32;

type Answer = "allow" | "reject" | "garbage" | "error";
type Status = "completed" | "failed";
type Obs =
  | { op: "request" | "lateRequest" | "stop"; c: string }
  | { op: "announce"; c: string; tc: string }
  | { op: "card"; c: string; status: Status }
  | { op: "answer" | "late"; c: string; a: Answer }
  | { op: "cancel" | "promptEnd" | "response" | "promptStart" | "pRequest" | "pAnswer" | "otherRequest" | "otherAnswer" }
  | { op: "final"; results: Record<string, "ran" | "denied" | "none"> };

// ------------------------------------------------------------- ACP client --

type PermissionRequest = { id: number; name: string | null; params: any; withdrawn: boolean; answered: boolean; sub: boolean };
type Card = { id: string; name: string; model: string | undefined; statuses: string[] };

class Client {
  private buffer = "";
  private nextId = 100;
  private pending = new Map<number, (message: any) => void>();
  readonly log: any[] = [];
  readonly permissions: PermissionRequest[] = [];
  /// Cards of the subagents' writes, by toolCallId, and every other card's id.
  readonly cards = new Map<string, Card>();
  readonly parentCards = new Set<string>();
  /// Requests the client was told to drop before they arrived.
  private readonly withdrawnEarly = new Set<number>();
  /// Every client-visible event, in the order it arrived or was sent; the
  /// plans add what they do.
  obs: Obs[] = [];
  childNames: string[] = [];
  /// The model children of a subagent whose run makes several calls, in call
  /// order; another subagent's one call is MODEL[name].
  runCalls = new Map<string, string[]>();
  private readonly seenCalls = new Map<string, number>();
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

  /// The model child of the next announce or request of `name`'s calls.
  private nextCall(name: string, kind: "announce" | "request"): string | undefined {
    const list = this.runCalls.get(name) ?? (MODEL[name] === undefined ? [] : [MODEL[name]!]);
    const key = `${kind}:${name}`;
    const n = this.seenCalls.get(key) ?? 0;
    this.seenCalls.set(key, n + 1);
    return list[Math.min(n, list.length - 1)];
  }

  private receive(message: any) {
    this.log.push({ at: Date.now(), dir: "in", message });
    if (message.method === "session/request_permission" && message.id !== undefined) {
      const meta = message.params?._meta?.fx?.subagent;
      const path = String(message.params?.toolCall?.rawInput?.path ?? "");
      const name = typeof meta?.name === "string" ? meta.name : /^(\w+)\.txt$/.exec(path)?.[1] ?? null;
      const early = this.withdrawnEarly.has(message.id);
      this.permissions.push({ id: message.id, name, params: message.params, withdrawn: early, answered: false, sub: meta !== undefined });
      const model = name === null || meta === undefined ? undefined : this.nextCall(name, "request");
      if (meta === undefined) this.obs.push({ op: "pRequest" });
      else if (model === undefined) this.obs.push({ op: "otherRequest" });
      else this.obs.push({ op: early ? "lateRequest" : "request", c: model });
      return;
    }
    if (message.method === "$/cancel_request") {
      const request = this.permissions.find((entry) => entry.id === message.params?.requestId);
      if (request) request.withdrawn = true;
      else this.withdrawnEarly.add(message.params?.requestId);
      return;
    }
    if (message.method === "session/update") this.receiveUpdate(message.params?.update);
    if (message.method === undefined && typeof message.id === "number") this.pending.get(message.id)?.(message);
  }

  /// A card's announcement and its end are what the model watches.
  private receiveUpdate(update: any) {
    const id = update?.toolCallId;
    if (typeof id !== "string") return;
    if (update.sessionUpdate === "tool_call") {
      const path = String(update.rawInput?.path ?? "");
      const name = this.childNames.find((child) => path === `${child}.txt` || path === `${child}2.txt`);
      if (name === undefined) {
        this.parentCards.add(id);
        return;
      }
      const model = this.nextCall(name, "announce");
      this.cards.set(id, { id, name, model, statuses: [update.status] });
      if (model !== undefined) this.obs.push({ op: "announce", c: model, tc: id });
      return;
    }
    const card = this.cards.get(id);
    if (!card || update.sessionUpdate !== "tool_call_update") return;
    card.statuses.push(update.status);
    const model = card.model;
    if (model !== undefined && (update.status === "completed" || update.status === "failed")) {
      this.obs.push({ op: "card", c: model, status: update.status });
    }
  }

  send(message: object) {
    this.log.push({ at: Date.now(), dir: "out", message });
    (this.proc.stdin as any).write(`${JSON.stringify(message)}\n`);
    (this.proc.stdin as any).flush?.();
  }

  /// A prompt's response is observed as it arrives: after every card update
  /// it follows. A prompt that ends without a cancel ends first, which closes
  /// its gate; a cancel was observed when the plan sent it.
  request(method: string, params: object): Promise<any> {
    const id = this.nextId++;
    const response = new Promise<any>((resolve) => this.pending.set(id, (message: any) => {
      if (method === "session/prompt") {
        if (message.result?.stopReason !== "cancelled") this.obs.push({ op: "promptEnd" });
        this.obs.push({ op: "response" });
      }
      resolve(message);
    }));
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
  /// The call id every subagent's write uses, when the plan sets one, as
  /// models of different conversations number their calls alike.
  childCallId: string | null = null;
  /// Subagents whose model writes twice in one run and numbers both writes
  /// alike: `<name>.txt`, then `<name>2.txt`, both as call_1.
  writesTwice = new Set<string>();
  /// Environment for the fx process beyond the fixture's own.
  extraEnv: Record<string, string> = {};
  private readonly gateway: any;

  constructor(readonly children: string[]) {
    mkdirSync(join(this.home, ".fx"), { recursive: true, mode: 0o700 });
    mkdirSync(this.workspace, { recursive: true, mode: 0o700 });
    writeFileSync(join(this.home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false })}\n`, { mode: 0o600 });
    this.gateway = startDynamicFakeGateway(async (body: string) => this.respond(body), {});
  }

  private callId(name: string): string {
    return this.childCallId ?? `w_${name}`;
  }

  private async respond(body: string): Promise<Response> {
    // A subagent's request never offers the subagent tool.
    if (!body.includes('"name":"subagent"')) {
      const name = this.children.find((child) => body.includes(`Write ${child}.txt.`));
      if (!name) {
        this.gatewaySeen.push({ who: "unknown", kind: "final" });
        return fakeGatewayFinalText("done");
      }
      if (this.writesTwice.has(name)) {
        const decided = (JSON.parse(body).prompt ?? []).filter((item: any) => item.role === "tool").length;
        if (decided >= 2) {
          this.gatewaySeen.push({ who: name, kind: "after-decision" });
          return fakeGatewayFinalText(`${name} done`);
        }
        this.gatewaySeen.push({ who: name, kind: decided === 0 ? "first" : "second" });
        const file = decided === 0 ? `${name}.txt` : `${name}2.txt`;
        return fakeGatewayToolCall("call_1", "write_file", { path: file, content: `${name} wrote ${file}\n` });
      }
      if (body.includes(this.callId(name))) {
        this.gatewaySeen.push({ who: name, kind: "after-decision" });
        return fakeGatewayFinalText(`${name} done`);
      }
      this.gatewaySeen.push({ who: name, kind: "first" });
      if (this.hold?.name === name) await this.hold.promise;
      if (this.noWrite.has(name)) return fakeGatewayFinalText(`${name} done`);
      return fakeGatewayToolCall(this.callId(name), "write_file", { path: `${name}.txt`, content: `${name} wrote this\n` });
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
      ...this.extraEnv,
    };
  }

  async start(): Promise<{ client: Client; sessionId: string }> {
    const client = new Client(Bun.spawn([fxBin(), "acp"], { cwd: this.workspace, env: this.env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    client.childNames = this.children;
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
  group: "ordering" | "faults" | "cards" | "capacity" | "gap";
  children: string[];
  prompts: number;
  /// The modeled children c1 and c2 are two calls of one subagent run.
  oneRun?: boolean;
  repeat?: number;
  setup?: (f: Fixture) => void;
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

/// A card is announced pending, may move to in progress, and ends once, with
/// the status the plan expects, which is its last update.
function checkCard(client: Client, request: PermissionRequest, status: Status) {
  const id = request.params?.toolCall?.toolCallId;
  const card = client.cards.get(id);
  expect(card !== undefined, `a card for ${id}, which its request names`);
  const statuses = card!.statuses;
  expect(statuses[0] === "pending", `${id}'s card announced pending, got ${JSON.stringify(statuses)}`);
  const finals = statuses.filter((s) => s === "completed" || s === "failed");
  expect(finals.length === 1 && statuses.at(-1) === status, `${id}'s card ended once as ${status}, got ${JSON.stringify(statuses)}`);
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
      const alpha = requestFor(client, "alpha")!, beta = requestFor(client, "beta")!;
      checkMeta(alpha, sessionId, "alpha");
      checkMeta(beta, sessionId, "beta");
      expect(alpha.id !== beta.id, "two request ids");
      client.answer(beta, "reject"); obs.push({ op: "answer", c: "c2", a: "reject" });
      client.answer(alpha, "allow"); obs.push({ op: "answer", c: "c1", a: "allow" });
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      expect(f.wrote("alpha") && !f.wrote("beta"), "only alpha.txt written");
      expect(client.permissions.length === 2, `two requests in all, got ${client.permissions.length}`);
      checkCard(client, alpha, "completed");
      checkCard(client, beta, "failed");
      expectGateway(f, ["alpha", "beta"], ["alpha", "beta"]);
      obs.push(final({ alpha: "ran", beta: "denied" }));
    },
  },
  {
    name: "cancel-then-late-allow", group: "ordering", children: ["alpha"], prompts: 2,
    async run(f, client, sessionId, obs) {
      const first = prompt(client, sessionId, "Delegate the write.");
      const request = await waitFor("alpha's request", () => requestFor(client, "alpha"), client);
      client.send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } }); obs.push({ op: "cancel" });
      const cancelled = await waitForResponse(first, client);
      expect(cancelled.result?.stopReason === "cancelled", `cancelled, got ${JSON.stringify(cancelled.result ?? cancelled.error)}`);
      await waitFor("$/cancel_request for alpha's request", () => request.withdrawn, client);
      client.answer(request, "allow"); obs.push({ op: "late", c: "c1", a: "allow" });
      await waitFor("alpha's turn after its decision", () => f.seen("alpha", "after-decision"), client);
      obs.push({ op: "promptStart" });
      const second = await waitForResponse(prompt(client, sessionId, "Continue."), client);
      expect(second.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(second.result ?? second.error)}`);
      expect(!f.wrote("alpha"), "alpha.txt not written after a late allow");
      expect(client.permissions.length === 1, "one request in all");
      checkCard(client, request, "failed");
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
      expect(client.permissions.length === 0 && client.cards.size === 0, "no request and no card once the prompt had closed");
      obs.push({ op: "promptStart" });
      const second = await waitForResponse(prompt(client, sessionId, "Continue."), client);
      expect(second.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(second.result ?? second.error)}`);
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
      checkMeta(request, sessionId, "alpha");
      f.hold!.release();
      await waitFor("$/cancel_request for alpha's request", () => request.withdrawn, client);
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      expect(!f.wrote("alpha"), "alpha.txt not written after the stop");
      expect(!request.answered && client.permissions.length === 1, "one request in all, never answered");
      checkCard(client, request, "failed");
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
      await waitFor("the parent's failure shown", () => client.log.some((entry) =>
        entry.dir === "in" && JSON.stringify(entry.message).includes("HTTP 400")), client);
      expect(!request.withdrawn, "alpha's request still open after the parent's turn failed");
      client.answer(request, "allow"); obs.push({ op: "answer", c: "c1", a: "allow" });
      // The failed turn sets the prompt's stop reason; the prompt still returns.
      const response = await waitForResponse(done, client);
      expect(response.result !== undefined, `a result, got ${JSON.stringify(response.error)}`);
      expect(f.wrote("alpha"), "alpha.txt written after its allow");
      checkCard(client, request, "completed");
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
      client.answer(request, how);
      // The model's client answers allow, reject, garbage, or error; a
      // cancelled outcome is a reject.
      obs.push({ op: "answer", c: "c1", a: how === "cancelled" ? "reject" : how });
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      expect(!f.wrote("alpha"), `alpha.txt not written after a ${how} answer`);
      checkCard(client, request, "failed");
      expectGateway(f, ["alpha"], ["alpha"]);
      obs.push(final({ alpha: "denied" }));
    },
  })),
  {
    // Both subagents number their write call_1. Each card and request carries
    // its child id with it, so no two ids in the session are alike.
    name: "shared-call-ids", group: "cards", children: ["alpha", "beta"], prompts: 1, repeat: 3,
    setup(f) { f.childCallId = "call_1"; },
    async run(f, client, sessionId, obs) {
      const done = prompt(client, sessionId, "Delegate both writes.");
      await waitFor("two subagent requests open at once", () => client.permissions.length >= 2, client);
      const alpha = requestFor(client, "alpha")!, beta = requestFor(client, "beta")!;
      checkMeta(alpha, sessionId, "alpha");
      checkMeta(beta, sessionId, "beta");
      const ids = [alpha, beta].map((request) => request.params?.toolCall?.toolCallId);
      expect(ids[0] !== ids[1], `two different toolCallIds, got ${JSON.stringify(ids)}`);
      expect(ids[0] === `${alpha.params._meta.fx.subagent.childId}:1:call_1` && ids[1] === `${beta.params._meta.fx.subagent.childId}:1:call_1`,
        `each id led by its child id and the call's order in its run, got ${JSON.stringify(ids)}`);
      client.answer(alpha, "allow"); obs.push({ op: "answer", c: "c1", a: "allow" });
      client.answer(beta, "reject"); obs.push({ op: "answer", c: "c2", a: "reject" });
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      expect(f.wrote("alpha") && !f.wrote("beta"), "only alpha.txt written");
      checkCard(client, alpha, "completed");
      checkCard(client, beta, "failed");
      obs.push(final({ alpha: "ran", beta: "denied" }));
    },
  },
  {
    // One subagent's model numbers both of its writes call_1. Each call is
    // announced with a card of its own, whose id carries the call's order in
    // its run, and each card is announced pending and ends once, with its
    // own call's status.
    name: "repeated-call-id", group: "cards", children: ["alpha"], prompts: 1, oneRun: true, repeat: 3,
    setup(f) { f.writesTwice.add("alpha"); },
    async run(f, client, sessionId, obs) {
      client.runCalls.set("alpha", ["c1", "c2"]);
      const done = prompt(client, sessionId, "Delegate the writes.");
      const first = await waitFor("alpha's first request", () => client.permissions[0], client);
      checkMeta(first, sessionId, "alpha");
      client.answer(first, "allow"); obs.push({ op: "answer", c: "c1", a: "allow" });
      const second = await waitFor("alpha's second request", () => client.permissions[1], client);
      client.answer(second, "allow"); obs.push({ op: "answer", c: "c2", a: "allow" });
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      const childId = first.params?._meta?.fx?.subagent?.childId;
      const ids = [first, second].map((request) => request.params?.toolCall?.toolCallId);
      expect(ids[0] === `${childId}:1:call_1` && ids[1] === `${childId}:2:call_1`, `ids led by the child id and the call's order, got ${JSON.stringify(ids)}`);
      expect(f.wrote("alpha") && existsSync(join(f.workspace, "alpha2.txt")), "both files written");
      checkCard(client, first, "completed");
      checkCard(client, second, "completed");
      expect(f.count("alpha", "first") === 1 && f.count("alpha", "second") === 1 && f.count("alpha", "after-decision") === 1,
        `alpha's three model requests, got ${JSON.stringify(f.gatewaySeen)}`);
      obs.push({ op: "final", results: { c1: "ran", c2: "ran" } });
    },
  },
  {
    // session/cancel with two subagent requests open. Each card's closing
    // update is read before the prompt's response, as ACP's prompt turn
    // requires, and the subagents' own later ends add no update.
    name: "cancel-closes-cards", group: "cards", children: ["alpha", "beta"], prompts: 1, repeat: 3,
    async run(f, client, sessionId, obs) {
      const done = prompt(client, sessionId, "Delegate both writes.");
      await waitFor("two subagent requests open", () => client.permissions.length >= 2, client);
      const alpha = requestFor(client, "alpha")!, beta = requestFor(client, "beta")!;
      client.send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } }); obs.push({ op: "cancel" });
      const cancelled = await waitForResponse(done, client);
      expect(cancelled.result?.stopReason === "cancelled", `cancelled, got ${JSON.stringify(cancelled.result ?? cancelled.error)}`);
      const responseAt = client.log.findIndex((entry) => entry.dir === "in" && entry.message.result?.stopReason === "cancelled");
      for (const request of [alpha, beta]) {
        const id = request.params?.toolCall?.toolCallId;
        const closedAt = client.log.findIndex((entry) => entry.dir === "in" && entry.message.method === "session/update" &&
          entry.message.params?.update?.toolCallId === id && entry.message.params.update.status === "failed");
        expect(closedAt >= 0 && closedAt < responseAt, `${id}'s card closed (at ${closedAt}) before the response (at ${responseAt})`);
      }
      await waitFor("both subagents' turns after their decision", () => f.seen("alpha", "after-decision") && f.seen("beta", "after-decision"), client);
      expect(!f.wrote("alpha") && !f.wrote("beta"), "no file written after the cancel");
      checkCard(client, alpha, "failed");
      checkCard(client, beta, "failed");
      expectGateway(f, ["alpha", "beta"], ["alpha", "beta"]);
      obs.push(final({ alpha: "denied", beta: "denied" }));
    },
  },
  {
    // Past the registry's size: 32 writers ask, 31 are asked and 1 is refused,
    // and a parent's own write still reaches the client, because a subagent
    // leaves the registry's last slot to it. zz reports without a write once
    // the flood is in, which starts the parent's turn that writes root.txt.
    name: "flood-then-parent", group: "capacity", children: [...Array.from({ length: CAPACITY }, (_, n) => `s${String(n + 1).padStart(2, "0")}`), "zz"], prompts: 1,
    async run(f, client, sessionId, obs) {
      const writers = f.children.filter((name) => name !== "zz");
      f.noWrite.add("zz");
      f.holdFirstRequest("zz");
      let parentWrote = false;
      f.onReport = () => {
        if (parentWrote) return fakeGatewayFinalText("PARENT_DONE");
        parentWrote = true;
        return fakeGatewayToolCall("w_root", "write_file", { path: "root.txt", content: "root wrote this\n" });
      };
      const done = prompt(client, sessionId, "Delegate forty writes.");
      await waitFor("every writer asked or was refused", () =>
        client.permissions.length + writers.filter((name) => f.count(name, "after-decision") === 1).length >= writers.length, client);
      const subagentRequests = client.permissions.filter((request) => request.sub);
      expect(subagentRequests.length === CAPACITY - 1, `${CAPACITY - 1} subagent requests open, got ${subagentRequests.length}`);
      f.hold!.release();
      const own = await waitFor("the parent's own request", () => client.permissions.find((request) => !request.sub), client);
      expect(own.params?.toolCall?.rawInput?.path === "root.txt", `the parent's request for root.txt, got ${JSON.stringify(own.params?.toolCall?.rawInput)}`);
      expect(!client.permissions.some((request) => request.withdrawn), "no request withdrawn yet");
      for (const request of client.permissions) {
        client.answer(request, "allow");
        obs.push(request.sub ? { op: "otherAnswer" } : { op: "pAnswer" });
      }
      const response = await waitForResponse(done, client);
      expect(response.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(response.result ?? response.error)}`);
      expect(f.wrote("root"), "root.txt written after the parent's own allow");
      expect(writers.filter((name) => f.wrote(name)).length === CAPACITY - 1, `${CAPACITY - 1} writers wrote their file`);
      obs.push(final({}));
    },
  },
  {
    // A cancel lands after a request is inserted and before it is written.
    // The request is written after its $/cancel_request went out, so the
    // client must be told again that it is withdrawn.
    name: "cancel-between-insert-and-write", group: "gap", children: ["alpha"], prompts: 2,
    setup(f) {
      f.extraEnv.FX_TEST_ACP_REQUEST_INSERTED = join(f.root, "request-inserted");
      f.extraEnv.FX_TEST_ACP_REQUEST_RELEASE = join(f.root, "request-release");
    },
    async run(f, client, sessionId, obs) {
      const inserted = f.extraEnv.FX_TEST_ACP_REQUEST_INSERTED!;
      const first = prompt(client, sessionId, "Delegate the write.");
      await waitFor("alpha's request held after its insert", () => existsSync(inserted) && client.cards.size === 1, client);
      expect(client.permissions.length === 0, "the request is not written yet");
      client.send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } }); obs.push({ op: "cancel" });
      const cancelled = await waitForResponse(first, client);
      expect(cancelled.result?.stopReason === "cancelled", `cancelled, got ${JSON.stringify(cancelled.result ?? cancelled.error)}`);
      writeFileSync(f.extraEnv.FX_TEST_ACP_REQUEST_RELEASE!, "");
      await waitFor("alpha's turn after its decision", () => f.seen("alpha", "after-decision"), client);
      obs.push({ op: "promptStart" });
      const second = await waitForResponse(prompt(client, sessionId, "Continue."), client);
      expect(second.result?.stopReason === "end_turn", `end_turn, got ${JSON.stringify(second.result ?? second.error)}`);
      const request = client.permissions[0];
      expect(request !== undefined, "alpha's request written after the cancel");
      // The client was told, after the request, that it is withdrawn.
      const written = client.log.findIndex((entry) => entry.dir === "in" && entry.message.id === request!.id && entry.message.method === "session/request_permission");
      const withdrawnAfter = client.log.findIndex((entry, at) => at > written && entry.dir === "in" &&
        entry.message.method === "$/cancel_request" && entry.message.params?.requestId === request!.id);
      expect(written >= 0 && withdrawnAfter > written, "a $/cancel_request after the request, so the client is left showing nothing");
      expect(!f.wrote("alpha"), "alpha.txt not written");
      checkCard(client, request!, "failed");
      expectGateway(f, ["alpha"], ["alpha"]);
      obs.push(final({ alpha: "denied" }));
    },
  },
];

async function waitForResponse(response: Promise<any>, client: Client): Promise<any> {
  let settled: any = null;
  response.then((value) => { settled = value; });
  return waitFor("the prompt's response", () => settled, client);
}

// ------------------------------------------------------------------ TLC --

function obsModule(obs: Obs[], parentIds: string[]): string {
  const s = (value: string) => JSON.stringify(value);
  const record = (o: Obs) => {
    const base = { c: "none", a: "none", tc: "none", status: "none" };
    const fields = (extra: Partial<typeof base>, results = "NoResults") => {
      const all = { ...base, ...extra };
      return `[op |-> ${s(o.op)}, c |-> ${s(all.c)}, a |-> ${s(all.a)}, tc |-> ${s(all.tc)}, status |-> ${s(all.status)}, results |-> ${results}]`;
    };
    switch (o.op) {
      case "request": case "lateRequest": case "stop": return fields({ c: o.c });
      case "announce": return fields({ c: o.c, tc: o.tc });
      case "card": return fields({ c: o.c, status: o.status });
      case "answer": case "late": return fields({ c: o.c, a: o.a });
      case "final": return fields({}, `[c1 |-> ${s(o.results.c1!)}, c2 |-> ${s(o.results.c2!)}]`);
      default: return fields({});
    }
  };
  return [
    "---------------------- MODULE AcpChildApprovalObs ----------------------",
    "(* Generated from one observed fx acp run. *)",
    'TChildren == {"c1", "c2"}',
    'NoResults == [c1 |-> "none", c2 |-> "none"]',
    `ParentIds == {${parentIds.map(s).join(", ")}}`,
    "TraceLog == <<",
    obs.map((o) => `  ${record(o)}`).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

async function validate(obs: Obs[], parentIds: string[], prompts: number, dir: string, oneRun = false) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "AcpChildApprovalObs.tla"), obsModule(obs, parentIds));
  writeFileSync(join(dir, "AcpChildApprovalTrace.cfg"), [
    "CONSTANTS",
    "    Children <- TChildren",
    '    Route = "host"',
    "    AtomicGate = TRUE",
    "    StopCancelsWait = TRUE",
    `    MaxPrompts = ${prompts}`,
    "    FinishCards = TRUE",
    "    SpawnClosesGate = TRUE",
    "    PrefixIds = TRUE",
    "    ReserveSlot = TRUE",
    "    ResendCancel = TRUE",
    "    OthersMayAsk = TRUE",
    `    Capacity = ${CAPACITY}`,
    `    OneRun = ${oneRun ? "TRUE" : "FALSE"}`,
    // The prompt's response and the closing of its cards are watched in every
    // run; the refusal cause and the other request kinds are not observable
    // from the client's side.
    '    Track = {"responses"}',
    '    Fixed = {"seq", "closeCards", "cardGate", "carryCause", "stopRefuses", "steerCloses"}',
    "    Kinds = {}",
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

// The trace check must be able to say no: TLC must reject each planted run,
// each of which breaks one law the model holds.
const ask = (c: string, tc: string): Obs[] => [{ op: "announce", c, tc }, { op: "request", c }];
const PLANTED: Array<{ name: string; prompts: number; parentIds?: string[]; oneRun?: boolean; obs: Obs[] }> = [
  // A request shown after the cancel, with no withdrawal after it.
  { name: "request-after-cancel", prompts: 1, obs: [{ op: "announce", c: "c1", tc: "x1" }, { op: "cancel" }, { op: "request", c: "c1" }] },
  { name: "late-allow-ran", prompts: 2, obs: [...ask("c1", "x1"), { op: "cancel" }, { op: "card", c: "c1", status: "failed" }, { op: "response" }, { op: "late", c: "c1", a: "allow" }, { op: "promptStart" }, { op: "promptEnd" }, { op: "response" }, { op: "final", results: { c1: "ran", c2: "none" } }] },
  { name: "rejected-write-ran", prompts: 1, obs: [...ask("c1", "x1"), ...ask("c2", "x2"), { op: "answer", c: "c2", a: "reject" }, { op: "answer", c: "c1", a: "allow" }, { op: "card", c: "c1", status: "completed" }, { op: "card", c: "c2", status: "failed" }, { op: "promptEnd" }, { op: "response" }, { op: "final", results: { c1: "ran", c2: "ran" } }] },
  // A card announced and never ended.
  { name: "card-never-ended", prompts: 1, obs: [...ask("c1", "x1"), { op: "answer", c: "c1", a: "allow" }, { op: "promptEnd" }, { op: "response" }, { op: "final", results: { c1: "ran", c2: "none" } }] },
  // A card that ends twice, or with a status its call did not have.
  { name: "card-ended-twice", prompts: 1, obs: [...ask("c1", "x1"), { op: "answer", c: "c1", a: "allow" }, { op: "card", c: "c1", status: "completed" }, { op: "card", c: "c1", status: "failed" }] },
  { name: "card-wrong-status", prompts: 1, obs: [...ask("c1", "x1"), { op: "answer", c: "c1", a: "reject" }, { op: "card", c: "c1", status: "completed" }] },
  // Two subagent cards with one id, and a subagent card with the parent's.
  { name: "shared-id", prompts: 1, obs: [{ op: "announce", c: "c1", tc: "call_1" }, { op: "announce", c: "c2", tc: "call_1" }] },
  { name: "parent-id", prompts: 1, parentIds: ["call_1"], obs: [{ op: "announce", c: "c1", tc: "call_1" }] },
  // One run's second call whose card has the id of its first call's.
  { name: "repeated-run-id", prompts: 1, oneRun: true, obs: [{ op: "announce", c: "c1", tc: "k:call_1" }, { op: "request", c: "c1" }, { op: "answer", c: "c1", a: "allow" }, { op: "card", c: "c1", status: "completed" }, { op: "announce", c: "c2", tc: "k:call_1" }] },
  // The response before a card the cancel left open ends.
  { name: "response-before-card-closed", prompts: 1, obs: [...ask("c1", "x1"), { op: "cancel" }, { op: "response" }, { op: "card", c: "c1", status: "failed" }] },
  // A card that ends after the response.
  { name: "card-after-response", prompts: 1, obs: [...ask("c1", "x1"), { op: "answer", c: "c1", a: "allow" }, { op: "promptEnd" }, { op: "response" }, { op: "card", c: "c1", status: "completed" }] },
  // A 32nd subagent request: the last slot is the parent's.
  { name: "subagent-takes-last-slot", prompts: 1, obs: Array.from({ length: CAPACITY }, (): Obs => ({ op: "otherRequest" })) },
];
for (const planted of PLANTED) {
  const tlc = await validate(planted.obs, planted.parentIds ?? [], planted.prompts, join(out, "planted", planted.name), planted.oneRun ?? false);
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
  plan.setup?.(fixture);
  const obs: Obs[] = [];
  let client: Client | null = null;
  let verdict = "ok";
  try {
    const started = await fixture.start();
    client = started.client;
    client.obs = obs;
    await plan.run(fixture, client, started.sessionId, obs);
    const tlc = await validate(obs, [...client.parentCards], plan.prompts, join(out, plan.name), plan.oneRun ?? false);
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
