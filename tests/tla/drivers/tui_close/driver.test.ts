// Drives the built fx through the close paths of design-a in tests/tla/tui_close.
//
// TLC writes the state graph of TuiClose.tla under design-a.cfg. Every close
// chain in the graph is a signal (INT, TERM, HUP) in a phase the real fx can be
// put into: idle, a turn in flight, the alternate screen open, or both. Each
// such phase runs once per signal in tmux, with the fake gateway holding the
// turn. The run is checked against the model's end state: the tty mode, the
// alternate screen, the clean record when a request was in flight, and how the
// process ended.
//
// Every reachable model state must be reached by a run or listed with the reason
// the driver cannot reach it. A state that is neither fails the test.
//
//   bun test ./tests/tla/drivers/tui_close/
//
// Needs tmux, Java with tla2tools.jar, and a built fx (FX_BIN or zig-out/bin/fx).
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, watch, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseValue } from "../graph.mjs";
import { TLA_ROOT, runTlc, writeJson } from "../lib/tlc";
import { artifacts, binary, shellQuote, targetHelpers, targetModule } from "../lib/context";

const TIMEOUT = 30_000;
const CLOSE_RECORDED_MARK = "fx-close-recorded";
const FULL_TRANSCRIPT_FOOTER = "esc close · pgup/pgdn scroll";
const SIGNALS = ["INT", "TERM", "HUP"] as const;
const SIGNUM: Record<string, number> = { INT: 2, TERM: 15, HUP: 1 };
const PHASES = ["idle", "turn", "alt", "turnalt", "shut_idle", "shut_turn", "err_shut"] as const;
const PHASE_PROMPT = (sig: string, phase: string) => `Close ${sig} during ${phase}.`;

type Model = Record<string, any>;
type Edge = { from: string; to: string; label: string };
type Phase = (typeof PHASES)[number];
type Observed = { tty: "cooked" | "raw"; screen: "normal" | "alt"; rec: "clean" | "none"; endCause: "signal" | "other"; status: number | null };

// The model states that a real run can be put into: either the steady event
// loop (run + ready) or the shutdown window held before disableRawMode
// (shut/errshut + release_modes), with the closer thread running and idle.
function runPhase(s: Model): Phase | null {
  if (s.closing || s.closeRuns !== 0 || !s.closerUp) return null;
  if (s.phase === "run") {
    if (s.loopBlocked || s.setup !== "ready") return null;
    const turn = s.req === "running";
    const alt = s.screen === "alt";
    if (turn) return alt ? "turnalt" : "turn";
    return alt ? "alt" : "idle";
  }
  if (s.stage !== "release_modes") return null;
  if (s.phase === "shut") return s.req === "running" ? "shut_turn" : "shut_idle";
  if (s.phase === "errshut" && s.req === "none") return "err_shut";
  return null;
}

async function loadGraph(dir: string) {
  const dot = readFileSync(join(dir, "graph.dot"), "utf8");
  const states = new Map<string, Model>();
  const next = new Map<string, Edge[]>();
  const prev = new Map<string, Edge[]>();
  const inits: string[] = [];
  const unescape = (label: string) => label.replace(/\\(.)/g, (_, char) => (char === "n" ? "\n" : char));
  for (const line of dot.split("\n")) {
    const edge = /^(-?\d+) -> (-?\d+) \[label="(\w+)"/.exec(line);
    if (edge) {
      const item = { from: edge[1]!, to: edge[2]!, label: edge[3]! };
      if (item.from === item.to) continue;
      if (!next.has(item.from)) next.set(item.from, []);
      if (!prev.has(item.to)) prev.set(item.to, []);
      next.get(item.from)!.push(item);
      prev.get(item.to)!.push(item);
      continue;
    }
    const node = /^(-?\d+) \[label="((?:[^"\\]|\\.)*)"(.*)$/.exec(line);
    if (!node) continue;
    const state: Model = {};
    for (const entry of unescape(node[2]!).split(/\n(?=\/\\ )/)) {
      const match = /^\/\\ (\w+) = ([\s\S]*)$/.exec(entry.trim());
      if (match) state[match[1]!] = parseValue(match[2]!.trim());
    }
    states.set(node[1]!, state);
    if (/style\s*=\s*filled/.test(node[3]!)) inits.push(node[1]!);
  }
  return { states, next, prev, inits };
}

