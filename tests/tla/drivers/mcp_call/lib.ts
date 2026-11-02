// Shared pieces of the `fx mcp call` bridge drivers: where the model and the
// core live, building and running the JSON-lines harness around the real core,
// the mapping between the model's acts and the core's events, a seeded random
// source, TLA+ value printing, and TLC runs on the pinned jar.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, runTlc, tlcToolchain, type TlcRun } from "../lib/tlc.ts";

export const SPEC_DIR = join(TLA_ROOT, "mcp_call", "spec");
export const MODEL_DIR = join(TLA_ROOT, "mcp_call");
export const CORE_SOURCE = join(REPO_ROOT, "src", "core", "mcp_host", "mcp_call.zig");
export const HARNESS_SOURCE = join(import.meta.dirname, "harness.zig");
/// MaxInFlight in MCMcpCall.cfg and TraceMcpCall.cfg; the harness runs the
/// core with this capacity.
export const CAPACITY = 2;

// TLC 1.7.4 (TLC2 2.19 of 08 August 2024, rev 5a47802), from
// https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
export const PINNED_JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88";
export const PINNED_TLC_VERSION = "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)";

export type Registered = { owner: string; token: string };
export type Entry = { id: number; owner: string; stage: string };
export type Effect = { kind: string; id?: number; owner?: string; reason?: string; outcome?: string; what?: string };
export type CoreState = { open: boolean; next: number; registered: Registered[]; entries: Entry[] };
export type Shown = CoreState & { out: Effect[] };
export type Act =
  | { name: "Init" | "Stopped" | "Crash" }
  | { name: "Started"; token: string }
  | { name: "OwnerAdded"; owner: string; token: string }
  | { name: "OwnerRemoved"; owner: string }
  | { name: "Request"; token: string; version: number }
  | { name: "Authorized"; id: number; allow: boolean }
  | { name: "CallFinished"; id: number; outcome: string }
  | { name: "ReplyDone"; id: number; delivered: boolean }
  | { name: "ClientGone"; id: number };
export type Event =
  | { event: "stopped" | "crash" }
  | { event: "started"; token: string }
  | { event: "owner_added"; owner: string; token: string }
  | { event: "owner_removed"; owner: string }
  | { event: "request"; token: string; version: number }
  | { event: "authorized"; id: number; allow: boolean }
  | { event: "call_finished"; id: number; outcome: string }
  | { event: "reply_done"; id: number; delivered: boolean }
  | { event: "client_gone"; id: number };

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

const sorted = <T>(items: T[]): T[] => [...items].sort((a, b) => (canonical(a) < canonical(b) ? -1 : canonical(a) > canonical(b) ? 1 : 0));

/// What a state shows, with every set in one order: the model prints sets,
/// the harness prints lists, and both are compared as sets.
export function shownOf(state: Record<string, unknown>): Shown {
  const { open, next, registered, entries, out } = state as Shown;
  return { open, next, registered: sorted(registered), entries: sorted(entries), out: sorted(out) };
}

/// The core variables of a state, without the step's effects and event:
/// what the next step depends on.
export function coreOf(state: Record<string, unknown>): CoreState {
  const { open, next, registered, entries } = shownOf(state);
  return { open, next, registered, entries };
}

