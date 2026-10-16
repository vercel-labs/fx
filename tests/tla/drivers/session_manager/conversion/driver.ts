// The driver for converting v1 sessions to v2 on open and deleting each
// converted v1 folder (D59, D60), and for salvaging damaged ones (D64): it
// runs the real binary and its observations are judged by TLC against
// tests/tla/session_manager/V1Conversion.tla.
//
// Each scenario runs real fx processes one step at a time: "older build"
// steps run a v1 writer (v1Writer, or an older release), requests run the
// target, through every way a session can be opened. After every
// step the driver observes what the step left: each v1 member's contents,
// each id in v2, the version a v2 copy equals (by the real readers on both
// sides), leftovers in the manager's .tmp, and the listing. The content
// oracle continues two copies of the pre-conversion profile, one with each
// store, and compares the requests fx sends the model for the root and its
// child; a difference marks that copy as matching no v1 version. Read-backs
// do the same for each kind of state D56 says the converter carries.
// check_conversion.py then asks TLC whether some behavior of V1Conversion
// passes through every observation in order.
import { expect, test } from "bun:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { tmpdir } from "node:os";
import { artifacts, binary, repetitions, shellQuote, targetHelpers, worktree } from "../../lib/context";

export const { startDynamicFakeGateway, fakeGatewayFinalText, fakeGatewayToolCall, fakeGatewaySse, FAKE_GATEWAY_MODEL, TmuxSession } = await targetHelpers();
// The models live with the code they describe (tests/tla/session_manager).
const checker = join(worktree, "tests/tla/session_manager/trace/check_conversion.py");
const savedLogsChecker = join(worktree, "tests/tla/session_manager/trace/check_saved_logs.py");

export type Answer = "none" | "opened" | "converted" | "busy" | "unreadable" | "notfound"
  | "recovered" | "healthy" | "unsalvageable" | "inv2";
// A member's damage, as the v1 writer's own `fx session recover` judges it.
type Damage = "ok" | "salvage" | "lost";
// open2: two processes opened the root at once; `ans2` is the second's answer.
type Kind = "create" | "write" | "hold" | "release" | "open" | "open2" | "all" | "crash" | "damage" | "fresh" | "list" | "recover";
export type Via = "ask" | "app" | "continue" | "picker" | "slash" | "acp";
type Run = { pid: number; code: number | null; signal: string | null; stdout: string; stderr: string; args: string[]; v2: boolean; home: string };
type Observation = {
  k: Kind; r: string; ans: Answer; ans2?: Answer; v1: Record<string, number>; pub: Record<string, string>;
  base: Record<string, number>; extra: Record<string, number>; bad: Record<string, Damage>;
  dirty: boolean; held: string[]; listed: string[]; denied: boolean;
};
type Verdict = { verdict: string; matched?: number; expected?: number; detail?: string; report: string };

// The v1 files that make a session's contents; locks and usage do not.
const CONTENT = new Set(["session.json", "events.jsonl", "children.json"]);
export const VIAS: Via[] = ["ask", "app", "continue", "picker", "slash", "acp"];

let pathFault: string | null = null;
// ../../lib/path-fault.c, built once per run.
function pathFaultLibrary(): string {
  if (pathFault) return pathFault;
  const library = join(artifacts, "path-fault.dylib");
  const source = join(import.meta.dirname, "../../lib/path-fault.c");
  const built = Bun.spawnSync(["clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", source, "-o", library]);
  assert.equal(built.exitCode, 0, `building the path fault failed: ${built.stderr.toString()}`);
  return (pathFault = library);
}

