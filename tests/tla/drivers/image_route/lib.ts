// Shared pieces of the image route drivers: where the model and the core
// live, building and running the JSON-lines harness around the real core, a
// seeded random source, TLA+ value printing, and TLC runs on the pinned jar.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, runTlc, tlcToolchain, type TlcRun } from "../lib/tlc.ts";

export const SPEC_DIR = join(TLA_ROOT, "image_route", "spec");
export const MODEL_DIR = join(TLA_ROOT, "image_route");
export const CORE_SOURCE = join(REPO_ROOT, "src", "core", "images", "image_route.zig");
export const HARNESS_SOURCE = join(import.meta.dirname, "harness.zig");

// TLC 1.7.4 (TLC2 2.19 of 08 August 2024, rev 5a47802), from
// https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
export const PINNED_JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88";
export const PINNED_TLC_VERSION = "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)";

export type View = { kind: "listed" | "missing" | "down"; vision: boolean; file_input: boolean };
export type Request = {
  user_images: boolean;
  earlier_images: boolean;
  pending_images: boolean;
  tool_images: boolean;
  fallback: boolean;
  catalog_down: boolean;
};
export type Effect = { kind: string; route?: string; mode?: string; tool_images?: string; earlier_images?: string; reason?: string };
export type CoreState = { support: string; resolved: boolean; notified: boolean; pending: Request[] };
export type Shown = CoreState & { out: Effect[] };
export type Act =
  | { name: "Init" | "Crash" }
  | { name: "TurnStarted"; view: View }
  | { name: "RequestReady"; req: Request }
  | { name: "CapabilitiesResolved"; view: View; answered: Request[] };
export type Event =
  | { event: "turn_started"; view: View }
  | { event: "request_ready"; req: Request }
  | { event: "capabilities_resolved"; view: View }
  | { event: "crash" };

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
  const bin = join(dir, "image-route-harness");
  const build = Bun.spawnSync([
    "zig", "build-exe", "-ODebug",
    "--dep", "image_route", `-Mroot=${HARNESS_SOURCE}`, `-Mimage_route=${core}`,
    `-femit-bin=${bin}`, "--cache-dir", join(REPO_ROOT, ".zig-cache"),
  ], { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" });
  if (build.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`harness build failed for ${core}:\n${build.stderr.toString()}${build.stdout.toString()}`);
  }
  return bin;
}

/// One running harness process. `crash()` kills it and starts a new one,
/// which begins from the core's zero state: the only way the harness loses
/// state is the way a real process does.
export class Harness {
  private proc!: ReturnType<typeof Bun.spawn>;
  private lines: string[] = [];
  private waiters: ((line: string) => void)[] = [];
  private buffered = "";
  last!: Shown;

  private constructor(private readonly bin: string) {}

  static async start(bin: string): Promise<Harness> {
    const harness = new Harness(bin);
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
    this.last = this.parse(await this.nextLine());
  }

  private nextLine(): Promise<string> {
    const line = this.lines.shift();
    if (line !== undefined) return Promise.resolve(line);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the harness did not answer within 5 s")), 5000);
      this.waiters.push((value) => { clearTimeout(timer); resolve(value); });
    });
  }

  private parse(line: string): Shown {
    const parsed = JSON.parse(line) as { state: CoreState; out: Effect[] };
    return { ...parsed.state, out: parsed.out };
  }

  async send(event: Event): Promise<Shown> {
    if (event.event === "crash") {
      await this.crash();
      return this.last;
    }
    const stdin = this.proc.stdin as import("bun").FileSink;
    stdin.write(`${JSON.stringify(event)}\n`);
    stdin.flush();
    this.last = this.parse(await this.nextLine());
    return this.last;
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

/// The event that performs `act` on the core.
export function eventFor(act: Act): Event {
  switch (act.name) {
    case "TurnStarted": return { event: "turn_started", view: act.view };
    case "RequestReady": return { event: "request_ready", req: act.req };
    case "CapabilitiesResolved": return { event: "capabilities_resolved", view: act.view };
    case "Crash": return { event: "crash" };
    case "Init": throw new Error("Init is not an event");
  }
}

/// The spec's act for `event`, applied from a core that showed `before`.
export function actFor(event: Event, before: Shown): Act {
  switch (event.event) {
    case "turn_started": return { name: "TurnStarted", view: event.view };
    case "request_ready": return { name: "RequestReady", req: event.req };
    case "capabilities_resolved": return { name: "CapabilitiesResolved", view: event.view, answered: before.pending };
    case "crash": return { name: "Crash" };
  }
}

/// The part of a spec state the code shows.
export function shownOf(state: Record<string, unknown>): Shown {
  const { support, resolved, notified, pending, out } = state as Shown;
  return { support, resolved, notified, pending, out };
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
  // A property TraceImageRoute re-exports from ImageRoute is reported under
  // its instance name, such as IR!ResolveOncePerTurn.
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

/// The spec files with `ImageRoute.tla` replaced by `spec`.
export function specFiles(spec = readFileSync(join(SPEC_DIR, "ImageRoute.tla"), "utf8")): Record<string, string> {
  return {
    "ImageRoute.tla": spec,
    "MCImageRoute.cfg": readFileSync(join(SPEC_DIR, "MCImageRoute.cfg"), "utf8"),
    "TraceImageRoute.tla": readFileSync(join(SPEC_DIR, "TraceImageRoute.tla"), "utf8"),
    "TraceImageRoute.cfg": readFileSync(join(SPEC_DIR, "TraceImageRoute.cfg"), "utf8"),
  };
}

/// A config that checks only `property`, which is an invariant or property
/// of MCImageRoute.cfg, against `specification`.
export function singleConfig(property: string, specification: string, invariants: string[]): string {
  const kind = invariants.includes(property) ? "INVARIANT" : "PROPERTY";
  return `SPECIFICATION ${specification}\n${specification === "TraceSpec" ? "CHECK_DEADLOCK FALSE\n" : ""}${kind}\n    ${property}\n`;
}

/// The names MCImageRoute.cfg lists, by section.
export function configNames(cfgText = readFileSync(join(SPEC_DIR, "MCImageRoute.cfg"), "utf8")) {
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
