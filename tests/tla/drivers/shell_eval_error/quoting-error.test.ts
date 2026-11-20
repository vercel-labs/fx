// Runs the built fx with each login shell this machine has (zsh, bash 3.2, and a
// bash 4 or later when one is installed) through the quoting-error scenario of
// tests/e2e/ask-presentation.test.ts, hands fx's real output to the test's own
// matcher (tests/e2e/shell-eval-error.ts), and has TLC replay what happened
// through tests/tla/shell_eval_error/ShellEvalError.tla. No model calls: a local
// fake gateway serves the tool call.
//
// fx takes the login shell from the passwd entry, so login-shell.c is built into
// a library that DYLD_INSERT_LIBRARIES loads into fx to name the shell (macOS
// only; a machine without a shell is skipped and says why).
//
// 1. The matcher must agree with the model on every real run: it accepts the
//    quoting error of each shell, with a one-digit and a two-digit line number,
//    and rejects a run without the error.
// 2. Controls: planted wrong matchers (the pattern before the fix, one that
//    accepts any line, one fixed to line 7) and a tampered or empty observation
//    must be rejected.
// 3. Lines no shell here prints, such as bash 5's, the shape the PGSO log showed
//    for bash 3.2, and near misses, go through the matcher on any platform.
import { test } from "bun:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { artifacts, binary, targetHelpers, targetModule, testEnvironment } from "../lib/context";
import { runTlc, TLA_ROOT } from "../lib/tlc";

const helpers = await targetHelpers();
const { EVAL_ERROR_PREFIX } = (await targetModule("shell-eval-error.ts")) as { EVAL_ERROR_PREFIX: RegExp };
const SPEC_DIR = join(TLA_ROOT, "shell_eval_error");
const TIMEOUT = 300_000;
const GUIDANCE = "The shell could not parse this command";

type ShellClass = "zsh" | "bash32" | "bash5";
type LineClass = "evalLine1" | "devFd0Eval" | "bashEvalLine" | "none";
type Shell = { cls: ShellClass; path: string };
type Scenario = { name: string; kind: "error" | "clean"; command: string; aliases: number };
type Observation = {
  name: string;
  shell: ShellClass;
  shellPath: string;
  kind: "error" | "clean";
  line: LineClass;
  lineNumber: number | null;
  body: string;
  verdict: "pass" | "fail";
};

const CANDIDATES = ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"];

// A long startup file moves the line number bash reports to two digits.
const SCENARIOS: Scenario[] = [
  { name: "unclosed quote", kind: "error", command: 'echo "oops', aliases: 0 },
  { name: "unclosed quote after a long startup file", kind: "error", command: 'echo "oops', aliases: 40 },
  { name: "no error", kind: "clean", command: "echo fx-clean-run", aliases: 0 },
];

function shellClass(path: string): ShellClass | null {
  const probe = Bun.spawnSync([path, "--version"], { stdout: "pipe", stderr: "pipe", env: { PATH: process.env.PATH ?? "" } });
  const text = new TextDecoder().decode(probe.stdout);
  if (probe.exitCode !== 0) return null;
  if (basename(path) === "zsh") return "zsh";
  const major = /version (\d+)\./.exec(text)?.[1];
  if (major === undefined) return null;
  return Number(major) < 4 ? "bash32" : "bash5";
}

const notes: string[] = [];

function findShells(): Shell[] {
  const found = new Map<ShellClass, Shell>();
  for (const path of CANDIDATES) {
    if (!existsSync(path)) continue;
    const cls = shellClass(path);
    if (cls && !found.has(cls)) found.set(cls, { cls, path });
  }
  for (const cls of ["zsh", "bash32", "bash5"] as const) {
    if (!found.has(cls)) notes.push(`skipped ${cls}: not installed (looked at ${CANDIDATES.join(", ")})`);
  }
  return [...found.values()];
}

let library: string | null = null;
// ./login-shell.c, built once per run.
function loginShellLibrary(): string {
  if (library) return library;
  const out = join(artifacts, "login-shell.dylib");
  const source = join(import.meta.dirname, "login-shell.c");
  const built = Bun.spawnSync(["clang", "-dynamiclib", "-O2", "-Wall", "-Wextra", source, "-o", out]);
  assert.equal(built.exitCode, 0, `building the login-shell library failed: ${built.stderr.toString()}`);
  return (library = out);
}

function shellToolResult(body: string): { output_delta?: string; retry_guidance?: string; exit_code?: number } {
  const prompt = JSON.parse(body).prompt as Array<{ role: string; content: Array<{ type: string; output?: { value: string } }> }>;
  const message = prompt.filter((entry) => entry.role === "tool").at(-1);
  const part = message?.content.find((entry) => entry.type === "tool-result");
  assert.ok(part?.output, "the second request holds no shell tool result");
  return JSON.parse(part.output.value);
}