/// A JSON value as TLA+: objects are records, arrays are sequences.
export function toTla(value: unknown): string {
  if (Array.isArray(value)) return `<<${value.map(toTla).join(", ")}>>`;
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
    return `[${entries.map(([k, v]) => `${k} |-> ${toTla(v)}`).join(", ")}]`;
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
/// into `dir`. Throws with the compiler's output when the build fails.
export function buildHarness(dir: string, core = CORE_SOURCE): string {
  mkdirSync(dir, { recursive: true });
  const bin = join(dir, "mcp-call-harness");
  const build = Bun.spawnSync([
    "zig", "build-exe", "-ODebug",
    "--dep", "mcp_call", `-Mroot=${HARNESS_SOURCE}`, `-Mmcp_call=${core}`,
    `-femit-bin=${bin}`, "--cache-dir", join(REPO_ROOT, ".zig-cache"),
  ], { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" });
  if (build.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`harness build failed for ${core}:\n${build.stderr.toString()}${build.stdout.toString()}`);
  }
  return bin;
}

/// One harness process and the lines it prints.
class HarnessProcess {
  readonly proc: ReturnType<typeof Bun.spawn>;
  private lines: string[] = [];
  private waiters: ((line: string) => void)[] = [];
  private buffered = "";

  constructor(bin: string) {
    this.proc = Bun.spawn([bin, "--capacity", String(CAPACITY)], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
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
  }

  nextLine(): Promise<string> {
    const line = this.lines.shift();
    if (line !== undefined) return Promise.resolve(line);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the harness did not answer within 5 s")), 5000);
      this.waiters.push((value) => { clearTimeout(timer); resolve(value); });
    });
  }

  write(text: string) {
    const stdin = this.proc.stdin as import("bun").FileSink;
    stdin.write(text);
    stdin.flush();
  }
}

/// One running harness process. `crash()` kills it and continues in a new
/// one, which begins from the core's zero state: the only way the harness
/// loses state is the way a real process does. A spare process is started
/// ahead of time, so a crash does not wait for one to start.
export class Harness {
  private current!: HarnessProcess;
  private spare!: HarnessProcess;
  private killed: Promise<number>[] = [];
  crashes = 0;
  last!: Shown;

  private constructor(private readonly bin: string) {}

  static async start(bin: string): Promise<Harness> {
    const harness = new Harness(bin);
    harness.spare = new HarnessProcess(bin);
    await harness.takeSpare();
    return harness;
  }

  private async takeSpare() {
    this.current = this.spare;
    this.spare = new HarnessProcess(this.bin);
    this.last = this.parse(await this.current.nextLine());
  }

  private parse(line: string): Shown {
    const parsed = JSON.parse(line) as { state: CoreState; out: Effect[] };
    return shownOf({ ...parsed.state, out: parsed.out });
  }

  async send(event: Event): Promise<Shown> {
    if (event.event === "crash") {
      await this.crash();
      return this.last;
    }
    this.current.write(`${JSON.stringify(event)}\n`);
    this.last = this.parse(await this.current.nextLine());
    return this.last;
  }

  async crash() {
    this.crashes += 1;
    this.current.proc.kill("SIGKILL");
    this.killed.push(this.current.proc.exited);
    await this.takeSpare();
  }

  async close() {
    (this.current.proc.stdin as import("bun").FileSink).end();
    this.spare.proc.kill("SIGKILL");
    await Promise.all([this.current.proc.exited, this.spare.proc.exited, ...this.killed]);
  }
}

/// The event that performs `act` on the core.
export function eventFor(act: Act): Event {
  switch (act.name) {
    case "Started": return { event: "started", token: act.token };
    case "Stopped": return { event: "stopped" };
    case "OwnerAdded": return { event: "owner_added", owner: act.owner, token: act.token };
    case "OwnerRemoved": return { event: "owner_removed", owner: act.owner };
    case "Request": return { event: "request", token: act.token, version: act.version };
    case "Authorized": return { event: "authorized", id: act.id, allow: act.allow };
    case "CallFinished": return { event: "call_finished", id: act.id, outcome: act.outcome };
    case "ReplyDone": return { event: "reply_done", id: act.id, delivered: act.delivered };
    case "ClientGone": return { event: "client_gone", id: act.id };
    case "Crash": return { event: "crash" };
    case "Init": throw new Error("Init is not an event");
  }
}

/// The spec's act for `event`.
export function actFor(event: Event): Act {
  switch (event.event) {
    case "started": return { name: "Started", token: event.token };
    case "stopped": return { name: "Stopped" };
    case "owner_added": return { name: "OwnerAdded", owner: event.owner, token: event.token };
    case "owner_removed": return { name: "OwnerRemoved", owner: event.owner };
    case "request": return { name: "Request", token: event.token, version: event.version };
    case "authorized": return { name: "Authorized", id: event.id, allow: event.allow };
    case "call_finished": return { name: "CallFinished", id: event.id, outcome: event.outcome };
    case "reply_done": return { name: "ReplyDone", id: event.id, delivered: event.delivered };
    case "client_gone": return { name: "ClientGone", id: event.id };
    case "crash": return { name: "Crash" };
  }
}

export type CheckedTlc = TlcRun & { verdict: "pass" | "violated" | "error"; property: string | null; tlcVersion: string | null };

/// Runs TLC and names the property it reports violated, including a
/// temporal property, which TLC reports without a name.
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
  // A property TraceMcpCall re-exports from McpCall is reported under its
  // instance name, such as MC!FreshIds.
  let property = /Error: (?:Invariant|Action property) ([\w!]+) is violated/.exec(run.output)?.[1]?.replace(/^\w+!/, "") ?? null;
  if (!property && /Temporal properties were violated/.test(run.output)) {
    const cfgText = files[cfg] ?? readFileSync(join(dir, cfg), "utf8");
    const listed = /PROPERTY\s+([\s\S]*)$/.exec(cfgText)?.[1]?.split(/\s+/).filter(Boolean) ?? [];
    property = listed.length === 1 ? listed[0]! : "temporal";
  }
  const passed = run.exitCode === 0 && /Model checking completed\. No error has been found\./.test(run.output);
  const verdict = passed ? "pass" : property ? "violated" : "error";
  return { ...run, verdict, property, tlcVersion };
}

