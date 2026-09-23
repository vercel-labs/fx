import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// The shared tmux helper imports eval helpers; do not load repository dotenv files.
process.env.FX_E2E_DISABLE_DOTENV = "1";
const {
  FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText, fakeGatewayToolCall,
  fakeShellRun, heldFakeGatewayFinalText, startDynamicFakeGateway,
  hasEmptyComposer, tmuxAvailable,
} = await import("./tmux-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const HEAD = "HISTORY_HEAD_29b7";
const TAIL = "HISTORY_TAIL_16d3";
const HANDOFF = `INTERNAL_HANDOFF_4e12: preserve ${HEAD} and ${TAIL}; follow the latest user request.`;
const FOLLOWUP = "FOLLOWUP_OK_732c";
const REOPEN = "REOPEN_OK_492a";
const ACTIVITY = /Compacting \((?:\d+h)?(?:\d+m)?\d+s\)/;
const COMPACTION_OUTPUT = /Compacting|compaction|Context compacted|No context to compact|Your existing context was kept|Synthetic summary rejection|INTERNAL_HANDOFF_4e12/i;

type Trigger = "manual" | "auto" | "overflow" | "ordinary";
type Outcome = "success" | "cancel" | "empty" | "provider-error";

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function checkpoints(bytes: Buffer): number {
  return bytes.toString().trim().split("\n").filter(Boolean)
    .map((line) => JSON.parse(line)).filter((frame) => frame.event?.context_checkpoint).length;
}

async function until(predicate: () => boolean, label: string, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await Bun.sleep(20);
  }
}