// The class of the first line a shell printed, by what the line looks like, and
// not by the matcher under test.
function classify(output: string): { line: LineClass; lineNumber: number | null } {
  const first = output.split("\n").find((entry) => entry.trim() !== "") ?? "";
  if (/^\(eval\):1: /.test(first)) return { line: "evalLine1", lineNumber: 1 };
  const fd = /^\/dev\/fd\/0: eval: line (\d+): /.exec(first);
  if (fd) return { line: "devFd0Eval", lineNumber: Number(fd[1]) };
  const bash = /^(?:\S*\/)?bash: eval: line (\d+): /.exec(first);
  if (bash) return { line: "bashEvalLine", lineNumber: Number(bash[1]) };
  return { line: "none", lineNumber: null };
}

async function runFx(shell: Shell, scenario: Scenario, index: number): Promise<Observation> {
  const label = `${shell.cls} / ${scenario.name}`;
  const root = mkdtempSync(join(artifacts, `run-${index}-`));
  const home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd);
  const startup = Array.from({ length: scenario.aliases }, (_, i) => `alias fx_tla_alias_${i}='true'\n`).join("");
  writeFileSync(join(home, ".zshrc"), startup);
  writeFileSync(join(home, ".bash_profile"), startup);
  const gateway = helpers.startFakeGateway([
    helpers.fakeGatewayToolCall("quoting", "shell", { request: { action: "run", command: scenario.command, yield_time_ms: 30_000 } }),
    helpers.fakeGatewayFinalText("Checked.\n"),
  ]);
  try {
    const child = Bun.spawn([binary, "ask", "--json", "--yolo", "--no-save", "Check the guidance."], {
      cwd,
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
      env: testEnvironment({
        HOME: home, FX_HOME: join(home, ".fx"), TMPDIR: root,
        AI_GATEWAY_API_KEY: "synthetic-shell-eval-error", FX_TEST_SKIP_ONBOARDING: "1", FX_PERMISSION_MODE: "auto",
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        DYLD_INSERT_LIBRARIES: loginShellLibrary(), FX_TLA_LOGIN_SHELL: shell.path,
      }),
    });
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    writeFileSync(join(root, "stdout.json"), stdout);
    writeFileSync(join(root, "stderr.txt"), stderr);
    assert.equal(code, 0, `${label}: fx exited ${code}\n${stderr}`);
    assert.ok(!stderr.includes("shell snapshot unavailable"), `${label}: the snapshot fell back\n${stderr}`);
    // The fake gateway must have counted the tool call and the answer after it.
    assert.equal(gateway.requests.length, 2, `${label}: the gateway saw ${gateway.requests.length} requests\n${stderr}`);
    const body = gateway.requests[1]!.body;
    writeFileSync(join(root, "request.json"), body);
    const result = shellToolResult(body);
    // fx names the login shell it runs in the turn context of every request.
    assert.ok(body.includes(`shell_path: ${shell.path}\\n`), `${label}: fx did not run ${shell.path} as the login shell`);
    const { line, lineNumber } = classify(result.output_delta ?? "");
    if (scenario.kind === "error") {
      assert.ok(result.retry_guidance?.includes(GUIDANCE), `${label}: no rewrite guidance in ${JSON.stringify(result)}`);
    } else {
      assert.equal(result.retry_guidance, undefined, `${label}: guidance for a clean run`);
    }
    EVAL_ERROR_PREFIX.lastIndex = 0;
    const verdict = EVAL_ERROR_PREFIX.test(body) ? "pass" : "fail";
    return { name: scenario.name, shell: shell.cls, shellPath: shell.path, kind: scenario.kind, line, lineNumber, body, verdict };
  } finally {
    gateway.stop();
  }
}

function observedModule(observed: Pick<Observation, "name" | "shell" | "shellPath" | "kind" | "line" | "verdict">[]): string {
  const rows = observed.map((o) =>
    `  \\* ${o.shell} ${o.shellPath}: ${o.name}\n  [shell |-> "${o.shell}", kind |-> "${o.kind}", line |-> "${o.line}", verdict |-> "${o.verdict}"]`);
  const runs = rows.length > 0 ? `<<\n${rows.join(",\n")}\n>>` : "<< >>";
  return `---- MODULE ShellEvalErrorObserved ----\nEXTENDS ShellEvalError\nObservedRuns == ${runs}\n====\n`;
}

/// ACCEPTED when TLC replays every observed run through the model.
async function replay(observed: Parameters<typeof observedModule>[0], label: string): Promise<"ACCEPTED" | "REJECTED"> {
  const dir = join(artifacts, "tlc", label);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "ShellEvalErrorObserved.tla"), observedModule(observed));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    "  Accepted <- FixedAccepted",
    "  Observed <- ObservedRuns",
    "INVARIANT NotAllMatched",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "ShellEvalErrorObserved", "trace.cfg", ["ShellEvalError.tla"], SPEC_DIR, ["-deadlock"]);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return "ACCEPTED";
  assert.equal(run.exitCode, 0, `TLC failed for ${label}:\n${run.output}`);
  return "REJECTED";
}