export function fixture(label: string) {
  const root = mkdtempSync(join(artifacts, label + "-"));
  const home = join(root, "home"), workspace = join(root, "workspace");
  mkdirSync(home, { mode: 0o700 }); mkdirSync(workspace, { mode: 0o700 });
  const v1Root = join(home, ".fx/sessions"), v2Root = join(v1Root, "v2");
  const runs: Run[] = [];
  const active = new Set<ReturnType<typeof Bun.spawn>>();
  const apps = new Set<any>();
  const acps = new Set<ChildProcess>();
  let respond: (body: string) => Response = () => fakeGatewayFinalText("UNEXPECTED_REQUEST");
  let injected: Record<string, string> = {};
  // A known window lets a long turn compact inside the turn.
  const gateway = startDynamicFakeGateway((body: string) => respond(body), {
    classifierDecision: "clear",
    models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128_000, max_tokens: 8192 }],
  });

  const env = (v2: boolean, homeDir = home) => {
    const e: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: homeDir, TMPDIR: root,
      AI_GATEWAY_API_KEY: "synthetic-conversion-fixture", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
      FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: FAKE_GATEWAY_MODEL, FX_PERMISSION_MODE: "full-access", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1",
      // The target of a build that still has the switch runs with it when the
      // driver's own environment sets it, and nothing else does: tmux passes
      // the driver's environment on.
      FX_SESSIONS_V2: v2 && process.env.FX_SESSIONS_V2 ? process.env.FX_SESSIONS_V2 : "0",
    };
    return { ...e, ...injected };
  };

  // `v2`: the target; otherwise the v1 writer, or the release `bin` names.
  function start(v2: boolean, args: string[], timeoutMs = 30_000, homeDir = home, extraEnv: Record<string, string> = {}, bin = v2 ? binary : v1Writer()) {
    const child = Bun.spawn([bin, ...args], { cwd: workspace, env: { ...env(v2, homeDir), ...extraEnv }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    active.add(child);
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    const finished = (async () => {
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      clearTimeout(timer); active.delete(child);
      const run = { pid: child.pid, code, signal: child.signalCode ?? null, stdout, stderr, args, v2, home: homeDir };
      runs.push(run);
      writeFileSync(join(root, "processes.json"), JSON.stringify(runs, null, 2));
      return run;
    })();
    return { child, finished };
  }
  const fx = (v2: boolean, args: string[], homeDir = home, extraEnv: Record<string, string> = {}, bin = v2 ? binary : v1Writer()) =>
    start(v2, args, 30_000, homeDir, extraEnv, bin).finished;

  // Older build (v1) asks; each must succeed.
  async function v1Ask(args: string[], homeDir = home) {
    const run = await fx(false, ["ask", "--json", "--auto", ...args], homeDir);
    assert.equal(run.code, 0, `v1 ask failed: ${run.stderr}${run.stdout}`);
    return JSON.parse(run.stdout);
  }

  function fingerprint(id: string, homeDir = home): string | null {
    const dir = join(homeDir, ".fx/sessions", id);
    if (!existsSync(join(dir, "session.json"))) return null;
    const hash = createHash("sha256");
    const walk = (d: string) => {
      for (const name of readdirSync(d).sort()) {
        const p = join(d, name), s = statSync(p);
        if (s.isDirectory()) walk(p);
        else if (CONTENT.has(name)) hash.update(relative(dir, p)).update("\0").update(readFileSync(p)).update("\0");
      }
    };
    walk(dir);
    return hash.digest("hex");
  }

  // Until `stop`, every fx this fixture starts runs with the path fault
  // on these absolute paths: "refuse" fails every move or removal of them,
  // "pause" blocks a rename of exactly one, for `pauseMs` when given. The
  // tmux app gets it too: it is started through /usr/bin/env, whose
  // arguments keep DYLD_* for the fx it starts.
  function faultPaths(mode: "refuse" | "pause", paths: string[], pauseMs?: number) {
    const dir = mkdtempSync(join(root, `${mode}-fault-`));
    const arm = join(dir, "armed"), record = join(dir, "hits.txt");
    writeFileSync(arm, "armed");
    injected = {
      DYLD_INSERT_LIBRARIES: pathFaultLibrary(), FX_PATH_FAULT_MODE: mode, FX_PATH_FAULT_ARM: arm,
      FX_PATH_FAULT_RECORD: record, FX_PATH_FAULT_TARGETS: paths.join(":"),
      ...(pauseMs === undefined ? {} : { FX_PATH_FAULT_PAUSE_MS: String(pauseMs) }),
    };
    const hits = () => (existsSync(record) ? readFileSync(record, "utf8").split("\n").filter(Boolean) : []);
    return {
      hits, reached: () => hits().length > 0,
      stop() { injected = {}; rmSync(arm, { force: true }); },
    };
  }
  // Real paths, as the fault compares them; the folders below home may not
  // exist yet.
  const v1Path = (id: string) => join(realpathSync(home), ".fx/sessions", id);
  const stagingPath = (id: string) => join(realpathSync(home), ".fx/sessions/v2/.tmp", id);

  return { root, home, workspace, v1Root, v2Root, runs, gateway, env, start, fx, v1Ask, fingerprint, apps, acps, faultPaths, v1Path, stagingPath,
    // What the host said in the last openVia: fx ask's output, ACP's load
    // error and session updates, or the app's screen and stderr.
    said: "",
    setRespond: (f: (body: string) => Response) => { respond = f; },
    async finish() {
      for (const app of apps) await app.kill().catch(() => {});
      for (const proc of acps) proc.kill("SIGKILL");
      for (const child of active) child.kill("SIGKILL");
      await Promise.all([...active].map(child => child.exited));
      const bodies = (list: any[] = []) => list.map(r => r.body);
      writeFileSync(join(root, "gateway-requests.json"), JSON.stringify({
        completions: bodies(gateway.requests), classifier: bodies(gateway.classifierRequests),
        evaluation: bodies(gateway.evaluationRequests), title: bodies(gateway.titleRequests),
      }, null, 2));
      gateway.stop();
    } };
}

export type Fixture = ReturnType<typeof fixture>;

export async function waitUntil(check: () => boolean | Promise<boolean>, timeoutMs: number): Promise<boolean> {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) { if (await check()) return true; await Bun.sleep(50); }
  return false;
}