/// The spec files with `McpCall.tla` replaced by `spec`.
export function specFiles(spec = readFileSync(join(SPEC_DIR, "McpCall.tla"), "utf8")): Record<string, string> {
  return {
    "McpCall.tla": spec,
    "MCMcpCall.cfg": readFileSync(join(SPEC_DIR, "MCMcpCall.cfg"), "utf8"),
    "TraceMcpCall.tla": readFileSync(join(SPEC_DIR, "TraceMcpCall.tla"), "utf8"),
    "TraceMcpCall.cfg": readFileSync(join(SPEC_DIR, "TraceMcpCall.cfg"), "utf8"),
  };
}

/// The CONSTANTS block of a config, as written.
export function constantsOf(cfgText: string): string {
  return /^CONSTANTS\n(?:[ \t]+.*\n)+/m.exec(cfgText)?.[0] ?? "";
}

/// A config that checks only `property` against `specification`, with the
/// constants of `baseCfg` (MCMcpCall.cfg or TraceMcpCall.cfg).
export function singleConfig(property: string, specification: string, invariants: string[], baseCfg: string): string {
  const kind = invariants.includes(property) ? "INVARIANT" : "PROPERTY";
  return `${constantsOf(baseCfg)}SPECIFICATION ${specification}\n${specification === "TraceSpec" ? "CHECK_DEADLOCK FALSE\n" : ""}${kind}\n    ${property}\n`;
}

/// The names a config lists, by section.
export function configNames(cfgText = readFileSync(join(SPEC_DIR, "MCMcpCall.cfg"), "utf8")) {
  const sections: Record<string, string[]> = {};
  let current = "";
  for (const raw of cfgText.split("\n")) {
    const line = raw.replace(/\\\*.*$/, "").trim();
    if (!line) continue;
    const [first, ...rest] = line.split(/\s+/);
    if (/^[A-Z_]+$/.test(first!)) {
      current = first!;
      sections[current] ??= [];
      sections[current]!.push(...rest);
    } else {
      sections[current]?.push(first!, ...rest);
    }
  }
  return { invariants: sections.INVARIANT ?? [], properties: sections.PROPERTY ?? [] };
}

/// Applies a planted bug: `find` must occur exactly once in `text`.
export function plant(text: string, find: string, replace: string, id: string): string {
  const first = text.indexOf(find);
  if (first < 0 || text.indexOf(find, first + 1) >= 0) {
    throw new Error(`${id}: the text to replace must occur exactly once`);
  }
  return text.slice(0, first) + replace + text.slice(first + find.length);
}
