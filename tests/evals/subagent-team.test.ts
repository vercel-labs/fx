import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertCommandSucceeds,
  cleanupIsolatedTestHome,
  cleanupWorkDir,
  createIsolatedTestHome,
  createWorkDir,
  EVAL_MODEL,
  runFx,
} from "./eval-helpers";

// Main manages its subagents the way a lead manages a team. Every subagent
// keeps its conversation until main closes it, and fx closes none on its
// own, so main must judge each one: keep a subagent whose context related
// work will need, close one whose work is done, and ask the user when only
// the user knows. fx gives it the facts (its list of subagents at each
// turn's start, the idle ones when it starts another, and a note on each
// report); these cases check what main does with them.

const TIMEOUT = 900_000;
let workDir: string | null = null;
let home: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
  if (home) { cleanupIsolatedTestHome(home); home = null; }
});

const STATS = `// Small statistics helpers.
function mean(values) {
  let sum = 0;
  for (let i = 0; i <= values.length; i++) sum += values[i] ?? 0;
  return sum / values.length;
}

function median(values) {
  const sorted = values.sort();
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : sorted[mid];
}

function range(values) {
  return Math.max(...values) - Math.min(values);
}

module.exports = { mean, median, range };
`;

const CHECK = `const assert = require("node:assert");
const { mean, median, range } = require("./src/stats.js");
assert.strictEqual(mean([1, 2, 3, 4]), 2.5);
const input = [10, 9, 2, 1];
assert.strictEqual(median(input), 5.5);
assert.deepStrictEqual(input, [10, 9, 2, 1]);
assert.strictEqual(median([3, 1, 2]), 2);
assert.strictEqual(range([4, 9, 1]), 8);
console.log("ok");
`;

type SubagentCall = { action?: string; agent?: string; message?: string };

/** Main's subagent calls, in order, from its saved session log. */
function subagentCalls(fxHome: string, sessionId: string): SubagentCall[] {
  const log = join(fxHome, ".fx", "sessions", "v2", sessionId, "log.jsonl");
  if (!existsSync(log)) throw new Error(`no saved log for ${sessionId}`);
  const calls: SubagentCall[] = [];
  for (const line of readFileSync(log, "utf8").split("\n")) {
    if (!line) continue;
    const entry = JSON.parse(line);
    if (entry.kind !== "item" || entry.type !== "tool_call" || entry.data?.tool_name !== "subagent") continue;
    const args = JSON.parse(entry.data.arguments_json ?? "{}");
    calls.push(args.request ?? args);
  }
  return calls;
}

/** The subagents main messaged, in the order it first did. */
function messagedNames(calls: SubagentCall[]): string[] {
  const names: string[] = [];
  for (const call of calls) {
    if (call.action !== "message" || !call.agent || call.agent === "parent") continue;
    if (!names.includes(call.agent)) names.push(call.agent);
  }
  return names;
}

/** The subagents still open after main's last call. A message after a close
 * starts a new one under that name. */
function openAtEnd(calls: SubagentCall[]): string[] {
  const open = new Set<string>();
  for (const call of calls) {
    if (!call.agent || call.agent === "parent") continue;
    if (call.action === "message") open.add(call.agent);
    if (call.action === "close") open.delete(call.agent);
  }
  return [...open];
}

function setup(): { ask: (args: string[]) => Promise<any> } {
  workDir = createWorkDir();
  home = createIsolatedTestHome();
  mkdirSync(join(workDir, "src"), { recursive: true });
  writeFileSync(join(workDir, "src", "stats.js"), STATS);
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({
    permission_mode: "auto",
    permission: { bash: "allow", edit: "allow", read: "allow" },
  }) + "\n", { mode: 0o600 });
  const ask = async (args: string[]) => {
    const run = await runFx(["ask", "--auto", "--json", "--timeout", "420", ...args], {
      cwd: workDir!,
      env: { HOME: home!, FX_MODEL: EVAL_MODEL, FX_SOUND: "0" },
      timeoutMs: 435_000,
    });
    if (run.code !== 0) throw new Error(`fx ask failed: code=${run.code}\nstdout=${run.stdout.slice(-2000)}\nstderr=${run.stderr.slice(-2000)}`);
    return JSON.parse(run.stdout.trim());
  };
  return { ask };
}

describe("eval: subagent team", () => {
  // A builder makes the fix and a second subagent reviews it. The builder
  // has the context the review's findings need, so main keeps it through the
  // review and sends it any fixes, rather than closing it early or starting
  // a third subagent. Once the work is done, main closes what nothing ahead
  // needs, or names what it kept and asks the user about it.
  test(
    "main keeps the builder through the review, sends it the fixes, and leaves no subagent unaccounted for",
    async () => {
      const { ask } = setup();
      const result = await ask([
        [
          "Work as a lead with a small team of subagents; do not edit files yourself.",
          "Have one subagent fix the bugs in src/stats.js: mean, median, and range are wrong, and median must not change its input.",
          "When it reports, have a different subagent review that change without editing any file.",
          "If the review finds a problem, get it fixed.",
          "When the work is done, reply with one line about what changed.",
        ].join(" "),
      ]);
      const calls = subagentCalls(home!, result.session_id);
      const finalText = String(result.final_output ?? result.output ?? "");
      console.log(`  subagent calls: ${JSON.stringify(calls.map(({ action, agent }) => ({ action, agent })))}`);
      console.log(`  final: ${finalText.slice(0, 400)}`);

      writeFileSync(join(workDir!, "check.js"), CHECK);
      assertCommandSucceeds(workDir!, "node check.js");

      const names = messagedNames(calls);
      expect(names.length).toBeGreaterThanOrEqual(2);
      const [builder, reviewer] = names as [string, string];
      const reviewStart = calls.findIndex((call) => call.action === "message" && call.agent === reviewer);
      // The builder was not closed before the review started.
      expect(calls.slice(0, reviewStart).some((call) => call.action === "close" && call.agent === builder)).toBe(false);
      // Fixes after the review went to the builder, not to a third subagent.
      expect(names.length).toBe(2);
      // Each subagent still open at the end is one main told the user about.
      for (const name of openAtEnd(calls)) expect(finalText).toContain(name);
    },
    TIMEOUT,
  );

  // Four one-question subagents finish, and nothing ahead needs any of
  // them. Main closes them, or tells the user which it kept and asks; it
  // does not leave them all idle without a word.
  test(
    "main closes finished one-question subagents or asks the user about them",
    async () => {
      const { ask } = setup();
      const result = await ask([
        [
          "Use one subagent per question, in parallel, and answer from their reports:",
          "1. How many functions does src/stats.js export?",
          "2. Which function in src/stats.js reads past the end of its array?",
          "3. Which function in src/stats.js changes its input?",
          "4. Which function in src/stats.js passes an array to Math.min?",
          "Reply with the four answers, one per line.",
        ].join(" "),
      ]);
      const calls = subagentCalls(home!, result.session_id);
      const finalText = String(result.final_output ?? result.output ?? "");
      console.log(`  subagent calls: ${JSON.stringify(calls.map(({ action, agent }) => ({ action, agent })))}`);
      console.log(`  final: ${finalText.slice(0, 600)}`);

      const names = messagedNames(calls);
      expect(names.length).toBeGreaterThanOrEqual(2);
      const open = openAtEnd(calls);
      // Either main closed the finished ones, or it named each one it kept
      // for the user.
      for (const name of open) expect(finalText).toContain(name);
    },
    TIMEOUT,
  );
});
