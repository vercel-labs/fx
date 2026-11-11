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

// Main is given two related tasks in sequence, both meant for subagents, in
// two prompts of one session: a review, then the fix. The second needs what
// the first one learned, so main should send it to the subagent that already
// has that context instead of starting a new one. Before fx told main which
// subagents were idle, main named a new subagent for each task and left the
// first one idle, so idle subagents piled up. Main may close the reviewer
// when it is done or keep it for more related work; it must not leave a
// second idle subagent behind.

const TIMEOUT = 600_000;
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

type SubagentCall = { action?: string; agent?: string };

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

describe("eval: subagent reuse", () => {
  test(
    "main sends a related second task to the subagent it already used, and leaves no extra idle subagent",
    async () => {
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
        const run = await runFx(["ask", "--auto", "--json", "--timeout", "270", ...args], {
          cwd: workDir!,
          env: { HOME: home!, FX_MODEL: EVAL_MODEL, FX_SOUND: "0" },
          timeoutMs: 285_000,
        });
        if (run.code !== 0) throw new Error(`fx ask failed: code=${run.code}\nstdout=${run.stdout.slice(-2000)}\nstderr=${run.stderr.slice(-2000)}`);
        return JSON.parse(run.stdout.trim());
      };
      const review = await ask([
        "Delegate this to a subagent instead of doing it yourself: have a subagent review src/stats.js and report every bug it finds, without editing any file. Then summarize its findings in one line.",
      ]);
      await ask([
        "--resume", review.session_id,
        "Now have a subagent fix the bugs that review found. When the fixes are in, reply with one line that lists what changed.",
      ]);
      const calls = subagentCalls(home, review.session_id);
      console.log(`  subagent calls: ${JSON.stringify(calls)}`);

      // The work itself got done.
      writeFileSync(join(workDir, "check.js"), CHECK);
      assertCommandSucceeds(workDir, "node check.js");

      // Both tasks went to one subagent.
      const messaged = calls.filter((call) => call.action === "message" && call.agent && call.agent !== "parent");
      expect(messaged.length).toBeGreaterThanOrEqual(2);
      const names = [...new Set(messaged.map((call) => call.agent))];
      expect(names).toHaveLength(1);
      // At most that one is still open at the end.
      const closed = new Set(calls.filter((call) => call.action === "close").map((call) => call.agent));
      expect(names.filter((name) => !closed.has(name)).length).toBeLessThanOrEqual(1);
    },
    TIMEOUT,
  );
});
