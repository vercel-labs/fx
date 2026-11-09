// Runs the built fx binary along tests/tla/tool_admission/RoutineNames.tla and
// has TLC check every turn it observes (RoutineNamesTrace.tla).
//
// Each turn is one `fx ask --json --no-save` in auto mode against a local fake
// gateway, in a temporary HOME, ZDOTDIR, and FX_HOME. The startup files
// (.zshrc and .bash_profile, so either login shell reads them) may alias git
// to `echo fx-alias-ran`, and may make the first login shell exit so the
// snapshot capture fails. The gateway's model replies with the turn's shell
// calls one at a time: a routine `git status`, the same with reload=true,
// `echo`, or an edit that adds or removes the alias. Its reviewer clears or
// holds each reviewed call as the turn plans. Every call carries a step-N
// word, so the reviewer and the driver know which call is which.
//
// For each call the driver records whether fx reviewed it and what happened:
// held, refused with the stale-approval result, ran with the alias, or ran
// for real. A capture fails only in a turn whose startup files plant the
// guard, so the model may fail at most that one. A turn may also break every
// snapshot replay (the startup files define a global alias for `setopt`, so the
// replayed option lines do not parse) and move ZDOTDIR: ~/.zshenv sets it to a
// folder that fx's own environment does not name, and the startup files live
// there. Those turns need zsh as the login shell. TLC replays the turn
// through the model's own actions with the fixed rule (Design "fixed"). --self-check also replays each turn that fx
// before the fix gets wrong through Design "main", which must reject it, and each
// turn that fx before the moved-ZDOTDIR repair gets wrong through Design
// "late_check", which must reject it.
// --random N adds N seeded turns, and --stress N one turn with N calls.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/tool_admission/driver.ts
//   bun tests/tla/drivers/tool_admission/driver.ts --self-check
//   bun tests/tla/drivers/tool_admission/driver.ts --random 40 --seed 7 --jobs 4
//   bun tests/tla/drivers/tool_admission/driver.ts --random 0 --stress 200
//   FX_BIN=/path/to/other/fx bun tests/tla/drivers/tool_admission/driver.ts
//
// Exit codes: 0 every turn accepted (and the self-check rejected), 1 a turn the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, tlcToolchain, writeJson } from "../lib/tlc";

type StepKind = "git" | "git_reload" | "warm" | "alias_on" | "alias_off";
type Plan = { kind: StepKind; hold: boolean };
type Turn = {
  id: string;
  startAliased: boolean;
  failFirstCapture: boolean;
  // The startup files set ZDOTDIR to a folder fx's own environment does not name.
  moved?: boolean;
  // Every snapshot replay fails before its command starts.
  brokenReplay?: boolean;
  steps: Plan[];
  // fx before the fix gets this turn wrong, so Design "main" must reject it.
  fixedByChange: boolean;
  // fx before the moved-ZDOTDIR repair gets this turn wrong, so Design "late_check" must reject it.
  lateCheckRejects?: boolean;
};
type Outcome = "alias" | "real" | "refused" | "held";
type ObservedStep = {
  kind: "git" | "nonroutine";
  reload: boolean;
  effect: "none" | "alias_on" | "alias_off";
  reviewed: boolean;
  outcome: Outcome;
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const MODEL = "openai/gpt-5";
const ALIAS_OUTPUT = "fx-alias-ran";
const ALIAS_LINE = `alias git='echo ${ALIAS_OUTPUT}'`;
const NO_ALIAS = "# no aliases\n";
// A global alias for the word `setopt` makes the replayed `\builtin setopt ...`
// option lines a parse error, so the replay stops before the command starts.
// The capture shell prints those lines inside quotes and still succeeds.
const BREAK_REPLAY = "alias -g setopt=';;'\n";
const STALE_APPROVAL = "the shell startup files changed after it was approved";
const CAPTURE_GUARD =
  'if [ ! -e "$HOME/.fx-driver-capture-failed" ]; then : > "$HOME/.fx-driver-capture-failed"; exit 7; fi\n';
const tlaDir = join(TLA_ROOT, "tool_admission");
const zshAvailable = existsSync("/bin/zsh");

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  random: option("--random", 12),
  seed: option("--seed", 1),
  jobs: option("--jobs", 4),
  stress: option("--stress", 0),
};

