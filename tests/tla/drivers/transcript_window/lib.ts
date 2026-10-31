// Shared pieces of the transcript window drivers: where the model and the
// core live, building and running the JSON-lines harness around the real
// core, the mapping between the model's actions and the core's events, a
// seeded random source, TLA+ value printing, and TLC runs on the pinned jar.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, runTlc, tlcToolchain, type TlcRun } from "../lib/tlc.ts";

export const SPEC_DIR = join(TLA_ROOT, "transcript_window", "spec");
export const MODEL_DIR = join(TLA_ROOT, "transcript_window");
export const CORE_SOURCE = join(REPO_ROOT, "src", "ui", "transcript", "transcript_window.zig");
export const HARNESS_SOURCE = join(import.meta.dirname, "harness.zig");

// TLC 1.7.4 (TLC2 2.19 of 08 August 2024, rev 5a47802), from
// https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
export const PINNED_JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88";
export const PINNED_TLC_VERSION = "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)";

export const SPEC_FILES = [
  "TranscriptWindow.tla",
  "MCTranscriptWindow.cfg",
  "MCTranscriptWindowUnsaved.cfg",
  "MCCtrlOReachesStart.cfg",
  "MCTranscriptWindowSweep.cfg",
  "MCTranscriptWindowSweepUnsaved.cfg",
  "TraceTranscriptWindow.tla",
  "TraceTranscriptWindow.cfg",
];

export type Config = { window: number; read_step: number; slice: number; saved: boolean };
export type Effect = { kind: string } & Record<string, unknown>;
export type Abstract = Record<string, unknown> & { nextSeq: number; savedThrough: number; cycle: number; cycleFirst: number; pending: number; nextToken: number };
export type Shown = { state: Abstract; live: number[]; out: Effect[]; rejected?: string };
export type Act = { name: string; id?: number; through?: number; token?: number; count?: number };
export type Event = Record<string, unknown> & { event: string };

/// The pinned toolchain, or a reason it is not the pinned one.
export function pinnedToolchain() {
  const toolchain = tlcToolchain();
  if (toolchain.jarSha256 !== PINNED_JAR_SHA256) {
    throw new Error(
      `tla2tools.jar at ${toolchain.jar} has sha256 ${toolchain.jarSha256}, not the pinned ${PINNED_JAR_SHA256}. ` +
        "Download v1.7.4 from https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar " +
        "and point TLA2TOOLS_JAR at it.",
    );
  }
  return toolchain;
}

/// A canonical JSON form with sorted keys, so equal values print equally.
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
    entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

/// A JSON value as TLA+. Objects are records and arrays sequences, except the
/// fields in `sets`, which print as sets.
export function toTla(value: unknown, sets: Set<string> = new Set(), key = ""): string {
  if (Array.isArray(value)) {
    const items = value.map((item) => toTla(item, sets));
    return sets.has(key) ? `{${items.join(", ")}}` : `<<${items.join(", ")}>>`;
  }
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
    return `[${entries.map(([k, v]) => `${k} |-> ${toTla(v, sets, k)}`).join(", ")}]`;
  }
  throw new Error(`cannot print ${String(value)} as TLA+`);
}

