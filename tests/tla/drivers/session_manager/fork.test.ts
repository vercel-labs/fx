// /fork (D58) through the real binary in a terminal, judged by TLC. Each
// scenario drives fx in tmux, then check_runtime.py has TLC check what it
// left: every process's wiring trace against
// tests/tla/session_manager/Wiring.tla (Fork with ForkIsNewSession,
// ForkLeavesSource and ForkBetweenTurns), each saved log against
// TurnLifecycle, and each fork's log against trace/ForkLog.tla: the
// source's first lines byte for byte, ending at a turn boundary. Faults
// planted into a kept run must be rejected.
import { expect, test } from "bun:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, shellQuote, targetHelpers, testEnvironment } from "../lib/context";
import { inspectRuntime, requireAccepted, type Model, type RuntimeEvidence } from "./bridge";

const { TmuxSession, startDynamicFakeGateway, fakeGatewayFinalText, fakeGatewayToolCall, heldFakeGatewayFinalText, FAKE_GATEWAY_MODEL, tmuxAvailable } =
  await targetHelpers();
const TIMEOUT = 20_000;

type Reply = (body: string) => Response | Promise<Response>;
type Process = { pid: number; exitCode: number | null; signal: string | null };
type App = { session: any; pid: number; stderr: string };

function fixture(label: string) {
  const root = mkdtempSync(join(artifacts, `fork-${label}-`));
  const home = join(root, "home"), workspace = join(root, "workspace"), trace = join(root, "wiring.log");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { mode: 0o700 });
  const sessionsRoot = join(home, ".fx/sessions/v2");
  let reply: Reply = () => fakeGatewayFinalText("UNSCRIPTED");
  const gateway = startDynamicFakeGateway(body => reply(body));
  const processes: Process[] = [];
  const apps: App[] = [];
  const env = () => testEnvironment({
    HOME: home, AI_GATEWAY_API_KEY: "synthetic-fork-fixture", FX_TEST_SKIP_ONBOARDING: "1",
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_MODEL: FAKE_GATEWAY_MODEL, FX_PERMISSION_MODE: "full-access", NO_COLOR: "1",
    FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "wiring",
  });
  return {
    root, trace, sessionsRoot, processes,
    script(next: Reply) { reply = next; },
    async app(args: string[] = []): Promise<App> {
      const stderr = join(root, `app-${apps.length + 1}.stderr`);
      writeFileSync(stderr, "");
      const command = [binary, ...args].map(shellQuote).join(" ");
      const session = await TmuxSession.create({ cmd: command, cwd: workspace, env: env(), stderrPath: stderr, width: 100, height: 40 });
      await session.waitForStableComposer(TIMEOUT);
      const app = { session, pid: session.processPid(), stderr };
      apps.push(app);
      return app;
    },
    async quit(app: App) {
      await app.session.sendKeys("C-u");
      await app.session.sendText("/quit");
      expect(await app.session.waitForSessionEnd(TIMEOUT)).toBe(true);
      processes.push({ pid: app.pid, exitCode: app.session.recordedExitStatus(), signal: null });
      expect(readFileSync(app.stderr, "utf8")).toBe("");
    },
    async crash(app: App) {
      process.kill(app.pid, "SIGKILL");
      expect(await app.session.waitForSessionEnd(TIMEOUT)).toBe(true);
      processes.push({ pid: app.pid, exitCode: null, signal: "SIGKILL" });
    },
    sessions(): string[] {
      if (!existsSync(sessionsRoot)) return [];
      return readdirSync(sessionsRoot).filter(id => !id.startsWith(".") && existsSync(join(sessionsRoot, id, "log.jsonl"))).sort();
    },
    log(id: string): any[] {
      return readFileSync(join(sessionsRoot, id, "log.jsonl"), "utf8").trimEnd().split("\n").map(line => JSON.parse(line));
    },
    /// TLC's verdict on the run: `ids` (default every saved session) under
    /// `models`, against this run's sessions and wiring trace.
    async judge(models: Model[], ids?: string[]) {
      const evidence: RuntimeEvidence = {
        version: 1, sessionsRoot, sessionIds: ids ?? this.sessions(), wiringTrace: trace, processes, requiredModels: models,
      };
      return inspectRuntime(evidence, join(root, "tlc"));
    },
    async finish() {
      for (const app of apps) await app.session.kill().catch(() => {});
      gateway.stop();
    },
  };
}
type Fixture = ReturnType<typeof fixture>;

