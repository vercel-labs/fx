// Runs checks of tests/tla/sdk/ProviderAuth.tla with the TLC that
// ../lib/tlc.ts finds.
// A check is a generated module that fixes the model's constants, a config
// naming the properties, and the verdict each property must have.
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { TLA_ROOT, tlcToolchain } from "../lib/tlc";

const tlaDir = join(TLA_ROOT, "sdk");

export const PROPERTIES = ["TypeOK", "NoRefreshReuse", "AtMostOneResend", "NoForeignToken", "ScopedAuth", "KeyNeverRefreshed"] as const;
export type Property = (typeof PROPERTIES)[number];
export type Verdict = "HOLDS" | "VIOLATED" | "TOOL_ERROR";

/** The model's constants for one check. */
export interface Setup {
  provider: "codex" | "grok" | "custom";
  /** Request id to engine id and URL kind, in order. */
  requests: Array<{ id: string; engine: string; url: "provider" | "other" }>;
  expiring: boolean;
  rejecting: boolean;
  foreignRefresh: boolean;
  checkAccount: boolean;
  scopeAll: boolean;
  noSingleFlight: boolean;
  /** The fixed design: one agent's engines share a memory. */
  sharedMemory?: boolean;
  /** The fixed design: a 401 retries on newer credentials before refreshing. */
  recheck?: boolean;
  /** The host's refreshLock: refreshes take turns across memories. */
  lock?: boolean;
}

const sha256 = (bytes: string | Buffer) => createHash("sha256").update(bytes).digest("hex");
const str = (value: string) => {
  if (!/^[a-z0-9]+$/.test(value)) throw new Error(`refusing unsafe TLA+ string ${JSON.stringify(value)}`);
  return `"${value}"`;
};
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

/** TLA+ definitions of the constants, named MC*. */
export function constantDefinitions(setup: Setup): string {
  const ids = setup.requests.map((r) => str(r.id)).join(", ");
  const engines = [...new Set(setup.requests.map((r) => str(r.engine)))].join(", ");
  const pick = (field: "engine" | "url") =>
    setup.requests.map((r, n) => `${n === 0 ? "IF" : "ELSE IF"} r = ${str(r.id)} THEN ${str(r[field])}`).join(" ") + ` ELSE "none"`;
  return [
    `MCProvider == ${str(setup.provider)}`,
    `MCEngines == {${engines}}`,
    `MCRequests == {${ids}}`,
    `MCEngineOf == [r \\in MCRequests |-> ${pick("engine")}]`,
    `MCUrlOf == [r \\in MCRequests |-> ${pick("url")}]`,
    `MCExpiring == ${bool(setup.expiring)}`,
    `MCRejecting == ${bool(setup.rejecting)}`,
    `MCForeignRefresh == ${bool(setup.foreignRefresh)}`,
    `MCCheckAccount == ${bool(setup.checkAccount)}`,
    `MCScopeAll == ${bool(setup.scopeAll)}`,
    `MCNoSingleFlight == ${bool(setup.noSingleFlight)}`,
    `MCSharedMemory == ${bool(setup.sharedMemory ?? false)}`,
    `MCRecheck == ${bool(setup.recheck ?? false)}`,
    `MCLock == ${bool(setup.lock ?? false)}`,
  ].join("\n");
}

export const constantOverrides = [
  "Provider <- MCProvider", "Engines <- MCEngines", "Requests <- MCRequests", "EngineOf <- MCEngineOf",
  "UrlOf <- MCUrlOf", "Expiring <- MCExpiring", "Rejecting <- MCRejecting", "ForeignRefresh <- MCForeignRefresh",
  "CheckAccount <- MCCheckAccount", "ScopeAll <- MCScopeAll", "NoSingleFlight <- MCNoSingleFlight",
  "SharedMemory <- MCSharedMemory", "Recheck <- MCRecheck", "Lock <- MCLock",
].map((line) => `  ${line}`).join("\n");

export interface TlcRun { exitCode: number; log: string; dir: string; command: string[] }

export async function runTlc(dir: string, spec: string, cfg: string, extra: string[] = []): Promise<TlcRun> {
  writeFileSync(join(dir, "check.cfg"), cfg, { mode: 0o600 });
  const { java, jar } = tlcToolchain();
  mkdirSync(join(dir, ".tlc-tmp"), { recursive: true });
  const command = [java, "-XX:+UseParallelGC", `-Djava.io.tmpdir=${join(dir, ".tlc-tmp")}`, "-cp", jar, "tlc2.TLC", "-workers", "1",
    "-metadir", join(dir, ".tlc-states"), "-config", "check.cfg", "-deadlock", ...extra, spec];
  const child = Bun.spawn(command, { cwd: dir, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const [exitCode, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
  const log = `${stderr}\n${stdout}`;
  writeFileSync(join(dir, "tlc.log"), log, { mode: 0o600 });
  writeFileSync(join(dir, "result.json"), JSON.stringify({ command, exitCode }, null, 2), { mode: 0o600 });
  return { exitCode, log, dir, command };
}

/** Copies the model modules into a fresh directory, with any generated modules. */
export function stage(root: string, name: string, generated: Record<string, string>): string {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const module of ["ProviderAuth.tla", "AuthTrace.tla"]) copyFileSync(join(tlaDir, module), join(dir, module));
  for (const [file, text] of Object.entries(generated)) writeFileSync(join(dir, file), text, { mode: 0o600 });
  return dir;
}

export const completed = (log: string) => log.includes("Model checking completed. No error has been found.");
export const violated = (log: string, name: string) => log.includes(`Invariant ${name} is violated`);

export function hashes(): Record<string, string> {
  return {
    "ProviderAuth.tla": sha256(readFileSync(join(tlaDir, "ProviderAuth.tla"))),
    "AuthTrace.tla": sha256(readFileSync(join(tlaDir, "AuthTrace.tla"))),
    "tla2tools.jar": tlcToolchain().jarSha256,
  };
}

/** Checks one property exhaustively over the model fixed by `setup`. */
export async function checkModel(root: string, label: string, setup: Setup, property: Property): Promise<{ verdict: Verdict; run: TlcRun; states?: string }> {
  const module = ["---- MODULE MC ----", "EXTENDS ProviderAuth", constantDefinitions(setup), "===="].join("\n");
  const dir = stage(mkdtempSync(join(root, `${label}-${property}-`)), "model", { "MC.tla": module });
  const run = await runTlc(dir, "MC.tla", `SPECIFICATION Spec\nINVARIANT ${property}\nCONSTANTS\n${constantOverrides}\n`);
  const states = /(\d+) distinct states found/.exec(run.log)?.[1];
  if (run.exitCode === 0 && completed(run.log)) return { verdict: "HOLDS", run, states };
  if (run.exitCode === 12 && violated(run.log, property)) return { verdict: "VIOLATED", run, states };
  return { verdict: "TOOL_ERROR", run, states };
}
