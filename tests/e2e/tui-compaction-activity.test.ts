import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { traceReportNames, waitForNewTraceReport } from "./trace-report";
import { logLines, onlySessionId, savedSession, savedText, savedToolCallIds, sessionDir } from "./saved-sessions";
import { bearer, rotateFxLogin, startFakeIssuer, writeFxLogin } from "./fx-login-fakes";

// The shared tmux helper imports eval helpers; do not load repository dotenv files.
process.env.FX_E2E_DISABLE_DOTENV = "1";
const {
  FAKE_GATEWAY_MODEL, TmuxSession, fakeGatewayFinalText, fakeGatewaySse, fakeGatewayToolCall,
  fakeShellRun, heldFakeGatewayFinalText, startDynamicFakeGateway,
  hasEmptyComposer, tmuxAvailable,
  turnSettled,
} = await import("./tmux-helpers");
const { HAS_API_KEY } = await import("../evals/eval-helpers");

const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const HEAD = "HISTORY_HEAD_29b7";
const TAIL = "HISTORY_TAIL_16d3";
// A fact entry, which the compacted conversation keeps whatever the turn
// numbers.
const HANDOFF = `Facts:\nF1: INTERNAL_HANDOFF_4e12: preserve ${HEAD} and ${TAIL}; follow the latest user request.`;
const FOLLOWUP = "FOLLOWUP_OK_732c";
const REOPEN = "REOPEN_OK_492a";
const ACTIVITY = /Compacting \d+% \((?:\d+h)?(?:\d+m)?\d+s\)/;
// The share of the summary written, then the compaction row's own clock.
const COMPACTION_CLOCK = /Compacting (\d+)% \(((?:\d+h)?(?:\d+m)?\d+s)\)/;
const TURN_CLOCK = /Thinking \(((?:\d+h)?(?:\d+m)?\d+s)\)/;
function clockSeconds(clock: string): number {
  const [, hours, minutes, seconds] = /^(?:(\d+)h)?(?:(\d+)m)?(\d+)s$/.exec(clock)!;
  return Number(hours ?? 0) * 3600 + Number(minutes ?? 0) * 60 + Number(seconds);
}
// The summary line a finished turn leaves after it, such as `  12s (↑34 ↓433)`.
const TURN_SUMMARY_LINE = /^  (\d+s|\d+m \d+s|\d+h \d{2}m)(?: \(↑[^\n]*\))?$/m;
/// The seconds on the summary line of the turn whose prompt holds `prompt`,
/// or null before that turn has finished.
function turnSummarySeconds(pane: string, prompt: string): number | null {
  const at = pane.lastIndexOf(prompt);
  if (at < 0) return null;
  const line = TURN_SUMMARY_LINE.exec(pane.slice(at));
  if (!line) return null;
  const [, hours, minutes, seconds] = /^(?:(\d+)h)?(?: ?(\d+)m)?(?: ?(\d+)s)?$/.exec(line[1]!)!;
  return Number(hours ?? 0) * 3600 + Number(minutes ?? 0) * 60 + Number(seconds ?? 0);
}
const COMPACTION_OUTPUT = /Compacting|compaction|Context compacted|No context to compact|Synthetic summary rejection|INTERNAL_HANDOFF_4e12/i;
// The line a successful compaction leaves in the transcript, with the time
// its row showed last.
const COMPACTED_LINE = /Context compacted \(((?:\d+h)?(?:\d+m)?\d+s)\)/g;
function compactedSeconds(text: string): number[] {
  return [...text.matchAll(COMPACTED_LINE)].map((match) => clockSeconds(match[1]!));
}
function withoutCompactedLines(text: string): string {
  return text.replace(COMPACTED_LINE, "");
}
// Ctrl+O gives each compaction's model call its own line, as for every call;
// nothing else there may speak of compaction.
const COMPACTION_CALL_LINE = /^  (?:[A-Z][a-z]{2} \d{1,2} )?\d{2}:\d{2}:\d{2} · [^\n]* \(compaction\)$/gm;
function withoutCompactionCallLines(full: string): string {
  return full.replace(COMPACTION_CALL_LINE, "");
}

type Trigger = "manual" | "auto" | "overflow" | "ordinary";
type Outcome = "success" | "cancel" | "empty" | "provider-error";

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

/// A session log's conversation: what a close or a reopen leaves as it was,
/// since the store adds only its own `closed` and `snapshot` lines then.
function conversationLines(text: string): string[] {
  return text.split("\n").filter(Boolean).filter((line) => !["closed", "snapshot"].includes(JSON.parse(line).kind));
}

/// The compactions a session log holds.
function checkpoints(bytes: Buffer): number {
  return bytes.toString().trim().split("\n").filter(Boolean)
    .map((line) => JSON.parse(line)).filter((line) => line.kind === "compacted").length;
}

async function until(predicate: () => boolean, label: string, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await Bun.sleep(20);
  }
}

