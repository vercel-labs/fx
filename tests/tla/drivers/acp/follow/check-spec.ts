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
    from: `THEN Prefix(client[c].has, p) ELSE <<>>`,
    to: `THEN Prefix(client[c].has, p - 1) ELSE <<>>`,
    expect: "InSync",
  },
  {
    id: "catch-up-repeat",
    note: "a catch-up replays the turn at the client's position again",
    from: `SubSeq(saved, p + 1, Len(saved))`,
    to: `SubSeq(saved, IF p > 0 THEN p ELSE 1, Len(saved))`,
    expect: "InSync",
  },
  {
    id: "compaction-rewrites-log",
    note: "a compaction rewrites the saved turns, which a compaction must leave as they are",
    from: `    /\\ saved' = saved`,
    to: `    /\\ saved' = <<0>>`,
    expect: "InSync",
  },
  {
    id: "live-turn-not-sent",
    note: "a saved turn is not sent to the connections that have the session open",
    from: `IF client[c].open`,
    to: `IF FALSE`,
    expect: "InSync",
  },
  {
    id: "replay-new-ids",
    note: "a replayed message gets a new id, as today",
    from: `id |-> IF Rules THEN turns[k] ELSE -1`,
    to: `id |-> -1`,
    expect: "StableIds",
  },
  {
    id: "position-not-updated",
    note: "a saved turn doesn't give the connections the session's new position",
    from: `!.pos = IF Rules THEN Len(saved) + 1 ELSE @]`,
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
    from: `f == IF OpenElsewhere(c) THEN folder ELSE w\n            IN`,
    to: `f == w\n            IN`,
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
    from: `replay |-> label,`,
    to: `replay |-> "none",`,
    expect: "ReplaySaid",
  },
  {
    id: "replay-always-after-position",
    note: "fx answers after_position even when it replays the whole session, so the client keeps its copy and gets the turns twice",
    from: `label == IF ~Rules THEN "none" ELSE IF known THEN "after_position" ELSE "full"`,
    to: `label == IF ~Rules THEN "none" ELSE "after_position"`,
    expect: "InSync",
  },
  {
    id: "forget-sends-old-position",
    note: "a client that lost its messages sends its old position anyway, so fx replays only the turns after it",
    from: `(withPos => ~client[c].lost)`,
    to: `TRUE`,
    expect: "InSync",
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