// What fx said when it refused, from any host's output; `otherwise` when it
// said none of these.
function refusal(text: string, where: string, otherwise?: Answer): Answer {
  if (/SessionBusy|session is busy|is open in another/i.test(text)) return "busy";
  if (/InvalidSessionFormat|can.?t be (read|converted)|unreadable|damaged/i.test(text)) return "unreadable";
  if (/SessionNotFound|session not found|not found|no remembered session/i.test(text)) return "notfound";
  if (otherwise) return otherwise;
  throw new Error(`Unclassified answer from ${where}: ${text.slice(0, 600)}`);
}

// The answer a v2 `fx ask` gave, from fx's own JSON.
export function askAnswer(run: Run, id: string): Answer {
  let json: any = null;
  try { json = JSON.parse(run.stdout); } catch { /* not JSON */ }
  if (run.code === 0 && json?.session_id === id) return "opened";
  return refusal(String(json?.error ?? json?.code ?? "") + " " + run.stdout + run.stderr, `fx ${run.args.join(" ")}`);
}

// A minimal ACP client over the real `fx acp`.
export class Acp {
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, (message: any) => void>();
  readonly updates: any[] = [];
  // The client's own MCP servers: the result carrier for each `mcp/message`.
  serve: (params: any) => object = () => ({});
  constructor(readonly proc: ChildProcess) {
    proc.stdout!.on("data", (chunk: Buffer) => {
      this.buffer += chunk.toString();
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
        if (!line.trim()) continue;
        const message = JSON.parse(line);
        if (message.method !== undefined && message.id !== undefined) {
          const result = message.method === "session/request_permission" ? { outcome: { outcome: "selected", optionId: "allow_once" } }
            : message.method === "mcp/message" ? this.serve(message.params ?? {}) : {};
          proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\n");
        } else if (message.method === "session/update") {
          this.updates.push(message.params.update);
        } else if (message.id !== undefined && this.pending.has(message.id)) {
          this.pending.get(message.id)!(message); this.pending.delete(message.id);
        }
      }
    });
  }
  static async start(f: Fixture, v2: boolean, homeDir = f.home) {
    const proc = spawn(v2 ? binary : v1Writer(), ["acp"], { cwd: f.workspace, env: f.env(v2, homeDir), stdio: ["pipe", "pipe", "pipe"] });
    f.acps.add(proc);
    const client = new Acp(proc);
    const initialized = await client.request("initialize", { protocolVersion: 1, clientCapabilities: {} });
    if (initialized.error) throw new Error(`ACP initialize failed: ${JSON.stringify(initialized.error)}`);
    return client;
  }
  request(method: string, params: unknown, timeoutMs = 30_000): Promise<any> {
    const id = this.nextId++;
    this.proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`ACP ${method} timed out`)), timeoutMs);
      this.pending.set(id, message => { clearTimeout(timer); resolve(message); });
    });
  }
  close() { this.proc.kill("SIGKILL"); }
}

// Opens `id` with v2 through one host and, once open, runs one turn.
export async function openVia(f: Fixture, id: string, via: Via, prompt = "CONV_NEXT", firstPrompt = "CONV_FIRST"): Promise<Answer> {
  f.said = "";
  if (via === "ask") {
    const run = await f.fx(true, ["ask", "--json", "--auto", "--resume-id", id, prompt]);
    f.said = run.stdout + run.stderr;
    return askAnswer(run, id);
  }
  if (via === "acp") {
    const client = await Acp.start(f, true);
    try {
      const loaded = await client.request("session/load", { sessionId: id, cwd: f.workspace, mcpServers: [] });
      f.said = JSON.stringify({ error: loaded.error, updates: client.updates });
      if (loaded.error) return refusal(JSON.stringify(loaded.error), "ACP session/load");
      const prompted = await client.request("session/prompt", { sessionId: id, prompt: [{ type: "text", text: prompt }] });
      assert(!prompted.error, `ACP prompt after load failed: ${JSON.stringify(prompted.error)}`);
      return "opened";
    } finally { client.close(); }
  }
  const flags = via === "app" ? `--resume ${shellQuote(id)}` : via === "continue" ? "-c" : via === "picker" ? "-r" : "";
  const stderrPath = join(f.root, `app-${via}-${Date.now()}.stderr`);
  const app = await TmuxSession.create({ cmd: `${shellQuote(binary)} ${flags}`, cwd: f.workspace, env: f.env(true), width: 120, height: 40, stderrPath });
  f.apps.add(app);
  const stderr = () => (existsSync(stderrPath) ? readFileSync(stderrPath, "utf8") : "");
  // What the app said; once it has exited, its stderr may still be on its way.
  const said = async () => {
    if (!app.isAlive()) await waitUntil(() => stderr().length > 0, 2_000);
    return (f.said = `${await app.captureFullScrollback().catch(() => "")}\n${stderr()}`);
  };
  try {
    if (via === "slash") { await app.waitForComposer(15_000); await app.sendText("/resume"); }
    if (via === "picker" || via === "slash") {
      // The picker must list the v1 session; choose it.
      if (!(await waitUntil(async () => (await app.capturePane()).includes(firstPrompt) || !app.isAlive(), 8_000)) || !app.isAlive()) {
        return app.isAlive() ? "notfound" : refusal(await said(), `the ${via} picker`);
      }
      await app.sendKeys("Enter");
    }
    // Opened means the app says it resumed a session and shows its turns. A
    // live app that never says so refused it in a notice, or opened
    // something else, or nothing.
    const resumed = await waitUntil(async () => !app.isAlive() || /session resumed|can.?t be converted/.test(await app.captureFullScrollback()), 15_000);
    if (!app.isAlive()) return refusal(await said(), `the app (${via})`);
    if (!resumed || !(await app.captureFullScrollback()).includes(firstPrompt)) return refusal(await said(), `the app (${via})`, "notfound");
    await app.sendText(prompt);
    assert(await waitUntil(async () => (await app.captureFullScrollback()).includes(`${prompt}_ANSWER`), 15_000), `the ${via} turn never answered`);
    await said();
    await app.sendText("/quit");
    await app.waitForSessionEnd(10_000);
    return "opened";
  } finally { await app.kill().catch(() => {}); f.apps.delete(app); }
}

