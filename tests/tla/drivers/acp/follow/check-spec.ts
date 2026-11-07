// Exhaustive TLC check of tests/tla/acp/AcpFollow.tla plus its planted bugs:
// each mutant must violate the property it names, checked alone, which shows
// that property catches that mistake. The rules have not landed in src/acp/
// yet, and following needs a session open on two connections, which needs
// the leader's socket, so there is no driver of fx here; the model's Today
// configs, in tests/tla/acp/check.sh, show fx now.
//
//   bun tests/tla/drivers/acp/follow/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "catch-up-gap",
    note: "a catch-up keeps one turn too few of the client's copy",
    from: `kept == IF known THEN SubSeq(client[c].has, 1, p.n) ELSE <<>>`,
    to: `kept == IF known THEN SubSeq(client[c].has, 1, p.n - 1) ELSE <<>>`,
    expect: "InSync",
  },
  {
    id: "catch-up-repeat",
    note: "a catch-up replays the turn at the client's position again",
    from: `rest == IF known THEN SubSeq(saved, p.n + 1, Len(saved)) ELSE saved`,
    to: `rest == IF known THEN SubSeq(saved, IF p.n > 0 THEN p.n ELSE 1, Len(saved)) ELSE saved`,
    expect: "InSync",
  },
  {
    id: "stale-position-trusted",
    note: "a position from before a compaction counts as known",
    from: `known == Rules /\\ withPos /\\ p.gen = gen /\\ 0 <= p.n /\\ p.n <= Len(saved)`,
    to: `known == Rules /\\ withPos /\\ 0 <= p.n /\\ p.n <= Len(saved)`,
    expect: "InSync",
  },
  {
    id: "live-turn-not-sent",
    note: "a saved turn is not sent to the connections that have the session open",
    from: `            IF client[c].open\n            THEN [client[c] EXCEPT !.has = Append(@, Live(turnsRun)),`,
    to: `            IF FALSE\n            THEN [client[c] EXCEPT !.has = Append(@, Live(turnsRun)),`,
    expect: "InSync",
  },
  {
    id: "replay-new-ids",
    note: "a replayed message gets a new id, as today (X21)",
    from: `id |-> IF Rules THEN turns[k] ELSE -1`,
    to: `id |-> -1`,
    expect: "StableIds",
  },
  {
    id: "position-not-updated",
    note: "a saved turn doesn't give the connections the session's new position",
    from: `!.pos = IF Rules THEN [gen |-> gen, n |-> Len(saved) + 1] ELSE @]`,
    to: `!.pos = @]`,
    expect: "PositionCurrent",
  },
  {
    id: "second-client-busy",
    note: "a second client can't load a session open elsewhere, as today",
    from: `    /\\ IF ~Rules /\\ OpenElsewhere(c)\n       THEN \\* Today the session is busy for a second client.`,
    to: `    /\\ IF OpenElsewhere(c)\n       THEN \\* Today the session is busy for a second client.`,
    expect: "JoinWorks",
  },
  {
    id: "joiner-sets-folder",
    note: "a client that loads a session open elsewhere replaces its folder",
    from: `                f == IF OpenElsewhere(c) THEN folder ELSE w\n            IN`,
    to: `                f == w\n            IN`,
    expect: "KeepsFolder",
  },
  {
    id: "close-stops-turn",
    note: "closing on one connection stops a turn another connection still follows",
    from: `    /\\ IF running /\\ ~OpenElsewhere(c)`,
    to: `    /\\ IF running`,
    expect: "CloseOnlyDetaches",
  },
  {
    id: "replay-unsaid",
    note: "a load doesn't say how it replayed",
    from: `replay |-> IF ~Rules THEN "none" ELSE IF known THEN "after_position" ELSE "full",`,
    to: `replay |-> "none",`,
    expect: "ReplaySaid",
  },
];

const SPEC_FILES = ["AcpFollow.tla", "MCAcpFollow.tla", "MCAcpFollow.cfg"];
const ACTION_PROPERTIES = new Set(["JoinWorks", "KeepsFolder", "CloseOnlyDetaches"]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake whichever one TLC would check first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    "    Conns <- MCConns",
    "    Folders <- MCFolders",
    "    MaxTurns = 3",
    "    MaxCompactions = 1",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-follow-spec");

  const bases = [];
  for (const cfg of ["MCAcpFollow.cfg"]) {
    const run = await runTlc(join(reportDir, "base", cfg), "MCAcpFollow.tla", cfg, SPEC_FILES);
    const passed = run.exitCode === 0 && /No error has been found/.test(run.output);
    console.log(`base ${cfg}: ${passed ? "PASS" : "FAIL"} (exit ${run.exitCode}, ${run.distinctStates} distinct states, depth ${run.depth})`);
    bases.push({ cfg, passed, exitCode: run.exitCode, distinctStates: run.distinctStates, depth: run.depth });
  }

  const source = readFileSync(join(SPEC_DIR, "AcpFollow.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpFollow.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpFollow.tla", "Target.cfg", ["MCAcpFollow.tla"]);
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
