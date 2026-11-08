// Exhaustive TLC check of tests/tla/acp/AcpPromptDelivery.tla plus its
// planted bugs: each mutant must violate the property it names, checked
// alone, which shows that property catches that mistake. The rules have not
// landed in src/acp/ yet, so there is no driver of fx here; the model's
// Today configs, in tests/tla/acp/check.sh, show fx's ACP path now.
//
//   bun tests/tla/drivers/acp/prompt_delivery/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

/// `msgs` names the message set in MCAcpPromptDelivery.tla the mutant needs.
type Mutant = { id: string; note: string; from: string; to: string; expect: string; msgs?: "MCMsgs" | "MCRefusals" };

const MUTANTS: Mutant[] = [
  {
    id: "no-interrupt",
    note: "a steer that arrives while the model streams waits instead of cutting the reply short (X20)",
    from: `[] Kind(m) = "steer" /\\ phase = "gen" /\\ Rules ->`,
    to: `[] Kind(m) = "steer" /\\ phase = "gen" /\\ FALSE ->`,
    expect: "NoSteerWaitsOnReply",
  },
  {
    id: "reply-end-ends",
    note: "a reply that ends while steers wait ends the turn instead of going on (X22)",
    from: `    /\\ IF waiting # <<>>\n       THEN /\\ phase' = "gen"`,
    to: `    /\\ IF FALSE\n       THEN /\\ phase' = "gen"`,
    expect: "ReplyEndContinues",
  },
  {
    id: "finishing-steer-fails",
    note: "a steer that arrives while the turn finishes fails with -32600, as today (X19)",
    from: `       THEN /\\ late' = late \\o waiting\n            /\\ UNCHANGED answers`,
    to: `       THEN /\\ answers' = [m \\in Msgs |-> IF m \\in Range(waiting) THEN Err(-32600) ELSE answers[m]]\n            /\\ UNCHANGED late`,
    expect: "NothingLost",
  },
  {
    id: "stop-forgets-waiting",
    note: "a stop drops the steers that were waiting, with no answer (Q39)",
    from: `       THEN LET handed == late \\o waiting IN`,
    to: `       THEN LET handed == late IN`,
    expect: "NothingLost",
  },
  {
    id: "queue-refused",
    note: "a queued prompt fails like a prompt during a turn, as today",
    from: `[] Kind(m) = "queue" /\\ Rules ->`,
    to: `[] Kind(m) = "queue" /\\ FALSE ->`,
    expect: "NothingLost",
  },
  {
    id: "queue-lifo",
    note: "the newest queued prompt runs first",
    from: `/\\ queue' = Append(queue, m)`,
    to: `/\\ queue' = <<m>> \\o queue`,
    expect: "QueuedInOrder",
  },
  {
    id: "late-one-at-a-time",
    note: "late steers run one turn each instead of together (Q40)",
    from: `/\\ late' = IF Rules THEN <<>> ELSE Tail(late)`,
    to: `/\\ late' = Tail(late)`,
    expect: "LateRunTogether",
  },
  {
    id: "queue-before-late",
    note: "a queued prompt runs before the steers that arrived late",
    from: `    CASE late # <<>> ->`,
    to: `    CASE late # <<>> /\\ queue = <<>> ->`,
    expect: "LateRunTogether",
  },
  {
    id: "withdraw-unanswered",
    note: "$/cancel_request removes a waiting prompt without answering it",
    from: `    /\\ answers' = [answers EXCEPT ![m] = Err(-32800)]`,
    to: `    /\\ answers' = answers`,
    expect: "NothingLost",
  },
  {
    id: "tool-end-places-twice",
    note: "the turn's next request after a tool holds its earlier prompts again",
    from: `    /\\ placed' = Place(Range(waiting))\n    /\\ waiting' = <<>>\n    /\\ UNCHANGED <<sent, running, late, queue, answers, started, tools, cancels, closed>>`,
    to: `    /\\ placed' = Place(Range(waiting) \\cup cur.ctx)\n    /\\ waiting' = <<>>\n    /\\ UNCHANGED <<sent, running, late, queue, answers, started, tools, cancels, closed>>`,
    expect: "AtMostOnce",
  },
  {
    id: "close-answers-again",
    note: "session/close answers prompts that already have their answer",
    from: `IF running /\\ m \\in cur.ctx THEN Ok("cancelled", Delivery(cur, m))`,
    to: `IF m \\in cur.ctx \\/ answers[m].kind # "none" THEN Ok("cancelled", Delivery(cur, m))`,
    expect: "AnsweredOnce",
  },
  {
    id: "image-steer-waits",
    note: "a steer with an image waits like a text steer",
    from: `              [] m = "I" ->`,
    to: `              [] FALSE ->`,
    expect: "ImageSteerRefused",
    msgs: "MCRefusals",
  },
  {
    id: "stop-fails-steers",
    note: "session/cancel fails the steers it finds waiting, as fx did before the rules",
    from: `            /\\ answers' = AnswerTurn(cur, "cancelled")`,
    to: `            /\\ answers' = [m \\in Msgs |-> IF m \\in Range(waiting) THEN Err(-32800) ELSE AnswerTurn(cur, "cancelled")[m]]`,
    expect: "StopKeepsSteers",
  },
];

const SPEC_FILES = ["AcpPromptDelivery.tla", "MCAcpPromptDelivery.tla", "MCAcpPromptDelivery.cfg", "MCAcpPromptDeliveryRefusals.cfg"];
const ACTION_PROPERTIES = new Set(["AnsweredOnce", "ReplyEndContinues", "LateRunTogether", "ImageSteerRefused", "StopKeepsSteers"]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string, msgs: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    `    Msgs <- ${msgs}`,
    "    MaxTools = 1",
    "    MaxCancels = 1",
    "    AllowClose = TRUE",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-prompt-delivery-spec");

  const bases = [];
  for (const cfg of ["MCAcpPromptDelivery.cfg", "MCAcpPromptDeliveryRefusals.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpPromptDelivery.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpPromptDelivery.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpPromptDelivery.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect, mutant.msgs ?? "MCMsgs"));
    const run = await runTlc(dir, "MCAcpPromptDelivery.tla", "Target.cfg", ["MCAcpPromptDelivery.tla"]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ ...mutant, exitCode: run.exitCode, violated: run.violated, killed });
  }

  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    bases,
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!bases.every((base) => base.passed) || !summary.allKilled) process.exit(1);
}

await main();
