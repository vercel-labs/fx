// Exhaustive TLC checks of tests/tla/acp/AcpJoin.tla plus its planted bugs.
// The base config must find no error, with fx's join (Rules TRUE). The Today
// config, fx before the join, must violate JoinWorks: a second connection's
// load is refused, so no connection joins. Each planted bug must violate the
// property it names, checked alone, which shows that property catches that
// mistake. The model covers a second connection joining a session another
// connection has open: the load's replay, the running copy and its notice, the
// answer, the live updates, a resume, a close, and a follower's refused change.
//
//   bun tests/tla/drivers/acp/join/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

type Replacement = { from: string; to: string };
type Mutant = { id: string; note: string; replacements: Replacement[]; expect: string };

const AUDIENCE = String.raw`Audience(j) == joiner[j] \in {"loaded", "resumed"}`;
const NEXT_LOAD = String.raw`        \/ Load(j)`;
const NEXT_HEAD = "\nNext ==\n";

// The planted bugs that split a join into two actions. Each one is put in the
// spec before Next, and Next runs the two halves where Load(j) ran.
const SPLIT_READ_THEN_COPY = [
  String.raw`SplitA(j) ==`,
  String.raw`    /\ Rules`,
  String.raw`    /\ joiner[j] = "out"`,
  String.raw`    /\ joiner' = [joiner EXCEPT ![j] = "listed"]`,
  String.raw`    /\ got' = [got EXCEPT ![j] = log]`,
  String.raw`    /\ mark' = [mark EXCEPT ![j] = Len(owner)]`,
  String.raw`    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, skip, closedLen, early, changed>>`,
  "",
  String.raw`SplitB(j) ==`,
  String.raw`    /\ joiner[j] = "listed"`,
  String.raw`    /\ joiner' = [joiner EXCEPT ![j] = "loaded"]`,
  String.raw`    /\ got' = [got EXCEPT ![j] = got[j] \o copy \o (IF dropped THEN <<Note>> ELSE <<>>) \o <<Ans>>]`,
  String.raw`    /\ skip' = [skip EXCEPT ![j] = SkipAtJoin]`,
  String.raw`    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, mark, closedLen, early, changed>>`,
].join("\n");

const LIST_THEN_REPLAY = [
  String.raw`ListR(j) ==`,
  String.raw`    /\ Rules`,
  String.raw`    /\ joiner[j] = "out"`,
  String.raw`    /\ joiner' = [joiner EXCEPT ![j] = "listed"]`,
  String.raw`    /\ got' = [got EXCEPT ![j] = <<>>]`,
  String.raw`    /\ mark' = [mark EXCEPT ![j] = Len(owner)]`,
  String.raw`    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, skip, closedLen, early, changed>>`,
  "",
  String.raw`ReplayR(j) ==`,
  String.raw`    /\ joiner[j] = "listed"`,
  String.raw`    /\ joiner' = [joiner EXCEPT ![j] = "loaded"]`,
  String.raw`    /\ got' = [got EXCEPT ![j] = got[j] \o log \o copy \o (IF dropped THEN <<Note>> ELSE <<>>) \o <<Ans>>]`,
  String.raw`    /\ skip' = [skip EXCEPT ![j] = SkipAtJoin]`,
  String.raw`    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, mark, closedLen, early, changed>>`,
].join("\n");

const LIST_THEN_ANSWER = [
  String.raw`ListA(j) ==`,
  String.raw`    /\ Rules`,
  String.raw`    /\ joiner[j] = "out"`,
  String.raw`    /\ joiner' = [joiner EXCEPT ![j] = "listed"]`,
  String.raw`    /\ got' = [got EXCEPT ![j] = log \o copy \o (IF dropped THEN <<Note>> ELSE <<>>)]`,
  String.raw`    /\ mark' = [mark EXCEPT ![j] = Len(owner)]`,
  String.raw`    /\ skip' = [skip EXCEPT ![j] = SkipAtJoin]`,
  String.raw`    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, closedLen, early, changed>>`,
  "",
  String.raw`AnsA(j) ==`,
  String.raw`    /\ joiner[j] = "listed"`,
  String.raw`    /\ joiner' = [joiner EXCEPT ![j] = "loaded"]`,
  String.raw`    /\ got' = [got EXCEPT ![j] = Append(got[j], Ans)]`,
  String.raw`    /\ UNCHANGED <<turn, phase, sent, runItems, copy, dropped, log, owner, mark, skip, closedLen, early, changed>>`,
].join("\n");