// One close chain of the model: a close edge from a run or shutdown-window
// state, its closing state when the closer has two steps, and the ended state it
// reaches; plus the graceful completion path when SIGINT is ignored during /exit.
type Chain = { run: string; closing: string | null; ended: string; sig: string; phase: Phase | null };

function shutdownCompletionEnds(graph: Awaited<ReturnType<typeof loadGraph>>, start: string): string[] {
  const ends: string[] = [];
  const seen = new Set<string>([start]);
  const queue = [start];
  while (queue.length > 0) {
    const id = queue.shift()!;
    const s = graph.states.get(id)!;
    if (s.phase === "ended" && s.endCause === "user") {
      ends.push(id);
      continue;
    }
    for (const edge of graph.next.get(id) ?? []) {
      if (!["DisableRaw", "Persist", "UninstallAfterPersist", "Finish"].includes(edge.label)) continue;
      if (!seen.has(edge.to)) {
        seen.add(edge.to);
        queue.push(edge.to);
      }
    }
  }
  return ends;
}

function closeChains(graph: Awaited<ReturnType<typeof loadGraph>>): Chain[] {
  const chains: Chain[] = [];
  const state = (id: string) => graph.states.get(id)!;
  for (const [from, edges] of graph.next) {
    const phase = runPhase(state(from));
    for (const edge of edges) {
      if (edge.label === "CloseNow") {
        chains.push({ run: from, closing: null, ended: edge.to, sig: state(edge.to).closeSig, phase });
      }
      if (edge.label === "CloseStart") {
        for (const finish of graph.next.get(edge.to) ?? []) {
          if (finish.label !== "CloseFinish") continue;
          chains.push({ run: from, closing: edge.to, ended: finish.to, sig: state(edge.to).closeSig, phase });
        }
      }
    }
    if ((phase === "shut_idle" || phase === "shut_turn") && state(from).intDisp === "ign") {
      for (const ended of shutdownCompletionEnds(graph, from)) {
        chains.push({ run: from, closing: null, ended, sig: "INT", phase });
      }
    }
  }
  return chains;
}

function enabledTtyFlags(sttyOutput: string): string[] {
  const words = new Set(sttyOutput.split(/\s+/));
  return ["isig", "icanon", "echo"].filter((flag) => words.has(flag));
}

function alternateScreenOn(session: { name: string }): boolean {
  const state = execFileSync("tmux", ["display-message", "-p", "-t", `${session.name}:0.0`, "#{alternate_on}"], { encoding: "utf8" }).trim();
  return state === "1";
}

// The deadline ends a wait on a fx that hangs; it is not how the wait is met.
function within<T>(event: Promise<T>, label: string): Promise<T> {
  const expired = new Promise<never>((_, reject) => {
    AbortSignal.timeout(TIMEOUT).addEventListener("abort", () => reject(new Error(`timed out waiting for ${label}`)));
  });
  return Promise.race([event, expired]);
}

function waitForFile(path: string): Promise<void> {
  if (existsSync(path)) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const dir = join(path, "..");
    const signal = AbortSignal.timeout(TIMEOUT);
    const watcher = watch(dir, () => {
      if (existsSync(path)) {
        watcher.close();
        resolve();
      }
    });
    signal.addEventListener("abort", () => {
      watcher.close();
      reject(new Error(`timed out waiting for ${path} (exists=${existsSync(path)})`));
    });
    if (existsSync(path)) {
      watcher.close();
      resolve();
    }
  });
}

// The last clean-close flag saved in any session of `home`. A record that a
// later record cleared counts as not clean.
function lastRecordClean(home: string, saved: any): boolean {
  let last = false;
  if (!existsSync(saved.storeRoot(home))) return false;
  for (const id of saved.savedSessionIds(home)) {
    const text = readFileSync(join(saved.sessionDir(home, id), "log.jsonl"), "utf8");
    for (const line of text.split("\n").filter(Boolean)) {
      const entry = JSON.parse(line);
      if (entry.kind !== "item" || entry.type !== "recovery") continue;
      const hex = entry.data?.record;
      last = typeof hex === "string" && (Buffer.from(hex, "hex")[2]! & 1) !== 0;
    }
  }
  return last;
}