// mulberry32: a small seeded generator, so a failing random turn replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const step = (kind: StepKind, hold = false): Plan => ({ kind, hold });

// The examiner's runs (#258): A, the first command; B, after a warm-up; C,
// after an edit during the turn. Then reloads, a removed alias, a failed
// capture, and a control with no alias.
function namedTurns(): Turn[] {
  return [
    { id: "first-alias", startAliased: true, failFirstCapture: false, steps: [step("git", true)], fixedByChange: true },
    { id: "first-alias-cleared", startAliased: true, failFirstCapture: false, steps: [step("git")], fixedByChange: true },
    { id: "warm-then-alias", startAliased: true, failFirstCapture: false, steps: [step("warm"), step("git", true)], fixedByChange: false },
    {
      id: "edit-then-git",
      startAliased: false,
      failFirstCapture: false,
      steps: [step("warm"), step("alias_on"), step("git", true)],
      fixedByChange: true,
    },
    { id: "reload", startAliased: false, failFirstCapture: false, steps: [step("git_reload", true)], fixedByChange: true },
    {
      id: "edit-then-reload",
      startAliased: false,
      failFirstCapture: false,
      steps: [step("alias_on"), step("git_reload", true)],
      fixedByChange: true,
    },
    {
      id: "alias-removed",
      startAliased: true,
      failFirstCapture: false,
      steps: [step("git"), step("alias_off"), step("git")],
      fixedByChange: true,
    },
    { id: "capture-fails", startAliased: true, failFirstCapture: true, steps: [step("git"), step("git", true)], fixedByChange: true },
    { id: "no-alias", startAliased: false, failFirstCapture: false, steps: [step("git"), step("git"), step("warm")], fixedByChange: false },
    // A moved ZDOTDIR changes nothing while the replay works.
    { id: "moved-zdotdir", startAliased: false, failFirstCapture: false, moved: true, steps: [step("git"), step("git")], fixedByChange: false },
    // Every replay fails: the first command reruns with full startup, and the failed state sends the next one to review.
    { id: "broken-replay", startAliased: false, failFirstCapture: false, brokenReplay: true, steps: [step("git"), step("git")], fixedByChange: false },
    // The same with ZDOTDIR moved (the examiner's run r8 on #1748): nothing changed, so no
    // routine command is refused, and each one that follows recaptures and runs.
    {
      id: "broken-replay-moved",
      startAliased: false,
      failFirstCapture: false,
      moved: true,
      brokenReplay: true,
      steps: [step("git"), step("git"), step("git")],
      fixedByChange: false,
      lateCheckRejects: true,
    },
    // An edit to the moved startup files after a failed replay still reaches review.
    {
      id: "broken-replay-moved-edit",
      startAliased: false,
      failFirstCapture: false,
      moved: true,
      brokenReplay: true,
      steps: [step("git"), step("alias_on"), step("git", true)],
      fixedByChange: false,
      lateCheckRejects: true,
    },
  ];
}

const RANDOM_KINDS: StepKind[] = ["git", "git", "git", "git_reload", "warm", "alias_on", "alias_off"];

function randomSteps(next: () => number, length: number): Plan[] {
  return Array.from({ length }, () => {
    const kind = RANDOM_KINDS[Math.floor(next() * RANDOM_KINDS.length)]!;
    return step(kind, kind.startsWith("git") && next() < 0.5);
  });
}

function turns(): Turn[] {
  // The moved and broken-replay turns need zsh as the login shell.
  const result = namedTurns().filter((turn) => zshAvailable || !(turn.moved || turn.brokenReplay));
  const next = generator(options.seed);
  for (let i = 0; i < options.random; i++) {
    result.push({
      id: `random-${options.seed}-${i}`,
      startAliased: next() < 0.5,
      failFirstCapture: next() < 0.15,
      steps: randomSteps(next, 1 + Math.floor(next() * 6)),
      fixedByChange: false,
      moved: zshAvailable && next() < 0.3,
      brokenReplay: zshAvailable && next() < 0.25,
    });
  }
  if (options.stress > 0) {
    result.push({
      id: `stress-${options.stress}`,
      startAliased: false,
      failFirstCapture: false,
      moved: zshAvailable,
      brokenReplay: zshAvailable,
      steps: randomSteps(generator(options.seed + 1), options.stress),
      fixedByChange: false,
    });
  }
  return result;
}

