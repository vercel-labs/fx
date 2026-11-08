// Runtime driver: drives the real `fx acp` binary against a local fake
// Gateway and asks TLC whether what a client sees is a behavior of the models
// in tests/tla/acp/:
//   - the stop reason of finished, length-limited, step-limited, kept-failure,
//     dropped-failure, cancelled, and steered turns, and whether the next
//     prompt's request holds the turn the stop reason ended
//     (AcpStopReasons.tla, through AcpStopReasonsTrace.tla). A kept failure is
//     a failed turn fx saves (an empty reply twice, malformed tool arguments,
//     a repeated terminal validation or shell failure, a failed request after
//     a tool step); a dropped failure is one it leaves out (HTTP 401 or 400 on
//     the first request, a stream cut inside a tool call);
//   - the config options of session/new, session/set_config_option, and
//     session/load (AcpConfigCategories.tla, through
//     AcpConfigCategoriesTrace.tla);
//   - the progress text of shell commands whose output chunks end inside
//     characters, on stdout and stderr (AcpCommandOutput.tla, through
//     AcpCommandOutputTrace.tla). Each plan makes the command runner cut
//     output where the plan says: a line end, 4096 bytes without one, or exit.
//     The command holds on a named pipe after each write until the driver has
//     read that write's progress frame, so no run depends on timing.
//
//   bun tests/tla/drivers/acp/conformance/driver.ts --label main   # after zig build
//
// No live model calls: every fx process gets an environment written out in
// full, with a fake key and the fake Gateway's URLs, and each run checks the
// fake Gateway saw its requests.
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { REPO_ROOT, outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "../../lib/tlc";
import {
  Acp,
  byteClass,
  collapse,
  textClasses,
  validate,
  type OptionsObservation,
  type OutputEvent,
  type OutputFrame,
  type StopObservation,
} from "./trace";

type Gateway = { baseUrl: string; chatUrl: string; requests: unknown[]; stop: () => void };
type Helpers = {
  startFakeGateway: (responses: unknown[], options?: object) => Gateway;
  startDynamicFakeGateway: (respond: (body: string) => Response | Promise<Response>, options?: object) => Gateway;
  fakeGatewayFinalText: (text: string) => Response;
  fakeGatewayToolCall: (id: string, name: string, input: object) => Response;
  fakeGatewaySse: (events: object[]) => Response;
};

// A model with both speed lanes, so session/new lists fast and ultrafast.
const LANES_MODEL = "openai/gpt-6-astra";
const PLAIN_MODEL = "anthropic/claude-plain";
const CATALOG = [
  {
    id: LANES_MODEL, name: "GPT-6 Astra", type: "language", owned_by: "openai", tags: ["tool-use", "reasoning"],
    reasoning_options: [{ type: "effort", values: ["high", "xhigh"] }],
    pricing: {
      service_tiers: {
        priority: { input: "0.00003", output: "0.00015" },
        ultrafast: { input: "0.00006", output: "0.0003" },
      },
    },
  },
  { id: PLAIN_MODEL, name: "Claude Plain", type: "language", owned_by: "anthropic", tags: ["tool-use"] },
];

// ------------------------------------------------------------- processes --

type Run = { root: string; home: string; workspace: string };

function makeRun(prefix: string, settings: object = {}): Run {
  const root = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), `${JSON.stringify({ session_titles: false, ...settings })}\n`, { mode: 0o600 });
  return { root, home, workspace };
}

/// The whole environment of an fx process under test, written out: nothing
/// is inherited, so no real credential or Gateway URL can reach it.
function fxEnvironment(run: Run, gateway: Gateway, extra: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    SHELL: "/bin/sh",
    HOME: run.home,
    FX_HOME: join(run.home, ".fx"),
    TMPDIR: tmpdir(),
    NO_COLOR: "1",
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_AUTO_UPGRADE: "0",
    FX_E2E_DISABLE_DOTENV: "1",
    FX_TEST_SKIP_ONBOARDING: "1",
    AI_GATEWAY_API_KEY: "acp-conformance-fake-key",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    ...extra,
  };
}