/// Mulberry32: a small seeded generator, so a failing run can be replayed.
export function seededRandom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Builds the harness around `core` (the real core, or a planted-bug copy)
/// into `dir`. ReleaseSafe keeps every safety check and makes the edge sweep's
/// millions of steps fast. Throws with the compiler's output on failure.
export function buildHarness(dir: string, core = CORE_SOURCE): string {
  mkdirSync(dir, { recursive: true });
  const bin = join(dir, "transcript-window-harness");
  const build = Bun.spawnSync([
    "zig", "build-exe", "-OReleaseSafe",
    "--dep", "transcript_window", `-Mroot=${HARNESS_SOURCE}`, `-Mtranscript_window=${core}`,
    `-femit-bin=${bin}`, "--cache-dir", join(REPO_ROOT, ".zig-cache"),
  ], { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" });
  if (build.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`harness build failed for ${core}:\n${build.stderr.toString()}${build.stdout.toString()}`);
  }
  return bin;
}

/// One running harness process. `crash()` kills it and starts a new one,
/// which begins from the core's zero state: the only way the harness loses
/// state is the way a real process does. `reset()` sends a config line, which
/// replaces the core's state with the zero state; the harness keeps no other
/// state, so the edge sweep uses it in place of a crash.
export class Harness {
  private proc!: ReturnType<typeof Bun.spawn>;
  private lines: string[] = [];
  private waiters: ((line: string) => void)[] = [];
  private buffered = "";
  last!: Shown;

  private constructor(private readonly bin: string, readonly config: Config) {}

  static async start(bin: string, config: Config): Promise<Harness> {
    const harness = new Harness(bin, config);
    await harness.spawn();
    return harness;
  }

  private async spawn() {
    this.lines = [];
    this.waiters = [];
    this.buffered = "";
    this.proc = Bun.spawn([this.bin], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
    const reader = (this.proc.stdout as ReadableStream<Uint8Array>).getReader();
    const decoder = new TextDecoder();
    (async () => {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        this.buffered += decoder.decode(value, { stream: true });
        let newline = this.buffered.indexOf("\n");
        while (newline >= 0) {
          const line = this.buffered.slice(0, newline);
          this.buffered = this.buffered.slice(newline + 1);
          const waiter = this.waiters.shift();
          if (waiter) waiter(line);
          else this.lines.push(line);
          newline = this.buffered.indexOf("\n");
        }
      }
    })();
    this.last = (await this.sendLines([JSON.stringify({ config: this.config })]))[0]!;
  }

  private nextLine(): Promise<string> {
    const line = this.lines.shift();
    if (line !== undefined) return Promise.resolve(line);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the harness did not answer within 10 s")), 10_000);
      this.waiters.push((value) => { clearTimeout(timer); resolve(value); });
    });
  }

  /// Writes every line at once and returns one parsed answer per line.
  private async sendLines(lines: string[]): Promise<Shown[]> {
    const stdin = this.proc.stdin as import("bun").FileSink;
    stdin.write(`${lines.join("\n")}\n`);
    stdin.flush();
    const shown: Shown[] = [];
    for (let i = 0; i < lines.length; i += 1) shown.push(JSON.parse(await this.nextLine()) as Shown);
    this.last = shown[shown.length - 1]!;
    return shown;
  }

  async send(event: Event): Promise<Shown> {
    return (await this.sendLines([JSON.stringify(event)]))[0]!;
  }

  /// One answer per event; a `reset` event is a config line.
  async sendMany(events: Event[]): Promise<Shown[]> {
    return this.sendLines(events.map((event) => (event.event === "reset" ? JSON.stringify({ config: this.config }) : JSON.stringify(event))));
  }

  async reset(): Promise<Shown> {
    return (await this.sendLines([JSON.stringify({ config: this.config })]))[0]!;
  }

  async crash() {
    this.proc.kill("SIGKILL");
    await this.proc.exited;
    await this.spawn();
  }

  async close() {
    (this.proc.stdin as import("bun").FileSink).end();
    await this.proc.exited;
  }
}

/// The event that performs `act` on the core. `target` is the model's state
/// after the step, which `Resumed` reads its arguments from. `Crash` is
/// returned as a `reset` event; drivers that kill the process handle it first.
export function eventFor(act: Act, target: Record<string, unknown>): Event {
  switch (act.name) {
    case "TurnStarted": return { event: "turn_started" };
    case "TurnEnded": return { event: "turn_ended" };
    case "BlockOpened": return { event: "block_opened", id: act.id };
    case "BlockChanged": return { event: "block_changed", id: act.id };
    case "BlockFinished": return { event: "block_finished", id: act.id };
    case "SavedThrough": return { event: "saved_through", seq: act.through };
    case "Compacted": return { event: "compacted" };
    case "Resized": return { event: "resized" };
    case "ReprintTick": return { event: "reprint_tick" };
    case "CtrlOOpened": return { event: "ctrlo_opened" };
    case "CtrlOScrolledOlder": return { event: "ctrlo_scrolled", dir: "older" };
    case "CtrlOScrolledNewer": return { event: "ctrlo_scrolled", dir: "newer" };
    case "CtrlOClosed": return { event: "ctrlo_closed" };
    case "LogReadDone": return { event: "log_read_done", token: act.token, count: act.count };
    case "LogReadFailed": return { event: "log_read_failed", token: act.token };
    case "Crash": return { event: "reset" };
    case "Resumed": return { event: "resumed", cycle: target.cycle, cycle_first: target.cycleFirst, next_seq: target.nextSeq };
    default: throw new Error(`${act.name} is not an event`);
  }
}

