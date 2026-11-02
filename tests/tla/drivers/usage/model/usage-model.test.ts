import { expect, test } from "bun:test";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { artifacts, repetitions, targetHelpers, worktree } from "../../lib/context";
import { TLA_ROOT } from "../../lib/tlc";
import { runChecks, simulate } from "./model";
import { Divergence, replay, type Env } from "./driver";
import { parseBehavior } from "./tla-trace";

const seed = (name: string, fallback: number) => Number(process.env[name] ?? fallback);
const count = (name: string, fallback: number) => Number(process.env[name] ?? fallback);

async function env(): Promise<Env> {
  const { TmuxSession, startFakeGateway } = await targetHelpers();
  const fakes = await import(pathToFileURL(join(worktree, "tests/e2e/usage-fakes.ts")).href);
  const cwd = join(artifacts, "workspace");
  mkdirSync(cwd, { recursive: true, mode: 0o700 });
  return { TmuxSession, startFakeGateway, usageEnv: fakes.usageEnv, utcDate: fakes.utcDate, writeUsageClock: fakes.writeUsageClock, cwd };
}

async function replayAll(label: string, hostile: boolean, traces: number, seedValue: number, given?: string[]) {
  const out = join(artifacts, label);
  mkdirSync(out, { recursive: true, mode: 0o700 });
  const files = given ?? await simulate(out, "tlc", hostile, traces, 30, seedValue);
  const e = await env();
  const results: Array<Record<string, unknown>> = [];
  for (let repetition = 0; repetition < repetitions; repetition++) {
    for (const file of files) {
      const name = file.split("/").pop()!;
      const root = join(out, `r${repetition}-${name}`);
      mkdirSync(root, { recursive: true, mode: 0o700 });
      const states = parseBehavior(readFileSync(file, "utf8"));
      const started = Date.now();
      try {
        const run = await replay(e, states, root);
        results.push({ trace: name, repetition, status: "pass", ms: Date.now() - started, ...run });
      } catch (err) {
        const detail = err instanceof Divergence ? err.detail : { stack: String((err as Error).stack) };
        results.push({ trace: name, repetition, status: err instanceof Divergence ? "diverged" : "error", message: (err as Error).message, file, ...detail });
      }
      writeFileSync(join(out, "results.json"), JSON.stringify({ seed: seedValue, hostile, traces: files.length, results }, null, 2));
    }
  }
  return results;
}

test("TLC: ideal and non-ideal conditions hold and planted bugs are caught", async () => {
  const out = join(artifacts, "tlc-checks");
  mkdirSync(out, { recursive: true, mode: 0o700 });
  const results = await runChecks(out);
  writeFileSync(join(out, "checks.json"), JSON.stringify(results.map(({ config, ...r }) => r), null, 2));
  const failed = results.filter((r) => !r.passed).map((r) => `${r.label}: expected ${r.expect} ${r.names ?? ""}, got ${r.verdict} ${r.violated ?? ""}`);
  expect(failed).toEqual([]);
}, 3_600_000);

test("Bun replays ideal behaviors from TLC against the real binary", async () => {
  const results = await replayAll("ideal", false, count("FX_USAGE_MODEL_IDEAL", 12), seed("FX_USAGE_MODEL_IDEAL_SEED", 777));
  expect(results.filter((r) => r.status !== "pass").map((r) => `${r.trace}: ${r.message}`)).toEqual([]);
}, 3_600_000);

test("Bun replays non-ideal behaviors (failures, crashes, unreadable cache, clock correction) against the real binary", async () => {
  const results = await replayAll("hostile", true, count("FX_USAGE_MODEL_HOSTILE", 24), seed("FX_USAGE_MODEL_HOSTILE_SEED", 4242));
  expect(results.filter((r) => r.status !== "pass").map((r) => `${r.trace}: ${r.message}`)).toEqual([]);
}, 3_600_000);

test("Bun replays the kept regression traces (behaviors that once diverged) against the real binary", async () => {
  const dir = join(TLA_ROOT, "usage", "traces");
  const files = readdirSync(dir).filter((name) => name.endsWith(".tla")).sort().map((name) => join(dir, name));
  expect(files.length).toBeGreaterThan(0);
  const results = await replayAll("regression", true, 0, 0, files);
  expect(results.filter((r) => r.status !== "pass").map((r) => `${r.trace}: ${r.message}`)).toEqual([]);
}, 1_800_000);