// Opens `id` in the v1 app and quits, which leaves it as the workspace's
// remembered session for `-c` (v1 keeps it in ~/.fx/continue/).
export async function rememberInV1(f: Fixture, id: string) {
  const app = await TmuxSession.create({ cmd: `${shellQuote(v1Writer())} --resume ${shellQuote(id)}`, cwd: f.workspace, env: f.env(false), width: 120, height: 40 });
  f.apps.add(app);
  try {
    await app.waitForComposer(15_000);
    await app.sendText("/quit");
    await app.waitForSessionEnd(10_000);
  } finally { await app.kill().catch(() => {}); f.apps.delete(app); }
  const continueDir = join(f.home, ".fx/continue");
  assert(existsSync(continueDir) && readdirSync(continueDir).some(n => readFileSync(join(continueDir, n), "utf8").trim() === id),
    "the v1 app did not remember the session for -c");
}

// `fx sessions convert`, as JSON or text: the run, and the answer it gave
// each root from its own report, where a root it did not skip converted.
export async function convertAll(f: Fixture, json = true) {
  const run = await f.fx(true, ["sessions", "convert", ...(json ? ["--json"] : [])]);
  const skipped = new Map<string, Answer>();
  if (json) {
    let report: any = null;
    try { report = JSON.parse(run.stdout); } catch { /* not JSON */ }
    assert.equal(report?.kind, "sessions_convert", `fx sessions convert gave no report: ${run.stdout}${run.stderr}`);
    for (const skip of report.skipped) skipped.set(skip.id, skip.error === "SessionBusy" ? "busy" : "unreadable");
  } else {
    assert.match(run.stdout, /^converted \d+, busy \d+, unreadable \d+\n/, `fx sessions convert gave no report: ${run.stdout}${run.stderr}`);
    for (const [, id, why] of run.stdout.matchAll(/^(\S+): (busy|unreadable)/gm)) skipped.set(id, why as Answer);
  }
  return { run, answer: (id: string): Answer => skipped.get(id) ?? "converted" };
}

// Makes a profile private (0700: ~/.fx, sessions/ and each session folder),
// the only kind the current build reads in v1; older releases left them 0755.
export function makePrivate(home: string) {
  const sessions = join(home, ".fx/sessions");
  for (const dir of [join(home, ".fx"), sessions, ...readdirSync(sessions).map(n => join(sessions, n)).filter(d => existsSync(join(d, "session.json")))]) {
    chmodSync(dir, 0o700);
  }
}