const CORE_FIELDS = [
  "cycle", "cycleFirst", "prevFirst", "nextSeq", "savedThrough", "turnOpen", "paintedThrough", "reprinting",
  "coOpen", "coLo", "coHi", "coAtStart", "pending", "pendingDir", "nextToken",
] as const;

/// What the code shows of a model state: the core's variables and the step's
/// effects. The model's `None` (MaxSeq + 1) is the core's -1.
export function modelView(state: Record<string, unknown>, none: number): string {
  const view: Record<string, unknown> = {};
  for (const field of CORE_FIELDS) view[field] = state[field];
  if (view.prevFirst === none) view.prevFirst = -1;
  view.live = [...(state.live as number[])].sort((a, b) => a - b);
  view.out = state.out;
  return canonical(view);
}

export function codeView(shown: Shown): string {
  const view: Record<string, unknown> = {};
  for (const field of CORE_FIELDS) view[field] = shown.state[field];
  view.live = shown.live;
  view.out = shown.out;
  return canonical(view);
}

export type CheckedTlc = TlcRun & {
  verdict: "pass" | "violated" | "error";
  property: string | null;
  tlcVersion: string | null;
  generated: number | null;
  distinct: number | null;
};

/// Runs TLC and names the property it reports violated, including a
/// temporal property, which TLC reports without a name. Totals come from the
/// final "states generated" line; earlier lines are progress reports.
export async function checkTlc(
  dir: string,
  module: string,
  cfg: string,
  files: Record<string, string>,
  extraArgs: string[] = [],
): Promise<CheckedTlc> {
  pinnedToolchain();
  mkdirSync(dir, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text);
  const run = await runTlc(dir, module, cfg, [], dir, ["-deadlock", ...extraArgs]);
  const tlcVersion = /^(TLC2 Version [^\n]*?)\s*$/m.exec(run.output)?.[1] ?? null;
  let property = /Error: (?:Invariant|Action property) ([\w!]+) is violated/.exec(run.output)?.[1]?.replace(/^\w+!/, "") ?? null;
  if (!property && /Temporal properties were violated/.test(run.output)) {
    const cfgText = files[cfg] ?? readFileSync(join(dir, cfg), "utf8");
    const listed = configNames(cfgText).PROPERTY ?? [];
    property = listed.length === 1 ? listed[0]! : "temporal";
  }
  const totals = [...run.output.matchAll(/(\d+) states generated, (\d+) distinct states found, 0 states left on queue/g)].at(-1);
  const passed = run.exitCode === 0 && /Model checking completed\. No error has been found\./.test(run.output);
  const verdict = passed ? "pass" : property ? "violated" : "error";
  return {
    ...run,
    verdict,
    property,
    tlcVersion,
    generated: totals ? Number(totals[1]) : null,
    distinct: totals ? Number(totals[2]) : null,
  };
}

/// The spec files with `TranscriptWindow.tla` replaced by `spec`.
export function specFiles(spec = readFileSync(join(SPEC_DIR, "TranscriptWindow.tla"), "utf8")): Record<string, string> {
  const files: Record<string, string> = {};
  for (const name of SPEC_FILES) files[name] = name === "TranscriptWindow.tla" ? spec : readFileSync(join(SPEC_DIR, name), "utf8");
  return files;
}

/// The names a config lists, by section.
export function configNames(cfgText: string): Record<string, string[]> {
  const sections: Record<string, string[]> = {};
  let current = "";
  for (const raw of cfgText.split("\n")) {
    const line = raw.replace(/\\\*.*$/, "").trim();
    if (!line) continue;
    const [first, ...rest] = line.split(/\s+/);
    if (/^[A-Z_]+$/.test(first!)) {
      current = first!;
      sections[current] ??= [];
      sections[current]!.push(...rest.filter((word) => /^\w+$/.test(word)));
    } else if (current && current !== "CONSTANTS") {
      sections[current]!.push(...line.split(/\s+/).filter((word) => /^\w+$/.test(word)));
    }
  }
  return sections;
}

/// The constants a config assigns, as text, by name.
export function configConstants(cfgText: string): Record<string, string> {
  const constants: Record<string, string> = {};
  for (const match of cfgText.matchAll(/^\s+(\w+) = (.+)$/gm)) constants[match[1]!] = match[2]!.trim();
  return constants;
}