function scenario(name: string, body: (f: Fixture) => Promise<void>) {
  test.skipIf(!tmuxAvailable())(name, async () => {
    const f = fixture(name.replace(/[^A-Za-z0-9]+/g, "-").slice(0, 40));
    try { await body(f); } finally { await f.finish(); }
  }, TIMEOUT * 8);
}

/// Answers each request by the scripted prompt that appears last in it, so a
/// fork's history and a resumed session's are answered by their newest prompt.
function byLatestPrompt(answers: Record<string, string>): Reply {
  return body => {
    const latest = Object.keys(answers).map(prompt => [prompt, body.lastIndexOf(prompt)] as const)
      .filter(([, at]) => at >= 0).sort((a, b) => b[1] - a[1])[0];
    return fakeGatewayFinalText(latest ? answers[latest[0]]! : "UNSCRIPTED");
  };
}

async function prompts(app: App, answers: Record<string, string>, which: string[]) {
  for (const prompt of which) {
    await app.session.sendText(prompt);
    await app.session.waitForText(answers[prompt]!, TIMEOUT);
  }
  await app.session.waitForStableComposer(TIMEOUT);
}

/// The pane once it has stopped changing; unlike waitForStableComposer, the
/// composer may hold text, as it does after a fork.
async function settled(app: App): Promise<string> {
  const deadline = Date.now() + TIMEOUT;
  let previous = "", since = Date.now();
  while (Date.now() < deadline) {
    const pane: string = await app.session.capturePane();
    if (pane !== previous) [previous, since] = [pane, Date.now()];
    else if (Date.now() - since >= 300) return pane;
    await Bun.sleep(25);
  }
  throw new Error(`pane never settled:\n${previous}`);
}

/// Opens /fork, moves `up` rows from the newest prompt, and forks there.
async function fork(app: App, up: number) {
  await app.session.sendText("/fork");
  await app.session.waitForText("enter fork", TIMEOUT);
  for (let n = 0; n < up; n++) await app.session.sendKeys("Up");
  await app.session.sendKeys("Enter");
  await app.session.waitForText("session forked", TIMEOUT);
  await settled(app);
}

const titles = (log: any[]) => log.filter(line => line.kind === "set" && line.key === "title").map(line => line.value);
const turnsIn = (log: any[]) => log.filter(line => line.kind === "turn_committed").length;

const ANSWERS = { "Fork prompt one.": "FORK_ONE", "Fork prompt two.": "FORK_TWO", "Fork prompt three.": "FORK_THREE", "A new prompt in the fork.": "FORK_NEW" };
// The run the planted faults below are made from.
let kept: { root: string; sessions: string; wiring: string; source: string; fork: string; processes: Process[] } | null = null;

scenario("a fork before the middle prompt holds the turns before it, and the source is unchanged", async f => {
  f.script(byLatestPrompt(ANSWERS));
  const app = await f.app();
  await prompts(app, ANSWERS, ["Fork prompt one.", "Fork prompt two.", "Fork prompt three."]);
  const [source] = f.sessions();
  const before = readFileSync(join(f.sessionsRoot, source!, "log.jsonl"));
  await fork(app, 1);
  expect(await app.session.capturePane()).toContain("Fork prompt two.");
  await app.session.sendKeys("C-u");
  await prompts(app, ANSWERS, ["A new prompt in the fork."]);
  await f.quit(app);
  const ids = f.sessions();
  expect(ids).toHaveLength(2);
  const forkId = ids.find(id => id !== source)!;
  const after = readFileSync(join(f.sessionsRoot, source!, "log.jsonl"));
  expect(after.subarray(0, before.length).equals(before)).toBe(true);
  expect(turnsIn(f.log(forkId))).toBe(2);
  requireAccepted(await f.judge(["turns", "wiring", "fork"]));
  kept = { root: f.root, sessions: f.sessionsRoot, wiring: f.trace, source: source!, fork: forkId, processes: [...f.processes] };
});

