// Drives the built fx along tests/tla/clipboard_read/ClipboardRead.tla.
//
// Each scenario starts zig-out/bin/fx (or FX_BIN) in tmux with a stub
// osascript first on PATH, an isolated HOME and FX_HOME, and a local fake
// gateway. The stub logs its pid, then waits for the driver to release it
// and writes a PNG or exits 1 as osascript does for an empty clipboard; it
// never reads the real clipboard. The driver presses keys, watches the pane
// and the stub's log, and records what fx did as steps of the design: the
// key it sent, the notice a paste showed, how osascript ended, and what
// reached the screen when the read was collected. A key fx does not read
// within WAIT_MS while osascript runs is recorded as Stalled.
//
// TLC then checks each run with TraceClipboardRead.tla: a run that is not a
// behavior of the design ends in a deadlock. fx before the clipboard read
// moved off the input loop fails every scenario, because a paste shows
// nothing until osascript exits.
//
//   bun tests/tla/drivers/clipboard_read/driver.ts [scenario...]
//
// Scenarios: image, no-image, timeout, quit. macOS only: fx reads clipboard
// images only there. Output goes to FX_TLA_OUT or a new temp folder.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, fxBin, outDir, runTlc, writeJson } from "../lib/tlc";
import { targetHelpers } from "../lib/context";

type Step = { name: string; key?: string; seen?: string; result?: string };

const WAIT_MS = 3_000;
const TIMEOUT_WAIT_MS = 16_000;
const SPEC_DIR = join(TLA_ROOT, "clipboard_read");
const PNG = join(REPO_ROOT, "tests", "e2e", "fixtures", "placeholder-logo.png");
const SCENARIOS = ["image", "no-image", "timeout", "quit"] as const;
type Scenario = (typeof SCENARIOS)[number];

if (process.platform !== "darwin") {
  console.log("clipboard_read driver: skipped, fx reads clipboard images only on macOS");
  process.exit(0);
}

const helpers = await targetHelpers();
const bin = fxBin();
const out = outDir("clipboard-read");

function writeStub(binDir: string, stubDir: string) {
  const stub = join(binDir, "osascript");
  writeFileSync(
    stub,
    [
      "#!/bin/sh",
      `dir='${stubDir}'`,
      "echo \"start $$\" >> \"$dir/log\"",
      "i=0",
      "while [ ! -e \"$dir/release\" ]; do",
      "  i=$((i + 1))",
      "  if [ \"$i\" -gt 600 ]; then echo \"gave-up $$\" >> \"$dir/log\"; exit 1; fi",
      "  sleep 0.05",
      "done",
      "out=$(printf '%s\\n' \"$2\" | sed -n 's/^set outFile to POSIX file \"\\(.*\\)\"$/\\1/p')",
      "if [ \"$(cat \"$dir/result\" 2>/dev/null)\" = image ] && [ -n \"$out\" ]; then",
      `  cp '${PNG}' "$out"`,
      "  echo \"exit 0 $$\" >> \"$dir/log\"",
      "  exit 0",
      "fi",
      "echo \"exit 1 $$\" >> \"$dir/log\"",
      "exit 1",
      "",
    ].join("\n"),
  );
  chmodSync(stub, 0o755);
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function until<T>(probe: () => T | null | undefined | false | Promise<T | null | undefined | false>, ms: number): Promise<T | null> {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await probe();
    if (value) return value as T;
    if (Date.now() > deadline) return null;
    await Bun.sleep(25);
  }
}

function count(text: string, needle: string): number {
  return text.split(needle).length - 1;
}

class Run {
  readonly steps: Step[] = [];
  readonly dir: string;
  readonly stubDir: string;
  readonly binDir: string;
  // Set once the run shows a step the design forbids; the scenario stops
  // there, and TLC rejects the trace.
  broken = false;
  beforePaste = "";
  session: any = null;
  gateway: any;

  constructor(readonly scenario: Scenario) {
    this.dir = join(out, scenario);
    mkdirSync(this.dir, { recursive: true });
    this.stubDir = join(this.dir, "stub");
    this.binDir = join(this.dir, "bin");
    mkdirSync(this.stubDir);
    mkdirSync(this.binDir);
    writeStub(this.binDir, this.stubDir);
  }

  stubLog(): string[] {
    const path = join(this.stubDir, "log");
    if (!existsSync(path)) return [];
    return readFileSync(path, "utf8").split("\n").filter((line) => line.length > 0);
  }

  starts(): number[] {
    return this.stubLog().filter((line) => line.startsWith("start ")).map((line) => Number(line.split(" ")[1]));
  }

  exited(pid: number): boolean {
    return this.stubLog().some((line) => line.startsWith("exit ") && line.endsWith(` ${pid}`));
  }

