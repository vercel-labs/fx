// TLC for the MCP host models in tests/tla/mcp_host/: the TLC that ../lib/tlc.ts
// finds, one run per call in a fresh work folder, and the run's verdict. Nothing
// here downloads anything or calls a model.
import { closeSync, cpSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, resolve } from "node:path";
import { TLA_ROOT, tlcToolchain } from "../lib/tlc";

export const here = import.meta.dirname;
export const tlaDir = join(TLA_ROOT, "mcp_host");

export const sha256 = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");
export const sha256Text = (text: string) => createHash("sha256").update(text).digest("hex");

export function tools() {
  return tlcToolchain();
}

export interface TlcRun {
  label: string;
  module: string;
  config: string;
  command: string[];
  exit: number;
  seconds: number;
  log: string;
  output: string;
  generated?: number;
  distinct?: number;
  queued?: number;
  violated?: string;
  /** An action property, which TLC names, unlike the rest of the temporal ones. */
  action?: string;
  temporal: boolean;
  completed: boolean;
}

/** Runs TLC on `module` with `cfgText` in a fresh folder under `outDir`; `files` replaces model files (planted bugs, TraceObs). */
export async function runTlc(opts: {
  outDir: string; label: string; module: string; cfgText: string;
  files?: Record<string, string>; extraArgs?: string[]; workers?: number; timeoutMs?: number;
}): Promise<TlcRun> {
  const { java, jar } = tools();
  const work = join(opts.outDir, opts.label);
  mkdirSync(join(work, "tmp"), { recursive: true, mode: 0o700 });
  for (const name of readdirSync(tlaDir)) if (/\.(tla|cfg)$/.test(name)) cpSync(join(tlaDir, name), join(work, name));
  for (const [name, text] of Object.entries(opts.files ?? {})) writeFileSync(join(work, name), text);
  const cfgName = `${opts.label}.run.cfg`;
  writeFileSync(join(work, cfgName), opts.cfgText);
  const command = [java, "-Xmx3g", "-XX:+UseParallelGC", `-Djava.io.tmpdir=${join(work, "tmp")}`, "-cp", jar, "tlc2.TLC",
    "-workers", String(opts.workers ?? 4), "-metadir", join(work, "states"), "-config", cfgName, ...(opts.extraArgs ?? []), `${opts.module}.tla`];
  const log = join(work, "tlc.log");
  const fd = openSync(log, "w", 0o600);
  const started = Date.now();
  let exit: number;
  try {
    const child = Bun.spawn(command, { cwd: work, stdin: "ignore", stdout: fd, stderr: fd });
    const timer = setTimeout(() => child.kill("SIGKILL"), opts.timeoutMs ?? 600_000);
    exit = await child.exited;
    clearTimeout(timer);
  } finally { closeSync(fd); }
  const output = readFileSync(log, "utf8");
  const stats = /([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue/.exec(output);
  const num = (s?: string) => (s === undefined ? undefined : Number(s.replaceAll(",", "")));
  return {
    label: opts.label, module: opts.module, config: cfgName, command, exit, seconds: (Date.now() - started) / 1000, log, output,
    generated: num(stats?.[1]), distinct: num(stats?.[2]), queued: num(stats?.[3]),
    violated: /Invariant (\w+) is violated/.exec(output)?.[1],
    action: /Action property (\w+) is violated/.exec(output)?.[1],
    temporal: output.includes("Temporal properties were violated"),
    completed: output.includes("Model checking completed. No error has been found."),
  };
}

/** Config text keeping the invariants, with PROPERTY limited to `keep` (or none). */
export function configWith(cfgText: string, change: { onlyProperty?: string; invariants?: string[] }): string {
  const lines = cfgText.split("\n");
  const out: string[] = [];
  let section = "";
  for (const raw of lines) {
    const words = raw.split("\\*")[0]!.trim().split(/\s+/).filter(Boolean);
    if (words.length && /^[A-Z]+$/.test(words[0]!) && ["CONSTANTS", "CONSTANT", "SPECIFICATION", "INIT", "NEXT", "INVARIANT", "INVARIANTS", "PROPERTY", "PROPERTIES"].includes(words[0]!)) {
      section = words[0]!;
      if (section.startsWith("PROPERT") && change.onlyProperty !== undefined) continue;
      if (section.startsWith("INVARIANT") && change.invariants !== undefined) continue;
      out.push(raw);
      continue;
    }
    if (section.startsWith("PROPERT") && change.onlyProperty !== undefined) continue;
    if (section.startsWith("INVARIANT") && change.invariants !== undefined) continue;
    out.push(raw);
  }
  if (change.invariants?.length) out.push("INVARIANTS", ...change.invariants.map((n) => `    ${n}`));
  if (change.onlyProperty) out.push(`PROPERTY ${change.onlyProperty}`);
  return out.join("\n") + "\n";
}