function shellWord(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function command(plan: Plan, index: number, startupFiles: string[], noAlias: string): string {
  const tag = `step-${index}`;
  switch (plan.kind) {
    case "git":
    case "git_reload":
      return `git status --short -- ${tag}`;
    case "warm":
      return `echo warm ${tag}`;
    case "alias_on":
      return [`: ${tag}`, ...startupFiles.map((file) => `printf '%s\\n' ${shellWord(ALIAS_LINE)} >> ${shellWord(file)}`)].join(" && ");
    case "alias_off":
      return [`: ${tag}`, ...startupFiles.map((file) => `printf '%s' ${shellWord(noAlias)} > ${shellWord(file)}`)].join(" && ");
  }
}

function observedKind(plan: Plan): Pick<ObservedStep, "kind" | "reload" | "effect"> {
  switch (plan.kind) {
    case "git":
      return { kind: "git", reload: false, effect: "none" };
    case "git_reload":
      return { kind: "git", reload: true, effect: "none" };
    case "warm":
      return { kind: "nonroutine", reload: false, effect: "none" };
    case "alias_on":
    case "alias_off":
      return { kind: "nonroutine", reload: false, effect: plan.kind };
  }
}

function toolResult(body: string, toolCallId: string): { type: string; text: string } | null {
  const request = JSON.parse(body) as { prompt?: Array<{ content?: unknown }> };
  for (const message of request.prompt ?? []) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, any>>) {
      if (part.type !== "tool-result" || part.toolCallId !== toolCallId) continue;
      const output = part.output as Record<string, unknown>;
      const text = String(output.type === "execution-denied" ? output.reason : output.value);
      return { type: String(output.type), text };
    }
  }
  return null;
}

// The shell tool's result is JSON text. A refusal carries exit code 126 and,
// depending on the call, the stale-approval message.
function exitCodeOf(text: string): number | null {
  try {
    const code = (JSON.parse(text) as { exit_code?: unknown }).exit_code;
    return typeof code === "number" ? code : null;
  } catch {
    return null;
  }
}

function classify(result: { type: string; text: string }): Outcome {
  if (result.type === "execution-denied") return "held";
  if (result.text.includes(STALE_APPROVAL) || exitCodeOf(result.text) === 126) return "refused";
  if (result.text.includes(ALIAS_OUTPUT)) return "alias";
  return "real";
}

class HarnessError extends Error {}

