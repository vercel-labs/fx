// Exhaustive TLC checks of tests/tla/acp/AcpSharedSession.tla: the rows of its
// configs, then its planted bugs. Each planted bug is checked alone against the
// property it names, which shows that property catches that mistake. The
// rows here match the AcpSharedSession rows in tests/tla/acp/check.sh. The
// rules have not landed in src/acp/ yet, so there is no driver of fx here; the
// model's Today configs show fx now.
//
//   bun tests/tla/drivers/acp/shared_session/check-spec.ts
//
// Exit status is non-zero when a row or a planted bug misses its verdict.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, outDir, runTlc, sha256File, tlcToolchain, writeJson } from "./tlc";

const SPEC = "AcpSharedSession.tla";
const MODULE = "MCAcpSharedSession.tla";

type Row = { config: string; expect: "-" | string };

const ROWS: Row[] = [
  { config: "MCAcpSharedSession.cfg", expect: "-" },
  { config: "MCAcpSharedSessionThree.cfg", expect: "-" },
  { config: "AcpSharedSessionOptIn.cfg", expect: "-" },
  { config: "AcpSharedSessionWitness-optin.cfg", expect: "NoUnlistedOpen" },
  { config: "AcpSharedSessionWitness-steer.cfg", expect: "NoSteerSent" },
  { config: "AcpSharedSessionToday-cancel.cfg", expect: "CancelStops" },
  { config: "AcpSharedSessionToday-clients.cfg", expect: "RosterCurrent" },
  { config: "AcpSharedSessionToday-prompts.cfg", expect: "EchoComplete" },
  { config: "AcpSharedSessionToday-request.cfg", expect: "RequestReachesAll" },
  { config: "AcpSharedSessionToday-joiner.cfg", expect: "JoinerListedBeforeAnswer" },
  { config: "AcpSharedSessionToday-sender.cfg", expect: "ChunkSenderGate" },
];

type Mutant = {
  id: string;
  note: string;
  lists: "all" | "c1";
  from: string;
  to: string;
  expect: string;
};