const MUTANTS: Mutant[] = [
  {
    id: "release-at-turn-end",
    note: "the save keeps the running copy, and only Release frees it",
    replacements: [
      {
        from: [
          "    /\\ copy' = <<>>",
          "    /\\ dropped' = FALSE",
          "    /\\ UNCHANGED <<turn, sent, runItems, owner, joiner",
        ].join("\n"),
        to: ["    /\\ UNCHANGED <<copy, dropped>>", "    /\\ UNCHANGED <<turn, sent, runItems, owner, joiner"].join("\n"),
      },
    ],
    expect: "LoadSeesAll",
  },
  {
    id: "join-without-write-lock",
    note: "the join reads the saved turns in one step and the copy in a later one, so a save can come between",
    replacements: [
      { from: NEXT_LOAD, to: "        \\/ SplitA(j)\n        \\/ SplitB(j)" },
      { from: NEXT_HEAD, to: `\n${SPLIT_READ_THEN_COPY}\n\nNext ==\n` },
    ],
    expect: "LoadSeesAll",
  },
  {
    id: "list-before-replay",
    note: "the joiner is listed before the replay, so an update sent between the two lands before the replay",
    replacements: [
      { from: NEXT_LOAD, to: "        \\/ ListR(j)\n        \\/ ReplayR(j)" },
      { from: NEXT_HEAD, to: `\n${LIST_THEN_REPLAY}\n\nNext ==\n` },
      { from: AUDIENCE, to: String.raw`Audience(j) == joiner[j] \in {"loaded", "resumed", "listed"}` },
    ],
    expect: "AnswerFirst",
  },
  {
    id: "list-before-answer",
    note: "the joiner is listed, and gets updates, before its answer is written",
    replacements: [
      { from: NEXT_LOAD, to: "        \\/ ListA(j)\n        \\/ AnsA(j)" },
      { from: NEXT_HEAD, to: `\n${LIST_THEN_ANSWER}\n\nNext ==\n` },
      { from: AUDIENCE, to: String.raw`Audience(j) == joiner[j] \in {"loaded", "resumed", "listed"}` },
    ],
    expect: "AnswerFirst",
  },
  {
    id: "follower-change-accepted",
    note: "a follower's change to the session is applied",
    replacements: [{ from: String.raw`    /\ changed' = changed`, to: String.raw`    /\ changed' = TRUE` }],
    expect: "FollowerChangesNothing",
  },
  {
    id: "closed-still-listed",
    note: "a closed connection stays in the audience and keeps getting updates",
    replacements: [{ from: AUDIENCE, to: String.raw`Audience(j) == joiner[j] \in {"loaded", "resumed", "closed"}` }],
    expect: "ClosedGetsNothing",
  },
  {
    id: "copy-past-limit",
    note: "the copy keeps updates past its limit and never marks a drop",
    replacements: [
      {
        from: [
          String.raw`    /\ copy' = IF Keeps THEN Append(copy, SendItem) ELSE copy`,
          String.raw`    /\ dropped' = (dropped \/ ~Keeps)`,
        ].join("\n"),
        to: [String.raw`    /\ copy' = Append(copy, SendItem)`, String.raw`    /\ dropped' = dropped`].join("\n"),
      },
    ],
    expect: "CopyBounded",
  },
];

const SPEC_FILES = ["AcpJoin.tla", "MCAcpJoin.tla", "MCAcpJoin.cfg", "AcpJoinToday.cfg"];

/// The constants every config here uses: two joiners, two turns of two updates,
/// a copy of one update, and fx's join.
const MC_CONSTANTS = ["    Joiners = {j1, j2}", "    MaxTurns = 2", "    MaxSends = 2", "    Limit = 1", "    Rules = TRUE"];

/// The config that checks one planted bug: its named invariant, alone.
function targetCfg(target: string): string {
  return ["CONSTANTS", ...MC_CONSTANTS, "INIT Init", "NEXT Next", `INVARIANT ${target}`, "CHECK_DEADLOCK FALSE", ""].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-join-spec");

  const base = await runTlc(join(reportDir, "base"), "MCAcpJoin.tla", "MCAcpJoin.cfg", SPEC_FILES);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(
    `base MCAcpJoin.cfg: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`,
  );

  const today = await runTlc(join(reportDir, "today"), "MCAcpJoin.tla", "AcpJoinToday.cfg", SPEC_FILES);
  const todayPassed = today.exitCode !== 0 && /Temporal properties were violated/.test(today.output);
  console.log(
    `today AcpJoinToday.cfg: ${todayPassed ? "JoinWorks violated, as required" : "FAIL"} (exit ${today.exitCode}, ${today.distinctStates} distinct states)`,
  );

  const source = readFileSync(join(SPEC_DIR, "AcpJoin.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    let text = source;
    for (const { from, to } of mutant.replacements) {
      const count = text.split(from).length - 1;
      if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
      text = text.replace(from, () => to);
    }
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpJoin.tla"), text);
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpJoin.tla", "Target.cfg", ["MCAcpJoin.tla"]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
    console.log(
      `mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect}, ${run.distinctStates} distinct states)`,
    );
    mutants.push({ id: mutant.id, note: mutant.note, expect: mutant.expect, exitCode: run.exitCode, violated: run.violated, distinctStates: run.distinctStates, killed });
  }

  const allKilled = mutants.every((mutant) => mutant.killed);
  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: base.exitCode, distinctStates: base.distinctStates, depth: base.depth },
    today: { passed: todayPassed, exitCode: today.exitCode, distinctStates: today.distinctStates },
    mutants,
    allKilled,
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !todayPassed || !allKilled) process.exit(1);
}

await main();
