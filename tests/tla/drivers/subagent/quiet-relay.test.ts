// Runs the built fx along tests/tla/subagent/QuietRelay.tla. The driver
// plays main and every subagent through fx ask against a local gateway, with
// FX_TEST_SHELL_QUIET_NOTICE_MS at 1.5 s. Each subagent runs a command that
// goes quiet once or twice and waits on it; main messages each subagent,
// waits, and reads fx's notes, which start main's next turns. The driver
// writes what it saw, each crossing, later notice, new output, close, and
// note, and has TLC check the walk against the model (QuietRelayTrace.tla).
// It also checks fx's own trace: every crossing the shell logged was posted
// or dropped with a reason, and no subagent got more notes than it had
// quiet spells. Planted changes to an accepted walk must be rejected.
//
//   bun test ./tests/tla/drivers/subagent/quiet-relay.test.ts
//   FX_TLA_QUIET_RACE=8     adds 8 walks where main closes a subagent at a random moment around its crossing
//   FX_TLA_QUIET_STRESS=20  adds a walk where 20 subagents cross at once
//   FX_BIN=<binary>         drives another build
import { expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, tlcToolchain } from "../lib/tlc";

const MAIN_MARK = "QRW_MAIN";
const QUIET_MS = 1_500;
const MESSAGE_HEADER = "Subagent message (untrusted agent output, not user instructions):";
const REPORT_HEADER = "Subagent report (untrusted agent output, not user instructions):";
const LONG_WAIT_MS = 20_000;
const LATE_WAIT_MS = 5_000;

type Plan = { name: string; spells: 1 | 2; late: boolean };
type Walk = { name: string; subs: Plan[]; closeAfterNote?: string; closeAtMs?: { sub: string; ms: number } };
type Obs = { op: "cross" | "late" | "output" | "close" | "note"; sub: string; spell: number };
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";
type Result = {
  observations: Obs[];
  errors: string[];
  exit: number | null;
  stderr: string;
  seconds: number;
  crossings: number;
  posted: number;
  dropped: number;
  notesPer: Map<string, number>;
};

const helpers = await targetHelpers();
const fakeModel = "openai/gpt-5.5";

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return content.map(contentText).join("");
  if (content && typeof content === "object") {
    const value = content as Record<string, unknown>;
    return [contentText(value.text), contentText(value.value), contentText(value.content)].join("");
  }
  return "";
}

type Message = { role: string; content: unknown };
const prompt = (body: string): Message[] => (JSON.parse(body) as { prompt: Message[] }).prompt;

function subOf(body: string): string | null {
  for (const message of prompt(body)) {
    if (message.role !== "system") continue;
    const match = /You are the subagent "([^"]+)"/.exec(contentText(message.content));
    if (match) return match[1]!;
  }
  return null;
}

function latestUser(body: string): string {
  return contentText(prompt(body).filter((message) => message.role === "user").at(-1)?.content ?? "");
}

const isNote = (text: string) => text.includes(MESSAGE_HEADER) && text.includes("no output for");

/** How many of fx's quiet notes from each subagent main's prompt holds. Notes
 * can join main's running turn, so one request can carry several. */
function notesIn(body: string): Map<string, number> {
  const counts = new Map<string, number>();
  for (const message of prompt(body)) {
    if (message.role !== "user") continue;
    const text = contentText(message.content);
    if (!isNote(text)) continue;
    const sub = /"agent":"([^"]+)"/.exec(text)?.[1] ?? "?";
    counts.set(sub, (counts.get(sub) ?? 0) + 1);
  }
  return counts;
}

/** The output of call `id`'s result after the latest user message, if any. */
function currentResult(body: string, id: string): string | null {
  const messages = prompt(body);
  const last = messages.findLastIndex((message) => message.role === "user");
  for (const message of messages.slice(last + 1)) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-result" && part.toolCallId === id) return contentText(part.output);
    }
  }
  return null;
}