// One real run: fx under a wrapper that records the tty mode and the exit status
// once fx has ended. The pane stays open so the screen can be read afterwards.
async function realRun(helpers: any, saved: any, sig: string, phase: Phase): Promise<Observed & { ttyText: string }> {
  const root = realpathSync(mkdtempSync(join(tmpdir(), `fx-tla-close-${sig.toLowerCase()}-${phase}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ sandbox: "none", permission_mode: "auto", permission: {} }));
  const prompt = PHASE_PROMPT(sig, phase);
  let heldNow = () => {};
  const held = new Promise<void>((resolve) => (heldNow = resolve));
  const gateway = helpers.startDynamicFakeGateway(async (body: string) => {
    if (body.includes(prompt)) {
      heldNow();
      return new Promise<Response>(() => {});
    }
    return helpers.fakeGatewayFinalText("UNRELATED");
  });
  const stderrPath = join(root, "stderr.log");
  const ttyAfter = join(root, "tty-after.txt");
  const statusPath = join(root, "status.txt");
  const heldPath = join(root, "shutdown.held");
  const releasePath = join(root, "shutdown.release");
  const wrapper = join(root, "wrapper.sh");
  const isShutPhase = phase === "shut_idle" || phase === "shut_turn" || phase === "err_shut";
  if (phase === "err_shut") {
    writeFileSync(join(home, ".fx", "recordings"), "not-a-directory");
  }
  writeFileSync(stderrPath, "");
  writeFileSync(
    wrapper,
    [
      "#!/bin/sh",
      shellQuote(binary),
      "code=$?",
      `/bin/stty -a > ${shellQuote(`${ttyAfter}.tmp`)}`,
      `/bin/mv ${shellQuote(`${ttyAfter}.tmp`)} ${shellQuote(ttyAfter)}`,
      `printf '%s\\n' "$code" > ${shellQuote(`${statusPath}.tmp`)}`,
      `/bin/mv ${shellQuote(`${statusPath}.tmp`)} ${shellQuote(statusPath)}`,
      `echo ${CLOSE_RECORDED_MARK}`,
      'exit "$code"',
      "",
    ].join("\n"),
  );
  const session = await helpers.TmuxSession.create({
    cmd: `/bin/sh ${shellQuote(wrapper)}`,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-tui-close-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: helpers.FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      NO_COLOR: "1",
      ...(isShutPhase
        ? {
            FX_TEST_SHUTDOWN_RELEASE_HELD: heldPath,
            FX_TEST_SHUTDOWN_RELEASE_RELEASE: releasePath,
          }
        : {}),
      ...(phase === "err_shut" ? { FX_DEBUG_RECORD: "1" } : {}),
    },
    stderrPath,
    width: 100,
    height: 32,
    remainOnExit: true,
  });
  try {
    if (phase !== "err_shut") {
      await session.waitForComposer(TIMEOUT);
    }
    if (phase === "turn" || phase === "turnalt" || phase === "shut_turn") {
      await session.sendText(prompt);
      await within(held, "the held request");
    }
    if (phase === "alt" || phase === "turnalt") {
      await session.sendKeys("C-o");
      await session.waitForText(FULL_TRANSCRIPT_FOOTER, TIMEOUT);
    }
    if (phase === "shut_idle" || phase === "shut_turn") {
      await session.sendText("/exit");
    }
    if (isShutPhase) {
      await waitForFile(heldPath);
    }
    const wrapperPid = session.processPid();
    const children = execFileSync("pgrep", ["-P", String(wrapperPid)], { encoding: "utf8" }).trim().split("\n");
    if (children.length !== 1) throw new Error(`expected one child of wrapper ${wrapperPid}, saw ${children.length}`);
    process.kill(Number(children[0]), `SIG${sig}` as NodeJS.Signals);
    if ((phase === "shut_idle" || phase === "shut_turn") && sig === "INT") {
      writeFileSync(releasePath, "go");
    }
    await Promise.race([
      waitForFile(statusPath),
      session.waitForText(CLOSE_RECORDED_MARK, TIMEOUT).then(() => waitForFile(statusPath)),
    ]);
    const ttyText = readFileSync(ttyAfter, "utf8");
    const tty = enabledTtyFlags(ttyText).length === 3 ? "cooked" : "raw";
    const screen = alternateScreenOn(session) ? "alt" : "normal";
    const rec = lastRecordClean(home, saved) ? "clean" : "none";
    const status = Number(readFileSync(statusPath, "utf8").trim());
    return { tty, screen, rec, endCause: status === 128 + SIGNUM[sig]! ? "signal" : "other", status, ttyText };
  } finally {
    await session.kill();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

test.skipIf(!isTmux())("every reachable close of design-a is run or listed, and each run matches the model", async () => {
  const helpers = await targetHelpers();
  const saved = await targetModule("saved-sessions.ts");
  const dir = join(artifacts, "tlc");
  const run = await runTlc(dir, "TuiClose", "design-a.cfg", ["TuiClose.tla", "design-a.cfg"], join(TLA_ROOT, "tui_close"), ["-dump", "dot,actionlabels", "graph"]);
  expect(run.exitCode).toBe(0);
  expect(run.violated).toBeNull();
  const graph = await loadGraph(dir);
  const state = (id: string) => graph.states.get(id)!;
  const chains = closeChains(graph);

  // Each reachable model state gets one verdict: "run" with its key, or the
  // reason the driver cannot reach it.
  type Verdict = { kind: "run"; key: string } | { kind: "listed"; reason: string };
  const reasonOfRun = (s: Model): string | null => {
    if (!s.closerUp) return "the closer thread did not start, so the in-handler fallback runs; that needs thread creation to fail, which a signal cannot cause";
    if (s.loopBlocked) return "the event loop is blocked; design a never waits on the loop, and the flag is not visible from outside";
    if (s.exitWanted) return "a design-b graceful exit request; design a never sets it";
    return null;
  };
  const verdicts = new Map<string, Verdict>();
  const endedChains = new Map<string, Chain[]>();
  for (const chain of chains) {
    if (!endedChains.has(chain.ended)) endedChains.set(chain.ended, []);
    endedChains.get(chain.ended)!.push(chain);
  }
  const shutStageReason = (s: Model): string => {
    if (!s.closerUp) return "the closer thread did not start, so the in-handler fallback runs; that needs thread creation to fail, which a signal cannot cause";
    if (s.stage === "release") return "leaveAlternateScreens runs before the FX_TEST_SHUTDOWN_RELEASE_* hold; no external signal can pause inside it";
    if (s.stage === "persist") return "persistence finalization after disableRawMode runs too fast to time a signal without a separate hold";
    if (s.stage === "release_uninst" || s.stage === "done") return "the tail of shutdown after persistence has no hold hook";
    return "unclassified shutdown state";
  };
  const classify = (id: string): Verdict => {
    const s = state(id);
    if (s.phase === "ended") {
      const runs = (endedChains.get(id) ?? []).filter((chain) => chain.phase && SIGNALS.includes(chain.sig as any));
      if (runs.length > 0) return { kind: "run", key: `${runs[0]!.sig} ${runs[0]!.phase}` };
      if (s.endCause === "error") return { kind: "listed", reason: "error shutdown completed without a signal; this driver sends a signal at the hold" };
      const from = endedChains.get(id)?.[0]?.run;
      if (from) {
        const source = classify(from);
        if (source.kind === "listed") return source;
      }
      if (s.endCause === "user") return { kind: "listed", reason: "normal /exit without closerUp or from an unheld stage" };
      return { kind: "listed", reason: "a signal after handlers were removed at the end of shutdown: tty is already cooked and request settled" };
    }
    if (s.closing) return { kind: "listed", reason: "the closer has taken its first step and has not finished; the end is the only state the driver sees" };
    if (s.phase === "setup") return { kind: "listed", reason: "startup before the first frame: the handlers and raw mode are not both in place, and no signal can be timed there" };
    if (s.phase === "shut" || s.phase === "errshut") {
      const shutKey = runPhase(s);
      if (shutKey) return { kind: "run", key: shutKey };
      return { kind: "listed", reason: shutStageReason(s) };
    }
    const key = runPhase(s);
    if (key) return { kind: "run", key: `${key}` };
    const reason = reasonOfRun(s);
    if (reason) return { kind: "listed", reason };
    return { kind: "listed", reason: "unclassified run state" };
  };
  for (const id of graph.states.keys()) verdicts.set(id, classify(id));
  const unclassified = [...verdicts].filter(([, verdict]) => verdict.kind === "listed" && (verdict.reason === "unclassified run state" || verdict.reason === "unclassified shutdown state"));
  expect(unclassified.map(([id]) => id)).toEqual([]);

  // Each key a run covers must have model ends, and all model ends for one key
  // must expect the same end state.
  const expected = new Map<string, Observed & { states: string[] }>();
  for (const chain of chains) {
    if (!chain.phase || !SIGNALS.includes(chain.sig as any)) continue;
    const s = state(chain.ended);
    const key = `${chain.sig} ${chain.phase}`;
    const observed: Observed = {
      tty: s.tty === "cooked" ? "cooked" : "raw",
      screen: s.screen === "alt" ? "alt" : "normal",
      rec: s.rec === "clean" ? "clean" : "none",
      endCause: s.endCause === "signal" ? "signal" : "other",
      status: null,
    };
    const prior = expected.get(key);
    if (!prior) expected.set(key, { ...observed, states: [chain.ended] });
    else {
      const same = prior.tty === observed.tty && prior.screen === observed.screen && prior.rec === observed.rec && prior.endCause === observed.endCause;
      if (!same) throw new Error(`the model's ends for ${key} disagree: ${JSON.stringify(prior)} vs ${JSON.stringify(observed)}`);
      prior.states.push(chain.ended);
    }
  }

  const failures: string[] = [];
  const runs: Record<string, unknown> = {};
  for (const sig of SIGNALS) {
    for (const phase of PHASES) {
      const key = `${sig} ${phase}`;
      const model = expected.get(key);
      if (!model) {
        failures.push(`${key}: the driver runs it, but the model has no close for it`);
        continue;
      }
      const real = await realRun(helpers, saved, sig, phase);
      const wantStatus = model.endCause === "signal" ? 128 + SIGNUM[sig]! : 0;
      const want = { tty: model.tty, screen: model.screen, rec: model.rec, endCause: model.endCause, status: wantStatus };
      const got = { tty: real.tty, screen: real.screen, rec: real.rec, endCause: real.endCause, status: real.status };
      runs[key] = { model: want, real: got, modelStates: model.states, tty: real.ttyText };
      if (JSON.stringify(want) !== JSON.stringify(got)) failures.push(`${key}: model ${JSON.stringify(want)}, fx ${JSON.stringify(got)}`);
    }
  }

  const listed = [...verdicts].filter(([, verdict]) => verdict.kind === "listed").map(([id, verdict]) => ({ id, reason: (verdict as any).reason, vars: state(id) }));
  const covered = [...verdicts].filter(([, verdict]) => verdict.kind === "run").length;
  const byReason = new Map<string, number>();
  for (const item of listed) byReason.set(item.reason, (byReason.get(item.reason) ?? 0) + 1);
  const report = { states: graph.states.size, initial: graph.inits.length, covered, listed: listed.length, byReason: Object.fromEntries(byReason), runs, failures };
  writeJson(join(artifacts, "report.json"), report);
  writeFileSync(
    join(artifacts, "unreached.md"),
    [`# States the driver does not reach (${listed.length} of ${graph.states.size})`, "", ...listed.map((item) => `- ${item.id}: ${item.reason}. ${JSON.stringify(item.vars)}`), ""].join("\n"),
  );
  console.log(`model: ${graph.states.size} states, ${covered} reached by runs, ${listed.length} listed; report in ${artifacts}`);
  for (const [reason, count] of byReason) console.log(`  ${count} listed: ${reason}`);
  expect(failures).toEqual([]);
}, 20 * 60_000);

function isTmux(): boolean {
  try {
    execFileSync("tmux", ["-V"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}