async function runTurn(helpers: any, turn: Turn, scratch: string): Promise<{ observed: ObservedStep[]; seconds: number }> {
  const root = mkdtempSync(join(scratch, `${turn.id}-`));
  const home = join(root, "home");
  const fxHome = join(root, "fx-home");
  const workspace = join(root, "workspace");
  const tmp = join(root, "tmp");
  for (const dir of [home, fxHome, workspace, tmp]) mkdirSync(dir, { recursive: true });
  writeFileSync(join(fxHome, "settings.json"), JSON.stringify({ sandbox: "none", permission: {} }));
  // A moved ZDOTDIR: fx's own environment names `home`, and ~/.zshenv moves it.
  const zshDir = turn.moved ? join(home, "moved-zdotdir") : home;
  if (turn.moved) {
    mkdirSync(zshDir, { recursive: true });
    writeFileSync(join(home, ".zshenv"), 'export ZDOTDIR="$HOME/moved-zdotdir"\n');
  }
  const startupFiles = [join(zshDir, ".zshrc"), join(home, ".bash_profile")];
  const noAlias = NO_ALIAS + (turn.brokenReplay ? BREAK_REPLAY : "");
  const guard = turn.failFirstCapture ? CAPTURE_GUARD : "";
  const base = turn.startAliased ? `${ALIAS_LINE}\n` : NO_ALIAS;
  writeFileSync(startupFiles[0]!, guard + base + (turn.brokenReplay ? BREAK_REPLAY : ""));
  // bash has no global aliases, and the broken-replay turns need zsh as the login shell.
  writeFileSync(startupFiles[1]!, guard + base);
  const init = Bun.spawnSync(["/usr/bin/git", "init", "--quiet"], {
    cwd: workspace,
    env: { HOME: home, PATH: "/usr/bin:/bin" },
  });
  if (init.exitCode !== 0) throw new HarnessError(`git init failed: ${init.stderr.toString()}`);

  const callId = (index: number) => `call_${index}_x`;
  const results: Array<{ type: string; text: string } | null> = [];
  const reviewed = new Set<number>();
  // A throw inside the fake gateway reaches fx as a failed review, so the
  // reviewer records its problem here and the turn fails afterwards.
  let reviewerProblem: string | null = null;
  let served = 0;
  const gateway = helpers.startDynamicFakeGateway(
    (body: string) => {
      if (served > 0 && served <= turn.steps.length) results[served - 1] = toolResult(body, callId(served - 1));
      if (served < turn.steps.length) {
        const index = served++;
        const plan = turn.steps[index]!;
        return helpers.fakeGatewayToolCall(callId(index), "shell", {
          request: {
            action: "run",
            command: command(plan, index, startupFiles, noAlias),
            yield_time_ms: 30_000,
            ...(plan.kind === "git_reload" ? { reload: true } : {}),
          },
        });
      }
      served++;
      return helpers.fakeGatewayFinalText(`turn ${turn.id} done`);
    },
    {
      models: [{ id: MODEL, type: "language", tags: ["tool-use"] }],
      classifierResponses: Array.from({ length: turn.steps.length * 2 + 4 }, () => (body: string) => {
        const line = helpers.reviewedActionEvidence(body) as string;
        const match = /step-(\d+)/.exec(line);
        const index = match ? Number(match[1]) : -1;
        if (!turn.steps[index]) {
          reviewerProblem ??= `review of an unplanned call: ${line}`;
          return helpers.fakeGatewayPermissionDecision("clear", "unplanned", "unplanned review");
        }
        reviewed.add(index);
        return turn.steps[index]!.hold
          ? helpers.fakeGatewayHeldDecision(`hold_${index}`, "planned hold")(body)
          : helpers.fakeGatewayPermissionDecision("clear", `clear_${index}`, "planned clear");
      }),
    },
  );
  try {
    const started = performance.now();
    // Every variable written out; nothing is inherited from the driver.
    const child = Bun.spawn([binary, "ask", "--json", "--no-save", "Run the planned shell calls."], {
      cwd: workspace,
      env: {
        HOME: home,
        ZDOTDIR: home,
        FX_HOME: fxHome,
        PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
        TMPDIR: tmp,
        TERM: "dumb",
        NO_COLOR: "1",
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_E2E_DISABLE_DOTENV: "1",
        FX_PERMISSION_MODE: "auto",
        FX_MODEL: MODEL,
        AI_GATEWAY_API_KEY: "fake-routine-names-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 60_000 + turn.steps.length * 5_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    writeFileSync(join(root, "fx.stdout"), stdout);
    writeFileSync(join(root, "fx.stderr"), stderr);
    if (reviewerProblem) throw new HarnessError(`${turn.id}: ${reviewerProblem}; see ${root}`);
    // The fake gateway must have served every planned call and the final
    // answer, or this run says nothing about the model.
    if (exit !== 0 || gateway.requests.length !== turn.steps.length + 1) {
      throw new HarnessError(
        `${turn.id}: fx exited ${exit} after ${gateway.requests.length} model requests ` +
          `(expected ${turn.steps.length + 1}); see ${root}`,
      );
    }
    const observed = turn.steps.map((plan, index) => {
      const result = results[index];
      if (!result) throw new HarnessError(`${turn.id}: no tool result for step ${index}; see ${root}`);
      return { ...observedKind(plan), reviewed: reviewed.has(index), outcome: classify(result) };
    });
    rmSync(root, { recursive: true, force: true });
    return { observed, seconds };
  } finally {
    gateway.stop();
  }
}

function tlaValue(value: unknown): string {
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `<<${value.map(tlaValue).join(", ")}>>`;
  const entries = Object.entries(value as Record<string, unknown>);
  return `[${entries.map(([key, entry]) => `${key} |-> ${tlaValue(entry)}`).join(", ")}]`;
}

async function check(dir: string, turn: Turn, observed: ObservedStep[], design: "fixed" | "main" | "late_check"): Promise<Verdict> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "RoutineNamesObserved.tla"),
    "---- MODULE RoutineNamesObserved ----\n" +
      `Observed == ${tlaValue({ start: turn.startAliased, moved: !!turn.moved, brokenReplay: !!turn.brokenReplay, failFirstCapture: turn.failFirstCapture, steps: observed })}\n` +
      "====\n",
  );
  writeFileSync(
    join(dir, "RoutineNamesTrace.cfg"),
    [
      "CONSTANTS",
      "    Cmds <- TraceCmds",
      "    MaxEdits = 0",
      "    MaxReloads = 0",
      // The startup files make a capture fail only in a turn that plants
      // the guard, and then only the first one, so failures are observed too.
      // A broken replay fails once per call at most.
      `    MaxFails = ${(turn.failFirstCapture ? 1 : 0) + (turn.brokenReplay ? observed.length : 0)}`,
      `    MaxGen = ${(turn.brokenReplay ? 3 : 2) * observed.length + 2}`,
      `    Design = "${design}"`,
      "INIT TraceInit",
      "NEXT TraceNext",
      "INVARIANT NotAllMatched",
      "",
    ].join("\n"),
  );
  const run = await runTlc(dir, "RoutineNamesTrace.tla", "RoutineNamesTrace.cfg", ["RoutineNames.tla", "RoutineNamesTrace.tla"], tlaDir, ["-deadlock"]);
  if (run.violated === "NotAllMatched") return "ACCEPTED";
  if (run.exitCode === 0) return "REJECTED";
  return "TOOL_ERROR";
}

