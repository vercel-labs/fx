// Runtime driver: drives the real `fx acp` binary against a local fake
// Gateway and asks TLC whether what a client sees is a behavior of the models
// in tests/tla/acp/:
//   - the stop reason of finished, length-limited, refused, cancelled, and
//     steered turns (AcpStopReasons.tla, through AcpStopReasonsTrace.tla);
//   - the config options of session/new, session/set_config_option, and
//     session/load (AcpConfigCategories.tla, through
//     AcpConfigCategoriesTrace.tla);
//   - the progress text of shell commands whose output chunks end inside
//     characters, on stdout and stderr (AcpCommandOutput.tla, through
//     AcpCommandOutputTrace.tla). Each plan makes the command runner cut
//     output where the plan says: a line end, 4096 bytes without one, or exit.
//
//   bun tests/tla/drivers/acp/conformance/driver.ts --label main   # after zig build
//
// No live model calls: every fx process gets an environment written out in
// full, with a fake key and the fake Gateway's URLs, and each run checks the
// fake Gateway saw its requests.
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
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
function fxEnvironment(run: Run, gateway: Gateway): Record<string, string> {
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
  };
}

function spawnAcp(fxBin: string, run: Run, gateway: Gateway): Acp {
  return new Acp(Bun.spawn([fxBin, "acp"], {
    cwd: run.workspace,
    env: fxEnvironment(run, gateway),
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

  const single = async (name: string, reason: string, reply: () => Response) => {
    const run = makeRun(`fx-acp-conf-${name}-`);
    const gateway = helpers.startFakeGateway([reply()]);
    const acp = spawnAcp(fxBin, run, gateway);
    try {
      const { sessionId } = await startSession(acp, run, "auto");
      const answer = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "Answer." }] });
      if (answer?.error) throw new Error(`${name}: session/prompt failed: ${JSON.stringify(answer.error)}`);
      requireGatewayRequests(gateway, 1, name);
      observations.push({ reason, response: "prompt", wire: String(answer.result.stopReason) });
    } finally {
      await acp.close();
      gateway.stop();
      rmSync(run.root, { recursive: true, force: true });
    }
  };
  await single("end-turn", "end_turn", () => helpers.fakeGatewayFinalText("Done."));
  await single("length", "max_output_tokens", lengthReply);
  await single("auth", "refused", unauthorized);

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
      observations.push({ reason: "cancelled", response: "prompt", wire: String(answer.result.stopReason) });
    } finally {
      release.resolve();
      await acp.close();
      gateway.stop();
      rmSync(run.root, { recursive: true, force: true });
    }
  }

  // A steering prompt the turn absorbs, and the turn then hits the length
  // limit: both responses carry the turn's reason.
  {
    const run = makeRun("fx-acp-conf-steer-");
    const asked = deferred();
    const release = deferred();
    const gateway = helpers.startFakeGateway([
      async () => {
        asked.resolve();
        await release.promise;
        return helpers.fakeGatewayFinalText("First answer.");
      },
      lengthReply(),
    ]);
    const acp = spawnAcp(fxBin, run, gateway);
    try {
      const { sessionId } = await startSession(acp, run, "auto");
      const first = acp.allocateId();
      acp.send(first, "session/prompt", { sessionId, prompt: [{ type: "text", text: "First question." }] });
      await asked.promise;
      const steer = acp.allocateId();
      acp.send(steer, "session/prompt", { sessionId, prompt: [{ type: "text", text: "Second question too." }], _meta: { fx: { steer: true } } });
      release.resolve();
      const answers = await acp.responses([first, steer]);
      const original = answers.get(first);
      const steered = answers.get(steer);
      if (original?.error || steered?.error) throw new Error(`steer: ${JSON.stringify({ original, steered })}`);
      if (steered.result?._meta?.fx?.steering !== "absorbed") throw new Error(`steer: not absorbed: ${JSON.stringify(steered)}`);
      requireGatewayRequests(gateway, 2, "steer");
      observations.push({ reason: "max_output_tokens", response: "prompt", wire: String(original.result.stopReason) });
      observations.push({ reason: "max_output_tokens", response: "steering", wire: String(steered.result.stopReason) });
    } finally {
      release.resolve();
      await acp.close();
      gateway.stop();
      rmSync(run.root, { recursive: true, force: true });
    }
  }
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

/// A POSIX shell command that writes each chunk, then pauses so the runner
/// delivers it before the next one starts.
function commandFor(plan: OutputPlan): string {
  const octal = (bytes: number[]) => bytes.map((byte) => `\\${byte.toString(8).padStart(3, "0")}`).join("");
  return plan.chunks.map((chunk) => {
    const redirect = chunk.src === "stderr" ? " >&2" : "";
    const write = chunk.pad > 0 ? `printf '%${chunk.pad}s${octal(chunk.bytes)}' ' '` : `printf '${octal(chunk.bytes)}'`;
    return `${write}${redirect}; sleep 0.3`;
  }).join("; ");
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
  const gateway = helpers.startFakeGateway([
    helpers.fakeGatewayToolCall(callId, "shell", { request: { action: "run", command: commandFor(plan), yield_time_ms: 30_000 } }),
    helpers.fakeGatewayFinalText("Ran it."),
  ]);
  const acp = spawnAcp(fxBin, run, gateway);
  try {
    const { sessionId } = await startSession(acp, run, "full-access");
    const answer = await acp.call("session/prompt", { sessionId, prompt: [{ type: "text", text: "Run the command." }] }, 60_000);
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
  const length = tamperedStop.find((o) => o.reason === "max_output_tokens");
  if (length) length.wire = "max_output_tokens";
  const tamperedOptions = structuredClone(options);
  const provider = tamperedOptions[0]?.options.find((o) => o.id === "provider");
  if (provider) provider.category = "model";
  const tamperedOutput = structuredClone(output);
  const frame = tamperedOutput.frames.find((f) => f.text.some((c) => c.startsWith("L")));
  if (frame) frame.valid = false;
  return [
    { name: "stop-unmapped-length", model: "stop" as const, trace: tamperedStop, expect: "REJECTED" },
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
