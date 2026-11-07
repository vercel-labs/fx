// Footer reclaim, runtime to spec: runs event scripts through the real
// TranscriptRuntime ("footer reclaim runtime trace driver" in
// src/ui/resize_tests.zig, built from src/footer_reclaim_root.zig) and has
// TLC check every run against FooterReclaim.tla through
// TraceFooterReclaim.tla. Each script writes rows, opens and closes the slash
// picker, resizes the window, takes the screen over and gives it back, and
// ends with what exit and suspend do before they erase the footer. Besides TLC, the run fails when a written row is in
// native history plus the screen other than exactly once after exit, which
// the resize harness's physical history probe counts from the bytes fx wrote.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT } from "../lib/tlc.ts";
import { checkTlc, seededRandom, specFiles, toTla, type CheckedTlc } from "./lib.ts";

type State = {
  rows: number;
  written: number;
  hist: number;
  top: number;
  open: boolean;
  exited: boolean;
  resizes: number;
  act: string;
  footer_bottom: number;
  screen_rows: number;
  cap: number;
};
type Run = { states: State[]; wrong_copies: number[] };

export type FooterResult = {
  traces: number;
  steps: number;
  baseCap: number | null;
  extra: number | null;
  tlc: CheckedTlc | null;
  problem: string | null;
  /// The runtime driver did not compile (a planted bug that is not Zig).
  compileError: boolean;
};

/// The scripts every run includes.
const SCRIPTED: { name: string; events: string[] }[] = [
  { name: "I815: a long transcript, the slash picker opened and closed", events: ["o1", "o29", "open", "close", "exit"] },
  {
    name: "three opens, output while open, exit with the picker open",
    events: ["o1", "o29", "open", "close", "open", "close", "open", "o1", "o2", "close", "o1", "open", "exit"],
  },
  { name: "a transcript shorter than the screen", events: ["o1", "o3", "open", "close", "o2", "exit"] },
  { name: "the transcript fills the screen while the picker is open", events: ["o1", "open", "o5", "o5", "o5", "close", "exit"] },
  { name: "exit after the picker closed", events: ["o1", "o40", "open", "o3", "close", "exit"] },
  { name: "a resize with the picker open, then close", events: ["o1", "o29", "open", "resize", "close", "o1", "exit"] },
  { name: "output and a resize with the picker open, exit with it open", events: ["o1", "o29", "open", "o2", "resize", "o1", "exit"] },
  { name: "a resize with the picker closed between two opens", events: ["o1", "o29", "open", "close", "resize", "open", "close", "exit"] },
  { name: "a takeover with the picker open, output, then close", events: ["o1", "o29", "open", "takeover", "o2", "o2", "close", "o1", "exit"] },
  { name: "an invalid anchor with the picker open, output, then close", events: ["o1", "o29", "open", "invalidate", "o2", "o2", "close", "o1", "exit"] },
];

function randomScript(next: () => number, length: number): string[] {
  const events = ["o1", `o${10 + Math.floor(next() * 20)}`];
  let open = false;
  for (let i = 0; i < length; i += 1) {
    const roll = next();
    if (roll < 0.45) events.push(`o${1 + Math.floor(next() * 3)}`);
    else if (roll < 0.5) events.push("resize");
    else if (roll < 0.53) events.push("takeover");
    else if (roll < 0.56) events.push("invalidate");
    else if (!open) {
      events.push("open");
      open = true;
    } else {
      events.push("close");
      open = false;
    }
  }
  events.push("exit");
  return events;
}

/// The rows the screen showed above the footer when the footer was on the
/// bottom row and the screen was full, for the idle or the open footer.
function fullCaps(runs: Run[], open: boolean): Set<number> {
  const caps = new Set<number>();
  for (const run of runs) {
    for (const state of run.states) {
      if (state.act === "Init" || state.exited || state.open !== open) continue;
      if (state.footer_bottom === state.screen_rows && state.rows - state.top === state.cap && state.top > 0) caps.add(state.cap);
    }
  }
  return caps;
}