  async launch() {
    const work = mkdtempSync(join(this.dir, "work-"));
    const home = join(work, "home");
    const fxHome = join(work, "fx-home");
    mkdirSync(home);
    mkdirSync(fxHome);
    this.gateway = helpers.startDynamicFakeGateway(() => helpers.fakeGatewayFinalText("unused"));
    this.session = await helpers.TmuxSession.create({
      cmd: bin,
      cwd: work,
      stderrPath: join(this.dir, "stderr.log"),
      width: 120,
      height: 40,
      isolated: true,
      env: {
        HOME: home,
        FX_HOME: fxHome,
        PATH: `${this.binDir}:/usr/bin:/bin:/usr/sbin:/sbin`,
        TMPDIR: work,
        AI_GATEWAY_API_KEY: "fake-clipboard-driver-key",
        VERCEL_OIDC_TOKEN: undefined,
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_AUTO_UPGRADE: "0",
        FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
        FX_GATEWAY_BASE_URL: this.gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: this.gateway.chatUrl,
        FX_TRACE_LOG: join(this.dir, "trace.log"),
        FX_TRACE_SCOPES: "images,input",
      },
    });
    await this.session.waitForComposer(15_000);
  }

  async screen(): Promise<string> {
    return await this.session.captureFullScrollback();
  }

  async paste() {
    if (this.broken) return;
    const before = await this.screen();
    this.beforePaste = before;
    const busyBefore = count(before, "already reading clipboard");
    const readingBefore = count(before, "reading clipboard") - busyBefore;
    await this.session.sendKeys("C-v");
    this.steps.push({ name: "Press", key: "paste" });
    const seen = await until(async () => {
      const now = await this.screen();
      const busy = count(now, "already reading clipboard");
      if (busy > busyBefore) return "busy";
      if (count(now, "reading clipboard") - busy > readingBefore) return "reading";
      return null;
    }, WAIT_MS);
    // A silent paste is recorded and the scenario goes on, so the run also
    // shows whether keys typed next are read.
    this.steps.push({ name: "Paste", seen: seen ?? "none" });
  }

  async type(text: string) {
    if (this.broken) return;
    await this.session.sendLiteral(text);
    this.steps.push({ name: "Press", key: "text" });
    const read = await until(async () => (await this.session.capturePane()).includes(text), WAIT_MS);
    if (read) {
      this.steps.push({ name: "Read" });
    } else {
      this.steps.push({ name: "Stalled" });
      this.broken = true;
    }
  }

  async childStarted(index: number): Promise<number | null> {
    if (this.broken) return null;
    return await until(() => this.starts()[index], WAIT_MS);
  }

  async release(result: "image" | "no_image", pid: number) {
    if (this.broken) return;
    writeFileSync(join(this.stubDir, "result"), result === "image" ? "image" : "none");
    writeFileSync(join(this.stubDir, "release"), "");
    const ended = await until(() => this.exited(pid), WAIT_MS);
    if (!ended) {
      this.broken = true;
      return;
    }
    this.steps.push({ name: "ChildExits", result });
  }

  async timedOut(pid: number) {
    if (this.broken) return;
    const killed = await until(() => !alive(pid), TIMEOUT_WAIT_MS);
    if (!killed || this.exited(pid)) {
      this.broken = true;
      return;
    }
    this.steps.push({ name: "TimeOut" });
  }

  async collected(expect: "inserted" | "no_image" | "timed_out", imageNumber = 1) {
    if (this.broken) return;
    // Compared with the screen before the paste that started this read: the
    // notice can land before this call takes a look.
    const before = this.beforePaste;
    const needle = { no_image: "no image found on clipboard", timed_out: "clipboard read timed out" } as const;
    const seen = await until(async () => {
      if (expect === "inserted") return (await this.session.capturePane()).includes(`[Image ${imageNumber}]`);
      const key = needle[expect];
      return count(await this.screen(), key) > count(before, key);
    }, WAIT_MS);
    this.steps.push({ name: "Collect", seen: seen ? expect : "none" });
    if (!seen) this.broken = true;
  }

  async quit(pid: number) {
    if (this.broken) return;
    await this.session.sendText("/quit");
    this.steps.push({ name: "Press", key: "quit" });
    // waitForSessionEnd throws when the session is still running.
    const ended = await this.session.waitForSessionEnd(WAIT_MS).catch(() => false);
    if (!ended) {
      this.steps.push({ name: "Stalled" });
      this.broken = true;
      return;
    }
    this.session = null;
    this.steps.push({ name: "Quit" });
    const killed = await until(() => !alive(pid), WAIT_MS);
    this.steps.push(killed && !this.exited(pid) ? { name: "CancelKill" } : { name: "ChildExits", result: "no_image" });
    this.steps.push({ name: "Exit" });
  }