async function pool<T, R>(items: T[], jobs: number, work: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.max(1, Math.min(jobs, items.length)) }, async () => {
      while (next < items.length) {
        const index = next++;
        results[index] = await work(items[index]!);
      }
    }),
  );
  return results;
}

async function main(): Promise<number> {
  const toolchain = tlcToolchain();
  const helpers = await targetHelpers();
  const out = outDir("tool-admission");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const planned = turns();
  console.log(`binary: ${binary}`);
  console.log(`output: ${out}`);
  console.log(`turns: ${planned.length} (seed ${options.seed}, random ${options.random}, stress ${options.stress})`);

  let harnessFailed = false;
  const reports = await pool(planned, options.jobs, async (turn) => {
    try {
      const { observed, seconds } = await runTurn(helpers, turn, scratch);
      const fixed = await check(join(out, "tlc", turn.id, "fixed"), turn, observed, "fixed");
      const main =
        options.selfCheck && turn.fixedByChange
          ? await check(join(out, "tlc", turn.id, "main"), turn, observed, "main")
          : null;
      const late =
        options.selfCheck && turn.lateCheckRejects
          ? await check(join(out, "tlc", turn.id, "late_check"), turn, observed, "late_check")
          : null;
      return { id: turn.id, turn, observed, seconds, fixed, main, late };
    } catch (error) {
      if (!(error instanceof HarnessError)) throw error;
      harnessFailed = true;
      return { id: turn.id, turn, observed: [], seconds: 0, fixed: "TOOL_ERROR" as Verdict, main: null, late: null, error: error.message };
    }
  });

  let failed = false;
  for (const report of reports) {
    const summary = report.observed.map((s) => `${s.kind}${s.reload ? "+reload" : ""}${s.effect === "none" ? "" : `:${s.effect}`}=${s.reviewed ? "reviewed/" : ""}${s.outcome}`).join(" ");
    const mainNote = report.main ? ` main=${report.main}` : "";
    const lateNote = report.late ? ` late_check=${report.late}` : "";
    console.log(`${report.fixed.padEnd(10)} ${report.id} (${report.seconds}s)${mainNote}${lateNote}  ${summary}${"error" in report ? `  ${report.error}` : ""}`);
    if (report.fixed !== "ACCEPTED") failed = true;
    if (report.main && report.main !== "REJECTED") failed = true;
    if (report.late && report.late !== "REJECTED") failed = true;
  }
  writeJson(join(out, "report.json"), { binary, toolchain, options, reports });
  console.log(`report: ${join(out, "report.json")}`);
  if (harnessFailed || reports.some((r) => r.fixed === "TOOL_ERROR" || r.main === "TOOL_ERROR" || r.late === "TOOL_ERROR")) return 2;
  return failed ? 1 : 0;
}

process.exit(await main());