/// `root` is the checkout whose src/ the driver builds: the repository, or a
/// copy with a planted bug (mutations.ts).
export async function footerRuntimeToSpec(options: { dir: string; randomTraces: number; length: number; seed: number; root?: string }): Promise<FooterResult> {
  mkdirSync(options.dir, { recursive: true });
  const next = seededRandom(options.seed);
  const scripts = [
    ...SCRIPTED,
    ...Array.from({ length: options.randomTraces }, (_, i) => ({ name: `random ${i + 1} (seed ${options.seed})`, events: randomScript(next, options.length) })),
  ];
  const eventsPath = join(options.dir, "events.json");
  const runsPath = join(options.dir, "runs.json");
  writeFileSync(eventsPath, `${JSON.stringify({ cols: 100, rows: 24, traces: scripts.map((script) => script.events) })}\n`);
  const empty = { traces: scripts.length, steps: 0, baseCap: null, extra: null, tlc: null, compileError: false };
  const home = mkdtempSync(join(tmpdir(), "fx-footer-reclaim-home-"));
  const test = Bun.spawnSync(
    ["zig", "test", "-lc", "src/footer_reclaim_root.zig", "--test-filter", "footer reclaim runtime trace driver", "--cache-dir", join(REPO_ROOT, ".zig-cache")],
    {
      cwd: options.root ?? REPO_ROOT,
      env: {
        ...process.env,
        FX_HOME: home,
        FX_SOUND: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_FOOTER_RECLAIM_EVENTS: eventsPath,
        FX_FOOTER_RECLAIM_TRACE: runsPath,
      },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  rmSync(home, { recursive: true, force: true });
  if (test.exitCode !== 0) {
    const output = `${test.stdout.toString()}${test.stderr.toString()}`;
    return {
      ...empty,
      compileError: /\.zig:\d+:\d+: error:/.test(output),
      problem: `the runtime driver failed: ${output.split("\n").slice(-12).join(" ")}`,
    };
  }
  const runs: Run[] = JSON.parse(readFileSync(runsPath, "utf8"));
  const steps = runs.reduce((sum, run) => sum + run.states.length - 1, 0);
  const problems: string[] = [];
  runs.forEach((run, i) => {
    if (run.wrong_copies.length > 0) {
      problems.push(`${scripts[i]!.name}: rows ${run.wrong_copies.slice(0, 6).join(", ")} are in native history and on the screen other than once after exit`);
    }
  });

  const idle = fullCaps(runs, false);
  const open = fullCaps(runs, true);
  if (idle.size !== 1 || open.size !== 1) {
    problems.push(`the full screen showed ${[...idle].join("/") || "no"} rows above the idle footer and ${[...open].join("/") || "no"} above the open one`);
    return { ...empty, steps, problem: problems.join("; ") };
  }
  const baseCap = [...idle][0]!;
  const extra = baseCap - [...open][0]!;
  const maxRows = Math.max(...runs.flatMap((run) => run.states.map((state) => state.rows)));
  const burst = Math.max(1, ...runs.flatMap((run) => run.states.slice(1).map((state, i) => state.rows - run.states[i]!.rows)));
  const maxResizes = Math.max(0, ...runs.flatMap((run) => run.states.map((state) => state.resizes)));

  const modelStates = runs.map((run) =>
    run.states.map((state) => ({ rows: state.rows, hist: state.hist, top: state.top, open: state.open, exited: state.exited, resizes: state.resizes, act: state.act })),
  );
  writeFileSync(join(options.dir, "traces.json"), `${JSON.stringify(modelStates, null, 1)}\n`);
  const data = [
    "---- MODULE FooterTraceData ----",
    "EXTENDS Integers",
    "Traces == <<",
    modelStates.map((states, i) => `  \\* ${scripts[i]!.name}\n  <<${states.map((state) => toTla(state)).join(",\n   ")}>>`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
  const files = specFiles();
  const cfgText = files["TraceFooterReclaim.cfg"]!.replace(
    /CONSTANTS\n[\s\S]*?\nSPECIFICATION/,
    `CONSTANTS\n    MaxRows = ${maxRows}\n    Burst = ${burst}\n    BaseCap = ${baseCap}\n    Extra = ${extra}\n    MaxResizes = ${maxResizes}\n    Release = "base"\nSPECIFICATION`,
  );
  const tlc = await checkTlc(join(options.dir, "tlc"), "TraceFooterReclaim", "TraceFooterReclaim.cfg", {
    ...files,
    "TraceFooterReclaim.cfg": cfgText,
    "FooterTraceData.tla": data,
  });
  return { traces: runs.length, steps, baseCap, extra, tlc, problem: problems.length > 0 ? problems.join("; ") : null, compileError: false };
}

// `bun footer-runtime-to-spec.ts` runs this direction on its own; verify.ts
// runs it as one stage of check.sh. FX_FOOTER_RECLAIM_TRACES and
// FX_TRANSCRIPT_WINDOW_SEED set the random scripts.
if (import.meta.main) {
  const { outDir } = await import("../lib/tlc.ts");
  const result = await footerRuntimeToSpec({
    dir: join(outDir("footer-reclaim"), "footer"),
    randomTraces: Number(process.env.FX_FOOTER_RECLAIM_TRACES ?? "40"),
    length: 30,
    seed: Number(process.env.FX_TRANSCRIPT_WINDOW_SEED ?? "20261030"),
  });
  const ok = result.tlc?.verdict === "pass" && result.problem === null;
  console.log(
    `${ok ? "PASS" : "FAIL"} footer runtime to spec: ${result.traces} traces, ${result.steps} steps, base footer ${result.baseCap ?? "?"} rows, surface +${result.extra ?? "?"}; ` +
      `TLC ${result.tlc?.verdict ?? "not run"}${result.tlc?.property ? ` (${result.tlc.property})` : ""}${result.problem ? `; ${result.problem}` : ""}`,
  );
  process.exit(ok ? 0 : 1);
}