function table(observed: Observation[]): string {
  return observed.map((o) => `${o.shell.padEnd(7)} ${o.kind.padEnd(6)} ${o.line.padEnd(13)} line ${String(o.lineNumber ?? "-").padEnd(3)} ${o.verdict}  ${o.name}`).join("\n");
}

const supported = process.platform === "darwin";
if (!supported) console.log("skipped every shell: the login shell is replaced with DYLD_INSERT_LIBRARIES, which needs macOS");

let observed: Promise<Observation[]> | undefined;
function observations(): Promise<Observation[]> {
  observed ??= (async () => {
    const shells = findShells();
    const runs: Observation[] = [];
    for (const shell of shells) {
      for (const scenario of SCENARIOS) runs.push(await runFx(shell, scenario, runs.length));
    }
    for (const note of notes) console.log(note);
    console.log(`${runs.length} runs in ${shells.map((s) => `${s.cls} (${s.path})`).join(", ")}\n${table(runs)}\n${artifacts}`);
    assert.ok(runs.length > 0, "no login shell to run");
    return runs;
  })();
  return observed;
}

test.skipIf(!supported)("the test's matcher accepts the quoting error of every login shell here, and TLC accepts the runs", async () => {
  const runs = await observations();
  // The two-digit line number the long startup file is meant to produce.
  for (const run of runs.filter((r) => r.shell === "bash32" && r.name.includes("long startup"))) {
    assert.ok((run.lineNumber ?? 0) >= 10, `bash 3.2 reported line ${run.lineNumber} after a long startup file`);
  }
  assert.equal(await replay(runs, "real"), "ACCEPTED", `TLC did not accept the runs:\n${table(runs)}`);
}, TIMEOUT);

// A wrong matcher judges the same real output; TLC must refuse the runs. A
// matcher is checked only when the machine has the run that tells it apart.
const MUTANTS: Array<{ name: string; pattern: RegExp; needs: (o: Observation) => boolean }> = [
  { name: "the pattern before the fix", pattern: /\(eval\):1:|\/dev\/fd\/0: eval:/, needs: (o) => o.shell === "bash32" && o.kind === "error" },
  { name: "a pattern that accepts any line", pattern: /(?:)/, needs: (o) => o.kind === "clean" },
  {
    name: "a pattern fixed to line 7",
    pattern: /\(eval\):1:|\/dev\/fd\/0: eval:|bash: eval: line 7:/,
    needs: (o) => o.shell === "bash32" && o.lineNumber !== 7,
  },
];

test.skipIf(!supported)("controls: planted wrong matchers and a tampered or empty observation are rejected", async () => {
  const runs = await observations();
  for (const mutant of MUTANTS) {
    if (!runs.some(mutant.needs)) {
      console.log(`skipped the control for ${mutant.name}: no run on this machine tells it apart`);
      continue;
    }
    const judged = runs.map((r) => ({ ...r, verdict: mutant.pattern.test(r.body) ? "pass" as const : "fail" as const }));
    assert.equal(await replay(judged, `mutant-${MUTANTS.indexOf(mutant)}`), "REJECTED", `TLC accepted ${mutant.name}`);
  }
  const first = runs[0]!;
  const tampered = [{ ...first, verdict: first.verdict === "pass" ? "fail" as const : "pass" as const }, ...runs.slice(1)];
  assert.equal(await replay(tampered, "tampered"), "REJECTED", "TLC accepted a flipped verdict");
  assert.equal(await replay([], "empty"), "REJECTED", "TLC accepted an empty observation");
}, TIMEOUT);

// Lines that shells print, written out so the matcher meets the ones this
// machine cannot make: bash 5's, from the tests in src/tools/shell/shell.zig, and
// the shape the PGSO log showed for bash 3.2, plus near misses that are not the
// quoting error. The matcher sees the line inside a JSON request body.
const LINES: Array<[string, string, boolean]> = [
  ["zsh", '(eval):1: unmatched "', true],
  ["bash 5", "/dev/fd/0: eval: line 2: unexpected EOF while looking for matching `\"'", true],
  ["bash 3.2 as the PGSO log showed it", "bash: eval: line 7: unexpected EOF while looking for matching `\"'", true],
  ["bash 3.2 with a long path and a long line number", "/usr/local/bin/bash: eval: line 123: syntax error: unexpected end of file", true],
  ["a bash run-time error, which does not name eval", '/dev/fd/0: line 3: 1 +  : syntax error: operand expected (error token is " ")', false],
  ["an eval error with no line number", "bash: eval: -x: invalid option", false],
  ["a command's own output", "fx-clean-run", false],
];

test("the test's matcher judges written-out shell lines", () => {
  for (const [name, text, accepted] of LINES) {
    EVAL_ERROR_PREFIX.lastIndex = 0;
    assert.equal(EVAL_ERROR_PREFIX.test(JSON.stringify(text)), accepted, `${name}: ${text}`);
  }
});