// Tracks one family through a scenario and turns each step into an observation.
// `older`: the root is in an older v1 format, which v1 migrates before it
// writes; its reference history is then what v1 shows after that migration.
export function observer(f: Fixture, rootId: string, homeDir = f.home, older = false) {
  const v1Root = join(homeDir, ".fx/sessions"), v2Root = join(v1Root, "v2");
  const versions = new Map<string, string[]>();        // id -> fingerprints in order of appearance
  const histories = new Map<string, unknown[][]>();    // root -> history per version, from the v1 reader
  const observations: Observation[] = [];
  const bad: Record<string, Damage> = {};
  const childBase: Record<string, number> = {};
  const fresh: string[] = [];       // v2 sessions the new build created, the model's NewIds
  const salvaged = new Map<string, number>();   // salvage copies, also NewIds: turns when made
  let others: string[] = [];        // other families' ids, outside this model
  let held: string[] = [];
  let childId: string | null = null;
  // `carried`: per kind of D56 state, whether the read-back found it carried.
  const content: { root: boolean | null; child: boolean | null; carried: Record<string, boolean> } = { root: null, child: null, carried: {} };

  const members = () => [rootId, ...(childId ? [childId] : [])];
  // The root's child as v1 records it: in the root's subagent/children.json,
  // or, in schema 3 (before children.json), by the child's own
  // subagent/control.json naming the root as its parent.
  function childOf(): string | null {
    const registry = join(v1Root, rootId, "subagent/children.json");
    if (existsSync(registry)) {
      const ids: string[] = (JSON.parse(readFileSync(registry, "utf8")).children ?? []).map((c: { id: string }) => c.id);
      return ids.find(id => existsSync(join(v1Root, id))) ?? null;
    }
    return (existsSync(v1Root) ? readdirSync(v1Root) : []).find(id => {
      const control = join(v1Root, id, "subagent/control.json");
      return existsSync(control) && JSON.parse(readFileSync(control, "utf8")).parent_id === rootId;
    }) ?? null;
  }
  async function history(v2: boolean, id: string, home = homeDir): Promise<unknown[] | null> {
    const run = await f.fx(v2, ["session", id, "--json"], home);
    if (run.code !== 0) return null;
    return JSON.parse(run.stdout).history ?? null;
  }
  // An older format's tool results: v1's migration keeps each body in
  // tool-results/<handle> and its history shows the text bare, while v2 keeps
  // the body as a blob named by its hash (D44, D47) and its history shows the
  // same text wrapped with that handle. The wrapper is dropped only when v1's
  // body has the stored size and the v2 blob holds exactly its bytes.
  const bodies = new Map<string, Buffer>();   // v1's result bodies, by handle
  const matched = new Set<string>();          // v2 blobs found equal to them
  const PREVIEW = /^<tool_result_preview handle="([^"]+)" stored_bytes="(\d+)">\n([\s\S]*)\n<\/tool_result_preview>\n<tool_result_handle>\1<\/tool_result_handle>\n[^\n]*$/;
  function unwrapped(id: string, h: unknown[]): unknown[] {
    return JSON.parse(JSON.stringify(h), (key, value) => {
      const m = key === "output" && typeof value === "string" ? PREVIEW.exec(value) : null;
      const body = m ? bodies.get(m[1]) : undefined;
      if (!m || !body || body.length !== Number(m[2])) return value;
      const blob = join(v2Root, id, "blobs", createHash("sha256").update(body).digest("hex"));
      if (!existsSync(blob) || !readFileSync(blob).equals(body)) return value;
      matched.add(blob);
      return m[3];
    });
  }
  // v1's history of the root. An older format is read on a private copy
  // after v1's own `fx session migrate`, the step v1 takes before it writes,
  // keeping the result bodies that migration wrote; the observed profile
  // stays as it is.
  async function reference(id: string): Promise<unknown[] | null> {
    if (!older) return history(false, id);
    const copy = mkdtempSync(join(f.root, "reference-"));
    try {
      cpSync(homeDir, copy, { recursive: true });
      makePrivate(copy);
      const migrated = await f.fx(false, ["session", "migrate", id, "--json"], copy);
      assert.equal(migrated.code, 0, `v1 could not migrate ${id}: ${migrated.stderr}${migrated.stdout}`);
      const results = join(copy, ".fx/sessions", id, "tool-results");
      if (existsSync(results)) for (const name of readdirSync(results)) bodies.set(name, readFileSync(join(results, name)));
      return await history(false, id, copy);
    } finally { rmSync(copy, { recursive: true, force: true }); }
  }
  async function listed(): Promise<string[]> {
    const run = await f.fx(true, ["sessions", "--all", "--json"], homeDir);
    assert.equal(run.code, 0, `v2 listing failed: ${run.stderr}`);
    return JSON.parse(run.stdout).sessions.map((s: any) => s.id).filter((id: string) => !others.includes(id));
  }

  // `denied`: the step had the file system refuse v1 deletes. `ans2`: an
  // open2 step's second answer.
  async function observe(k: Kind, ans: Answer = "none", denied = false, ans2?: Answer) {
    childId ??= childOf();
    const v1: Record<string, number> = {};
    for (const id of members()) {
      const fp = f.fingerprint(id, homeDir);
      if (!fp) { v1[id] = 0; continue; }
      // Damage keeps the version in the model: a member the driver made
      // unreadable keeps the version it had.
      if (bad[id]) { v1[id] = observations.at(-1)?.v1[id] ?? 0; continue; }
      const seen = versions.get(id) ?? [];
      if (!seen.includes(fp)) {
        seen.push(fp); versions.set(id, seen);
        if (id === rootId && !held.includes(id)) {
          const list = histories.get(id) ?? [];
          list[seen.length - 1] = (await reference(id)) ?? [];
          histories.set(id, list);
        }
      }
      v1[id] = seen.indexOf(fp) + 1;
    }
    const pub: Record<string, string> = {}, base: Record<string, number> = {}, extra: Record<string, number> = {};
    for (const id of members()) {
      const converted = existsSync(join(v2Root, id, "log.jsonl"));
      pub[id] = converted ? "import" : "none";
      base[id] = 0; extra[id] = 0;
      if (!converted) continue;
      if (id === rootId) {
        // The v1 version whose history the v2 copy starts with, by the real readers.
        const read = await history(true, id);
        const copy = older && read ? unwrapped(id, read) : read;
        const known = histories.get(id) ?? [];
        base[id] = -1;
        for (let n = known.length; n >= 1; n--) {
          const h = known[n - 1];
          if (copy && h && h.length <= copy.length && JSON.stringify(copy.slice(0, h.length)) === JSON.stringify(h)) {
            base[id] = n; extra[id] = copy.length - h.length; break;
          }
        }
      } else {
        // A child has no reader of its own: its copy is held to the version it
        // had just before the request that published it (a crash's orphan is
        // reused as it is), and the content oracle checks it.
        childBase[id] ??= observations.at(-1)?.v1[id] ?? v1[id];
        base[id] = childBase[id];
      }
    }
    // A fresh session's turns are all appended after its creation.
    for (const id of fresh) {
      const turns = existsSync(join(v2Root, id, "log.jsonl")) ? await history(true, id) : null;
      pub[id] = turns ? "fresh" : "none"; base[id] = 0; extra[id] = turns?.length ?? 0;
    }
    // A salvage copy starts with the turns it salvaged.
    for (const [id, made] of salvaged) {
      const turns = existsSync(join(v2Root, id, "log.jsonl")) ? await history(true, id) : null;
      pub[id] = turns ? "salvage" : "none"; base[id] = 0; extra[id] = turns ? turns.length - made : 0;
    }
    const tmp = join(v2Root, ".tmp");
    const dirty = existsSync(tmp) && readdirSync(tmp).length > 0;
    const o: Observation = {
      k, r: ["open", "open2", "all", "crash", "recover"].includes(k) ? rootId : "none", ans, ...(ans2 ? { ans2 } : {}), v1, pub, base, extra,
      bad: Object.fromEntries(members().map(id => [id, bad[id] ?? "ok"])), dirty, held: [...held], listed: await listed(), denied,
    };
    observations.push(o);
    writeFileSync(join(f.root, "observations.json"), JSON.stringify(observations, null, 2));
    return o;
  }

  return {
    observations, observe, members, content, root: f.root,
    get childId() { return childOf() ?? childId; },
    get matchedBlobs() { return [...matched]; },
    hold(ids: string[]) { held = ids; },
    // A member the driver just damaged: whether the v1 writer's own recover,
    // on a private copy, still salvages a start of it.
    async damage(id: string) {
      const copy = mkdtempSync(join(f.root, "salvage-oracle-"));
      try {
        cpSync(homeDir, copy, { recursive: true });
        makePrivate(copy);
        const run = await f.fx(false, ["session", "recover", id, "--json"], copy);
        bad[id] = run.code === 0 ? "salvage" : "lost";
      } finally { rmSync(copy, { recursive: true, force: true }); }
      return bad[id];
    },
    fresh(id: string) { fresh.push(id); },
    salvaged(id: string, turns: number) { salvaged.set(id, turns); },
    others(ids: string[]) { others = ids; },
    async check(label: string): Promise<Verdict> {
      // Content the oracle found different, or state a read-back found
      // lost, matches no v1 version.
      const lost = content.root === false || Object.values(content.carried).includes(false);
      const judged = observations.map(o => {
        const copy = JSON.parse(JSON.stringify(o)) as Observation;
        if (lost && copy.pub[rootId] === "import") copy.base[rootId] = -1;
        if (childId && content.child === false && copy.pub[childId] === "import") copy.base[childId] = -1;
        return copy;
      });
      const dir = mkdtempSync(join(f.root, `tlc-${label}-`));
      const request = join(dir, "request.json");
      writeFileSync(request, JSON.stringify({ version: 1, ids: { root: rootId, child: childId, fresh: [...fresh, ...salvaged.keys()] }, observations: judged, content }, null, 2));
      const child = Bun.spawn(["python3", checker, "--request", request, "--report", join(dir, "report")], { stdout: "pipe", stderr: "pipe" });
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      writeFileSync(join(dir, "process.json"), JSON.stringify({ code, stdout, stderr }, null, 2));
      const result = JSON.parse(stdout) as Verdict;
      const exits: Record<string, number> = { ACCEPTED: 0, REJECTED: 1, INCONCLUSIVE: 2, TOOL_ERROR: 3 };
      assert.equal(exits[result.verdict], code, "checker verdict and exit disagree");
      if (result.verdict === "ACCEPTED") assert(result.matched === judged.length && judged.length > 0, "acceptance without every observation matched");
      return result;
    },
  };
}