// Each `from` must occur exactly once in AcpSharedSession.tla. String.raw keeps
// the TLA+ backslashes as written.
const MUTANTS: Mutant[] = [
  {
    id: "answer-keeps-others",
    note: "the first answer doesn't cancel the request on the other clients",
    lists: "all",
    from: String.raw`            /\ chan' = [d \in Conns |-> IF d \in sentTo \ {c} THEN Append(chan[d], CancelMsg(perm.id)) ELSE chan[d]]`,
    to: String.raw`            /\ UNCHANGED chan`,
    expect: "NoOrphanRequest",
  },
  {
    id: "late-answer-applied",
    note: "an answer that comes after the request was decided is applied too",
    lists: "all",
    from: String.raw`    /\ IF shown[c] = perm.id /\ ~perm.decided`,
    to: String.raw`    /\ IF shown[c] = perm.id`,
    expect: "DecidedOnce",
  },
  {
    id: "joiner-without-request",
    note: "a client that opens the session while a request waits doesn't get it",
    lists: "all",
    from: String.raw`           ask == IF Rules /\ Waiting THEN <<Req(perm.id)>> ELSE <<>>`,
    to: String.raw`           ask == <<>>`,
    expect: "RequestReachesAll",
  },
  {
    id: "request-to-sender-only",
    note: "the request goes only to the client whose prompt runs, as today",
    lists: "all",
    from: String.raw`           to == IF Rules THEN {d \in Conns : open[d]} ELSE {d \in {turn} : open[d]}`,
    to: String.raw`           to == {d \in {turn} : open[d]}`,
    expect: "RequestReachesAll",
  },
  {
    id: "decided-request-to-joiner",
    note: "a client that opens the session gets a request that was already decided",
    lists: "all",
    from: String.raw`           ask == IF Rules /\ Waiting THEN <<Req(perm.id)>> ELSE <<>>`,
    to: String.raw`           ask == IF Rules /\ perm.id # 0 THEN <<Req(perm.id)>> ELSE <<>>`,
    expect: "NoOrphanRequest",
  },
  {
    id: "cancel-keeps-request",
    note: "session/cancel stops the turn but leaves the waiting request on the clients",
    lists: "all",
    from: String.raw`                    /\ chan' = [d \in Conns |-> IF d \in sentTo THEN Append(chan[d], CancelMsg(perm.id)) ELSE chan[d]]`,
    to: String.raw`                    /\ UNCHANGED chan`,
    expect: "NoOrphanRequest",
  },
  {
    id: "prompt-to-sender",
    note: "a prompt goes back to its sender too",
    lists: "all",
    from: String.raw`IF Rules /\ open[d] /\ d # c THEN Append(chan[d], Echo(k, c, d)) ELSE chan[d]]`,
    to: String.raw`IF Rules /\ open[d] THEN Append(chan[d], Echo(k, c, d)) ELSE chan[d]]`,
    expect: "NoSelfEcho",
  },
  {
    id: "prompt-not-sent",
    note: "the other clients don't get a client's prompt",
    lists: "all",
    from: String.raw`IF Rules /\ open[d] /\ d # c THEN Append(chan[d], Echo(k, c, d)) ELSE chan[d]]`,
    to: String.raw`IF FALSE THEN Append(chan[d], Echo(k, c, d)) ELSE chan[d]]`,
    expect: "EchoComplete",
  },
  {
    id: "clients-not-on-close",
    note: "the list of clients doesn't go out when a client closes the session",
    lists: "all",
    from: String.raw`          /\ chan' = [d \in Conns |-> chan[d] \o RosterOut(d, now, ordN)]`,
    to: String.raw`          /\ UNCHANGED chan`,
    expect: "RosterCurrent",
  },
  {
    id: "clients-not-to-joiner",
    note: "a client that opens the session with session/load doesn't get the list of clients",
    lists: "all",
    from: String.raw`ask \o RosterOut(c, now, ordN) \o <<AnswerMsg>>`,
    to: String.raw`ask \o <<AnswerMsg>>`,
    expect: "RosterCurrent",
  },
  {
    id: "stale-main",
    note: "after the main client closes, the list still names it as main",
    lists: "all",
    from: String.raw`chan' = [d \in Conns |-> chan[d] \o RosterOut(d, now, ordN)]`,
    to: String.raw`chan' = [d \in Conns |-> chan[d] \o RosterOut(d, now, order)]`,
    expect: "MainCurrent",
  },
  {
    id: "roster-to-unlisted",
    note: "a client that does not list sh.fx/sessionClients is sent the list",
    lists: "c1",
    from: String.raw`IF Rules /\ now[d] /\ d \in Lists THEN`,
    to: String.raw`IF Rules /\ now[d] THEN`,
    expect: "OptInRoster",
  },
  {
    id: "joiner-no-self",
    note: "the list a client gets on session/load leaves the client out",
    lists: "all",
    from: String.raw`ask \o RosterOut(c, now, ordN) \o <<AnswerMsg>>`,
    to: String.raw`ask \o <<Clients(Roster(now) \ {c}, Head(ordN))>> \o <<AnswerMsg>>`,
    expect: "JoinerListedBeforeAnswer",
  },
  {
    id: "joiner-after-answer",
    note: "the list a client gets on session/load comes after its answer",
    lists: "all",
    from: String.raw`ask \o RosterOut(c, now, ordN) \o <<AnswerMsg>>`,
    to: String.raw`ask \o <<AnswerMsg>> \o RosterOut(c, now, ordN)`,
    expect: "JoinerListedBeforeAnswer",
  },
  {
    id: "new-list-before-answer",
    note: "a client that opens the session with session/new gets the list before its answer",
    lists: "all",
    from: String.raw`<<AnswerMsg>> \o ask \o RosterOut(c, now, ordN)`,
    to: String.raw`RosterOut(c, now, ordN) \o ask \o <<AnswerMsg>>`,
    expect: "NewListAfterAnswer",
  },
  {
    id: "roster-no-member",
    note: "the closing client is sent an empty list",
    lists: "all",
    from: String.raw`chan' = [d \in Conns |-> chan[d] \o RosterOut(d, now, ordN)]`,
    to: String.raw`chan' = [d \in Conns |-> IF d = c THEN chan[d] \o <<Clients({}, None)>> ELSE chan[d] \o RosterOut(d, now, ordN)]`,
    expect: "NoListWithoutMember",
  },
  {
    id: "chunk-no-id",
    note: "a prompt or steer chunk to a listing client omits the sender",
    lists: "all",
    from: String.raw`IF SenderKey /\ d \in Lists THEN s ELSE None`,
    to: String.raw`None`,
    expect: "ChunkSenderGate",
  },
  {
    id: "chunk-id-unlisted",
    note: "a prompt or steer chunk to a client that does not list the capability names the sender",
    lists: "c1",
    from: String.raw`IF SenderKey /\ d \in Lists THEN s ELSE None`,
    to: String.raw`s`,
    expect: "ChunkSenderGate",
  },
];

