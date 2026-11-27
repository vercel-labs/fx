// The bridge grace, timed on the real harness. A bash call that a bridge call
// holds does not yield until the grace has passed since the hold was last seen
// (managed_execution.zig `held`, with contract.bridge_yield_grace_ms). This
// scenario ends a subagent wait, so its hold drops, and then asks the first call
// to yield. The yield must land no sooner than the grace after the drop, and
// within the window the harness gives a yield with no bridge call holding it.
import { Harness } from "./lib.ts";
import { harnessEnv, newHome, type Vars } from "./agent-lib.ts";

/// contract.bridge_yield_grace_ms, as the code defines it.
export const BRIDGE_GRACE_MS = 1000;
/// The harness's window for a yield with no bridge call holding it.
export const YIELD_WINDOW_MS = 1500;
/// managed_execution polls the hold every 10 ms and counts the grace from the
/// last poll that saw it, so the grace can start up to one poll before the
/// drop. The check allows that much, and a little scheduling noise on top.
/// A hold that no poll saw gives no grace, so the wait below holds the call
/// for about 50 ms, long enough for several polls to see it.
export const TIMING_SLACK_MS = 50;

export type GraceRun = { delayMs: number; yielded: boolean; out: string[] };

/// One run: a program starts, its wait takes the subagent's report when the
/// child posts, and the first call then yields. Returns the time from the hold
/// drop to the yield, as the harness measured it.
export async function yieldAfterHold(bin: string, dir: string): Promise<GraceRun> {
  const harness = await Harness.start(bin, newHome(dir), harnessEnv());
  try {
    await harness.send({ event: "run" });
    await harness.send({ event: "start_wait" });
    const posted = await harness.send({ event: "post" });
    requireState(posted.state, "the post ends the wait with mail", { call: "none", told: "mail" });
    const reply = await harness.send({ event: "yield" });
    const note = reply.out.find((line) => /^yield \d+ ms after the hold dropped$/.test(line));
    if (note === undefined) throw new Error(`the yield gave no timing note: ${JSON.stringify(reply.out)}`);
    return {
      delayMs: Number(/^yield (\d+) ms/.exec(note)![1]),
      yielded: reply.state.bash === "yielded",
      out: reply.out,
    };
  } finally {
    await harness.close();
  }
}

/// What is wrong with one run of the scenario. Empty when the grace held.
export function graceProblems(run: GraceRun): string[] {
  const problems: string[] = [];
  if (!run.yielded) problems.push(`the yield did not land within ${YIELD_WINDOW_MS} ms`);
  if (run.delayMs < BRIDGE_GRACE_MS - TIMING_SLACK_MS) {
    problems.push(`the yield came ${run.delayMs} ms after the hold dropped, before the ${BRIDGE_GRACE_MS} ms grace`);
  }
  if (run.delayMs > YIELD_WINDOW_MS + TIMING_SLACK_MS) {
    problems.push(`the yield came ${run.delayMs} ms after the hold dropped, after the ${YIELD_WINDOW_MS} ms window`);
  }
  return problems;
}

function requireState(state: Vars, what: string, want: Record<string, unknown>) {
  for (const [key, value] of Object.entries(want)) {
    if (state[key] !== value) throw new Error(`${what}: ${key} is ${JSON.stringify(state[key])}, want ${JSON.stringify(value)}`);
  }
}