scenario("a fork before the first prompt holds no turn and puts that prompt in the composer", async f => {
  f.script(byLatestPrompt(ANSWERS));
  const app = await f.app();
  await prompts(app, ANSWERS, ["Fork prompt one.", "Fork prompt two."]);
  await fork(app, 1);
  expect(await app.session.capturePane()).toContain("Fork prompt one.");
  await f.quit(app);
  const ids = f.sessions();
  expect(ids).toHaveLength(2);
  expect(ids.map(id => turnsIn(f.log(id))).sort()).toEqual([0, 2]);
  requireAccepted(await f.judge(["turns", "wiring", "fork"]));
});

scenario("a fork of a fork is a third session, titled with one fork mark", async f => {
  f.script(byLatestPrompt(ANSWERS));
  const app = await f.app();
  await prompts(app, ANSWERS, ["Fork prompt one.", "Fork prompt two."]);
  await app.session.sendText("/rename Fork source");
  await app.session.waitForText('renamed to "Fork source"', TIMEOUT);
  await fork(app, 0);
  await app.session.sendKeys("C-u");
  await prompts(app, ANSWERS, ["A new prompt in the fork."]);
  await fork(app, 0);
  await f.quit(app);
  const ids = f.sessions();
  expect(ids).toHaveLength(3);
  const forks = ids.filter(id => f.log(id)[0].forked_from);
  expect(forks).toHaveLength(2);
  for (const id of forks) expect(titles(f.log(id)).at(-1)).toBe("Fork source (fork)");
  requireAccepted(await f.judge(["turns", "wiring", "fork"]));
});

scenario("/fork while a turn runs waits for it and forks nothing", async f => {
  const held = heldFakeGatewayFinalText();
  f.script(body => body.includes("A slow prompt.") ? held.response : fakeGatewayFinalText("UNSCRIPTED"));
  const app = await f.app();
  await app.session.sendText("A slow prompt.");
  await app.session.waitForText("Thinking", TIMEOUT);
  await app.session.sendText("/fork");
  await app.session.waitForText("/fork is available once the current turn finishes", TIMEOUT);
  held.release("SLOW_DONE");
  await app.session.waitForText("SLOW_DONE", TIMEOUT);
  await app.session.waitForStableComposer(TIMEOUT);
  await f.quit(app);
  expect(f.sessions()).toHaveLength(1);
  expect(readFileSync(f.trace, "utf8")).not.toContain("action=Fork");
  requireAccepted(await f.judge(["turns", "wiring"]));
});

// The model forks only with no child running (ForkBetweenTurns). A subagent
// the parent's reply to steering left working keeps that turn open, so /fork
// must wait for it too.
scenario("/fork while a subagent still works after steering waits for it", async f => {
  const child = heldFakeGatewayFinalText();
  let childAsked = false;
  f.script(raw => {
    const body = JSON.parse(raw);
    const latest = JSON.stringify(body.prompt?.filter((item: any) => item.role === "user").at(-1)?.content ?? "");
    if (latest.includes("FORK_CHILD_TASK")) { childAsked = true; return child.response; }
    if (raw.includes("FORK_CHILD_RESULT")) return fakeGatewayFinalText("PARENT_AFTER_CHILD");
    if (latest.includes("Answer now.")) return fakeGatewayFinalText("STEERED");
    if (latest.includes("Delegate the slow work.")) {
      return fakeGatewayToolCall("fork-delegation", "subagent", { request: { action: "run", task: "FORK_CHILD_TASK" } });
    }
    return fakeGatewayFinalText("UNSCRIPTED");
  });
  const app = await f.app();
  await app.session.sendText("Delegate the slow work.");
  await app.session.waitForPane(() => childAsked, TIMEOUT);
  await app.session.sendText("Answer now.");
  await app.session.waitForText("STEERED", TIMEOUT);
  await app.session.sendText("/fork");
  const pane: string = await app.session.waitForPane(
    (text: string) => text.includes("/fork is available once the current turn finishes") || text.includes("enter fork"), TIMEOUT);
  expect(pane).not.toContain("enter fork");
  child.release("FORK_CHILD_RESULT");
  await app.session.waitForText("PARENT_AFTER_CHILD", TIMEOUT);
  await app.session.waitForStableComposer(TIMEOUT);
  await fork(app, 0);
  await f.quit(app);
  requireAccepted(await f.judge(["turns", "children", "wiring", "fork"]));
});