function spawnAcp(fxBin: string, run: Run, gateway: Gateway, extra: Record<string, string> = {}): Acp {
  return new Acp(Bun.spawn([fxBin, "acp"], {
    cwd: run.workspace,
    env: fxEnvironment(run, gateway, extra),
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  }));
}

async function startSession(acp: Acp, run: Run, mode: string): Promise<{ sessionId: string; configOptions: any[] }> {
  await acp.call("initialize", { protocolVersion: 1 });
  const created = await acp.call("session/new", { cwd: run.workspace, mcpServers: [] });
  const sessionId = created?.result?.sessionId;
  if (typeof sessionId !== "string") throw new Error(`session/new failed: ${JSON.stringify(created)}`);
  const moded = await acp.call("session/set_mode", { sessionId, modeId: mode });
  if (moded?.error) throw new Error(`session/set_mode failed: ${JSON.stringify(moded.error)}`);
  return { sessionId, configOptions: created.result.configOptions };
}

function requireGatewayRequests(gateway: Gateway, minimum: number, what: string) {
  if (gateway.requests.length < minimum) {
    throw new Error(`${what}: the fake Gateway saw ${gateway.requests.length} requests, expected at least ${minimum}`);
  }
}

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

// ----------------------------------------------------------- stop reasons --

/// One shell call that runs at once, for a model reply that asks for it.
const shellCall = (helpers: Helpers, id: string) =>
  helpers.fakeGatewayToolCall(id, "shell", { request: { action: "run", command: "echo one", yield_time_ms: 30_000 } });