// --- the content oracle ---------------------------------------------------

function oracleReplies(f: Fixture, family: boolean, agent: string) {
  f.setRespond(body => {
    if (family && body.includes("CONV_ORACLE") && !body.includes("CONV_ORACLE_CHILD")) {
      return fakeGatewayToolCall("conv-oracle", "subagent", { request: { action: "message", agent, message: "CONV_ORACLE_CHILD" } });
    }
    if (family && body.includes("CONV_ORACLE_CHILD") && !body.includes("CONV_ORACLE_CHILD_ANSWER")) {
      return fakeGatewayFinalText("CONV_ORACLE_CHILD_ANSWER");
    }
    return fakeGatewayFinalText("CONV_ORACLE_ANSWER");
  });
}

// The messages a request shows the model, without its system prompt, with the
// profile's own path (which differs between the two copies) masked.
export function shown(body: string, home: string): string {
  const prompt = (JSON.parse(body).prompt ?? []).filter((m: any) => m.role !== "system");
  return JSON.stringify(prompt).replaceAll(home, "<home>");
}

// Continues two copies of `snapshot` (the profile before conversion), the
// first with `firstV2` and the second with `secondV2`, and compares what the
// model was shown for the root and, in a family, for its child.
// `v1Private`: a v1 side runs on a private copy (makePrivate), for a profile
// an older release left readable by others, which current v1 refuses.
// `agent`: the name the root's child answers to.
export async function compareContinuations(f: Fixture, snapshot: string, rootId: string, family: boolean, firstV2: boolean, secondV2: boolean, v1Private = false, agent = "helper") {
  const sides = [] as { root?: string; child?: string; ok: boolean; home: string }[];
  for (const [n, v2] of [[1, firstV2], [2, secondV2]] as const) {
    const home = join(f.root, `oracle-${n}-${v2 ? "v2" : "v1"}`);
    cpSync(snapshot, home, { recursive: true });
    if (v1Private && !v2) makePrivate(home);
    oracleReplies(f, family, agent);
    const mark = f.gateway.requests.length;
    const run = await f.fx(v2, ["ask", "--json", "--auto", "--resume-id", rootId, "CONV_ORACLE"], home);
    const bodies: string[] = f.gateway.requests.slice(mark).map((r: any) => r.body);
    const root = bodies.find(b => b.includes("CONV_ORACLE") && !b.includes("CONV_ORACLE_CHILD"));
    const child = bodies.find(b => b.includes("CONV_ORACLE_CHILD") && !b.includes("CONV_ORACLE_CHILD_ANSWER"));
    sides.push({ root: root && shown(root, home), child: child && shown(child, home), ok: run.code === 0, home });
  }
  writeFileSync(join(f.root, `oracle-${firstV2 ? "v2" : "v1"}-${secondV2 ? "v2" : "v1"}.json`), JSON.stringify(sides, null, 2));
  const [a, b] = sides;
  return {
    root: a.ok && b.ok && !!a.root && a.root === b.root,
    child: family ? a.ok && b.ok && !!a.child && a.child === b.child : null,
  };
}