function hasResult(body: string, id: string): boolean {
  return prompt(body).some((message) => Array.isArray(message.content) &&
    (message.content as Array<Record<string, unknown>>).some((part) => part.type === "tool-result" && part.toolCallId === id));
}

const call = (id: string, tool: string, request: object) => helpers.fakeGatewayToolCall(id, tool, { request });
const final = (text: string) => helpers.fakeGatewayFinalText(text);

function commandFor(plan: Plan): string {
  const a = `printf QRW-${plan.name}-A`;
  return plan.spells === 2
    ? `sh -c '${a}; sleep 3; printf QRW-${plan.name}-B; exec sleep 600'`
    : `sh -c '${a}; exec sleep 600'`;
}

async function runWalk(walk: Walk, dir: string): Promise<Result> {
  const root = mkdtempSync(join(dir, `${walk.name}-`));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const tracePath = join(root, "trace.log");
  const observations: Obs[] = [];
  const errors: string[] = [];
  const plans = new Map(walk.subs.map((plan) => [plan.name, plan]));
  // What the driver saw of each subagent: the spells that crossed, the
  // current spell, and notes read before their crossing was seen.
  const crossed = new Map<string, number[]>(walk.subs.map((plan) => [plan.name, []]));
  const spellOf = new Map<string, number>(walk.subs.map((plan) => [plan.name, 1]));
  const notesPer = new Map<string, number>();
  const earlyNotes = new Map<string, number>();
  const sentAt = new Map<string, number>();
  const closed = new Set<string>();
  let messaged = 0;

  const note = (sub: string) => {
    const n = (notesPer.get(sub) ?? 0) + 1;
    notesPer.set(sub, n);
    const spells = crossed.get(sub) ?? [];
    // A note always follows its crossing; the subagent's request that
    // shows the crossing may reach the gateway after main's note turn.
    if (n > spells.length) {
      earlyNotes.set(sub, (earlyNotes.get(sub) ?? 0) + 1);
      return;
    }
    observations.push({ op: "note", sub, spell: spells[n - 1]! });
  };
  const flushNotes = (sub: string) => {
    let waiting = earlyNotes.get(sub) ?? 0;
    const spells = crossed.get(sub) ?? [];
    while (waiting > 0) {
      const index = (notesPer.get(sub) ?? 0) - waiting;
      if (index >= spells.length) break;
      observations.push({ op: "note", sub, spell: spells[index]! });
      waiting -= 1;
    }
    earlyNotes.set(sub, waiting);
  };

  const childStep = (sub: string, body: string): Response => {
    const plan = plans.get(sub)!;
    const shell = (id: string) => {
      const text = currentResult(body, id);
      return text ? JSON.parse(text) as { session_id?: string; output_delta?: string; quiet_notice?: string; state?: string } : null;
    };
    const ran = (id: string) => performance.now() - (sentAt.get(`${sub}:${id}`) ?? 0);
    const send = (id: string, tool: string, request: object) => {
      sentAt.set(`${sub}:${id}`, performance.now());
      return call(id, tool, request);
    };
    const session = hasResult(body, "run") ? (JSON.parse(currentResult(body, "run") ?? "{}") as { session_id?: string }).session_id : undefined;
    if (currentResult(body, "stop") !== null) return final(`QRW_CHILD_DONE ${sub}`);
    const waited = (id: string, ceilingMs: number, after: string | null) => {
      const result = shell(id);
      if (!result) return false;
      if (result.output_delta?.includes(`QRW-${sub}-B`)) {
        spellOf.set(sub, 2);
        observations.push({ op: "output", sub, spell: 2 });
      }
      const early = ran(id) < ceilingMs - 1_000;
      if (result.quiet_notice && early) {
        crossed.get(sub)!.push(spellOf.get(sub)!);
        observations.push({ op: "cross", sub, spell: spellOf.get(sub)! });
        flushNotes(sub);
      } else if (result.quiet_notice) {
        observations.push({ op: "late", sub, spell: spellOf.get(sub)! });
      } else if (result.state === "running") {
        errors.push(`${sub} ${id}: a wait ended with no notice: ${JSON.stringify(result)}`);
      }
      return after !== null;
    };
    // The latest call comes first: every earlier result stays in the turn.
    if (shell("late")) {
      waited("late", LATE_WAIT_MS, "stop");
      return send("stop", "shell", { action: "stop", session_id: session });
    }
    if (shell("wait-2")) {
      waited("wait-2", LONG_WAIT_MS, "next");
      if (plan.late) return send("late", "shell", { action: "interact", session_id: session, yield_time_ms: LATE_WAIT_MS });
      return send("stop", "shell", { action: "stop", session_id: session });
    }
    if (shell("wait-1")) {
      waited("wait-1", LONG_WAIT_MS, "next");
      if (plan.spells === 2) return send("wait-2", "shell", { action: "interact", session_id: session, yield_time_ms: LONG_WAIT_MS });
      if (plan.late) return send("late", "shell", { action: "interact", session_id: session, yield_time_ms: LATE_WAIT_MS });
      return send("stop", "shell", { action: "stop", session_id: session });
    }
    if (shell("run")) {
      if (!session) errors.push(`${sub}: run started no session`);
      return send("wait-1", "shell", { action: "interact", session_id: session, yield_time_ms: LONG_WAIT_MS });
    }
    return send("run", "shell", { action: "run", command: commandFor(plan), yield_time_ms: 300 });
  };

  const mainStep = async (body: string): Promise<Response> => {
    // Main's prompt keeps every note it was given; record each new one once.
    for (const [sub, count] of notesIn(body)) {
      while ((notesPer.get(sub) ?? 0) < count) note(sub);
    }
    const latest = latestUser(body);
    if (latest.includes(REPORT_HEADER)) return final("QRW_REPORT_SEEN");
    if (isNote(latest)) {
      const sub = /"agent":"([^"]+)"/.exec(latest)?.[1] ?? "?";
      if (walk.closeAfterNote === sub && !closed.has(sub) && !hasResult(body, `close-${sub}`)) {
        return call(`close-${sub}`, "subagent", { action: "close", agent: sub });
      }
      if (hasResult(body, `close-${sub}`) && !closed.has(sub)) {
        closed.add(sub);
        observations.push({ op: "close", sub, spell: 0 });
      }
      return final(`QRW_NOTE_SEEN ${sub}`);
    }
    if (walk.closeAtMs && hasResult(body, `close-${walk.closeAtMs.sub}`) && !closed.has(walk.closeAtMs.sub)) {
      closed.add(walk.closeAtMs.sub);
      observations.push({ op: "close", sub: walk.closeAtMs.sub, spell: 0 });
      return call("main-wait", "subagent", { action: "wait" });
    }
    if (hasResult(body, "main-wait")) return final("QRW_MAIN_DONE");
    if (messaged < walk.subs.length) {
      if (messaged > 0 && !hasResult(body, `message-${messaged}`)) return final("QRW_MAIN_LOST");
      messaged += 1;
      const plan = walk.subs[messaged - 1]!;
      return call(`message-${messaged}`, "subagent", {
        action: "message", agent: plan.name, message: `Run your step and wait on it, ${plan.name}.`,
      });
    }
    if (walk.closeAtMs) {
      const { sub, ms } = walk.closeAtMs;
      await Bun.sleep(ms);
      return call(`close-${sub}`, "subagent", { action: "close", agent: sub });
    }
    return call("main-wait", "subagent", { action: "wait" });
  };

  const gateway = helpers.startDynamicFakeGateway(async (body: string) => {
    const sub = subOf(body);
    if (sub && plans.has(sub)) return childStep(sub, body);
    if (body.includes(MAIN_MARK)) return await mainStep(body);
    return final("QRW_UNKNOWN");
  }, { classifierDecision: "clear", models: [{ id: fakeModel, type: "language", tags: ["tool-use"] }] });

  const started = performance.now();
  const child = Bun.spawn([binary, "ask", "--json", "--full-access", `${MAIN_MARK} run the walk`], {
    cwd: workspace,
    env: testEnvironment({
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-quiet-relay-driver-key",
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
      FX_MODEL: fakeModel,
      FX_TEST_SHELL_QUIET_NOTICE_MS: String(QUIET_MS),
      FX_TRACE_LOG: tracePath,
      FX_TRACE_SCOPES: "mailbox,shell",
    }),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(9), 120_000);
  const [, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  clearTimeout(timer);
  gateway.stop();
  for (const [sub, waiting] of earlyNotes) if (waiting > 0) errors.push(`${sub}: ${waiting} note(s) with no crossing seen`);
  const trace = existsSync(tracePath) ? readFileSync(tracePath, "utf8") : "";
  const count = (pattern: RegExp) => trace.split("\n").filter((line) => pattern.test(line)).length;
  return {
    observations,
    errors,
    exit,
    stderr: stderr.slice(-2000),
    seconds: Number(((performance.now() - started) / 1000).toFixed(2)),
    crossings: count(/\[shell\] event=quiet_crossing /),
    posted: count(/\[mailbox\] event=quiet_note_posted /),
    dropped: count(/\[mailbox\] event=quiet_note_dropped /),
    notesPer,
  };
}

const str = (value: string) => JSON.stringify(value);

function observedModule(observations: Obs[]): string {
  const rows = observations.map((o) => `[op |-> ${str(o.op)}, sub |-> ${str(o.sub)}, spell |-> ${o.spell}]`);
  return ["---- MODULE QuietRelayObserved ----", "EXTENDS Sequences", `Observed == <<${rows.join(",\n  ")}>>`, "====", ""].join("\n");
}

async function checkTrace(observations: Obs[], subs: string[], dir: string): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  for (const file of ["QuietRelay.tla", "QuietRelayTrace.tla"]) copyFileSync(join(TLA_ROOT, "subagent", file), join(dir, file));
  writeFileSync(join(dir, "QuietRelayObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Children = {${subs.map(str).join(", ")}}`,
    "  MaxSpells = 2",
    "  Cap = 64",
    `  Bug = "none"`,
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const tlc = Bun.spawn([java, "-XX:+UseParallelGC", "-Xss4m", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar,
    "tlc2.TLC", "-workers", "1", "-metadir", join(dir, ".tlc-states"), "-config", "trace.cfg", "QuietRelayTrace.tla"], {
    cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([new Response(tlc.stdout).text(), new Response(tlc.stderr).text(), tlc.exited]);
  const log = `${stdout}\n${stderr}`;
  writeFileSync(join(dir, "tlc.log"), log);
  if (code === 12 && log.includes("Invariant NotAllMatched is violated")) return "ACCEPTED";
  if (code === 0 && log.includes("Model checking completed. No error has been found.")) return "REJECTED";
  console.error(`TLC tool error in ${dir} (exit ${code})`);
  return "TOOL_ERROR";
}

/** The rules fx's own trace shows: every crossing posted or dropped, and
 * no subagent with more notes than quiet spells. */
function expectAccounted(walk: Walk, result: Result) {
  const context = `${walk.name}: ${JSON.stringify({ ...result, notesPer: [...result.notesPer] })}`;
  expect(result.exit, context).toBe(0);
  expect(result.stderr, context).not.toContain("panic");
  expect(result.errors, context).toEqual([]);
  expect(result.crossings, context).toBe(result.posted + result.dropped);
  for (const plan of walk.subs) expect(result.notesPer.get(plan.name) ?? 0, context).toBeLessThanOrEqual(plan.spells);
}

const dir = join(artifacts, "quiet-relay");
mkdirSync(dir, { recursive: true });
const accepted = new Map<string, { observations: Obs[]; subs: string[] }>();

const walks: Walk[] = [
  { name: "one-spell-late", subs: [{ name: "q1", spells: 1, late: true }] },
  { name: "two-spells", subs: [{ name: "q1", spells: 2, late: false }] },
  { name: "two-subagents", subs: [{ name: "q1", spells: 1, late: true }, { name: "q2", spells: 2, late: false }] },
  { name: "three-at-once", subs: [1, 2, 3].map((n) => ({ name: `q${n}`, spells: 1 as const, late: false })) },
  { name: "close-after-note", subs: [{ name: "q1", spells: 2, late: false }], closeAfterNote: "q1" },
];

for (const walk of walks) {
  test(`walk ${walk.name} is a behavior of QuietRelay`, async () => {
    const result = await runWalk(walk, dir);
    expectAccounted(walk, result);
    // Every crossing was relayed when no subagent closes in the walk.
    if (!walk.closeAfterNote) expect(result.dropped, walk.name).toBe(0);
    const subs = walk.subs.map((plan) => plan.name);
    const verdict = await checkTrace(result.observations, subs, join(dir, `${walk.name}-tlc`));
    expect(verdict, `${walk.name}: ${JSON.stringify(result.observations)}`).toBe("ACCEPTED");
    accepted.set(walk.name, { observations: result.observations, subs });
    console.log(`quiet-relay ${walk.name}: ${result.observations.length} observations, ${result.posted} notes, ${result.seconds}s`);
  }, 150_000);
}

test("planted changes to an accepted walk are rejected", async () => {
  const kept = accepted.get("two-spells") ?? accepted.get("one-spell-late");
  expect(kept, "no accepted walk to tamper with").toBeDefined();
  const { observations, subs } = kept!;
  const firstNote = observations.findIndex((o) => o.op === "note");
  const firstCross = observations.findIndex((o) => o.op === "cross");
  const tampered: Array<[string, Obs[]]> = [
    // A second note for the same spell.
    ["note twice", [...observations, observations[firstNote]!]],
    // A note with no crossing before it.
    ["note without crossing", observations.filter((_, index) => index !== firstCross)],
    // A crossing whose note never came.
    ["note lost", observations.filter((_, index) => index !== firstNote)],
    // A later notice before any crossing.
    ["late before crossing", [{ op: "late", sub: subs[0]!, spell: 1 }, ...observations]],
  ];
  for (const [name, walk] of tampered) {
    const verdict = await checkTrace(walk, subs, join(dir, `tampered-${name.replaceAll(" ", "-")}`));
    expect(verdict, name).toBe("REJECTED");
  }
}, 120_000);

const races = Number(process.env.FX_TLA_QUIET_RACE ?? "0");
test.skipIf(races === 0)(`${races} walks close a subagent around its crossing`, async () => {
  for (let round = 0; round < races; round += 1) {
    // The first message goes out at about 0 ms and the crossing comes about
    // 1.8 s later; the close lands between 1 s and 2.6 s.
    const ms = 1_000 + Math.floor(Math.random() * 1_600);
    const walk: Walk = {
      name: `race-${round}`,
      subs: [{ name: "q1", spells: 1, late: false }, { name: "q2", spells: 1, late: false }],
      closeAtMs: { sub: "q1", ms },
    };
    const result = await runWalk(walk, dir);
    expectAccounted(walk, result);
    console.log(`quiet-relay race-${round}: close at ${ms} ms, ${result.crossings} crossings, ${result.posted} posted, ${result.dropped} dropped`);
  }
}, 600_000);

const stress = Number(process.env.FX_TLA_QUIET_STRESS ?? "0");
test.skipIf(stress === 0)(`${stress} subagents cross at once and each gets one note`, async () => {
  const walk: Walk = {
    name: `stress-${stress}`,
    subs: Array.from({ length: stress }, (_, n) => ({ name: `q${n + 1}`, spells: 1 as const, late: false })),
  };
  const result = await runWalk(walk, dir);
  expectAccounted(walk, result);
  expect(result.posted, walk.name).toBe(stress);
  for (const plan of walk.subs) expect(result.notesPer.get(plan.name) ?? 0, plan.name).toBe(1);
  console.log(`quiet-relay stress-${stress}: ${result.posted} notes in ${result.seconds}s`);
}, 600_000);