const SPEC_FILES = [SPEC, MODULE, "MCAcpSharedSession.cfg", "MCAcpSharedSessionThree.cfg"];

function targetCfg(target: string, lists: "all" | "c1"): string {
  const listed = lists === "all" ? `{"c1", "c2"}` : `{"c1"}`;
  return [
    "CONSTANTS",
    "    Rules = TRUE",
    `    Conns = {"c1", "c2"}`,
    `    Lists = ${listed}`,
    "    SenderKey = TRUE",
    "    MaxPrompts = 2",
    "    MaxAsks = 2",
    "INIT Init",
    "NEXT Next",
    "CONSTRAINT ChanBound",
    `INVARIANT ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

type Result = {
  name: string;
  expect: string;
  ok: boolean;
  detail: string;
  states: number | null;
  depth: number | null;
  seconds: number;
};

function report(result: Result) {
  const tag = result.ok ? "ok  " : "FAIL";
  const seconds = (result.seconds).toFixed(1);
  console.log(
    `${tag} ${result.name}: ${result.detail} (distinct states ${result.states ?? "n/a"}, depth ${result.depth ?? "n/a"}, ${seconds} s)`,
  );
}

async function main() {
  tlcToolchain();
  const reportDir = outDir("acp-shared-session-spec");
  const results: Result[] = [];

  console.log("rows");
  for (const row of ROWS) {
    const run = await runTlc(join(reportDir, "rows", row.config), MODULE, row.config, [SPEC, MODULE, row.config]);
    let ok: boolean;
    let detail: string;
    if (row.expect === "-") {
      ok = run.exitCode === 0 && /No error has been found/.test(run.output);
      detail = ok ? "no error" : `exit ${run.exitCode}`;
    } else {
      ok = run.exitCode !== 0 && run.violated === row.expect;
      detail = ok ? `${row.expect} violated, as required` : `violated ${run.violated ?? "none"}, exit ${run.exitCode}`;
    }
    const result = {
      name: row.config,
      expect: row.expect,
      ok,
      detail,
      states: run.distinctStates,
      depth: run.depth,
      seconds: run.durationMs / 1000,
    };
    results.push(result);
    report(result);
  }

  const source = readFileSync(join(SPEC_DIR, SPEC), "utf8");
  console.log("planted bugs");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, SPEC), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect, mutant.lists));
    const run = await runTlc(dir, MODULE, "Target.cfg", [MODULE]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
    const result = {
      name: mutant.id,
      expect: mutant.expect,
      ok: killed,
      detail: killed ? `${mutant.expect} violated, as required` : `violated ${run.violated ?? "none"}, exit ${run.exitCode}`,
      states: run.distinctStates,
      depth: run.depth,
      seconds: run.durationMs / 1000,
    };
    results.push(result);
    report(result);
    mutants.push({ ...mutant, exitCode: run.exitCode, violated: run.violated, killed });
  }

  const failed = results.filter((result) => !result.ok);
  const summary = {
    toolchain: tlcToolchain(),
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    results,
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`\n${results.length - failed.length} of ${results.length} rows and planted bugs as expected; report in ${reportDir}`);
  if (failed.length > 0) process.exit(1);
}

await main();