// Reads one kind of state back (D56) from two copies of `snapshot`, opened
// with `v2s[0]` and `v2s[1]`: what `read` finds each copy shows, with the
// copy's own profile path masked, or null when it shows nothing. Copies keep
// their file times.
export async function readBack(f: Fixture, snapshot: string, kind: string, v2s: [boolean, boolean],
  read: (home: string, v2: boolean) => Promise<string | null>): Promise<(string | null)[]> {
  const sides = [] as { home: string; v2: boolean; reading: string | null }[];
  for (const [n, v2] of v2s.entries()) {
    const home = join(f.root, `${kind}-${n + 1}-${v2 ? "v2" : "v1"}`);
    cpSync(snapshot, home, { recursive: true, preserveTimestamps: true });
    sides.push({ home, v2, reading: (await read(home, v2))?.replaceAll(home, "<home>") ?? null });
  }
  writeFileSync(join(f.root, `${kind}-${v2s.map(v => (v ? "v2" : "v1")).join("-")}.json`), JSON.stringify(sides, null, 2));
  return sides.map(side => side.reading);
}

// --- scenario helpers --------------------------------------------------------

export function plainReplies(f: Fixture) {
  f.setRespond(body => fakeGatewayFinalText(body.includes("CONV_NEXT") ? "CONV_NEXT_ANSWER" : body.includes("CONV_MORE") ? "CONV_MORE_ANSWER" : "CONV_FIRST_ANSWER"));
}

// CONV_FAMILY delegates to the child "helper", which answers.
export function familyReplies(f: Fixture) {
  f.setRespond(body => {
    if (body.includes("CONV_FAMILY")) {
      if (body.includes("CONV_CHILD_ANSWER")) return fakeGatewayFinalText("CONV_PARENT_DONE");
      return fakeGatewayToolCall("conv-delegate", "subagent", { request: { action: "message", agent: "helper", message: "Report the conversion marker." } });
    }
    if (body.includes("Report the conversion marker.")) return fakeGatewayFinalText("CONV_CHILD_ANSWER");
    return fakeGatewayFinalText("CONV_NEXT_ANSWER");
  });
}

