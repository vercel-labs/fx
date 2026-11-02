// Exhaustive TLC check of the permission-mode contract plus mutation
// qualification: each planted mutant must violate the named property, which
// shows the properties are strong enough to catch that mistake.
//
//   bun tests/tla/drivers/acp/permission_modes/check-spec.ts
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { outDir } from "../../lib/tlc";
import { SPEC_DIR, runTlc, sha256File, tlcToolchain, utcStamp, writeJson } from "./tlc";

type Mutant = { id: string; note: string; from: string; to: string; expect: string };

const MUTANTS: Mutant[] = [
  {
    id: "new-reports-ask",
    note: "a new session reports Ask whatever fx enforces (an earlier fx)",
    from: `/\\ last = Obs("new", "none", TRUE, TRUE, SessionView(Eff(profile)), "none", profile)`,
    to: `/\\ last = Obs("new", "none", TRUE, TRUE, SessionView("ask"), "none", profile)`,
    expect: "ReportsEnforcedMode",
  },
  {
    id: "lists-code",
    note: "the options still list the old code mode",
    from: `[current |-> m, legacy |-> m, listed |-> ModesCsv,`,
    to: `[current |-> m, legacy |-> m, listed |-> "code,ask",`,
    expect: "ListsExactlyCliModes",
  },
  {
    id: "extra-option-field",
    note: "option values carry a field outside ACP's schema",
    from: `names |-> NamesCsv, schemaOk |-> TRUE]`,
    to: `names |-> NamesCsv, schemaOk |-> FALSE]`,
    expect: "SchemaClean",
  },
  {
    id: "legacy-modes-stale",
    note: "the older modes field shows the default instead of the session's mode",
    from: `[current |-> m, legacy |-> m,`,
    to: `[current |-> m, legacy |-> DefaultMode,`,
    expect: "ReportsEnforcedMode",
  },
  {
    id: "resume-ignores-profile",
    note: "a resumed session starts in the default mode",
    from: `LET resumed == Eff(profile) IN`,
    to: `LET resumed == DefaultMode IN`,
    expect: "SessionsStartFromProfile",
  },
  {
    id: "fresh-ignores-profile",
    note: "a new process starts sessions in the default mode",
    from: `LET started == Eff(profile) IN`,
    to: `LET started == DefaultMode IN`,
    expect: "SessionsStartFromProfile",
  },
  {
    id: "default-ask",
    note: "an unset profile means Ask instead of Auto",
    from: `Eff(p) == IF p = "unset" THEN DefaultMode ELSE p`,
    to: `Eff(p) == IF p = "unset" THEN "ask" ELSE p`,
    expect: "DefaultIsAuto",
  },
  {
    id: "unknown-accepted",
    note: "set_config_option answers success for an unknown mode (an earlier fx)",
    from: `ELSE /\\ last' = Obs("set", v, FALSE, FALSE, NoView, "none", profile)`,
    to: `ELSE /\\ last' = Obs("set", v, TRUE, FALSE, NoView, "none", profile)`,
    expect: "UnknownRejected",
  },
  {
    id: "config-change-not-saved",
    note: "a set_config_option change is not saved to the profile (an earlier fx)",
    from: `/\\ profile' = v\n         /\\ last' = Obs("set"`,
    to: `/\\ profile' = profile\n         /\\ last' = Obs("set"`,
    expect: "ChangeIsSaved",
  },
  {
    id: "legacy-change-not-saved",
    note: "a session/set_mode change is not saved to the profile (an earlier fx)",
    from: `/\\ profile' = v\n         /\\ last' = Obs("legacy"`,
    to: `/\\ profile' = profile\n         /\\ last' = Obs("legacy"`,
    expect: "ChangeIsSaved",
  },
  {
    id: "stored-misread",
    note: "the profile's saved mode differs from what the session uses",
    from: `Enforce(cur), profile)`,
    to: `Enforce(cur), "unset")`,
    expect: "StoredIsProfile",
  },
  {
    id: "implicit-full-access",
    note: "a prompt leaves the session in full access without the user choosing it",
    from: `/\\ UNCHANGED <<profile, cur>>`,
    to: `/\\ cur' = "full-access"\n    /\\ UNCHANGED profile`,
    expect: "FullAccessOnlyByChoice",
  },
  {
    id: "status-shows-open-session",
    note: "fx status reports the open session's mode instead of the next session's",
    from: `StatusView(Eff(profile))`,
    to: `StatusView(cur)`,
    expect: "StatusMatchesNextSession",
  },
  {
    id: "new-session-stale",
    note: "session/new keeps the process's mode instead of reading the saved one (the spare-process bug)",
    from: `LET opened == Eff(profile) IN`,
    to: `LET opened == cur IN`,
    expect: "SessionsStartFromProfile",
  },
  {
    id: "other-process-leaks",
    note: "another process saving a mode switches the open session",
    from: `/\\ UNCHANGED <<cur, saved>>`,
    to: `/\\ cur' = v\n    /\\ UNCHANGED saved`,
    expect: "OpenSessionKeepsMode",
  },
  {
    id: "full-access-reviewed",
    note: "full access still sends actions to the automatic reviewer",
    from: `[] m = "full-access" -> "direct/ran"`,
    to: `[] m = "full-access" -> "reviewed/ran"`,
    expect: "PromptEnforcesMode",
  },
  {
    id: "rejection-changes-mode",
    note: "a rejected change still switches the session",
    from: `ELSE /\\ last' = Obs("set", v, FALSE, FALSE, NoView, "none", profile)\n         /\\ UNCHANGED <<profile, cur, saved>>`,
    to: `ELSE /\\ last' = Obs("set", v, FALSE, FALSE, NoView, "none", profile)\n         /\\ cur' = "ask"\n         /\\ UNCHANGED <<profile, saved>>`,
    expect: "RejectedChangesNothing",
  },
];