async function fixture(trigger: Trigger, outcome: Outcome = "success", longResume = false) {
  // Ctrl+O includes the recording path; keep it free of forbidden notice words.
  const root = mkdtempSync(join(tmpdir(), "fx-activity-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    model: FAKE_GATEWAY_MODEL, auto_upgrade: false, startup_scrollback: false,
  }));
  // Failure attempts need an older exchange outside the retained suffix, but
  // must leave the next ordinary request below the automatic pressure threshold.
  const seedTurns = trigger === "manual" && outcome !== "success" ? 3 : 1;
  const lines = seedTurns > 1 ? 400 : trigger === "ordinary" ? 2 : trigger === "auto" || longResume ? 18_000 : 1600;
  const seedReply = (turn: number) => `${turn === 1 ? HEAD : `HISTORY_MIDDLE_${turn}`}\n${"history alpha beta gamma delta sample line\n".repeat(lines)}SEED_DONE_${turn}${turn === seedTurns ? `\n${TAIL}` : ""}`;
  const summaryHold = heldFakeGatewayFinalText();
  const ordinaryHold = heldFakeGatewayFinalText();
  let phase: "seed" | "attempt" | "followup" | "reopen" = "seed";
  let summaries = 0;
  let ordinary = 0;
  let overflowSent = false;
  let terminal: InstanceType<typeof TmuxSession> | undefined;
  const requests: object[] = [];
  const gateway = startDynamicFakeGateway((raw) => {
    const request = JSON.parse(raw);
    const summary = request.toolChoice?.type === "none" && request.tools?.length === 0;
    requests.push({ phase, summary, at: Date.now(), bytes: raw.length,
      head: raw.includes(HEAD), tail: raw.includes(TAIL), handoff: raw.includes("INTERNAL_HANDOFF_4e12"),
      followup: raw.includes("Follow the latest request.") || raw.includes("Recover with another request."),
      reopen: raw.includes("Continue after reopening.") || raw.includes("Check the reopened context."),
    });
    if (summary) {
      summaries++;
      if (phase === "attempt" && outcome === "provider-error") {
        return Response.json({ error: { message: "Synthetic summary rejection for Bearer abcdef0123456789xyz" } }, { status: 400 });
      }
      if (phase === "attempt" && summaries === 1) return summaryHold.response;
      // Each chunk/retry needs a fresh Response, not a consumed held body.
      return fakeGatewayFinalText(phase === "attempt" && outcome === "empty" ? "" : HANDOFF);
    }
    ordinary++;
    if (phase === "seed") return fakeGatewayFinalText(seedReply(ordinary));
    if (phase === "attempt") {
      if (trigger === "overflow" && !overflowSent) {
        overflowSent = true;
        return Response.json({ error: {
          type: "invalid_request_error", code: "context_length_exceeded",
          message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
        } }, { status: 400 });
      }
      return ordinaryHold.response;
    }
    return fakeGatewayFinalText(phase === "reopen" ? REOPEN : FOLLOWUP);
  }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-compaction-key",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_SKIP_ONBOARDING: "1",
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  let sessionId = "";
  let eventsPath = "";
  let initial = Buffer.alloc(0);
  let launchIndex = 0;
  const stderrPaths: string[] = [];
  const tapes: string[] = [];
  async function cli(args: string[]) {
    const child = Bun.spawn([binary, ...args], { cwd: workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill(), 30_000);
    try {
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      expect(code).toBe(0);
      expect(stderr).toBe("");
      return JSON.parse(stdout);
    } finally { clearTimeout(timer); }
  }
  async function launch(withoutCredential = false, withTraceLog = true) {
    const tape = join(root, `terminal-${++launchIndex}.fxtape`);
    const stderr = join(root, `terminal-${launchIndex}.stderr`);
    tapes.push(tape);
    stderrPaths.push(stderr);
    const terminalEnv: Record<string, string> = { ...env, FX_RECORD: tape, FX_DEBUG_RECORD_SILENT_BANNER: "1",
      FX_TRACE_LOG: join(root, `terminal-${launchIndex}.trace`),
      FX_TRACE_SCOPES: "input,worker,session,scroll,agent,gateway,compaction",
    };
    if (withoutCredential) delete terminalEnv.AI_GATEWAY_API_KEY;
    if (!withTraceLog) {
      delete terminalEnv.FX_TRACE_LOG;
      delete terminalEnv.FX_TRACE_SCOPES;
    }
    // Do not inherit provider overrides, credentials, shell startup or dotenv state.
    const command = `/usr/bin/env -i ${Object.entries(terminalEnv).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)} --resume ${shellQuote(sessionId)}`;
    terminal = await TmuxSession.create({
      cmd: command, cwd: workspace, env: { HOME: home, FX_SOUND: "0" }, isolated: true,
      stderrPath: stderr, width: 90, height: 32, minimumHistoryLines: 25_000,
      startupWaitMs: 0,
    });
    // A composer can be painted while resume history is still being restored.
    // Wait for a stable frame, then acknowledge input without submitting a turn
    // or retiring the retained resume transcript before the tested /compact.
    await terminal.waitForStableComposer(20_000);
    await terminal.sendLiteral("startup-input-handshake");
    await terminal.waitForText("startup-input-handshake", 5000);
    await terminal.sendKeys("C-u");
    await terminal.waitForComposer(5000);
    return terminal;
  }
  async function waitForResumeHandoff() {
    if (lines < 18_000) return;
    const tracePath = join(root, `terminal-${launchIndex}.trace`);
    // Wait only after submission: the composer accepts input during restoration,
    // but replies need the immutable history source to hand off to the live one.
    // 18k rows / 64 per frame needs about 282 frames. Debug observations reached
    // 77 ms median / 134 ms max per frame; 60s bounds the drain, not the reply.
    await until(() => readFileSync(tracePath, "utf8").includes("resume historical flow committed"),
      `resume history-source handoff in ${tracePath}`, 60_000);
  }
  function durable() {
    const bytes = readFileSync(eventsPath);
    expect(bytes.subarray(0, initial.length).equals(initial)).toBe(true);
    return checkpoints(bytes);
  }
  async function close() {
    if (!terminal) return;
    expect(terminal.paneStatus()).toEqual({ dead: false, status: null });
    await terminal.sendText("/quit");
    expect(await terminal.waitForSessionEnd(5000)).toBe(true);
    await terminal.kill();
    terminal = undefined;
    for (const path of stderrPaths) expect(readFileSync(path, "utf8")).toBe("");
  }
  async function cleanup(passed: boolean) {
    if (!passed) {
      writeFileSync(join(root, "requests.json"), JSON.stringify({
        trigger, outcome, phase, seedTurns, summaries, ordinary, overflowSent, requests,
        paneStatus: terminal?.paneStatus(),
      }, null, 2));
      if (terminal) writeFileSync(join(root, "failure.scrollback.ansi"), await terminal.captureFullScrollbackEscapes());
      console.error(`compaction evidence retained: ${root}; phase=${phase}, summaries=${summaries}, ordinary=${ordinary}`);
    }
    summaryHold.dispose();
    ordinaryHold.dispose();
    await terminal?.kill();
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
  }
  try {
    for (let turn = 1; turn <= seedTurns; turn++) {
      const reply = await cli(["ask", "--json", "--auto", ...(sessionId ? ["--resume", sessionId] : []), `Seed ordinary historical turn ${turn}.`]);
      if (sessionId) expect(reply.session_id).toBe(sessionId);
      else sessionId = reply.session_id;
      expect(sessionId).toBeTruthy();
      expect(ordinary).toBe(turn);
      expect(summaries).toBe(0);
    }
    eventsPath = join(home, ".fx/sessions", sessionId, "events.jsonl");
    initial = readFileSync(eventsPath);
    expect(initial.toString()).toContain(HEAD);
    expect(initial.toString()).toContain(TAIL);
    expect(checkpoints(initial)).toBe(0);
    expect(summaries).toBe(0);
    expect(ordinary).toBe(seedTurns);
    phase = "attempt";
    return {
      launch, close, cleanup, durable, cli, tapes, root, seedTurns, summaryHold, ordinaryHold, waitForResumeHandoff,
      savedEvents: () => readFileSync(eventsPath, "utf8"),
      counts: () => ({ summaries, ordinary, overflowSent }),
      phase: (value: typeof phase) => { phase = value; },
      lastRequest: () => gateway.requests.at(-1)!.body,
      requestsContaining: (marker: string) => gateway.requests.map((request) => request.body).filter((body) => body.includes(marker)),
    };
  } catch (error) { await cleanup(false); throw error; }
}

async function assertSilent(terminal: InstanceType<typeof TmuxSession>, root: string, label: string) {
  const inline = await terminal.captureFullScrollbackEscapes();
  writeFileSync(join(root, `${label}.scrollback.ansi`), inline);
  expect(inline.length).toBeGreaterThan(0);
  expect(inline).not.toMatch(COMPACTION_OUTPUT);
  await terminal.sendKeys("C-o");
  await terminal.waitForText("full detail", 5000);
  await terminal.sendKeys("End");
  const full = await terminal.waitForPane((pane) => pane.includes("full detail"), 5000);
  writeFileSync(join(root, `${label}.full-transcript.txt`), full);
  expect(full).not.toMatch(COMPACTION_OUTPUT);
  await terminal.sendKeys("C-o");
  await terminal.waitForComposer(5000);
}

async function assertLive(terminal: InstanceType<typeof TmuxSession>) {
  const first = await terminal.waitForText(ACTIVITY, 10_000);
  const clock = first.match(ACTIVITY)![0];
  const markers = new Set<boolean>();
  const later = await terminal.waitForPane((pane) => {
    const rows = pane.split("\n").filter((line) => ACTIVITY.test(line));
    if (rows.length === 0) return false;
    expect(rows).toHaveLength(1);
    expect(rows[0]).not.toMatch(/[↑↓]|tokens|chunk|%/i);
    markers.add(rows[0].includes("•"));
    return markers.size === 2 && !rows[0].includes(clock);
  }, 5000);
  expect(later.match(/Compacting/g)).toHaveLength(1);
}

describe.skipIf(!tmuxAvailable())("tui: compaction activity", () => {
  for (const trigger of ["manual", "auto", "overflow"] as const) {
    test(`${trigger}: held summary is transient, commits once released, and resumes ordinary work`, async () => {
      const f = await fixture(trigger, "success", trigger === "manual");
      let passed = false;
      try {
        const terminal = await f.launch();
        // First interaction after a long resume; do not retire the resume source with a prompt.
        await terminal.sendText(trigger === "manual" ? "/compact" : "Continue the current turn.");
        await until(() => f.counts().summaries === 1, "first summary request");
        await assertLive(terminal);
        expect(f.durable()).toBe(0);
        expect(f.counts().ordinary).toBe(f.seedTurns + (trigger === "overflow" ? 1 : 0));
        if (trigger === "manual") {
          await terminal.sendKeys("C-o");
          await terminal.waitForText("full detail", 5000);
          expect(await terminal.capturePane()).not.toMatch(COMPACTION_OUTPUT);
          await terminal.sendKeys("C-o");
          await terminal.waitForText(ACTIVITY, 5000);
          await terminal.resizeWindow(52, 24);
          await terminal.waitForText(ACTIVITY, 5000);
          await terminal.resizeWindow(90, 32);
        }
        f.summaryHold.release(HANDOFF);
        await until(() => f.durable() > 0, "acknowledged checkpoint");
        if (trigger === "manual") {
          await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && hasEmptyComposer(pane), 10_000);
          expect(f.counts().ordinary).toBe(f.seedTurns);
          expect(f.counts().summaries).toBeGreaterThan(1);
        } else {
          await until(() => f.counts().ordinary === f.seedTurns + (trigger === "overflow" ? 2 : 1), "ordinary request after compaction");
          const pane = await terminal.waitForText(/Thinking \(/, 10_000);
          expect(pane).not.toMatch(ACTIVITY);
          expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
          f.ordinaryHold.release("CURRENT_TURN_OK_f713");
          await f.waitForResumeHandoff();
          await terminal.waitForPane((pane) => pane.includes("CURRENT_TURN_OK_f713") && hasEmptyComposer(pane), 10_000);
        }
        expect(f.counts().overflowSent).toBe(trigger === "overflow");
        expect(f.durable()).toBe(1);
        const before = f.counts();
        f.phase("followup");
        await terminal.sendText("Follow the latest request.");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...before, ordinary: before.ordinary + 1 });
        expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
        await assertSilent(terminal, f.root, "completed");
        await f.close();
        f.phase("reopen");
        const reopened = await f.launch();
        await reopened.sendText("Continue after reopening.");
        await f.waitForResumeHandoff();
        await reopened.waitForPane((pane) => pane.includes(REOPEN) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...before, ordinary: before.ordinary + 2 });
        expect(f.durable()).toBe(1);
        expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
        await assertSilent(reopened, f.root, "reopened");
        await f.close();
        for (const tape of f.tapes) {
          const replay = await f.cli(["replay", tape, "--json"]);
          expect(replay.frame_count).toBeGreaterThan(0);
          expect(replay.stdout_bytes).toBeGreaterThan(0);
        }
        passed = true;
      } finally { await f.cleanup(passed); }
    }, 120_000);
  }

  for (const trigger of ["manual", "auto"] as const) {
    test(`${trigger}: a message submitted during a held compaction waits and runs after with compacted context`, async () => {
      const f = await fixture(trigger, "success", trigger === "manual");
      let passed = false;
      try {
        const terminal = await f.launch();
        await terminal.sendText(trigger === "manual" ? "/compact" : "Continue the current turn.");
        await until(() => f.counts().summaries === 1, "summary request in flight");
        await terminal.waitForText(ACTIVITY, 10_000);
        const steer = trigger === "manual" ? "STEER_DURING_COMPACT_7f2a" : "STEER_DURING_AUTOCOMPACT_3b9c";
        await terminal.sendText(steer);
        // While the summary is held, the message must neither start its own
        // turn nor cancel the compaction: no new gateway request arrives and
        // the activity row stays visible. The resume backlog can delay fresh
        // transcript cards, so only footer activity is asserted here.
        await Bun.sleep(1500);
        expect(f.counts()).toEqual({ summaries: 1, ordinary: f.seedTurns, overflowSent: false });
        await terminal.waitForText(ACTIVITY, 5000);
        // Flip phases before releasing so every later ordinary request gets a
        // fresh FOLLOWUP response; the steer turn can start within milliseconds
        // of the checkpoint, before a later flip would land.
        f.phase("followup");
        f.summaryHold.release(HANDOFF);
        await until(() => f.durable() > 0, "acknowledged checkpoint");
        await f.waitForResumeHandoff();
        await until(() => f.requestsContaining(steer).length > 0, "steer request after compaction");
        expect(f.requestsContaining(steer)[0]).toContain("INTERNAL_HANDOFF_4e12");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane), 20_000);
        await f.close();
        passed = true;
      } finally { await f.cleanup(passed); }
    }, 90_000);
  }

  test("overflow: a message submitted during held in-turn compaction rides the rebuilt request", async () => {
    const f = await fixture("overflow", "success");
    let passed = false;
    try {
      const terminal = await f.launch();
      await terminal.sendText("Continue the current turn.");
      await until(() => f.counts().summaries === 1, "summary request in flight");
      await terminal.waitForText(ACTIVITY, 10_000);
      const steer = "STEER_DURING_OVERFLOW_5c1d";
      await terminal.sendText(steer);
      // While the summary is held, the message must neither start its own
      // turn nor cancel the compaction.
      await Bun.sleep(1500);
      expect(f.counts()).toEqual({ summaries: 1, ordinary: f.seedTurns + 1, overflowSent: true });
      await terminal.waitForText(ACTIVITY, 5000);
      f.summaryHold.release(HANDOFF);
      await until(() => f.durable() > 0, "acknowledged checkpoint");
      // The rebuilt continuation is held by ordinaryHold; the steering must
      // already ride it, as same-turn guidance, before any reply arrives.
      await until(() => f.requestsContaining(steer).length > 0, "steering in the rebuilt request");
      const steered = f.requestsContaining(steer);
      expect(steered).toHaveLength(1);
      expect(steered[0]).toContain("<user_steering>");
      expect(steered[0]).toContain("INTERNAL_HANDOFF_4e12");
      f.ordinaryHold.release("CURRENT_TURN_OK_OVERFLOW_STEER");
      await terminal.waitForPane((pane) => pane.includes("CURRENT_TURN_OK_OVERFLOW_STEER") && hasEmptyComposer(pane), 20_000);
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 90_000);

  for (const outcome of ["cancel", "empty", "provider-error"] as const) {
    test(`manual ${outcome}: scoped feedback preserves history and permits later input and reopen`, async () => {
      const f = await fixture("manual", outcome);
      let passed = false;
      try {
        const terminal = await f.launch();
        await terminal.sendText("/compact");
        await until(() => f.counts().summaries > 0, "summary boundary");
        if (outcome !== "provider-error") {
          await assertLive(terminal);
          expect(f.durable()).toBe(0);
          if (outcome === "cancel") {
            await terminal.sendInterruptEscapePair(10_000);
          } else f.summaryHold.release("");
        }
        const feedback = outcome === "cancel"
          ? "Compaction cancelled. Try /compact again when ready."
          : "Compaction failed. Try /compact again.";
        await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && pane.includes(feedback) && hasEmptyComposer(pane), 15_000);
        expect(f.durable()).toBe(0);
        expect(f.counts().ordinary).toBe(f.seedTurns);
        expect(f.counts().summaries).toBe(outcome === "empty" ? 2 : 1);
        const afterFailure = f.counts();
        if (outcome === "cancel") f.summaryHold.dispose();
        await terminal.sendKeys("Escape");
        await terminal.waitForPane((pane) => !/compact/i.test(pane) && hasEmptyComposer(pane), 5000);
        await assertSilent(terminal, f.root, "failed");
        f.phase("followup");
        await terminal.sendText("Recover with another request.");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...afterFailure, ordinary: f.seedTurns + 1 });
        expect(f.lastRequest()).toContain(HEAD);
        expect(f.lastRequest()).toContain(TAIL);
        expect(f.lastRequest()).not.toContain("INTERNAL_HANDOFF_4e12");
        expect(f.durable()).toBe(0);
        await f.close();
        f.phase("reopen");
        const reopened = await f.launch();
        await reopened.sendText("Check the reopened context.");
        await reopened.waitForPane((pane) => pane.includes(REOPEN) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...afterFailure, ordinary: f.seedTurns + 2 });
        expect(f.lastRequest()).toContain(HEAD);
        expect(f.lastRequest()).toContain(TAIL);
        expect(f.lastRequest()).not.toContain("INTERNAL_HANDOFF_4e12");
        expect(f.durable()).toBe(0);
        await assertSilent(reopened, f.root, "failed-reopen");
        await f.close();
        passed = true;
      } finally { await f.cleanup(passed); }
    }, 90_000);
  }

  for (const trigger of ["auto", "ordinary"] as const) {
    test(`${trigger}: cancellation provenance preserves the correct transcript after reopen`, async () => {
      const f = await fixture(trigger);
      let passed = false;
      try {
        const terminal = await f.launch();
        await terminal.sendText("Cancel this held response.");
        await until(() => trigger === "auto" ? f.counts().summaries === 1 : f.counts().ordinary === 2, "held cancellation boundary");
        await terminal.waitForText(trigger === "auto" ? ACTIVITY : /Thinking \(/, 10_000);
        await terminal.sendInterruptEscapePair(10_000);
        if (trigger === "auto") {
          await terminal.waitForText("Compaction cancelled.", 10_000);
          // An empty composer already exists while feedback is visible. Wait
          // for Escape's visible acknowledgement, not a fixed sendKeys delay,
          // so the slash in /quit cannot become part of a Meta key sequence.
          terminal.sendKeysImmediate(["Escape"]);
        } else {
          await terminal.waitForText("Cancelled", 10_000);
        }
        await terminal.waitForPane((pane) => hasEmptyComposer(pane) &&
          !/Compaction cancelled|Compacting|Thinking/.test(pane), 5000);
        const interruptions = () => f.savedEvents().trim().split("\n")
          .map((line) => JSON.parse(line)).filter((frame) => frame.event?.interrupted);
        await until(() => interruptions().length === 1, "durable cancellation", 5000);
        expect(interruptions()[0].event.interrupted.reason).toBe("cancelled");
        expect(interruptions()[0].event.interrupted.cancellation_origin === "compaction").toBe(trigger === "auto");
        const cancelledCounts = { summaries: trigger === "auto" ? 1 : 0,
          ordinary: f.seedTurns + (trigger === "ordinary" ? 1 : 0), overflowSent: false };
        expect(f.counts()).toEqual(cancelledCounts);
        expect(f.durable()).toBe(0);
        const cancelledEvents = f.savedEvents();
        await f.close();
        expect(f.counts()).toEqual(cancelledCounts);
        expect(f.savedEvents()).toBe(cancelledEvents);

        const reopened = await f.launch();
        await reopened.sendKeys("C-o");
        await reopened.waitForText("full detail", 5000);
        await reopened.sendKeys("End");
        const full = await reopened.waitForPane((pane) => pane.includes("Cancel this held response."), 5000);
        writeFileSync(join(f.root, "cancellation-reopened.txt"), full);
        expect(full.includes("Cancelled")).toBe(trigger === "ordinary");
        expect(full).not.toMatch(COMPACTION_OUTPUT);
        await reopened.sendKeys("C-o");
        await reopened.waitForComposer(5000);
        expect(await reopened.captureFullScrollbackEscapes()).not.toMatch(COMPACTION_OUTPUT);
        await f.close();
        expect(f.counts()).toEqual(cancelledCounts);
        expect(f.savedEvents()).toBe(cancelledEvents);
        expect(f.durable()).toBe(0);
        for (const tape of f.tapes) {
          const replay = await f.cli(["replay", tape, "--json"]);
          expect(replay.frame_count).toBeGreaterThan(0);
          expect(replay.stdout_bytes).toBeGreaterThan(0);
        }
        passed = true;
      } finally { await f.cleanup(passed); }
    }, 60_000);
  }

  test("manual failure then success: /trace records compaction decisions and failures without FX_TRACE", async () => {
    const f = await fixture("manual", "provider-error");
    let passed = false;
    try {
      const terminal = await f.launch(false, false);
      await terminal.sendText("/compact");
      await terminal.waitForText("Compaction failed. Try /compact again.", 15_000);
      expect(f.durable()).toBe(0);
      f.phase("followup");
      await terminal.sendText("/compact");
      await until(() => f.durable() === 1, "checkpoint after recovery compact");
      await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && hasEmptyComposer(pane), 10_000);

      const before = new Set(readdirSync(f.root).filter((name) => name.startsWith("fx-trace-") && name.endsWith(".md")));
      let report = "";
      await terminal.sendText("/trace");
      await until(() => {
        const fresh = readdirSync(f.root).filter((name) => name.startsWith("fx-trace-") && name.endsWith(".md") && !before.has(name));
        if (fresh.length === 0) return false;
        const content = readFileSync(join(f.root, fresh[fresh.length - 1]), "utf8");
        if (!content.includes("## Transcript Timeline")) return false;
        report = content;
        return true;
      }, "trace report", 15_000);

      // No FX_TRACE_LOG was configured, so the opt-in trace tail is absent while
      // the always-on compaction section still carries the full story.
      expect(report).not.toContain("## Trace Tail");
      expect(report).toContain("## Context Compaction\n");
      expect(report).toMatch(/last=\d+ failed=[1-9]\d* \(always recorded; does not require FX_TRACE\)/);
      expect(report).toContain("event=summary_transport_failed");
      // Provider error text is secret-masked before it reaches the report.
      expect(report).toContain("[redacted]");
      expect(report).not.toContain("abcdef0123456789xyz");
      expect(report).toContain("event=transaction_failed");
      expect(report).toContain("event=provider_start");
      expect(report).toContain("event=provider_completed");
      expect(report).toContain("event=committed");
      const problems = report.split("## Problems")[1]?.split("##")[0] ?? "";
      expect(problems).toContain("- context compaction");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 120_000);

  test("missing credentials keep compaction feedback local without hiding ordinary auth errors", async () => {
    const f = await fixture("manual");
    let passed = false;
    try {
      const terminal = await f.launch(true);
      const authMessage = "fx needs access to Vercel AI Gateway";
      async function authNotices(label: string) {
        await terminal.sendKeys("C-o");
        await terminal.waitForText("full detail", 5000);
        await terminal.sendKeys("End");
        const pane = await terminal.waitForPane((text) => text.includes("full detail") && text.includes(authMessage), 5000);
        writeFileSync(join(f.root, `${label}.txt`), pane);
        await terminal.sendKeys("C-o");
        await terminal.waitForComposer(5000);
        return pane.split(authMessage).length - 1;
      }
      const initialNotices = await authNotices("auth-before");
      expect(initialNotices).toBeGreaterThan(0);
      await terminal.sendText("/compact");
      await terminal.waitForText("Compaction was not started.", 5000);
      expect(f.counts().summaries).toBe(0);
      expect(f.counts().ordinary).toBe(f.seedTurns);
      expect(f.durable()).toBe(0);
      await terminal.sendKeys("Escape");
      expect(await authNotices("auth-after-compaction")).toBe(initialNotices);

      await terminal.sendText("Ordinary request without a credential.");
      await terminal.waitForText(authMessage, 5000);
      expect(await authNotices("auth-after-ordinary")).toBe(initialNotices + 1);
      expect(f.counts().ordinary).toBe(f.seedTurns);
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 60_000);

  test("ordinary held request remains Thinking without compaction or extra requests", async () => {
    const f = await fixture("ordinary");
    let passed = false;
    try {
      const terminal = await f.launch();
      await terminal.sendText("Ordinary control request.");
      await until(() => f.counts().ordinary === 2, "ordinary held request");
      await terminal.waitForText(/Thinking \(/, 5000);
      expect(f.counts().summaries).toBe(0);
      expect(f.durable()).toBe(0);
      f.ordinaryHold.release("ORDINARY_CONTROL_OK_727a");
      await terminal.waitForPane((pane) => pane.includes("ORDINARY_CONTROL_OK_727a") && hasEmptyComposer(pane), 10_000);
      expect(f.counts().ordinary).toBe(2);
      await assertSilent(terminal, f.root, "control");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 60_000);

  for (const injectedStaleCheckpoint of [false, true]) {
    test(`overflow recovery ${injectedStaleCheckpoint ? "blocks a stale checkpoint" : "saves a retained image turn"} after a killed post-compaction tool`, async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-compaction-recovery-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const image = join(workspace, "before.png");
      const queuedImage = join(workspace, "queued.png");
      const trace = join(root, "active.trace");
      const activeStderr = join(root, "active.stderr");
      const resumedStderr = join(root, "resumed.stderr");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace);
      copyFileSync(join(import.meta.dir, "fixtures/favicon.png"), image);
      copyFileSync(join(import.meta.dir, "fixtures/favicon.png"), queuedImage);
      for (let step = 2; step <= 24; step++) {
        writeFileSync(join(workspace, `probe-${step}.txt`),
          Array.from({ length: 80 }, (_, line) =>
            `READ_PROBE_BEFORE_OVERFLOW_67e step=${step} line=${line} long evidence for retained context boundary\n`).join(""));
      }
      writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
        model: FAKE_GATEWAY_MODEL, auto_upgrade: false, startup_scrollback: false,
      }));

      const summaryHold = heldFakeGatewayFinalText();
      let phase: "seed" | "active" | "resume" | "followup" = "seed";
      let ordinary = 0;
      let summaries = 0;
      let summaryReleased = false;
      let postCompactionTool = false;
      const gateway = startDynamicFakeGateway((raw) => {
        const request = JSON.parse(raw);
        const summary = request.toolChoice?.type === "none" && request.tools?.length === 0;
        if (summary) {
          summaries++;
          return summaryHold.response;
        }
        ordinary++;
        if (phase === "seed") return fakeGatewayFinalText("RECOVERY_COMPACTION_SEED_67e");
        if (phase === "active" && summaryReleased) {
          postCompactionTool = true;
          return fakeShellRun("post-compact-tool-67e",
            "printf POST_COMPACT_TOOL_RUNNING_67e; sleep 15; printf POST_COMPACT_TOOL_FINISHED_67e");
        }
        if (phase === "active" && ordinary === 10) {
          return fakeShellRun("early-steer-tool-67e", "printf EARLY_STEER_TOOL_RUNNING_67e; sleep 2");
        }
        if (phase === "active" && ordinary === 19) {
          return fakeShellRun("late-steer-tool-67e", "printf LATE_STEER_TOOL_RUNNING_67e; sleep 2");
        }
        if (phase === "active" && ordinary <= 24) {
          return fakeGatewayToolCall(`probe-read-${ordinary}-67e`, "read_file", { path: `probe-${ordinary}.txt` });
        }
        if (phase === "active" && ordinary === 25) {
          return Response.json({ error: {
            type: "invalid_request_error", code: "context_length_exceeded",
            message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
          } }, { status: 400 });
        }
        if (phase === "resume") return fakeGatewayFinalText("RECOVERY_SAVED_TURN_67e");
        return fakeGatewayFinalText("RECOVERY_FOLLOWUP_67e");
      }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["vision", "file-input", "tool-use"], context_window: 400000, max_tokens: 8192 }] });
      const env: Record<string, string> = {
        PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
        TERM: "xterm-256color", AI_GATEWAY_API_KEY: "fake-compaction-key",
        FX_DISABLE_KEYCHAIN: "1", FX_SKIP_ONBOARDING: "1", FX_E2E_DISABLE_DOTENV: "1",
        FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_PERMISSION_MODE: "full-access",
        FX_TRACE_LOG: trace, FX_TRACE_SCOPES: "input,worker,session,agent,compaction,images,gateway",
        FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      };
      const command = (sessionId: string) => `/usr/bin/env -i ${Object.entries(env)
        .map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)} --resume ${shellQuote(sessionId)}`;
      const savedFrames = (eventsPath: string) => readFileSync(eventsPath, "utf8").trim().split("\n")
        .filter(Boolean).map((line) => JSON.parse(line));
      let active: InstanceType<typeof TmuxSession> | undefined;
      let resumed: InstanceType<typeof TmuxSession> | undefined;
      let passed = false;
      try {
        const seed = Bun.spawn([binary, "ask", "--json", "--auto", "Seed the compaction recovery scenario."], {
          cwd: workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe",
        });
        const [seedCode, seedStdout, seedStderr] = await Promise.all([
          seed.exited, new Response(seed.stdout).text(), new Response(seed.stderr).text(),
        ]);
        expect(seedCode).toBe(0);
        expect(seedStderr).toBe("");
        const sessionId = JSON.parse(seedStdout).session_id as string;
        const sessionDir = join(home, ".fx/sessions", sessionId);
        const eventsPath = join(sessionDir, "events.jsonl");
        const recoveryPath = join(sessionDir, "recovery.json");
        const completedBefore = savedFrames(eventsPath).filter((frame) => frame.event?.turn_completed).length;

        phase = "active";
        active = await TmuxSession.create({
          cmd: command(sessionId), cwd: workspace, env, isolated: true, remainOnExit: true,
          stderrPath: activeStderr, width: 110, height: 36, startupWaitMs: 0,
        });
        await active.waitForStableComposer(15_000);
        const steer = (async () => {
          await active!.waitForText("EARLY_STEER_TOOL_RUNNING_67e", 15_000);
          await active!.sendText("STEER_EARLY_67e");
          await active!.waitForText("LATE_STEER_TOOL_RUNNING_67e", 15_000);
          await active!.sendText("STEER_LATE_67e");
        })();
        await active.sendText(`ACTIVE_IMAGE_TURN_67e ${image}`);
        await until(() => summaries === 1, "context-overflow compaction", 20_000);
        await steer;
        summaryReleased = true;
        summaryHold.release("COMPACTION_HANDOFF_67e preserve the retained image context");
        await until(() => postCompactionTool && savedFrames(eventsPath)
          .some((frame) => frame.event?.context_checkpoint), "post-compaction tool", 20_000);
        const retained = JSON.parse(readFileSync(recoveryPath, "utf8")).checkpoint.execution;
        expect(retained.tool_steps).toHaveLength(9);
        expect(retained.steering).toHaveLength(1);
        await active.waitForText("POST_COMPACT_TOOL_RUNNING_67e", 10_000);
        await active.sendText(`QUEUED_DURING_TOOL_67e ${queuedImage}`);
        await until(() => existsSync(trace) && readFileSync(trace, "utf8").split("event=prompt_enqueue").length >= 3,
          "queued image admission", 5_000);
        if (injectedStaleCheckpoint) {
          const stale = JSON.parse(readFileSync(recoveryPath, "utf8"));
          expect(stale.checkpoint.execution.tool_steps.length).toBeGreaterThanOrEqual(2);
          stale.checkpoint.execution.tool_steps = stale.checkpoint.execution.tool_steps.slice(2);
          for (const steering of stale.checkpoint.execution.steering) {
            expect(steering.after_tool_step_count).toBeGreaterThanOrEqual(2);
            steering.after_tool_step_count -= 2;
          }
          writeFileSync(recoveryPath, JSON.stringify(stale));
          expect(stale.checkpoint.execution.tool_steps).toHaveLength(7);
        }

        const fixturePid = active.processPid();
        const fixtureCommand = execFileSync("ps", ["-p", String(fixturePid), "-o", "command="], { encoding: "utf8" });
        expect(fixtureCommand).toContain(binary);
        expect(fixtureCommand).toContain(sessionId);
        process.kill(fixturePid, "SIGKILL");
        await until(() => active!.paneStatus().dead, "fixture fx SIGKILL", 5_000);
        const completedAtKill = savedFrames(eventsPath).filter((frame) => frame.event?.turn_completed).length;
        expect(completedAtKill).toBe(completedBefore);
        await active.kill();
        active = undefined;

        phase = "resume";
        const requestsBeforeResume = gateway.requestCount();
        resumed = await TmuxSession.create({
          cmd: command(sessionId), cwd: workspace, env, isolated: true, remainOnExit: true,
          stderrPath: resumedStderr, width: 110, height: 36, startupWaitMs: 0,
        });
        // The kill left a recovering turn behind, so resume asks before retrying it.
        await resumed.waitForPane((pane) =>
          pane.includes("fx quit unexpectedly while this response was recovering"), 15_000);
        await resumed.waitForStableComposer(10_000);
        expect(gateway.requestCount()).toBe(requestsBeforeResume);
        await resumed.sendText("continue");
        const recoveryScreen = await resumed.waitForPane((pane) =>
          pane.includes("RECOVERY_SAVED_TURN_67e") || pane.includes("InvalidContextHistoryStart"), 15_000);
        await resumed.waitForStableComposer(10_000);
        if (injectedStaleCheckpoint) {
          // The stale checkpoint fails validation before any request is sent,
          // stays unsaved, and blocks later messages the same way.
          expect(recoveryScreen).not.toContain("RECOVERY_SAVED_TURN_67e");
          expect(gateway.requestCount()).toBe(requestsBeforeResume);
          await resumed.sendText("go on");
          const blockedScreen = await resumed.waitForPane((pane) =>
            pane.split("InvalidContextHistoryStart").length > 2, 10_000);
          expect(blockedScreen).not.toContain("DuplicateImageId");
          expect(gateway.requestCount()).toBe(requestsBeforeResume);
          expect(existsSync(recoveryPath)).toBe(true);
          expect(savedFrames(eventsPath).filter((frame) => frame.event?.turn_completed).length).toBe(completedAtKill);
        } else {
          expect(recoveryScreen).toContain("RECOVERY_SAVED_TURN_67e");
          expect(recoveryScreen).not.toContain("InvalidContextHistoryStart");
          const resumeRequest = gateway.requests.at(-1)?.body ?? "";
          expect(resumeRequest).toContain("STEER_LATE_67e");
          expect(resumeRequest).toContain('"type":"file"');
          phase = "followup";
          const requestsBeforeFollowup = gateway.requestCount();
          await resumed.sendText("RECOVERY_FOLLOWUP_REQUEST_67e");
          const finalScreen = await resumed.waitForPane((pane) => pane.includes("RECOVERY_FOLLOWUP_67e"), 15_000);
          expect(finalScreen).not.toContain("InvalidContextHistoryStart");
          expect(finalScreen).not.toContain("DuplicateImageId");
          await until(() => savedFrames(eventsPath).filter((frame) => frame.event?.turn_completed).length === completedAtKill + 2,
            "saved recovered and follow-up turns", 10_000);
          expect(gateway.requestCount()).toBe(requestsBeforeFollowup + 1);
          expect(existsSync(recoveryPath)).toBe(false);
        }
        const imageIds = savedFrames(eventsPath).flatMap((frame) =>
          frame.event?.user?.images?.map((image: { id: number }) => image.id) ?? []);
        expect(new Set(imageIds).size).toBe(imageIds.length);
        expect(readFileSync(activeStderr, "utf8")).toBe("");
        expect(readFileSync(resumedStderr, "utf8")).toBe("");
        passed = true;
      } finally {
        if (!passed) {
          writeFileSync(join(root, "failure.json"), JSON.stringify({ ordinary, summaries, phase }, null, 2));
          if (resumed) writeFileSync(join(root, "failure.scrollback.txt"), await resumed.captureFullScrollback());
          console.error(`compaction recovery evidence retained: ${root}`);
        }
        await active?.kill();
        await resumed?.kill();
        summaryHold.dispose();
        gateway.stop();
        if (passed) rmSync(root, { recursive: true, force: true });
      }
    }, 90_000);
  }
});
