// Has TLC judge answers: each case's expected match against
// FuzzyMatch!Match, and each observed menu listing against
// FuzzyMatch!Listing. The data goes into a generated module next to a copy
// of the spec, so every run keeps the exact files it checked.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { SPEC_DIR, atomFields, atoms, checkTlc, toTla, type Field, type Match, type Tier } from "./lib.ts";

export type Judged = { index: number; tier: Tier; field: number };

/// `field` here counts from 1, as the model's does.
export type ModelCase = { query: Uint8Array; fields: Field[]; expect: Match };

function caseModule(cases: ModelCase[]): string {
  const data = cases.map((c) =>
    toTla({ q: atoms(c.query), fields: atomFields(c.fields), expect: c.expect }),
  );
  return `---- MODULE CheckCases ----
EXTENDS FuzzyMatch
CaseData == <<${data.join(",\n  ")}>>
VARIABLE x
Init == x = 0
Next == UNCHANGED x
Spec == Init /\\ [][Next]_x
Got(i) == Match(CaseData[i].q, CaseData[i].fields)
Bad == {i \\in 1..Len(CaseData) : Got(i) # CaseData[i].expect}
CasesAgree == Bad = {} \\/ ((\\A i \\in Bad : PrintT(<<"FM_BAD", i, Got(i).tier, Got(i).field>>)) /\\ FALSE)
====
`;
}

/// TLC's verdict on `cases`: the indexes (from 1) whose expectation it
/// rejects, with what it computes instead.
export async function judgeCases(dir: string, cases: ModelCase[], fuzzyMatch?: string) {
  const files: Record<string, string> = {
    "FuzzyMatch.tla": fuzzyMatch ?? readFileSync(join(SPEC_DIR, "FuzzyMatch.tla"), "utf8"),
    "CheckCases.tla": caseModule(cases),
    "CheckCases.cfg": "SPECIFICATION Spec\nINVARIANT\n    CasesAgree\n",
  };
  const run = await checkTlc(dir, "CheckCases", "CheckCases.cfg", files);
  const bad: Judged[] = [];
  const seen = new Set<number>();
  for (const found of run.output.matchAll(/<<"FM_BAD", (\d+), "(\w+)", (\d+)>>/g)) {
    const index = Number(found[1]);
    if (seen.has(index)) continue;
    seen.add(index);
    bad.push({ index, tier: found[2] as Tier, field: Number(found[3]) });
  }
  const ok = run.verdict === "pass";
  if (!ok && run.verdict !== "violated") throw new Error(`TLC failed on ${dir}:\n${run.output.slice(-2000)}`);
  return { ok, bad, run };
}

export type Observation = {
  items: Field[][];
  query: Uint8Array;
  mode: "ranked" | "filtered";
  /// The 1-based indexes the surface showed, in order: its first rows.
  shown: number[];
  /// How many matches the surface says it has.
  count: number;
};

function listingModule(observations: Observation[]): string {
  const data = observations.map((o) =>
    toTla({ items: o.items.map(atomFields), q: atoms(o.query), mode: o.mode, shown: o.shown, count: o.count }),
  );
  return `---- MODULE CheckListings ----
EXTENDS FuzzyMatch
ObsData == <<${data.join(",\n  ")}>>
VARIABLE x
Init == x = 0
Next == UNCHANGED x
Spec == Init /\\ [][Next]_x
Expected(i) == Listing(ObsData[i].items, ObsData[i].q, ObsData[i].mode)
Agrees(i) ==
    /\\ Len(Expected(i)) = ObsData[i].count
    /\\ ObsData[i].shown = SubSeq(Expected(i), 1, Len(ObsData[i].shown))
Printed == \\A i \\in 1..Len(ObsData) : PrintT(<<"FM_LIST", i, Expected(i)>>)
Bad == {i \\in 1..Len(ObsData) : ~Agrees(i)}
ListingsAgree == Printed /\\ (Bad = {} \\/ ((\\A i \\in Bad : PrintT(<<"FM_LIST_BAD", i>>)) /\\ FALSE))
====
`;
}

/// TLC's verdict on observed listings, and the model's listing for each.
export async function judgeListings(dir: string, observations: Observation[]) {
  const files: Record<string, string> = {
    "FuzzyMatch.tla": readFileSync(join(SPEC_DIR, "FuzzyMatch.tla"), "utf8"),
    "CheckListings.tla": listingModule(observations),
    "CheckListings.cfg": "SPECIFICATION Spec\nINVARIANT\n    ListingsAgree\n",
  };
  const run = await checkTlc(dir, "CheckListings", "CheckListings.cfg", files);
  if (run.verdict === "error") throw new Error(`TLC failed on ${dir}:\n${run.output.slice(-2000)}`);
  const expected = new Map<number, number[]>();
  for (const found of run.output.matchAll(/<<"FM_LIST", (\d+), <<([\d, ]*)>>>>/g)) {
    const index = Number(found[1]);
    if (!expected.has(index)) expected.set(index, found[2]!.trim() ? found[2]!.split(",").map((s) => Number(s.trim())) : []);
  }
  const bad = new Set<number>();
  for (const found of run.output.matchAll(/<<"FM_LIST_BAD", (\d+)>>/g)) bad.add(Number(found[1]));
  return { ok: run.verdict === "pass", expected, bad: [...bad].sort((a, b) => a - b), run };
}

/// The engine's answer (field from 0, null for none) as the model states it.
export function modelMatch(answer: { tier: Tier; field: number | null }): Match {
  return answer.tier === "none" ? { tier: "none", field: 0 } : { tier: answer.tier, field: (answer.field ?? 0) + 1 };
}