// Opens `id`, pauses the conversion at the rename of `path`, and kills it
// there: a crash at exactly that point.
export async function crashAtRename(f: Fixture, o: ReturnType<typeof observer>, id: string, path: string) {
  const fault = f.faultPaths("pause", [path]);
  const pending = f.start(true, ["ask", "--json", "--auto", "--resume-id", id, "CONV_NEXT"]);
  let done = false;
  pending.finished.then(() => { done = true; });
  const reached = await waitUntil(() => done || fault.reached(), 15_000) && fault.reached();
  if (reached) pending.child.kill("SIGKILL");
  const ended = await pending.finished;
  fault.stop();
  writeFileSync(join(f.root, "fault-boundary.json"), JSON.stringify({ path, reached, signal: ended.signal, code: ended.code }, null, 2));
  assert(reached, `Owned fault boundary not reached: the open never renamed ${path} (exit ${ended.code}: ${ended.stdout.slice(0, 200)})`);
  expect(ended.signal).toBe("SIGKILL");
  await o.observe("crash");
}

// The last commit of main whose fx writes v1 sessions: the v1 writer for
// every "older build" step that names no other release, unless
// FX_TLA_V1_WRITER names another release of the same format, such as v0.0.14.
export const lastV1Commit = "9656a2c2cdb487f6acb12883cee43ca167df0829";
export const v1Writer = () => olderRelease(process.env.FX_TLA_V1_WRITER || lastV1Commit);

const releases = new Map<string, string>();
const releaseCache = process.env.FX_TLA_RELEASE_CACHE ?? join(tmpdir(), "fx-tla-releases");
// An fx release or commit, built from the target's own history once per
// machine in a cache outside every repository, to write the v1 formats it
// wrote; release-<ref>.json records its commit and binary hash. A ref builds
// only with the Zig it was written for: the default `zig` when its version
// matches, otherwise the one FX_RELEASE_ZIG names. Returns its binary.
export function olderRelease(ref: string): string {
  const cached = releases.get(ref);
  if (cached) return cached;
  const git = (...args: string[]) => Bun.spawnSync(["git", "-C", worktree, ...args]);
  const commit = git("rev-parse", `${ref}^{commit}`).stdout.toString().trim();
  assert.match(commit, /^[0-9a-f]{40}$/, `fx ${ref} is not in this checkout's history`);
  const dir = join(releaseCache, commit), bin = join(dir, "zig-out/bin/fx");
  const wanted = /minimum_zig_version = "([^"]+)"/.exec(git("show", `${commit}:build.zig.zon`).stdout.toString())?.[1];
  const local = Bun.spawnSync(["zig", "version"]).stdout.toString().trim();
  const zig = wanted === local ? "zig" : process.env.FX_RELEASE_ZIG;
  assert(zig, `fx ${ref} needs Zig ${wanted}; set FX_RELEASE_ZIG to it`);
  if (!existsSync(bin)) {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
    const extracted = Bun.spawnSync(["sh", "-c", `git -C ${shellQuote(worktree)} archive ${commit} | tar -x -C ${shellQuote(dir)}`]);
    assert.equal(extracted.exitCode, 0, `extracting fx ${ref} failed: ${extracted.stderr.toString()}`);
    const built = Bun.spawnSync([zig, "build"], { cwd: dir });
    assert.equal(built.exitCode, 0, `building fx ${ref} with ${zig} failed: ${built.stderr.toString().slice(-2000)}`);
  }
  const sha256 = createHash("sha256").update(readFileSync(bin)).digest("hex");
  writeFileSync(join(artifacts, `release-${ref.replace(/[^\w.-]/g, "_")}.json`), JSON.stringify({ ref, commit, bin, sha256, zig }, null, 2));
  releases.set(ref, bin);
  return bin;
}

// Every v2 log a run left, converted ones included, through the saved-log
// check (TurnLifecycle and Subagents under TLC); none may be unreadable.
async function checkSavedLogs(root: string, label: string) {
  const found = Bun.spawnSync(["find", root, "-type", "d", "-path", "*/.fx/sessions/v2"]).stdout.toString().split("\n")
    .filter(dir => dir && readdirSync(dir).some(name => existsSync(join(dir, name, "log.jsonl"))));
  if (!found.length) return;
  const child = Bun.spawn(["python3", savedLogsChecker, ...found], { stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  writeFileSync(join(root, `saved-logs-${label}.json`), JSON.stringify({ roots: found, code, stdout, stderr }, null, 2));
  expect(code === 0 && !/UNREADABLE/.test(stdout), `saved-log TLC check failed for ${found.join(", ")}: ${stdout}${stderr}`).toBe(true);
}

export async function requireAccepted(o: ReturnType<typeof observer>, label: string) {
  const result = await o.check(label);
  expect(result.verdict, `TLC ${result.verdict}: ${result.detail ?? ""} (evidence ${result.report})`).toBe("ACCEPTED");
  await checkSavedLogs(o.root, label);
  return result;
}

export function scenario(name: string, body: (f: Fixture) => Promise<void>) {
  test(name, async () => {
    for (let iteration = 0; iteration < repetitions; iteration++) {
      const f = fixture(name.replace(/[^a-z0-9]+/gi, "-").slice(0, 40));
      try { await body(f); } finally { await f.finish(); }
    }
  }, Math.max(240_000, repetitions * 240_000));
}