const SPEC_FILES = ["AcpPermissionModes.tla", "MCAcpPermissionModes.tla", "MCAcpPermissionModes.cfg"];
const ACTION_PROPERTIES = new Set(["RejectedChangesNothing", "OpenSessionKeepsMode", "FullAccessOnlyByChoice"]);

/// Checks a mutant against its target property alone, so a kill shows that
/// property catches the mistake regardless of which one TLC checks first.
function targetCfg(target: string): string {
  return [
    "CONSTANTS",
    "    Profiles <- MCProfiles",
    "    Values <- MCValues",
    "INIT Init",
    "NEXT Next",
    `${ACTION_PROPERTIES.has(target) ? "PROPERTY" : "INVARIANT"} ${target}`,
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n");
}

async function main() {
  const tool = tlcToolchain();
  const reportDir = outDir("acp-permission-modes-spec");
  mkdirSync(reportDir, { recursive: true });

  const base = await runTlc(join(reportDir, "base"), "MCAcpPermissionModes.tla", "MCAcpPermissionModes.cfg", SPEC_FILES);
  const basePassed = base.exitCode === 0 && /No error has been found/.test(base.output);
  console.log(`base spec: ${basePassed ? "PASS" : "FAIL"} (exit ${base.exitCode}, ${base.distinctStates} distinct states, depth ${base.depth})`);

  const source = readFileSync(join(SPEC_DIR, "AcpPermissionModes.tla"), "utf8");
  const mutants = [];
  for (const mutant of MUTANTS) {
    const count = source.split(mutant.from).length - 1;
    if (count !== 1) throw new Error(`mutant ${mutant.id}: pattern matched ${count} times`);
    const dir = join(reportDir, "mutants", mutant.id);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "AcpPermissionModes.tla"), source.replace(mutant.from, mutant.to));
    writeFileSync(join(dir, "Target.cfg"), targetCfg(mutant.expect));
    const run = await runTlc(dir, "MCAcpPermissionModes.tla", "Target.cfg", ["MCAcpPermissionModes.tla"]);
    const killed = run.exitCode !== 0 && run.violated === mutant.expect;
    console.log(`mutant ${mutant.id}: ${killed ? "KILLED" : "SURVIVED"} (exit ${run.exitCode}, violated ${run.violated ?? "none"}, expected ${mutant.expect})`);
    mutants.push({ ...mutant, exitCode: run.exitCode, violated: run.violated, killed });
  }

  const summary = {
    toolchain: tool,
    spec_sha256: Object.fromEntries(SPEC_FILES.map((name) => [name, sha256File(join(SPEC_DIR, name))])),
    base: { passed: basePassed, exitCode: base.exitCode, distinctStates: base.distinctStates, depth: base.depth, argv: base.argv },
    mutants,
    allKilled: mutants.every((mutant) => mutant.killed),
  };
  writeJson(join(reportDir, "summary.json"), summary);
  console.log(`mutants killed: ${mutants.filter((mutant) => mutant.killed).length}/${mutants.length}`);
  console.log(`report: ${reportDir}`);
  if (!basePassed || !summary.allKilled) process.exit(1);
}

await main();