async function fixture(trigger: Trigger, outcome: Outcome = "success", longResume = false, overflowDelayMs = 0) {
  // Ctrl+O includes the recording path; keep it free of forbidden notice words.
  const root = mkdtempSync(join(tmpdir(), "fx-activity-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(workspace, "seed-notes.txt"), "seed notes\n");
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    model: FAKE_GATEWAY_MODEL, auto_upgrade: false,
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
    // Each seed turn reads a note before replying, so compaction has work to
    // summarize. That extra request is not counted as ordinary.
    const seedRead = `seed-read-${ordinary + 1}`;
    if (phase === "seed" && !raw.includes(`"${seedRead}"`)) return fakeGatewayToolCall(seedRead, "read_file", { path: "seed-notes.txt" });
    ordinary++;
    if (phase === "seed") return fakeGatewayFinalText(seedReply(ordinary));
    if (phase === "attempt") {
      if (trigger === "overflow" && !overflowSent) {
        overflowSent = true;
        const overflow = Response.json({ error: {
          type: "invalid_request_error", code: "context_length_exceeded",
          message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
        } }, { status: 400 });
        return overflowDelayMs > 0 ? Bun.sleep(overflowDelayMs).then(() => overflow) : overflow;
      }
      return ordinaryHold.response;
    }
    return fakeGatewayFinalText(phase === "reopen" ? REOPEN : FOLLOWUP);
  }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-compaction-key",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_SKIP_WORKSPACE_TRUST: "1",
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  let sessionId = "";
  let eventsPath = "";
  let initial = Buffer.alloc(0);
  let launchIndex = 0;
  const stderrPaths: string[] = [];
  const tapes: string[] = [];
  async function cli(args: string[], expectedStderr = "") {
    const child = Bun.spawn([binary, ...args], { cwd: workspace, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    const timer = setTimeout(() => child.kill(), 30_000);
    try {
      const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      expect(code).toBe(0);
      expect(stderr).toBe(expectedStderr);
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
      const reply = await cli(["ask", "--json", "--auto", ...(sessionId ? ["--resume", sessionId] : []), `Seed ordinary historical turn ${turn}.`], "Reading seed-notes.txt\n");
      if (sessionId) expect(reply.session_id).toBe(sessionId);
      else sessionId = reply.session_id;
      expect(sessionId).toBeTruthy();
      expect(ordinary).toBe(turn);
      expect(summaries).toBe(0);
    }
    eventsPath = join(sessionDir(home, sessionId), "log.jsonl");
    initial = readFileSync(eventsPath);
    // A large read's body is one of the session's blobs (D44).
    expect(savedText(home, sessionId)).toContain(HEAD);
    expect(savedText(home, sessionId)).toContain(TAIL);
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

/// Compaction leaves nothing in the transcript but one `Context compacted`
/// line for each compaction that succeeded on this screen.
async function assertCompactionQuiet(terminal: InstanceType<typeof TmuxSession>, root: string, label: string, compacted = 0) {
  const inline = await terminal.captureFullScrollbackEscapes();
  writeFileSync(join(root, `${label}.scrollback.ansi`), inline);
  expect(inline.length).toBeGreaterThan(0);
  expect(compactedSeconds(inline)).toHaveLength(compacted);
  expect(withoutCompactedLines(inline)).not.toMatch(COMPACTION_OUTPUT);
  await terminal.sendKeys("C-o");
  await terminal.waitForText("esc close · pgup/pgdn scroll", 5000);
  await terminal.sendKeys("End");
  const full = await terminal.waitForPane((pane) => pane.includes("esc close · pgup/pgdn scroll"), 5000);
  writeFileSync(join(root, `${label}.full-transcript.txt`), full);
  // The full transcript shows one page, which may not reach the line.
  expect(compactedSeconds(full).length).toBeLessThanOrEqual(compacted);
  expect(withoutCompactedLines(withoutCompactionCallLines(full))).not.toMatch(COMPACTION_OUTPUT);
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
    expect(rows[0]).not.toMatch(/[↑↓]|tokens|chunk/i);
    markers.add(rows[0].includes("•"));
    return markers.size === 2 && !rows[0].includes(clock);
  }, 5000);
  expect(later.match(/Compacting/g)).toHaveLength(1);
}

/// One turn reads a.txt, b.txt and c.txt, and a compaction between the first
/// read and the second summarizes the first: `auto` before the next request,
/// `overflow` after the provider refuses it for its size. The session still
/// saves the first read (D87), so a reopened transcript and Ctrl+O show the
/// turn as it ran, while the model never gets a.txt back: not on the next
/// turn, and not after the reopen.
async function foldedReadAfterReopen(trigger: "auto" | "overflow") {
  const root = mkdtempSync(join(tmpdir(), `fx-folded-read-${trigger}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(workspace, "seed-notes.txt"), "seed notes\n");
  // One-letter words count as a token each, so a.txt's preview pushes the
  // turn's next request past 10% of the window, which the first stays under.
  const FOLDED = "FOLDED_READ_5c2e";
  const letters = "a b c d e f g h i j k l m n o p q r s t";
  writeFileSync(join(workspace, "a.txt"), `${FOLDED} ${letters}\n${`${letters}\n`.repeat(999)}`);
  writeFileSync(join(workspace, "b.txt"), "bravo\n");
  writeFileSync(join(workspace, "c.txt"), "charlie\n");
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    model: FAKE_GATEWAY_MODEL, auto_upgrade: false,
    ...(trigger === "auto" ? { auto_compact_percent: 10 } : {}),
  }));
  const PROMPT = "Read the three files.";
  const DONE = "FOLDED_TURN_DONE_7c1a";
  const handoff = "Facts:\nF1: FOLDED_HANDOFF_51aa: the user asked to read three files.";
  let phase: "seed" | "turn" | "next" | "reopen" = "seed";
  let turnSteps = 0;
  const bodies: { phase: typeof phase; summary: boolean; body: string }[] = [];
  const gateway = startDynamicFakeGateway((raw) => {
    const request = JSON.parse(raw);
    // A summary request can keep the conversation's tools for the cache, so
    // its instruction marks it too.
    const summary = (request.toolChoice?.type === "none" && request.tools?.length === 0) ||
      raw.includes("Write the compaction notes") || raw.includes("Your notes on the turns above left some out");
    bodies.push({ phase, summary, body: raw });
    if (summary) return fakeGatewayFinalText(handoff);
    if (phase === "seed") {
      if (!raw.includes('"seed-read"')) return fakeGatewayToolCall("seed-read", "read_file", { path: "seed-notes.txt" });
      // No usage, which would scale fx's later size estimates.
      return fakeGatewaySse([
        { type: "text-delta", id: "answer_1", delta: `${"history alpha beta gamma delta sample line\n".repeat(40)}SEED_DONE` },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ]);
    }
    if (phase === "next") return fakeGatewayFinalText("NEXT_OK");
    if (phase === "reopen") return fakeGatewayFinalText(REOPEN);
    turnSteps++;
    const steps: Array<() => Response> = [
      () => fakeGatewayToolCall("read_a", "read_file", { path: "a.txt", line_count: 1000 }),
      ...(trigger === "overflow" ? [() => Response.json({ error: {
        type: "invalid_request_error", code: "context_length_exceeded",
        message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
      } }, { status: 400 })] : []),
      () => fakeGatewayToolCall("read_b", "read_file", { path: "b.txt" }),
      () => fakeGatewayToolCall("read_c", "read_file", { path: "c.txt" }),
    ];
    return steps[turnSteps - 1]?.() ?? fakeGatewayFinalText(DONE);
  }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 67_000 + 8192, max_tokens: 8192 }] });
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-compaction-key",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_SKIP_WORKSPACE_TRUST: "1",
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  let terminal: InstanceType<typeof TmuxSession> | undefined;
  const stderrPaths: string[] = [];
  async function launch(resume: string | null) {
    const stderrPath = join(root, `terminal-${stderrPaths.length + 1}.stderr`);
    stderrPaths.push(stderrPath);
    const command = `/usr/bin/env -i ${Object.entries(env).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)}${resume ? ` --resume ${shellQuote(resume)}` : ""}`;
    terminal = await TmuxSession.create({
      cmd: command, cwd: workspace, env: { HOME: home, FX_SOUND: "0" }, isolated: true,
      stderrPath, width: 100, height: 40, startupWaitMs: 0,
    });
    await terminal.waitForStableComposer(20_000);
    return terminal;
  }
  async function quit() {
    await terminal!.sendText("/quit");
    expect(await terminal!.waitForSessionEnd(10_000)).toBe(true);
    await terminal!.kill();
    terminal = undefined;
  }
  const finished = (pane: string, marker: string) => pane.includes(marker) && hasEmptyComposer(pane) && turnSettled(pane);
  const turnRows = (pane: string) => pane.slice(pane.lastIndexOf(`┃ ${PROMPT}`));
  let passed = false;
  try {
    const live = await launch(null);
    await live.sendText("Seed one turn.");
    await live.waitForPane((pane) => finished(pane, "SEED_DONE") && /^  (?:[^\n]* · )?\d+s(?: \(↑[^\n]*\))?$/m.test(pane), 20_000);
    phase = "turn";
    await live.sendText(PROMPT);
    const liveRows = turnRows(await live.waitForPane((pane) => finished(pane, DONE) && /Explored \d files/.test(pane), 30_000));
    expect(bodies.some((entry) => entry.phase === "turn" && entry.summary)).toBe(true);
    // Live, the compaction's row splits the reads in two. fx saves no such
    // row, so after reopen the reads are one row.
    const liveAt = (row: string) => liveRows.indexOf(row);
    expect(liveAt("● Read a.txt L1-1000")).toBeGreaterThanOrEqual(0);
    expect(liveAt("✓ Context compacted (")).toBeGreaterThan(liveAt("● Read a.txt L1-1000"));
    expect(liveAt("● Read b.txt, c.txt")).toBeGreaterThan(liveAt("✓ Context compacted ("));
    expect(liveRows).toContain("Explored 3 files");
    phase = "next";
    await live.sendText("Next live turn.");
    await live.waitForPane((pane) => finished(pane, "NEXT_OK"), 20_000);
    await quit();

    const id = onlySessionId(home);
    const reopened = await launch(id);
    const reopenedRows = turnRows(await reopened.waitForPane((pane) => pane.includes(DONE) && hasEmptyComposer(pane), 20_000));
    expect(reopenedRows).toContain("● Read a.txt, b.txt, c.txt");
    expect(reopenedRows).toContain("Explored 3 files");
    // Ctrl+O shows a.txt's read too, pages above its end.
    await reopened.sendKeys("C-o");
    let page = await reopened.waitForText("esc close · pgup/pgdn scroll", 5000);
    const pages = [page];
    while (!page.includes(`┃ ${PROMPT}`) && pages.length < 40) {
      await reopened.sendKeys("PageUp");
      const before = page;
      page = await reopened.waitForPane((pane) => pane !== before, 5000);
      pages.push(page);
    }
    const full = pages.join("\n");
    expect(full).toContain("● Read a.txt");
    expect(full).toContain(FOLDED);
    await reopened.sendKeys("Escape");
    await reopened.waitForComposer(5000);
    phase = "reopen";
    await reopened.sendText("Continue after reopening.");
    await reopened.waitForPane((pane) => finished(pane, REOPEN), 20_000);
    await quit();
    // The log holds the turn once, whole, as `fx session` shows it.
    logLines(home, id);
    expect(savedToolCallIds((await savedSession(home, id)).history)).toEqual(["seed-read", "read_a", "read_b", "read_c"]);

    // The summary stands in for a.txt in every request after the compaction.
    const after = bodies.filter((entry) => entry.phase === "next" || entry.phase === "reopen");
    expect(after.length).toBeGreaterThanOrEqual(2);
    for (const entry of after) expect(entry.body.includes(FOLDED)).toBe(false);
    for (const path of stderrPaths) expect(readFileSync(path, "utf8")).toBe("");
    passed = true;
  } finally {
    if (!passed) {
      if (terminal) writeFileSync(join(root, "failure.pane.txt"), await terminal.capturePane());
      console.error(`folded read evidence retained: ${root}; phase=${phase}`);
    }
    await terminal?.kill();
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
  }
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
          await terminal.waitForText("esc close · pgup/pgdn scroll", 5000);
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
          await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && hasEmptyComposer(pane) && compactedSeconds(pane).length === 1, 10_000);
          expect(f.counts().ordinary).toBe(f.seedTurns);
          // The reply holds only facts, so fx asks once more for the notes
          // of the turn that did work.
          expect(f.counts().summaries).toBe(2);
        } else {
          await until(() => f.counts().ordinary === f.seedTurns + (trigger === "overflow" ? 2 : 1), "ordinary request after compaction");
          const pane = await terminal.waitForText(/Thinking \(/, 10_000);
          expect(pane).not.toMatch(ACTIVITY);
          expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
          f.ordinaryHold.release("CURRENT_TURN_OK_f713");
          await f.waitForResumeHandoff();
          await terminal.waitForPane((pane) => pane.includes("CURRENT_TURN_OK_f713") && hasEmptyComposer(pane) && turnSettled(pane), 10_000);
        }
        expect(f.counts().overflowSent).toBe(trigger === "overflow");
        expect(f.durable()).toBe(1);
        const before = f.counts();
        f.phase("followup");
        await terminal.sendText("Follow the latest request.");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane) && turnSettled(pane), 10_000);
        expect(f.counts()).toEqual({ ...before, ordinary: before.ordinary + 1 });
        expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
        await assertCompactionQuiet(terminal, f.root, "completed", 1);
        await f.close();
        f.phase("reopen");
        const reopened = await f.launch();
        await reopened.sendText("Continue after reopening.");
        await f.waitForResumeHandoff();
        await reopened.waitForPane((pane) => pane.includes(REOPEN) && hasEmptyComposer(pane), 10_000);
        expect(f.counts()).toEqual({ ...before, ordinary: before.ordinary + 2 });
        expect(f.durable()).toBe(1);
        expect(f.lastRequest()).toContain("INTERNAL_HANDOFF_4e12");
        // The line is not saved, so the reopened session does not show it.
        await assertCompactionQuiet(reopened, f.root, "reopened");
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

  test("manual: the row moves while the model reads, then counts the summary as it is written", async () => {
    const f = await fixture("manual", "success");
    let passed = false;
    try {
      const terminal = await f.launch();
      await terminal.sendText("/compact");
      await until(() => f.counts().summaries === 1, "first summary request");
      const seen: number[] = [];
      const record = (pane: string) => {
        const rows = pane.split("\n").filter((line) => COMPACTION_CLOCK.test(line));
        if (rows.length === 0) return null;
        expect(rows).toHaveLength(1);
        const value = Number(COMPACTION_CLOCK.exec(rows[0]!)![1]);
        seen.push(value);
        return value;
      };
      // The reply is held, so nothing of the summary has arrived. The row
      // moves all the same: the request earns a share of the row for its wait.
      await terminal.waitForPane((pane) => (record(pane) ?? 0) >= 2, 15_000);
      const waited = seen.at(-1)!;
      // A wait earns less than half of the row.
      expect(waited).toBeLessThan(50);
      // Two of the five sections arrive; the rest is held. They are a third
      // of the notes, far more than a wait of this length can earn.
      f.summaryHold.send("Rules:\nnone\n\nDecisions:\nnone\n\n");
      const counted = await terminal.waitForPane((pane) => (record(pane) ?? 0) >= waited + 20, 10_000);
      const count = seen.at(-1)!;
      expect(count).toBeLessThan(100);
      // Once its notes arrive, only notes move the row: its clock runs on
      // for three seconds and the count holds.
      const since = clockSeconds(COMPACTION_CLOCK.exec(counted)![2]!);
      await terminal.waitForPane((pane) => {
        const row = COMPACTION_CLOCK.exec(pane);
        if (row === null) return false;
        expect(record(pane)).toBe(count);
        return clockSeconds(row[2]!) >= since + 3;
      }, 15_000);
      f.summaryHold.release(HANDOFF);
      await until(() => f.durable() > 0, "acknowledged checkpoint");
      await terminal.waitForPane((pane) => {
        record(pane);
        return !ACTIVITY.test(pane) && hasEmptyComposer(pane) && compactedSeconds(pane).length === 1;
      }, 10_000);
      // The percentage only goes up.
      for (let i = 1; i < seen.length; i++) expect(seen[i]!).toBeGreaterThanOrEqual(seen[i - 1]!);
      expect(seen.some((value) => value > 0 && value < 100)).toBe(true);
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 120_000);

  test("manual: a summary stream that breaks midway keeps its count while another model finishes", async () => {
    const f = await fixture("manual", "success");
    let passed = false;
    try {
      const terminal = await f.launch();
      await terminal.sendText("/compact");
      await until(() => f.counts().summaries === 1, "first summary request");
      const seen: number[] = [];
      const record = (pane: string) => {
        const row = COMPACTION_CLOCK.exec(pane);
        if (row) seen.push(Number(row[1]));
        return row ? Number(row[1]) : null;
      };
      // The row is up while the reply is held.
      await terminal.waitForPane((pane) => record(pane) !== null, 10_000);
      f.summaryHold.send("Rules:\nnone\n\nDecisions:\nnone\n\n");
      // The two sections are counted: a wait this short earns far less.
      await terminal.waitForPane((pane) => (record(pane) ?? 0) >= 20, 10_000);
      const before = seen.at(-1)!;
      // The stream ends before the reply is finished; fx asks another model.
      f.summaryHold.dispose();
      await until(() => f.counts().summaries >= 2, "a second summary request");
      await until(() => f.durable() > 0, "acknowledged checkpoint");
      await terminal.waitForPane((pane) => {
        record(pane);
        return !ACTIVITY.test(pane) && hasEmptyComposer(pane) && compactedSeconds(pane).length === 1;
      }, 10_000);
      for (let i = 1; i < seen.length; i++) expect(seen[i]!).toBeGreaterThanOrEqual(seen[i - 1]!);
      expect(Math.min(...seen.slice(seen.indexOf(before)))).toBeGreaterThanOrEqual(before);
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 120_000);

  test("overflow: compaction counts its own time from zero with its count, and the turn clock goes on from where it stopped", async () => {
    // The turn's first request answers with the overflow only after 3 s, so
    // the turn clock is past zero when compaction starts.
    const f = await fixture("overflow", "success", false, 3000);
    let passed = false;
    try {
      const terminal = await f.launch();
      await terminal.sendText("Continue the current turn.");
      let before = -1;
      const started = await terminal.waitForPane((pane) => {
        const turn = TURN_CLOCK.exec(pane);
        if (turn) before = Math.max(before, clockSeconds(turn[1]!));
        return COMPACTION_CLOCK.test(pane);
      }, 15_000);
      expect(before).toBeGreaterThanOrEqual(2);
      expect(clockSeconds(COMPACTION_CLOCK.exec(started)![2]!)).toBeLessThanOrEqual(1);
      // The summary is held, so the row's count stays below 100% while its
      // own clock runs well past what the turn showed.
      let most = 0;
      await terminal.waitForPane((pane) => {
        const row = COMPACTION_CLOCK.exec(pane);
        if (row) most = Math.max(most, clockSeconds(row[2]!));
        return row !== null && Number(row[1]) < 100 && clockSeconds(row[2]!) >= 6;
      }, 15_000);
      f.summaryHold.release(HANDOFF);
      await until(() => f.durable() > 0, "acknowledged checkpoint");
      const resumed = await terminal.waitForText(TURN_CLOCK, 10_000);
      expect(resumed).not.toMatch(COMPACTION_CLOCK);
      // The turn goes on from the second compaction started in, plus at most
      // the second the release took; the 6 s or more of compaction are not in it.
      const after = clockSeconds(TURN_CLOCK.exec(resumed)![1]!);
      expect(after).toBeGreaterThanOrEqual(before);
      expect(after).toBeLessThanOrEqual(before + 2);
      f.ordinaryHold.release("CURRENT_TURN_OK_f713");
      const finished = await terminal.waitForPane((pane) =>
        pane.includes("CURRENT_TURN_OK_f713") && hasEmptyComposer(pane) && turnSummarySeconds(pane, "Continue the current turn.") !== null, 10_000);
      // The finished turn's duration leaves out the compaction too: about
      // what its clock showed, not that plus the 6 s of compaction.
      const total = turnSummarySeconds(finished, "Continue the current turn.")!;
      expect(total).toBeGreaterThanOrEqual(after - 1);
      expect(total).toBeLessThanOrEqual(after + 2);
      // The compaction leaves one line with the time its row showed last,
      // plus at most the moments the release and the save took.
      expect(finished).toContain("✓ Context compacted (");
      const lines = compactedSeconds(finished);
      expect(lines).toHaveLength(1);
      expect(lines[0]).toBeGreaterThanOrEqual(most);
      expect(lines[0]).toBeLessThanOrEqual(most + 2);
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 90_000);

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
      await terminal.waitForPane((pane) => pane.includes("CURRENT_TURN_OK_OVERFLOW_STEER") && hasEmptyComposer(pane) && turnSettled(pane), 20_000);
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
        // A failed or empty summary is retried once on the fallback model.
        expect(f.counts().summaries).toBe(outcome === "cancel" ? 1 : 2);
        const afterFailure = f.counts();
        if (outcome === "cancel") f.summaryHold.dispose();
        await terminal.sendKeys("Escape");
        await terminal.waitForPane((pane) => !/compact/i.test(pane) && hasEmptyComposer(pane), 5000);
        await assertCompactionQuiet(terminal, f.root, "failed");
        f.phase("followup");
        await terminal.sendText("Recover with another request.");
        await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane) && turnSettled(pane), 10_000);
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
        await assertCompactionQuiet(reopened, f.root, "failed-reopen");
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
          .map((line) => JSON.parse(line)).filter((line) => line.kind === "item" && line.type === "interruption");
        await until(() => interruptions().length === 1, "durable cancellation", 5000);
        expect(interruptions()[0].data.reason).toBe("cancelled");
        // An ordinary cancellation leaves its origin out, which reads as "turn".
        expect((interruptions()[0].data.cancellation_origin ?? "turn") === "compaction").toBe(trigger === "auto");
        const cancelledCounts = { summaries: trigger === "auto" ? 1 : 0,
          ordinary: f.seedTurns + (trigger === "ordinary" ? 1 : 0), overflowSent: false };
        expect(f.counts()).toEqual(cancelledCounts);
        expect(f.durable()).toBe(0);
        const cancelledEvents = f.savedEvents();
        await f.close();
        expect(f.counts()).toEqual(cancelledCounts);
        expect(f.savedEvents().startsWith(cancelledEvents)).toBe(true);
        expect(conversationLines(f.savedEvents())).toEqual(conversationLines(cancelledEvents));

        const reopened = await f.launch();
        await reopened.sendKeys("C-o");
        await reopened.waitForText("esc close · pgup/pgdn scroll", 5000);
        await reopened.sendKeys("End");
        const full = await reopened.waitForPane((pane) => pane.includes("Cancel this held response."), 5000);
        writeFileSync(join(f.root, "cancellation-reopened.txt"), full);
        expect(full.includes("Cancelled")).toBe(trigger === "ordinary");
        expect(withoutCompactionCallLines(full)).not.toMatch(COMPACTION_OUTPUT);
        await reopened.sendKeys("C-o");
        await reopened.waitForComposer(5000);
        expect(await reopened.captureFullScrollbackEscapes()).not.toMatch(COMPACTION_OUTPUT);
        await f.close();
        expect(f.counts()).toEqual(cancelledCounts);
        expect(f.savedEvents().startsWith(cancelledEvents)).toBe(true);
        expect(conversationLines(f.savedEvents())).toEqual(conversationLines(cancelledEvents));
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

  for (const trigger of ["auto", "overflow"] as const) {
    test(`${trigger}: a read the compaction inside its turn summarized still shows after reopen, and the model never gets it back`, async () => {
      await foldedReadAfterReopen(trigger);
    }, 120_000);
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

      const before = new Set(traceReportNames(f.root));
      await terminal.sendText("/trace");
      const report = await waitForNewTraceReport(f.root, before);

      // No FX_TRACE_LOG was configured, so the opt-in trace log tail is absent
      // while the always-on compaction records still carry the full story.
      expect(report.all("trace_log")).toEqual([]);
      const compaction = report.one("compaction");
      expect(compaction.failed).toBeGreaterThan(0);
      const events = report.all("compaction_event");
      expect(events).toHaveLength(Number(compaction.retained));
      const names = events.map((event) => event.event);
      for (const name of ["summary_transport_failed", "transaction_failed", "provider_start", "provider_completed", "committed"]) {
        expect(names).toContain(name);
      }
      // Provider error text is secret-masked before it reaches the report.
      expect(events.some((event) => String(event.detail ?? "").includes("[redacted]"))).toBe(true);
      expect(report.text).not.toContain("abcdef0123456789xyz");
      expect(report.problems("compaction").length).toBeGreaterThan(0);
      // The failures are also kept apart from the event window, so later
      // events never push them out of the trace or its problems.
      const kept = report.all("failed_compaction_event");
      expect(kept.length).toBeGreaterThan(0);
      expect(compaction.kept_failures).toBe(kept.length);
      expect(compaction.session_failures).toBeGreaterThanOrEqual(kept.length);
      const keptNames = kept.map((event) => event.event);
      expect(keptNames).toContain("summary_transport_failed");
      expect(keptNames).toContain("transaction_failed");
      expect(kept.every((event) => event.failed === true)).toBe(true);
      expect(report.problems("compaction").map((problem) => problem.event)).toContain("transaction_failed");
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
        await terminal.waitForText("esc close · pgup/pgdn scroll", 5000);
        await terminal.sendKeys("End");
        const pane = await terminal.waitForPane((text) => text.includes("esc close · pgup/pgdn scroll") && text.includes(authMessage), 5000);
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
      await assertCompactionQuiet(terminal, f.root, "control");
      await f.close();
      passed = true;
    } finally { await f.cleanup(passed); }
  }, 60_000);

  test("auto: steering sent during a turn stays user text through compaction", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-compaction-steering-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
      model: FAKE_GATEWAY_MODEL, auto_upgrade: false,
    }));
    for (let n = 1; n <= 30; n++) {
      writeFileSync(join(workspace, `probe-${n}.txt`), `STEER_PROBE_${n}_8d4 context pressure line\n`.repeat(250));
    }
    const task = "STEER_TASK_8d4: read the probe files and report progress.";
    // Longer than the excerpt compaction used for generated notices.
    const steering = "STEER_RULE_8d4: prefix every progress line with S1>. " +
      "Keep all of this correction. ".repeat(80) + "STEER_END_8d4";
    const ordinaryBodies: string[] = [];
    const summaryBodies: string[] = [];
    const gateway = startDynamicFakeGateway((raw) => {
      const request = JSON.parse(raw);
      if (request.toolChoice?.type === "none" && request.tools?.length === 0) {
        summaryBodies.push(raw);
        return fakeGatewayFinalText("STEER_SUMMARY_8d4: the probe files are being read.");
      }
      ordinaryBodies.push(raw);
      const n = ordinaryBodies.length;
      if (summaryBodies.length > 0) return fakeGatewayFinalText("STEER_DONE_8d4");
      if (n === 1) return fakeShellRun("steer-window-8d4", "printf STEER_WINDOW_8d4; sleep 3");
      if (n <= 31) return fakeGatewayToolCall(`steer-probe-${n - 1}-8d4`, "read_file", { path: `probe-${n - 1}.txt` });
      return fakeGatewayFinalText("STEER_NOT_COMPACTED_8d4");
    }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 60000, max_tokens: 4096 }] });
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
      TERM: "xterm-256color", AI_GATEWAY_API_KEY: "fake-compaction-key",
      FX_DISABLE_KEYCHAIN: "1", FX_TEST_SKIP_ONBOARDING: "1", FX_E2E_DISABLE_DOTENV: "1",
      FX_TEST_SKIP_WORKSPACE_TRUST: "1",
      FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_PERMISSION_MODE: "full-access",
      FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    };
    const command = `/usr/bin/env -i ${Object.entries(env)
      .map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)}`;
    let terminal: InstanceType<typeof TmuxSession> | undefined;
    let passed = false;
    try {
      terminal = await TmuxSession.create({
        cmd: command, cwd: workspace, env, isolated: true, remainOnExit: true,
        stderrPath, width: 120, height: 40, startupWaitMs: 0,
      });
      await terminal.waitForStableComposer(15_000);
      await terminal.sendText(task);
      // The command's row shows its steps in short form while it runs.
      await terminal.waitForText("Running printf, sleep", 15_000);
      await terminal.sendText(steering);
      await until(() => summaryBodies.length === 1, "automatic compaction", 60_000);
      await terminal.waitForText("STEER_DONE_8d4", 20_000);

      const steered = ordinaryBodies.filter((body) => body.includes("STEER_RULE_8d4"));
      expect(steered.length).toBeGreaterThan(1);
      expect(steered[0]).toContain("<user_steering>");

      const source = JSON.parse(summaryBodies[0]!).prompt
        .filter((message: { role: string }) => message.role === "user")
        .map((message: { content: { text?: string }[] }) => message.content.map((part) => part.text ?? "").join(""))
        .join("\n");
      const at = source.indexOf("STEER_RULE_8d4");
      expect(at).toBeGreaterThan(-1);
      // Steering is the user's own message, labeled as added during the turn.
      const header = source.slice(source.lastIndexOf("[", at), at);
      expect(header).toBe("[User, added while the assistant worked]\n");
      expect(source).toContain(steering);
      // The task stays the live request, so the summarizer sees it only as context.
      expect(source).toContain(`[Turn in progress]\n[User, this message stays in the conversation after the summary]\n${task}`);

      const log = join(sessionDir(home, onlySessionId(home)), "log.jsonl");
      await until(() => readFileSync(log, "utf8").includes("\"turn_committed\""), "saved turn", 10_000);
      const handoff = readFileSync(log, "utf8").trim().split("\n")
        .map((line) => JSON.parse(line)).find((line) => line.kind === "compacted")?.data.summary ?? "";
      expect(handoff.startsWith("fx-compactor-v1\n")).toBe(true);
      const state = JSON.parse(handoff.slice("fx-compactor-v1\n".length));
      // Only the turn in progress was compacted; its steering is kept exactly.
      expect(state.turns).toEqual([]);
      expect(state.open.users).toEqual([steering]);
      expect(state.tool_count).toBeGreaterThan(0);
      expect(state.open.first_tool).toBe(1);

      const afterCompaction = ordinaryBodies.at(-1)!;
      expect(afterCompaction).toContain("<compacted_conversation>");
      expect(afterCompaction).toContain("STEER_END_8d4");
      expect(afterCompaction.split("STEER_TASK_8d4").length - 1).toBe(1);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (!passed) {
        writeFileSync(join(root, "failure.json"), JSON.stringify({ ordinary: ordinaryBodies.length, summaries: summaryBodies.length }, null, 2));
        if (terminal) writeFileSync(join(root, "failure.scrollback.txt"), await terminal.captureFullScrollback());
        console.error(`compaction steering evidence retained: ${root}`);
      }
      await terminal?.kill();
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
    }
  }, 90_000);

  test("manual: Ctrl+O after the turn across a compaction opens without reading the session log", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-compaction-ctrlo-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    const stderrPath = join(root, "stderr");
    const tracePath = join(root, "trace.log");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
      model: FAKE_GATEWAY_MODEL, auto_upgrade: false,
    }));
    const answers = [
      "CTRLO_OLDER_FIRST_5c1",
      "CTRLO_OLDER_SECOND_5c1",
      Array.from({ length: 40 }, (_, i) => `CTRLO_OLDER_ROW_${i + 1}_5c1`).join("\n\n"),
      "CTRLO_AFTER_COMPACTION_5c1",
    ];
    let turns = 0;
    const gateway = startDynamicFakeGateway((raw) => {
      const request = JSON.parse(raw);
      if (request.toolChoice?.type === "none" && request.tools?.length === 0) {
        return fakeGatewayFinalText("Facts:\nF1: CTRLO_SUMMARY_5c1: earlier turns.");
      }
      turns += 1;
      return fakeGatewayFinalText(answers[Math.min(turns, answers.length) - 1]!);
    });
    const env: Record<string, string> = {
      PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
      TERM: "xterm-256color", AI_GATEWAY_API_KEY: "fake-compaction-key",
      FX_DISABLE_KEYCHAIN: "1", FX_TEST_SKIP_ONBOARDING: "1", FX_E2E_DISABLE_DOTENV: "1",
      FX_TEST_SKIP_WORKSPACE_TRUST: "1",
      FX_SOUND: "0", FX_AUTO_UPGRADE: "0", NO_COLOR: "1",
      FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "full_transcript_cache",
    };
    const command = `/usr/bin/env -i ${Object.entries(env)
      .map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)}`;
    const trace = () => (existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "");
    let terminal: InstanceType<typeof TmuxSession> | undefined;
    let passed = false;
    try {
      terminal = await TmuxSession.create({
        cmd: command, cwd: workspace, env, isolated: true, remainOnExit: true,
        stderrPath, width: 100, height: 32, startupWaitMs: 0,
      });
      await terminal.waitForStableComposer(15_000);
      for (const [index, answer] of answers.slice(0, 3).entries()) {
        await terminal.sendText(`Answer ${index + 1}.`);
        await terminal.waitForPane((pane) => pane.includes(answer.split("\n").at(-1)!) && hasEmptyComposer(pane) && turnSettled(pane), 15_000);
      }
      const id = onlySessionId(home);
      await terminal.sendText("/compact");
      await until(() => logLines(home, id).some((line) => line.kind === "compacted"), "the compaction");
      await terminal.waitForPane((pane) => !/Preparing compaction|Compacting/.test(pane) && hasEmptyComposer(pane), 15_000);
      // The turn across the compaction ends, so the window lets the older
      // cycle go and Ctrl+O's newest page joins it from the log.
      await terminal.sendText("One more turn.");
      await terminal.waitForPane((pane) => pane.includes("CTRLO_AFTER_COMPACTION_5c1") && hasEmptyComposer(pane) && turnSettled(pane), 15_000);
      // Between turns the cycle is read in the background and kept.
      await until(() => trace().includes("archive_loaded back=1"), "the background read of the joined cycle", 15_000);
      const openAt = trace().length;
      await terminal.sendKeys("C-o");
      await terminal.waitForText("esc close", 15_000);
      await terminal.waitForText("CTRLO_OLDER_ROW_40_5c1", 15_000);
      const atOpen = trace().slice(openAt);
      await terminal.sendKeys("Escape");
      await terminal.waitForComposer(15_000);
      // The open shows the older cycle without reading the log again.
      expect(atOpen).not.toContain("archive_read_started");
      expect(atOpen).not.toContain("archive_loaded");
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (!passed) {
        writeFileSync(join(root, "failure.trace.log"), trace());
        if (terminal) writeFileSync(join(root, "failure.scrollback.txt"), await terminal.captureFullScrollback());
        console.error(`compaction Ctrl+O evidence retained: ${root}`);
      }
      await terminal?.kill();
      gateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
    }
  }, 90_000);

  test("manual: a summary the gateway rejects for a login another fx renewed is sent again with the renewed login", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-compact-renewed-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    writeFileSync(join(workspace, "seed-notes.txt"), "seed notes\n");
    writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
      model: FAKE_GATEWAY_MODEL, auto_upgrade: false,
    }));
    const issuer = startFakeIssuer({ refresh: () => "unexpected-refresh" });
    writeFxLogin(home, issuer.issuerUrl, "launch-token");
    const summaryTokens: string[] = [];
    // Older turns outside the kept suffix, so /compact has work to do.
    const seedTurns = 3;
    let seeded = 0;
    const gateway = startDynamicFakeGateway((raw) => {
      const request = JSON.parse(raw);
      if (request.toolChoice?.type === "none" && request.tools?.length === 0) {
        // The gateway records each request before it answers.
        const token = bearer(gateway.requests.at(-1)!.headers);
        summaryTokens.push(token);
        if (token === "launch-token") {
          // Another fx renewed the shared login after /compact read it.
          rotateFxLogin(home, "rotated-token");
          return Response.json({ error: { message: "token expired" } }, { status: 401 });
        }
        return fakeGatewayFinalText(HANDOFF);
      }
      if (seeded < seedTurns) {
        const seedRead = `seed-read-${seeded + 1}`;
        if (!raw.includes(`"${seedRead}"`)) return fakeGatewayToolCall(seedRead, "read_file", { path: "seed-notes.txt" });
        seeded++;
        const head = seeded === 1 ? HEAD : `HISTORY_MIDDLE_${seeded}`;
        return fakeGatewayFinalText(`${head}\n${"history alpha beta gamma delta sample line\n".repeat(400)}SEED_DONE_${seeded}${seeded === seedTurns ? `\n${TAIL}` : ""}`);
      }
      return fakeGatewayFinalText(FOLLOWUP);
    }, { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
    let terminal: InstanceType<typeof TmuxSession> | undefined;
    let passed = false;
    try {
      terminal = await TmuxSession.create({
        cmd: binary,
        cwd: workspace,
        isolated: true,
        env: {
          HOME: home, TMPDIR: root, FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
          FX_TEST_SKIP_ONBOARDING: "1", FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_TEST_OAUTH_ISSUER_URL: issuer.issuerUrl, FX_OAUTH_CLIENT_ID: "test-client", FX_NO_OPEN_BROWSER: "1",
        },
      });
      await terminal.waitForStableComposer(20_000);
      for (let turn = 1; turn <= seedTurns; turn++) {
        await terminal.sendText(`Read the seed notes, part ${turn}.`);
        await terminal.waitForPane((pane) => pane.includes(`SEED_DONE_${turn}`) && hasEmptyComposer(pane) && turnSettled(pane), 20_000);
      }
      await terminal.sendText("/compact");
      await until(() => summaryTokens.length >= 2, "the renewed summary request");
      await terminal.waitForPane((pane) => !ACTIVITY.test(pane) && hasEmptyComposer(pane), 15_000);
      // One refused summary request, then every request with the renewed login.
      expect(summaryTokens[0]).toBe("launch-token");
      expect(summaryTokens.slice(1).length).toBeGreaterThan(0);
      expect(summaryTokens.slice(1).every((token) => token === "rotated-token")).toBe(true);
      expect(issuer.refreshes).toHaveLength(0);
      expect(await terminal.capturePane()).not.toContain("Compaction failed");
      // The next request carries the compacted context.
      await terminal.sendText("Follow the latest request.");
      await terminal.waitForPane((pane) => pane.includes(FOLLOWUP) && hasEmptyComposer(pane), 15_000);
      expect(gateway.requests.at(-1)!.body).toContain("INTERNAL_HANDOFF_4e12");
      passed = true;
    } finally {
      await terminal?.kill();
      gateway.stop();
      issuer.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
    }
  }, 90_000);
});

// Core keeps a turn's tool calls in one presentation group until the model
// writes text, so the calls after a notice in the middle of the turn share
// the group of the calls before it. The main screen draws them below the
// notice. These notices are not saved, so after `--resume` the calls share
// one row again.
const NOTICE_PROMPT = "Read the three files.";
const NOTICE_DONE = "NOTICE_ROWS_DONE_7c1a";
const NOTICE_REJECTION = "REJECTED_9d2e";
const NOTICE_HANDOFF = "Facts:\nF1: NOTICE_ROWS_HANDOFF_51aa: the user asked to read three files.";
// fx measures a request as a whole, tool catalog included, and compacts when
// that estimate reaches 10% of the usable input: the window less the 8192
// tokens kept for output. This turn must compact once, after a.txt's preview
// and before the calls that follow, so the point sits between them. Measured
// here: about 6.4k for the turn's first request, 8.5k with a.txt's preview of
// one-letter words, and 6.2k to 6.8k for the requests after the compaction.
// The point, 7.6k, is about 0.9k from either side, so a tool catalog that
// grows by less than that still yields one compaction.
const NOTICE_AUTO_COMPACT_AT_TOKENS = 7_600;
const NOTICE_AUTO_CONTEXT_WINDOW = NOTICE_AUTO_COMPACT_AT_TOKENS * 10 + 8192;
const NOTICE_CLOCK = /\((?:\d+h)?(?:\d+m)?\d+s\)/g;

type NoticeMiddle = "overflow" | "auto" | "provider-error" | "effort" | "empty-reply";
const NOTICE_EMPTY_REPLY = "The model stopped without a reply (provider reason: UNEXPECTED_TOOL_CALL). Asking it to continue.";

/// The rows from the turn's prompt to its answer, without blank rows and
/// with clocks as `(Ns)`, so live and resumed screens compare row for row.
function noticeTurnRows(grid: string[]): string[] {
  const rows = grid.map((row) => row.trimEnd().replace(NOTICE_CLOCK, "(Ns)")).filter((row) => row !== "");
  const start = rows.findLastIndex((row) => row === `┃ ${NOTICE_PROMPT}`);
  const end = rows.findLastIndex((row) => row.includes(NOTICE_DONE));
  expect(start).toBeGreaterThanOrEqual(0);
  expect(end).toBeGreaterThan(start);
  return rows.slice(start, end + 1);
}

function noticeTurnDone(pane: string): boolean {
  return pane.includes(NOTICE_DONE) && hasEmptyComposer(pane) && turnSettled(pane) && /Explored \d+ files/.test(pane);
}

/// Reads a.txt, shows the notice `middle` makes, reads b.txt and then c.txt,
/// and answers. Returns the turn's rows live, in Ctrl+O, and after
/// `--resume last`.
async function readAroundNotice(middle: NoticeMiddle) {
  const compacts = middle === "overflow" || middle === "auto";
  const root = mkdtempSync(join(tmpdir(), "fx-notice-rows-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(workspace, "seed-notes.txt"), "seed notes\n");
  const oneLetterWords = Array.from({ length: 1000 }, () => "a b c d e f g h i j k l m n o p q r s t").join("\n");
  writeFileSync(join(workspace, "a.txt"), middle === "auto" ? `${oneLetterWords}\n` : "alpha\n");
  writeFileSync(join(workspace, "b.txt"), "bravo\n");
  writeFileSync(join(workspace, "c.txt"), "charlie\n");
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    model: FAKE_GATEWAY_MODEL, auto_upgrade: false,
    ...(middle === "auto" ? { auto_compact_percent: 10 } : {}),
  }));
  // The earlier turn gives compaction something to fold. It reports no
  // usage, since fx would scale its later size estimates by it.
  const seedLines = middle === "auto" ? 40 : 1600;
  const seedReply = `${"history alpha beta gamma delta sample line\n".repeat(seedLines)}SEED_DONE`;
  let seeding = compacts;
  let steps = 0;
  let releaseSecondRead = () => {};
  const secondReadReleased = new Promise<void>((resolve) => { releaseSecondRead = resolve; });
  const turnSteps: Array<() => Response | Promise<Response>> = [
    () => fakeGatewayToolCall("read_a", "read_file", { path: "a.txt" }),
    ...(middle === "overflow" ? [() => Response.json({ error: {
      type: "invalid_request_error", code: "context_length_exceeded",
      message: "This model's maximum context length is 128000 tokens. The request exceeds the context window.",
    } }, { status: 400 })] : []),
    ...(middle === "provider-error" ? [() => Response.json({ error: {
      type: "invalid_request_error", message: NOTICE_REJECTION,
    } }, { status: 403 })] : []),
    // No text and no call, with a reason the AI SDK folds into `other`.
    ...(middle === "empty-reply" ? [() => fakeGatewaySse([
      { type: "finish", finishReason: { unified: "other", raw: "UNEXPECTED_TOOL_CALL" } },
    ])] : []),
    middle === "effort"
      ? async () => {
        await secondReadReleased;
        return fakeGatewayToolCall("read_b", "read_file", { path: "b.txt" });
      }
      : () => fakeGatewayToolCall("read_b", "read_file", { path: "b.txt" }),
    () => fakeGatewayToolCall("read_c", "read_file", { path: "c.txt" }),
    () => fakeGatewayFinalText(NOTICE_DONE),
  ];
  const gateway = startDynamicFakeGateway((raw) => {
    const request = JSON.parse(raw);
    // A summary request can keep the conversation's tools for the cache,
    // so its instruction marks it too.
    const summary = (request.toolChoice?.type === "none" && request.tools?.length === 0) ||
      raw.includes("Write the compaction notes") || raw.includes("Your notes on the turns above left some out");
    if (summary) return fakeGatewayFinalText(NOTICE_HANDOFF);
    if (seeding) {
      if (!raw.includes('"seed-read"')) return fakeGatewayToolCall("seed-read", "read_file", { path: "seed-notes.txt" });
      return fakeGatewaySse([
        { type: "text-delta", id: "answer_1", delta: seedReply },
        { type: "finish", finishReason: { unified: "stop", raw: "stop" } },
      ]);
    }
    const next = turnSteps[steps++];
    return next ? next() : new Response("unexpected request", { status: 500 });
  }, { models: [{
    id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"],
    context_window: middle === "auto" ? NOTICE_AUTO_CONTEXT_WINDOW : 128000, max_tokens: 8192,
    reasoning_options: [{ type: "effort", values: ["low", "medium", "high"] }],
  }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    TERM: "xterm-256color", AI_GATEWAY_API_KEY: "synthetic-notice-key",
    FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_TEST_SKIP_ONBOARDING: "1",
    FX_TEST_SKIP_WORKSPACE_TRUST: "1",
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  const stderrPaths: string[] = [];
  let terminal: InstanceType<typeof TmuxSession> | undefined;
  async function launch(args: string) {
    const stderrPath = join(root, `terminal-${stderrPaths.length + 1}.stderr`);
    stderrPaths.push(stderrPath);
    const command = `/usr/bin/env -i ${Object.entries(env).map(([key, value]) => shellQuote(`${key}=${value}`)).join(" ")} ${shellQuote(binary)} ${args}`;
    terminal = await TmuxSession.create({
      cmd: command, cwd: workspace, env: { HOME: home, FX_SOUND: "0" }, isolated: true,
      stderrPath, width: 100, height: 40, startupWaitMs: 0,
    });
    await terminal.waitForStableComposer(20_000);
    return terminal;
  }
  let passed = false;
  try {
    const live = await launch("");
    if (seeding) {
      await live.sendText("Seed one turn.");
      await live.waitForPane((pane) => pane.includes("SEED_DONE") && hasEmptyComposer(pane) && turnSettled(pane), 20_000);
      seeding = false;
    }
    await live.sendText(NOTICE_PROMPT);
    if (middle === "provider-error") {
      await live.waitForPane((pane) => pane.includes(NOTICE_REJECTION) && pane.includes("press Esc"), 15_000);
      await live.sendKeys("Enter");
    } else if (middle === "effort") {
      await live.waitForPane((pane) => pane.includes("● Read a.txt") && /Thinking \(/.test(pane), 15_000);
      await until(() => steps === 2, "the second read's request");
      await live.sendText("/effort high");
      await live.waitForText("Next turn will use reasoning effort high", 10_000);
      releaseSecondRead();
    }
    const livePane = await live.waitForPane(noticeTurnDone, 20_000);
    const liveRows = noticeTurnRows(livePane.split("\n"));
    await live.sendKeys("C-o");
    await live.waitForText("esc close · pgup/pgdn scroll", 5000);
    await live.sendKeys("End");
    const fullRows = (await live.waitForPane((pane) => pane.includes(NOTICE_DONE) && pane.includes("esc close"), 5000)).split("\n");
    await live.sendKeys("C-o");
    await live.waitForComposer(5000);
    await live.sendText("/quit");
    expect(await live.waitForSessionEnd(10_000)).toBe(true);
    await live.kill();

    const resumed = await launch("--resume last");
    const resumedRows = noticeTurnRows((await resumed.waitForPane(noticeTurnDone, 20_000)).split("\n"));
    await resumed.sendText("/quit");
    expect(await resumed.waitForSessionEnd(10_000)).toBe(true);
    for (const path of stderrPaths) expect(readFileSync(path, "utf8")).toBe("");
    passed = true;
    return { liveRows, livePane, fullRows, resumedRows };
  } finally {
    if (!passed) {
      if (terminal) writeFileSync(join(root, "failure.scrollback.txt"), await terminal.captureFullScrollback());
      console.error(`notice rows evidence retained: ${root}; steps=${steps}`);
    }
    await terminal?.kill();
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
  }
}

/// Checks that Ctrl+O's page shows each of `marks`, in this order.
function expectFullTranscriptOrder(rows: string[], marks: string[]) {
  const at = marks.map((mark) => rows.findIndex((row) => row.includes(mark)));
  expect(at.every((index) => index >= 0)).toBe(true);
  expect(at).toEqual([...at].sort((left, right) => left - right));
}

describe.skipIf(!tmuxAvailable())("tui: tool rows around a notice in the middle of a turn", () => {
  const compactedRows = [
    `┃ ${NOTICE_PROMPT}`,
    "● Read a.txt",
    "✓ Context compacted (Ns)",
    "● Read b.txt, c.txt",
    `  ${NOTICE_DONE}`,
  ];

  test("overflow: the calls after an in-turn compaction draw below its line, and share one row after resume", async () => {
    const { liveRows, fullRows, resumedRows } = await readAroundNotice("overflow");
    expect(liveRows).toEqual(compactedRows);
    expectFullTranscriptOrder(fullRows, ["● Read a.txt", "Context compacted", "● Read b.txt", "● Read c.txt", NOTICE_DONE]);
    expect(resumedRows).toEqual([`┃ ${NOTICE_PROMPT}`, "● Read a.txt, b.txt, c.txt", `  ${NOTICE_DONE}`]);
  }, 120_000);

  test("auto: the calls after an in-turn compaction draw below its line, and share one row after resume", async () => {
    const { liveRows, resumedRows } = await readAroundNotice("auto");
    expect(liveRows).toEqual(compactedRows);
    // This compaction folds the turn's first step into its summary. The log
    // still saves that step (D87), so resume draws it in the shared row.
    expect(resumedRows).toEqual([`┃ ${NOTICE_PROMPT}`, "● Read a.txt, b.txt, c.txt", `  ${NOTICE_DONE}`]);
  }, 120_000);

  test("provider error: the calls after the reason fx showed while it waited draw below it, and share one row after resume", async () => {
    const { liveRows, livePane, fullRows, resumedRows } = await readAroundNotice("provider-error");
    expect(liveRows).toEqual([
      `┃ ${NOTICE_PROMPT}`,
      "● Read a.txt",
      `⚠ ${NOTICE_REJECTION}`,
      "● Read b.txt, c.txt",
      `  ${NOTICE_DONE}`,
    ]);
    expect(livePane).not.toContain("system:");
    expect(livePane).not.toContain("HTTP 403");
    expect(fullRows.join("\n")).toContain("HTTP 403 · invalid_request_error");
    expectFullTranscriptOrder(fullRows, ["● Read a.txt", NOTICE_REJECTION, "● Read b.txt", "● Read c.txt", NOTICE_DONE]);
    expect(resumedRows).toEqual([`┃ ${NOTICE_PROMPT}`, "● Read a.txt, b.txt, c.txt", `  ${NOTICE_DONE}`]);
  }, 120_000);

  test("/effort during the turn: the calls after its line draw below it, and share one row after resume", async () => {
    const { liveRows, fullRows, resumedRows } = await readAroundNotice("effort");
    expect(liveRows).toEqual([
      `┃ ${NOTICE_PROMPT}`,
      "● Read a.txt",
      `* Next turn will use reasoning effort high for ${FAKE_GATEWAY_MODEL}`,
      "● Read b.txt, c.txt",
      `  ${NOTICE_DONE}`,
    ]);
    expectFullTranscriptOrder(fullRows, ["● Read a.txt", "Next turn will use reasoning effort high", "● Read b.txt", "● Read c.txt", NOTICE_DONE]);
    expect(resumedRows).toEqual([`┃ ${NOTICE_PROMPT}`, "● Read a.txt, b.txt, c.txt", `  ${NOTICE_DONE}`]);
  }, 120_000);

  test("empty reply: the calls after fx asked the model to continue draw below that line, and share one row after resume", async () => {
    const { liveRows, fullRows, resumedRows } = await readAroundNotice("empty-reply");
    expect(liveRows).toEqual([
      `┃ ${NOTICE_PROMPT}`,
      "● Read a.txt",
      `  ${NOTICE_EMPTY_REPLY}`,
      "● Read b.txt, c.txt",
      `  ${NOTICE_DONE}`,
    ]);
    expectFullTranscriptOrder(fullRows, ["● Read a.txt", "The model stopped without a reply", "● Read b.txt", "● Read c.txt", NOTICE_DONE]);
    expect(resumedRows).toEqual([`┃ ${NOTICE_PROMPT}`, "● Read a.txt, b.txt, c.txt", `  ${NOTICE_DONE}`]);
  }, 120_000);
});

// A real model writes the summary of an automatic compaction that starts in
// the middle of a turn. Opt in with FX_E2E_REAL_API=1 and an AI Gateway
// credential; FX_COMPACTION_LIVE_MODEL picks another model.
const LIVE_MODEL = process.env.FX_COMPACTION_LIVE_MODEL ?? "anthropic/claude-haiku-4.5";
const LIVE = process.env.FX_E2E_REAL_API === "1" && HAS_API_KEY;
// The turn row names its phase: thinking, running a tool, or generating.
const LIVE_TURN_CLOCK = /(?:Thinking|Running|Generating) \(((?:\d+h)?(?:\d+m)?\d+s)\)/;
const LIVE_PROMPT = "Use read_file to read part1.txt, then part2.txt, then part3.txt, one file per step. Then reply with the single word DONE.";

describe.skipIf(!tmuxAvailable() || !LIVE)("tui: compaction activity with a live model", () => {
  test("live: compaction in the middle of a turn counts from zero with its count, and the turn clock goes on from where it stopped", async () => {
    const root = mkdtempSync(join(tmpdir(), "fx-live-compaction-"));
    const home = join(root, "home");
    const workspace = join(root, "workspace");
    mkdirSync(join(home, ".fx"), { recursive: true });
    mkdirSync(workspace);
    // The earlier turn holds about 5k tokens and each part about 6k, so the
    // turn's first request stays under 10% of the model's usable input and a
    // later request in the same turn crosses it.
    const body = (tag: string, lines: number) => Array.from({ length: lines }, (_, line) =>
      `${tag} ${line}: notes on the river survey, gauge readings, and weather by the bank`).join("\n");
    writeFileSync(join(workspace, "seed.txt"), body("seed", 200));
    for (const part of [1, 2, 3]) {
      writeFileSync(join(workspace, `part${part}.txt`), `${body(`part${part}`, 300)}\n`);
    }
    writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
      model: LIVE_MODEL, auto_compact_percent: 10, auto_upgrade: false,
    }));
    // A local gateway plays the earlier turn, so only this turn and its
    // compaction reach the live model.
    const seedGateway = startDynamicFakeGateway((raw) => raw.includes('"seed-read"')
      ? fakeGatewayFinalText("SEED_OK")
      : fakeGatewayToolCall("seed-read", "read_file", { path: "seed.txt" }),
    { models: [{ id: FAKE_GATEWAY_MODEL, type: "language", tags: ["tool-use"], context_window: 200000, max_tokens: 64000 }] });
    const stderrPath = join(root, "terminal.stderr");
    const tracePath = join(root, "terminal.trace");
    let terminal: InstanceType<typeof TmuxSession> | undefined;
    const samples: { at: number; turn?: number; compaction?: number; percent?: number }[] = [];
    let passed = false;
    try {
      const seed = Bun.spawn([binary, "ask", "--json", "--auto", "Read seed.txt."], {
        cwd: workspace, stdin: "ignore", stdout: "pipe", stderr: "pipe",
        env: {
          PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root, AI_GATEWAY_API_KEY: "synthetic-seed-key",
          FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1", FX_TEST_SKIP_ONBOARDING: "1", FX_SOUND: "0",
          FX_AUTO_UPGRADE: "0", FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: seedGateway.baseUrl,
          FX_GATEWAY_CHAT_URL: seedGateway.chatUrl, FX_TEST_GATEWAY_CHAT_URL: seedGateway.chatUrl,
          FX_TEST_GATEWAY_MODELS_URL: `${seedGateway.baseUrl}/coding-agent/v1/models`,
        },
      });
      const [seedCode, seedOut] = await Promise.all([seed.exited, new Response(seed.stdout).text()]);
      expect(seedCode).toBe(0);
      const sessionId = JSON.parse(seedOut).session_id as string;

      terminal = await TmuxSession.create({
        cmd: `${shellQuote(binary)} --resume ${shellQuote(sessionId)}`,
        cwd: workspace,
        env: {
          HOME: home, TMPDIR: root,
          AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
          VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
          FX_E2E_DISABLE_DOTENV: "1", FX_AUTO_UPGRADE: "0", FX_MODEL: LIVE_MODEL,
          FX_TRACE_LOG: tracePath, FX_TRACE_SCOPES: "compaction,worker",
        },
        isolated: true, width: 100, height: 32, stderrPath, startupWaitMs: 0,
      });
      await terminal.waitForStableComposer(30_000);
      const sent = Date.now();
      await terminal.sendText(LIVE_PROMPT);
      let pane = "";
      // The model may take more or fewer steps; the test waits for the turn
      // to end, which leaves its summary line after the prompt.
      const finished = (text: string) => turnSummarySeconds(text, "one file per step") !== null && hasEmptyComposer(text);
      while (Date.now() - sent < 240_000) {
        pane = await terminal.capturePane();
        const turn = LIVE_TURN_CLOCK.exec(pane);
        const compaction = COMPACTION_CLOCK.exec(pane);
        samples.push({
          at: Date.now() - sent,
          turn: turn ? clockSeconds(turn[1]!) : undefined,
          compaction: compaction ? clockSeconds(compaction[2]!) : undefined,
          percent: compaction ? Number(compaction[1]) : undefined,
        });
        if (finished(pane)) break;
        await Bun.sleep(100);
      }
      expect(finished(pane)).toBe(true);

      // Each stretch of compaction rows, with the turn clock's last reading
      // before it, how long before the stretch that was, and the turn
      // clock's first reading after it.
      type Episode = { before?: number; gap: number; first: number; most: number; percents: number[]; after?: number };
      const episodes: Episode[] = [];
      let lastTurn: { seconds: number; at: number } | undefined;
      let compacting = false;
      for (const sample of samples) {
        if (sample.compaction !== undefined) {
          if (!compacting) {
            episodes.push({
              before: lastTurn?.seconds, gap: lastTurn ? sample.at - lastTurn.at : 0,
              first: sample.compaction, most: sample.compaction, percents: [],
            });
          }
          compacting = true;
          const episode = episodes.at(-1)!;
          episode.most = Math.max(episode.most, sample.compaction);
          if (sample.percent !== undefined && episode.percents.at(-1) !== sample.percent) episode.percents.push(sample.percent);
          continue;
        }
        compacting = false;
        if (sample.turn === undefined) continue;
        const open = episodes.at(-1);
        if (open && open.after === undefined) open.after = sample.turn;
        lastTurn = { seconds: sample.turn, at: sample.at };
      }
      console.log(`live compaction with ${LIVE_MODEL}: ${JSON.stringify(episodes)}`);
      expect(episodes.length).toBeGreaterThan(0);
      // At least one compaction came after the turn had shown its clock.
      expect(episodes.some((episode) => episode.before !== undefined && episode.after !== undefined)).toBe(true);
      for (const episode of episodes) {
        expect(episode.first).toBeLessThanOrEqual(1);
        // The count only goes up, and it moves while the summary streams in.
        for (let i = 1; i < episode.percents.length; i++) expect(episode.percents[i]!).toBeGreaterThan(episode.percents[i - 1]!);
        expect(episode.percents.some((value) => value > 0)).toBe(true);
        if (episode.before === undefined || episode.after === undefined) continue;
        // The turn goes on from where it stopped: at most the seconds from
        // its last reading to the compaction, plus one for each sampling
        // edge. The compaction's own seconds are not in it.
        expect(episode.after).toBeGreaterThanOrEqual(episode.before);
        expect(episode.after).toBeLessThanOrEqual(episode.before + Math.ceil(episode.gap / 1000) + 2);
      }
      // The finished turn's duration leaves out the compaction too: about
      // what the turn clock last showed.
      const total = turnSummarySeconds(pane, "one file per step")!;
      console.log(`live turn: clock last ${lastTurn?.seconds}s, summary ${total}s`);
      expect(total).toBeGreaterThanOrEqual(lastTurn!.seconds - 1);
      expect(total).toBeLessThanOrEqual(lastTurn!.seconds + 2);
      // Each compaction leaves a line; the longest one's shows about the
      // time its row showed last.
      const lines = compactedSeconds(await terminal.captureFullScrollback());
      console.log(`live compacted lines: ${JSON.stringify(lines)}`);
      expect(lines.length).toBeGreaterThanOrEqual(episodes.length);
      const longest = Math.max(...episodes.map((episode) => episode.most));
      expect(lines.some((seconds) => seconds >= longest && seconds <= longest + 2)).toBe(true);
      expect(checkpoints(readFileSync(join(sessionDir(home, sessionId), "log.jsonl")))).toBeGreaterThan(0);
      await terminal.sendText("/quit");
      expect(await terminal.waitForSessionEnd(10_000)).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      passed = true;
    } finally {
      if (!passed) {
        writeFileSync(join(root, "samples.json"), JSON.stringify(samples, null, 2));
        if (terminal) writeFileSync(join(root, "failure.scrollback.txt"), await terminal.captureFullScrollback());
        console.error(`live compaction evidence retained: ${root}`);
      }
      await terminal?.kill();
      seedGateway.stop();
      if (passed) rmSync(root, { recursive: true, force: true });
    }
  }, 300_000);
});