async function stopReasons(fxBin: string, helpers: Helpers): Promise<StopObservation[]> {
  const observations: StopObservation[] = [];
  const lengthReply = () => helpers.fakeGatewaySse([
    { type: "text-delta", id: "answer_1", delta: "Cut short" },
    { type: "finish", finishReason: { unified: "length", raw: "length" } },
  ]);
  const unauthorized = () => new Response(JSON.stringify({ error: { message: "bad key" } }), {
    status: 401,
    headers: { "content-type": "application/json" },
  });

  /// One turn that ends for `cause`. With `probe`, a second prompt follows and
  /// the first request it makes says whether the next prompt holds the first
  /// prompt, which is its own probe text, and each text in `keeps` (the first
  /// tool call's id): the turn is kept when all are there, dropped when none
  /// is, and a request with some of them fails the run.
  const single = async (
    name: string,
    cause: string,
    replies: unknown[],
    options: { steps?: number; mode?: string; probe?: boolean; keeps?: string[] } = {},
  ) => {
    const run = makeRun(`fx-acp-conf-${name}-`);
    const gateway = helpers.startFakeGateway(replies);
    const extra = options.steps === undefined ? {} : { FX_MAX_AGENT_STEPS: String(options.steps) };
    const acp = spawnAcp(fxBin, run, gateway, extra);
    try {
      const { sessionId } = await startSession(acp, run, options.mode ?? "auto");
      const probe = `Probe for ${name}.`;
      const answer = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: probe }] });
      if (answer?.error) throw new Error(`${name}: session/prompt failed: ${JSON.stringify(answer.error)}`);
      requireGatewayRequests(gateway, 1, name);
      let history: StopObservation["history"] = "unseen";
      if (options.probe) {
        const before = gateway.requests.length;
        const next = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "Next question." }] });
        if (next?.error) throw new Error(`${name}: the next session/prompt failed: ${JSON.stringify(next.error)}`);
        requireGatewayRequests(gateway, before + 1, `${name} next prompt`);
        const request = gateway.requests[before] as { body: string };
        if (!request.body.includes("Next question.")) throw new Error(`${name}: the next request lacks the next prompt`);
        const held = [probe, ...(options.keeps ?? [])].map((text) => request.body.includes(text));
        if (held.every(Boolean)) history = "kept";
        else if (!held.some(Boolean)) history = "dropped";
        else throw new Error(`${name}: the next request holds only part of the turn: ${JSON.stringify(held)}`);
      }
      observations.push({ cause, response: "prompt", wire: String(answer.result.stopReason), history });
    } finally {
      await acp.close();
      gateway.stop();
      rmSync(run.root, { recursive: true, force: true });
    }
  };
  await single("finished", "finished", [helpers.fakeGatewayFinalText("Done."), helpers.fakeGatewayFinalText("Next.")], { probe: true });
  await single("length", "length_limit", [lengthReply()]);
  await single("auth", "dropped_failure", [unauthorized(), helpers.fakeGatewayFinalText("Next.")], { probe: true });
  // The step limit of two ends the turn after its second model request, and
  // the next prompt carries on from where it stopped.
  await single(
    "step-limit",
    "step_limit",
    [shellCall(helpers, "limit_step_1"), shellCall(helpers, "limit_step_2"), helpers.fakeGatewayFinalText("Next.")],
    { steps: 2, mode: "full-access", probe: true },
  );


  // A failed turn fx keeps. Each ends the turn with a notice that says to
  // continue, and the saved history holds the prompt and, where the turn ran a
  // tool call, the call.
  const emptyReply = () => helpers.fakeGatewaySse([
    { type: "finish", finishReason: { unified: "other", raw: "UNEXPECTED_TOOL_CALL" }, usage: { inputTokens: { total: 3 }, outputTokens: { total: 8 } } },
  ]);
  const invalidShell = (id: string, pathFirst: boolean) => helpers.fakeGatewaySse([
    {
      type: "tool-call",
      toolCallId: id,
      toolName: "shell",
      input: {
        request: {
          command: "printf unexpected > must-not-run.txt",
          tty: true,
          shell: pathFirst ? { path: "/bin/bash", kind: "executable" } : { kind: "executable", path: "/bin/bash" },
        },
        yield_time_ms: "1000",
      },
    },
    { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
  ]);
  const failingShell = (id: string) =>
    helpers.fakeGatewayToolCall(id, "shell", { request: { action: "run", command: "echo bad >&2; exit 1", yield_time_ms: 30_000 } });
  const badRequest = () => new Response(JSON.stringify({ error: { message: "bad request" } }), {
    status: 400,
    headers: { "content-type": "application/json" },
  });
  const next = () => helpers.fakeGatewayFinalText("Next.");
  await single("empty-twice", "kept_failure", [emptyReply(), emptyReply(), next()], { probe: true });
  await single(
    "malformed",
    "kept_failure",
    [
      helpers.fakeGatewaySse([
        { type: "tool-call", toolCallId: "malformed_1", toolName: "ask_user_question", input: '{"depth":1,"depth":2}' },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      helpers.fakeGatewaySse([
        { type: "tool-call", toolCallId: "malformed_2", toolName: "ask_user_question", input: '{"depth":1,"depth":2}' },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      helpers.fakeGatewaySse([
        { type: "tool-call", toolCallId: "malformed_3", toolName: "read_file", input: '{"path":"README.md",}' },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" } },
      ]),
      next(),
    ],
    { probe: true, keeps: ["malformed_1"] },
  );
  await single(
    "terminal-validation",
    "kept_failure",
    [invalidShell("invalid_1", false), invalidShell("invalid_2", true), next()],
    { mode: "full-access", probe: true, keeps: ["invalid_1"] },
  );
  await single(
    "shell-failure",
    "kept_failure",
    [failingShell("fail_1"), failingShell("fail_2"), failingShell("fail_3"), next()],
    { mode: "full-access", probe: true, keeps: ["fail_1"] },
  );
  await single(
    "tool-then-400",
    "kept_failure",
    [shellCall(helpers, "tool_1"), badRequest(), next()],
    { mode: "full-access", probe: true, keeps: ["tool_1"] },
  );

  // A failed turn fx leaves out: HTTP 400 on the first request, and a stream
  // that breaks inside a tool call before any call ran.
  await single("first-400", "dropped_failure", [badRequest(), next()], { probe: true });
  const brokenSearch = () => new Response(
    `data: ${JSON.stringify({ type: "tool-input-start", id: "search_open", toolName: "exa_search" })}\n\n`
      + `data: ${JSON.stringify({ type: "tool-input-delta", id: "search_open", delta: "{\"query\":" })}\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
  await single("broken-search", "dropped_failure", [...Array.from({ length: 12 }, brokenSearch), next()], { probe: true, keeps: ["search_open"] });

  // A cancel while the model is still answering.
  {
    const run = makeRun("fx-acp-conf-cancel-");
    const asked = deferred();
    const release = deferred();
    const gateway = helpers.startFakeGateway([async () => {
      asked.resolve();
      await release.promise;
      return helpers.fakeGatewayFinalText("Too late.");
    }]);
    const acp = spawnAcp(fxBin, run, gateway);
    try {
      const { sessionId } = await startSession(acp, run, "auto");
      const id = acp.allocateId();
      acp.send(id, "session/prompt", { sessionId, prompt: [{ type: "text", text: "Answer slowly." }] });
      await asked.promise;
      acp.notify("session/cancel", { sessionId });
      const answer = (await acp.responses([id])).get(id);
      if (answer?.error) throw new Error(`cancel: session/prompt failed: ${JSON.stringify(answer.error)}`);
      requireGatewayRequests(gateway, 1, "cancel");
      observations.push({ cause: "cancelled", response: "prompt", wire: String(answer.result.stopReason), history: "unseen" });
    } finally {
      release.resolve();
      await acp.close();
      gateway.stop();
      rmSync(run.root, { recursive: true, force: true });
    }
  }

  // A steering prompt the turn absorbs, and the turn then ends: both responses
  // carry the turn's reason.
  const steered = async (name: string, cause: string, second: unknown, steps?: number) => {
    const run = makeRun(`fx-acp-conf-steer-${name}-`);
    const asked = deferred();
    const release = deferred();
    const gateway = helpers.startFakeGateway([
      async () => {
        asked.resolve();
        await release.promise;
        return helpers.fakeGatewayFinalText("First answer.");
      },
      second,
    ]);
    const acp = spawnAcp(fxBin, run, gateway, steps === undefined ? {} : { FX_MAX_AGENT_STEPS: String(steps) });
    try {
      const { sessionId } = await startSession(acp, run, "full-access");
      const first = acp.allocateId();
      acp.send(first, "session/prompt", { sessionId, prompt: [{ type: "text", text: "First question." }] });
      await asked.promise;
      const steer = acp.allocateId();
      acp.send(steer, "session/prompt", { sessionId, prompt: [{ type: "text", text: "Second question too." }], _meta: { fx: { steer: true } } });
      release.resolve();
      const answers = await acp.responses([first, steer]);
      const original = answers.get(first);
      const steeredAnswer = answers.get(steer);
      if (original?.error || steeredAnswer?.error) throw new Error(`${name}: ${JSON.stringify({ original, steeredAnswer })}`);
      if (steeredAnswer.result?._meta?.fx?.steering !== "absorbed") throw new Error(`${name}: not absorbed: ${JSON.stringify(steeredAnswer)}`);
      requireGatewayRequests(gateway, 2, name);
      observations.push({ cause, response: "prompt", wire: String(original.result.stopReason), history: "unseen" });
      observations.push({ cause, response: "steering", wire: String(steeredAnswer.result.stopReason), history: "unseen" });
    } finally {
      release.resolve();
      await acp.close();
      gateway.stop();
      rmSync(run.root, { recursive: true, force: true });
    }
  };
  await steered("length", "length_limit", lengthReply());
  // The steering prompt starts the second model request, which asks for a
  // command and meets the step limit of two.
  await steered("step-limit", "step_limit", shellCall(helpers, "steer_limit_step"), 2);
  return observations;
}

// ---------------------------------------------------------- config options --

const optionsOf = (configOptions: unknown): Array<{ id: string; category: string }> => {
  if (!Array.isArray(configOptions)) throw new Error(`no configOptions: ${JSON.stringify(configOptions)}`);
  return configOptions.map((option: any) => ({ id: String(option.id), category: String(option.category) }));
};

async function configOptions(fxBin: string, helpers: Helpers): Promise<OptionsObservation[]> {
  const observations: OptionsObservation[] = [];
  const run = makeRun("fx-acp-conf-options-", { models: { gateway: LANES_MODEL } });
  const gateway = helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText("Saved."), { models: () => CATALOG });
  let acp = spawnAcp(fxBin, run, gateway);
  try {
    const { sessionId, configOptions: created } = await startSession(acp, run, "auto");
    observations.push({ op: "new", options: optionsOf(created) });
    for (const model of [PLAIN_MODEL, LANES_MODEL]) {
      const set = await acp.call("session/set_config_option", { sessionId, configId: "model", value: model });
      if (set?.error) throw new Error(`set model ${model}: ${JSON.stringify(set.error)}`);
      observations.push({ op: "set", options: optionsOf(set.result.configOptions) });
    }
    // The first turn saves the session, so a new process can load it.
    const prompt = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "Save this chat." }] });
    if (prompt?.error) throw new Error(`prompt: ${JSON.stringify(prompt.error)}`);
    requireGatewayRequests(gateway, 1, "options");
    await acp.close();
    acp = spawnAcp(fxBin, run, gateway);
    await acp.call("initialize", { protocolVersion: 1 });
    const loaded = await acp.call("session/load", { sessionId, cwd: run.workspace, mcpServers: [] });
    if (loaded?.error) throw new Error(`session/load: ${JSON.stringify(loaded.error)}`);
    observations.push({ op: "load", options: optionsOf(loaded.result.configOptions) });
  } finally {
    await acp.close();
    gateway.stop();
    rmSync(run.root, { recursive: true, force: true });
  }
  return observations;
}

// --------------------------------------------------------- command output --

// One chunk the runner delivers: whole lines, or 4096 bytes without a line
// end, or what is left at exit. `pad` spaces come first, then `bytes`.
type PlanChunk = { src: "stdout" | "stderr"; pad: number; bytes: number[] };
type OutputPlan = { name: string; chunks: PlanChunk[] };

const RUNNER_FLUSH_BYTES = 4096; // pending_output_flush_bytes in src/core/execution/command_runner.zig
const NEWLINE = 0x0a;
// a, a continuation byte, and lead bytes of 2-, 3- and 4-byte sequences that
// form valid characters with 0x9f, and FF, which never starts one.
const ALPHABET = [0x61, 0x9f, 0xd0, 0xe2, 0xf0, 0xff];

const line = (src: PlanChunk["src"], ...bytes: number[]): PlanChunk => ({ src, pad: 0, bytes: [...bytes, NEWLINE] });
const fill = (src: PlanChunk["src"], ...tail: number[]): PlanChunk => ({ src, pad: RUNNER_FLUSH_BYTES - tail.length, bytes: tail });
const rest = (src: PlanChunk["src"], ...bytes: number[]): PlanChunk => ({ src, pad: 0, bytes });

const DIRECTED_OUTPUT: OutputPlan[] = [
  {
    name: "o1-split-per-stream",
    chunks: [
      fill("stdout", 0xd0), fill("stderr", 0xf0, 0x9f), line("stdout", 0xaf), line("stderr", 0x98, 0x80),
      fill("stdout", 0xf0), line("stdout", 0x9f, 0x98, 0x80), line("stdout", 0x62, 0xff, 0x62), rest("stdout", 0x74, 0xe2, 0x82),
    ],
  },
  {
    name: "o2-largest-tail-and-strays",
    chunks: [
      fill("stdout", 0xf0, 0x9f, 0x98), line("stdout", 0x80), line("stdout", 0x9f, 0x9f), fill("stderr", 0xe2),
      line("stderr", 0xff), fill("stdout", 0xd0), line("stdout", 0xd0, 0x9f), rest("stderr", 0xf0, 0x9f),
    ],
  },
];

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomOutputPlans(count: number, seed: number): OutputPlan[] {
  const rand = mulberry32(seed);
  const pick = <T>(items: T[]): T => items[Math.floor(rand() * items.length)]!;
  const bytes = (min: number, max: number) => Array.from({ length: min + Math.floor(rand() * (max - min + 1)) }, () => pick(ALPHABET));
  return Array.from({ length: count }, (_, index) => {
    const chunks: PlanChunk[] = [];
    for (let step = 0; step < 6; step++) {
      const src = pick(["stdout", "stderr"] as const);
      chunks.push(rand() < 0.5 ? fill(src, ...bytes(1, 3)) : line(src, ...bytes(0, 4)));
    }
    // What is left at exit comes out stdout first, then stderr.
    if (rand() < 0.7) chunks.push(rest("stdout", ...bytes(1, 3)));
    if (rand() < 0.5) chunks.push(rest("stderr", ...bytes(1, 3)));
    return { name: `r${String(index + 1).padStart(2, "0")}-seed${seed}`, chunks };
  });
}

/// The runner delivers a chunk at once when it fills 4096 bytes or ends a line,
/// which sends one progress frame. What is left at exit waits for the call to end.
const sendsFrame = (chunk: PlanChunk) => chunk.pad > 0 || chunk.bytes.at(-1) === NEWLINE;

/// A POSIX shell command that writes each chunk. After each chunk that sends a
/// frame it reads the named pipe `gates[n]`, which the driver writes once it
/// has read that frame, so the next chunk reaches the runner as a chunk of its
/// own whatever the speed of the machine.
function commandFor(plan: OutputPlan, gates: string[]): string {
  const octal = (bytes: number[]) => bytes.map((byte) => `\\${byte.toString(8).padStart(3, "0")}`).join("");
  let held = 0;
  return plan.chunks.map((chunk) => {
    const redirect = chunk.src === "stderr" ? " >&2" : "";
    const write = chunk.pad > 0 ? `printf '%${chunk.pad}s${octal(chunk.bytes)}' ' '` : `printf '${octal(chunk.bytes)}'`;
    return sendsFrame(chunk) ? `${write}${redirect}; read _ < '${gates[held++]}'` : `${write}${redirect}`;
  }).join("; ");
}

/// The progress frames fx has sent so far for `callId`: updates that carry text.
function progressFrames(acp: Acp, callId: string): number {
  return acp.lines.filter(({ message }) => {
    const update = message?.params?.update;
    if (update?.toolCallId !== callId || update.sessionUpdate !== "tool_call_update" || update.status !== "in_progress") return false;
    return (update.content ?? []).some((item: any) => (item?.content?.text ?? "") !== "");
  }).length;
}

function eventsFor(plan: OutputPlan): OutputEvent[] {
  const events: OutputEvent[] = plan.chunks.map((chunk) => ({
    kind: "chunk",
    src: chunk.src,
    bytes: collapse([...Array(chunk.pad).fill("A"), ...chunk.bytes.map(byteClass)]),
  }));
  events.push({ kind: "finish", src: "stdout", bytes: [] }, { kind: "finish", src: "stderr", bytes: [] });
  return events;
}

async function commandOutput(fxBin: string, helpers: Helpers, plan: OutputPlan): Promise<{ events: OutputEvent[]; frames: OutputFrame[] }> {
  const callId = "conformance_shell";
  const run = makeRun("fx-acp-conf-output-");
  const gates = plan.chunks.filter(sendsFrame).map((_, index) => join(run.root, `gate-${index}`));
  for (const gate of gates) {
    const made = Bun.spawnSync(["mkfifo", gate]);
    if (made.exitCode !== 0) throw new Error(`${plan.name}: mkfifo ${gate} failed: ${made.stderr.toString()}`);
  }
  const gateway = helpers.startFakeGateway([
    helpers.fakeGatewayToolCall(callId, "shell", { request: { action: "run", command: commandFor(plan, gates), yield_time_ms: 30_000 } }),
    helpers.fakeGatewayFinalText("Ran it."),
  ]);
  const acp = spawnAcp(fxBin, run, gateway);
  try {
    const { sessionId } = await startSession(acp, run, "full-access");
    const id = acp.allocateId();
    acp.send(id, "session/prompt", { sessionId, prompt: [{ type: "text", text: "Run the command." }] });
    for (const [index, gate] of gates.entries()) {
      await acp.until(() => progressFrames(acp, callId) > index, `${plan.name}: the progress frame for write ${index + 1}`);
      await writeFile(gate, "go\n");
    }
    const answer = (await acp.responses([id], 60_000)).get(id);
    if (answer?.error) throw new Error(`${plan.name}: session/prompt failed: ${JSON.stringify(answer.error)}`);
    requireGatewayRequests(gateway, 2, plan.name);
    const frames: OutputFrame[] = [];
    let finished = false;
    for (const { message, valid } of acp.lines) {
      const update = message?.params?.update;
      if (!valid && message === null) {
        frames.push({ text: [], valid: false });
        continue;
      }
      if (update?.toolCallId !== callId || update.sessionUpdate !== "tool_call_update") continue;
      if (update.status !== "in_progress") {
        finished = true;
        continue;
      }
      const text = (update.content ?? []).map((item: any) => item?.content?.text ?? "").join("");
      if (text === "") continue;
      if (finished) throw new Error(`${plan.name}: progress after the call's final update`);
      frames.push({ text: textClasses(text), valid });
    }
    if (!finished) throw new Error(`${plan.name}: the call never got its final update`);
    return { events: eventsFor(plan), frames };
  } finally {
    await acp.close();
    gateway.stop();
    rmSync(run.root, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------- controls --

function controls(stop: StopObservation[], options: OptionsObservation[], output: { events: OutputEvent[]; frames: OutputFrame[] }) {
  const tamperedStop = structuredClone(stop);
  const length = tamperedStop.find((o) => o.cause === "length_limit");
  if (length) length.wire = "max_output_tokens";
  // The step limit answered with refusal, as fx did before it named itself.
  const refusedLimit = structuredClone(stop);
  const limit = refusedLimit.find((o) => o.cause === "step_limit" && o.history === "kept");
  if (limit) limit.wire = "refusal";
  // The step limit's turn missing from the next request.
  const droppedLimit = structuredClone(stop);
  const kept = droppedLimit.find((o) => o.cause === "step_limit" && o.history === "kept");
  if (kept) kept.history = "dropped";
  // A failed request's turn still in the next request.
  const keptFailure = structuredClone(stop);
  const failed = keptFailure.find((o) => o.cause === "dropped_failure" && o.history === "dropped");
  if (failed) failed.history = "kept";
  // A failed turn fx keeps answered with refusal, as fx did before it.
  const refusedKept = structuredClone(stop);
  const keptAnswer = refusedKept.find((o) => o.cause === "kept_failure");
  if (keptAnswer) keptAnswer.wire = "refusal";
  // A failed turn fx leaves out answered with end_turn.
  const endedDropped = structuredClone(stop);
  const droppedAnswer = endedDropped.find((o) => o.cause === "dropped_failure");
  if (droppedAnswer) droppedAnswer.wire = "end_turn";
  // A failed turn answered with end_turn that the next request leaves out.
  const droppedKept = structuredClone(stop);
  const keptHistory = droppedKept.find((o) => o.cause === "kept_failure" && o.history === "kept");
  if (keptHistory) keptHistory.history = "dropped";
  const tamperedOptions = structuredClone(options);
  const provider = tamperedOptions[0]?.options.find((o) => o.id === "provider");
  if (provider) provider.category = "model";
  const tamperedOutput = structuredClone(output);
  const frame = tamperedOutput.frames.find((f) => f.text.some((c) => c.startsWith("L")));
  if (frame) frame.valid = false;
  return [
    { name: "stop-unmapped-length", model: "stop" as const, trace: tamperedStop, expect: "REJECTED" },
    { name: "stop-step-limit-refusal", model: "stop" as const, trace: refusedLimit, expect: "REJECTED" },
    { name: "stop-step-limit-dropped", model: "stop" as const, trace: droppedLimit, expect: "REJECTED" },
    { name: "stop-failure-kept", model: "stop" as const, trace: keptFailure, expect: "REJECTED" },
    { name: "stop-kept-failure-refusal", model: "stop" as const, trace: refusedKept, expect: "REJECTED" },
    { name: "stop-dropped-failure-end-turn", model: "stop" as const, trace: endedDropped, expect: "REJECTED" },
    { name: "stop-kept-failure-dropped", model: "stop" as const, trace: droppedKept, expect: "REJECTED" },
    { name: "options-provider-model", model: "options" as const, trace: tamperedOptions, expect: "REJECTED" },
    { name: "output-invalid-frame", model: "output" as const, trace: tamperedOutput, expect: "REJECTED" },
    { name: "stop-empty", model: "stop" as const, trace: [], expect: "TOOL_ERROR" },
  ];
}

// -------------------------------------------------------------------- main --

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(worktree: string, ...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

async function main() {
  const worktree = resolve(argValue("--worktree") ?? REPO_ROOT);
  const fxBin = join(worktree, "zig-out", "bin", "fx");
  if (!existsSync(fxBin)) throw new Error(`missing ${fxBin}; run zig build first`);
  const label = argValue("--label") ?? "run";
  const seed = Number(argValue("--seed") ?? "20261107");
  const randomCount = Number(argValue("--random") ?? "4");

  const reportDir = outDir(`acp-conformance-${label}`);
  const status = git(worktree, "status", "--porcelain");
  const manifest = {
    label,
    worktree,
    head: git(worktree, "rev-parse", "HEAD"),
    dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git(worktree, "diff", "HEAD")) : null,
    fx_binary_sha256: sha256File(fxBin),
    toolchain: tlcToolchain(),
    bun: Bun.version,
    seed,
    randomCount,
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const helpers = await import(join(worktree, "tests", "e2e", "tmux-helpers.ts")) as Helpers;
  const results: Array<{ name: string; verdict: string; length: number; error?: string }> = [];
  const check = async (name: string, model: "stop" | "options" | "output", observe: () => Promise<any>) => {
    let trace: any = null;
    try {
      trace = await observe();
    } catch (caught) {
      const error = caught instanceof Error ? caught.message : String(caught);
      results.push({ name, verdict: "RUN_ERROR", length: 0, error });
      console.log(`${name}: RUN_ERROR ${error}`);
      return null;
    }
    const checked = await validate(model, trace, join(reportDir, "traces", name));
    results.push({ name, verdict: checked.verdict, length: checked.length });
    console.log(`${name}: ${checked.verdict} (${checked.length} steps)`);
    return trace;
  };

  const stop = await check("stop-reasons", "stop", () => stopReasons(fxBin, helpers));
  const options = await check("config-options", "options", () => configOptions(fxBin, helpers));
  let firstOutput: any = null;
  for (const plan of [...DIRECTED_OUTPUT, ...randomOutputPlans(randomCount, seed)]) {
    const trace = await check(`output-${plan.name}`, "output", () => commandOutput(fxBin, helpers, plan));
    firstOutput ??= trace;
  }

  // Controls show the bridge tells conforming runs from tampered ones.
  const controlResults = [];
  if (stop && options && firstOutput) {
    for (const control of controls(stop, options, firstOutput)) {
      const got = (await validate(control.model, control.trace, join(reportDir, "controls", control.name))).verdict;
      controlResults.push({ name: control.name, expect: control.expect, got });
      console.log(`control ${control.name}: ${got} (expected ${control.expect})`);
    }
  }
  const controlsPassed = controlResults.length > 0 && controlResults.every((control) => control.got === control.expect);
  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  writeJson(join(reportDir, "summary.json"), { manifest, counts, controlsPassed, controls: controlResults, results });
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "passed" : "not passed"}`);
  console.log(`report: ${reportDir}`);
  const allAccepted = results.every((result) => result.verdict === "ACCEPTED");
  process.exit(allAccepted && controlsPassed ? 0 : 1);
}

await main();