scenario("a crash right after a fork leaves the fork and its source whole", async f => {
  f.script(byLatestPrompt(ANSWERS));
  const first = await f.app();
  await prompts(first, ANSWERS, ["Fork prompt one.", "Fork prompt two."]);
  const [source] = f.sessions();
  await fork(first, 0);
  await f.crash(first);
  const forkId = f.sessions().find(id => id !== source)!;
  for (const id of [forkId, source!]) {
    const again = await f.app(["--resume", id]);
    await again.session.waitForText("FORK_ONE", TIMEOUT);
    await f.quit(again);
  }
  requireAccepted(await f.judge(["turns", "wiring", "fork"]));
});

scenario("Esc closes the fork menu without forking", async f => {
  f.script(byLatestPrompt(ANSWERS));
  const app = await f.app();
  await prompts(app, ANSWERS, ["Fork prompt one."]);
  await app.session.sendText("/fork");
  await app.session.waitForText("enter fork", TIMEOUT);
  await app.session.sendKeys("Escape");
  await app.session.waitForPane((pane: string) => !pane.includes("enter fork"), TIMEOUT);
  await f.quit(app);
  expect(f.sessions()).toHaveLength(1);
  requireAccepted(await f.judge(["turns", "wiring"]));
});

scenario("/fork with no prompt yet says so and saves nothing", async f => {
  const app = await f.app();
  await app.session.sendText("/fork");
  await app.session.waitForText("nothing to fork yet", TIMEOUT);
  await f.quit(app);
  expect(f.sessions()).toHaveLength(0);
  requireAccepted(await f.judge(["wiring"], []));
});

// Planted faults, made from the first scenario's kept run: each copy changes
// one thing the model forbids, and TLC must reject it.

function crc32c(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (crc & 1 ? 0x82f63b78 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/// `line` with `from` replaced by `to` and its CRC recomputed, so the change
/// reaches the model instead of the line check.
function resealed(line: string, from: string, to: string): string {
  const marker = line.lastIndexOf(',"crc":"');
  assert(marker > 0 && line.slice(0, marker).includes(from), `no ${from} to plant in that line`);
  const body = line.slice(0, marker).replace(from, to);
  return `${body},"crc":"${crc32c(Buffer.from(body)).toString(16).padStart(8, "0")}"}`;
}

async function plantedVerdict(models: Model[], plant: (copy: { sessions: string; wiring: string }) => void) {
  assert(kept, "the first scenario keeps the run these faults are planted into");
  const root = mkdtempSync(join(kept.root, "planted-"));
  const copy = { sessions: join(root, "sessions"), wiring: join(root, "wiring.log") };
  cpSync(kept.sessions, copy.sessions, { recursive: true });
  cpSync(kept.wiring, copy.wiring);
  plant(copy);
  const evidence: RuntimeEvidence = {
    version: 1, sessionsRoot: copy.sessions, sessionIds: [kept.source, kept.fork].sort(), wiringTrace: copy.wiring,
    processes: kept.processes, requiredModels: models,
  };
  return (await inspectRuntime(evidence, join(root, "tlc"))).verdict;
}

test.skipIf(!tmuxAvailable())("planted: a fork moved inside a turn is rejected", async () => {
  const verdict = await plantedVerdict(["wiring"], copy => {
    const lines = readFileSync(copy.wiring, "utf8").trimEnd().split("\n");
    const at = lines.findIndex(line => line.includes("[wiring] action=Fork "));
    const begin = lines.slice(0, at).findLastIndex(line => line.includes("[wiring] action=BeginTurn "));
    assert(at > 0 && begin >= 0, "the kept run has a fork after a turn began");
    const [moved] = lines.splice(at, 1);
    lines.splice(begin + 1, 0, moved!);
    writeFileSync(copy.wiring, lines.join("\n") + "\n");
  });
  expect(verdict).toBe("REJECTED");
}, TIMEOUT * 4);

test.skipIf(!tmuxAvailable())("planted: a fork whose copied line differs from its source is rejected", async () => {
  const verdict = await plantedVerdict(["fork"], copy => {
    const path = join(copy.sessions, kept!.fork, "log.jsonl");
    const lines = readFileSync(path, "utf8").trimEnd().split("\n");
    const at = lines.findIndex(line => line.includes("Fork prompt one."));
    assert(at > 0, "the kept fork copied the first prompt");
    lines[at] = resealed(lines[at]!, "Fork prompt one.", "Fork prompt ONE.");
    writeFileSync(path, lines.join("\n") + "\n");
  });
  expect(verdict).toBe("REJECTED");
}, TIMEOUT * 4);