  async stop() {
    if (this.session) await this.session.kill();
    this.session = null;
    this.gateway?.stop();
    // A stub left waiting gives up on its own; release it now.
    writeFileSync(join(this.stubDir, "release"), "");
  }
}

async function drive(run: Run) {
  await run.launch();
  switch (run.scenario) {
    case "image": {
      writeFileSync(join(run.stubDir, "result"), "image");
      await run.paste();
      const pid = await run.childStarted(0);
      await run.type("typed while reading");
      await run.paste();
      if (pid !== null) await run.release("image", pid);
      await run.collected("inserted");
      if (run.starts().length !== 1) run.broken = true;
      break;
    }
    case "no-image": {
      await run.paste();
      const pid = await run.childStarted(0);
      if (pid !== null) await run.release("no_image", pid);
      await run.collected("no_image");
      break;
    }
    case "timeout": {
      await run.paste();
      const first = await run.childStarted(0);
      if (first !== null) await run.timedOut(first);
      await run.collected("timed_out");
      await run.paste();
      const second = await run.childStarted(1);
      if (second !== null) await run.release("no_image", second);
      await run.collected("no_image");
      break;
    }
    case "quit": {
      await run.paste();
      const pid = await run.childStarted(0);
      if (pid !== null) await run.quit(pid);
      break;
    }
  }
}

function tlaValue(step: Step): string {
  const fields = Object.entries(step).map(([name, value]) => `${name} |-> ${JSON.stringify(value)}`);
  return `[${fields.join(", ")}]`;
}

async function check(run: Run) {
  const tlcDir = join(run.dir, "tlc");
  mkdirSync(tlcDir, { recursive: true });
  writeFileSync(
    join(tlcDir, "ClipboardTraces.tla"),
    [
      "---- MODULE ClipboardTraces ----",
      `\\* fx ${bin}, scenario ${run.scenario}.`,
      `DriverTrace == <<${run.steps.map(tlaValue).join(",\n    ")}>>`,
      "====",
      "",
    ].join("\n"),
  );
  writeFileSync(
    join(tlcDir, "Driver.cfg"),
    "SPECIFICATION Spec\nCONSTANT Trace <- DriverTrace\nCHECK_DEADLOCK TRUE\nINVARIANT Safe\n",
  );
  return await runTlc(tlcDir, "TraceClipboardRead.tla", "Driver.cfg", ["ClipboardRead.tla", "TraceClipboardRead.tla"], SPEC_DIR);
}

const chosen = (process.argv.slice(2).length > 0 ? process.argv.slice(2) : [...SCENARIOS]) as Scenario[];
for (const name of chosen) {
  if (!SCENARIOS.includes(name)) throw new Error(`unknown scenario ${name}; choose from ${SCENARIOS.join(", ")}`);
}

console.log(`clipboard_read driver: fx ${bin}, output ${out}`);
const summary: Array<Record<string, unknown>> = [];
let failed = 0;
for (const name of chosen) {
  const run = new Run(name);
  const started = Date.now();
  try {
    await drive(run);
  } finally {
    await run.stop();
  }
  const chatRequests = run.gateway?.requests?.length ?? -1;
  const tlc = await check(run);
  const accepted = tlc.exitCode === 0;
  // No scenario submits a prompt, so the fake gateway must see no chat request.
  const ok = accepted && chatRequests === 0;
  if (!ok) failed += 1;
  const entry = {
    scenario: name,
    ok,
    accepted,
    chatRequests,
    osascriptStarts: run.starts().length,
    steps: run.steps,
    tlcExit: tlc.exitCode,
    distinctStates: tlc.distinctStates,
    ms: Date.now() - started,
  };
  summary.push(entry);
  writeJson(join(run.dir, "run.json"), entry);
  console.log(
    `${ok ? "ok  " : "FAIL"}  ${name}: ${run.steps.length} steps, TLC ${accepted ? "accepted" : `rejected (exit ${tlc.exitCode})`}, ` +
      `osascript starts ${run.starts().length}, chat requests ${chatRequests}, ${entry.ms} ms`,
  );
  if (!accepted) console.log(`      steps: ${run.steps.map((step) => step.name + (step.seen ? `(${step.seen})` : step.key ? `(${step.key})` : step.result ? `(${step.result})` : "")).join(" ")}`);
}
writeJson(join(out, "summary.json"), summary);
console.log(`${chosen.length - failed}/${chosen.length} scenarios accepted; summary ${join(out, "summary.json")}`);
process.exit(failed === 0 ? 0 : 1);
