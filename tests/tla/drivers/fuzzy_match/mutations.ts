// Planted bugs from tests/tla/fuzzy_match/mutations.json: each must be
// caught, or the checks that should catch it measure nothing.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import type { Case } from "./cases.ts";
import { MODEL_DIR, SPEC_DIR, checkTlc, configInfo, onlyInvariant, plant, specFiles, type Field, type Match } from "./lib.ts";
import { judgeCases, judgeListings, modelMatch } from "./tlc-cases.ts";

type SpecBug = { id: string; rule: string; breaks: string; cfg: string; find: string; replace: string; expect: string };
type OracleBug = { id: string; rule: string; file: "oracle.ts" | "lib.ts"; breaks: string; find: string; replace: string };
type CodeBug = { id: string; rule: string; breaks: string; find: string; replace: string; expect: string };

export function loadMutations() {
  return JSON.parse(readFileSync(join(MODEL_DIR, "mutations.json"), "utf8")) as { spec: SpecBug[]; oracle: OracleBug[]; code: CodeBug[] };
}

/// Runs `tasks` with at most `limit` running at once.
export async function pool<T>(limit: number, tasks: (() => Promise<T>)[]): Promise<T[]> {
  const results: T[] = new Array(tasks.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, tasks.length) }, async () => {
    while (next < tasks.length) {
      const index = next++;
      results[index] = await tasks[index]!();
    }
  });
  await Promise.all(workers);
  return results;
}

export type SpecBugResult = SpecBug & { caught: boolean; alone: string; full: string };

/// Each spec bug, alone with its expected invariant and with its full config.
export async function specMutations(dir: string, concurrency = 6, only?: (id: string) => boolean): Promise<SpecBugResult[]> {
  const bugs = loadMutations().spec.filter((bug) => only === undefined || only(bug.id));
  const original = readFileSync(join(SPEC_DIR, "FuzzyMatch.tla"), "utf8");
  return await pool(concurrency, bugs.map((bug) => async () => {
    const mutated = plant(original, bug.find, bug.replace, bug.id);
    const files = specFiles(mutated);
    const { module, invariants } = configInfo(bug.cfg);
    if (!invariants.includes(bug.expect)) throw new Error(`${bug.id}: ${bug.cfg} does not check ${bug.expect}`);
    const aloneCfg = onlyInvariant(files[bug.cfg]!, bug.expect);
    const alone = await checkTlc(join(dir, bug.id, "alone"), module, "Alone.cfg", { ...files, "Alone.cfg": aloneCfg }, ["-workers", "2"]);
    const full = await checkTlc(join(dir, bug.id, "full"), module, bug.cfg, files, ["-workers", "2"]);
    const aloneText = alone.verdict === "violated" ? `violated ${alone.property}` : alone.verdict;
    const fullText = full.verdict === "violated" ? `violated ${full.property}` : full.verdict;
    const caught = alone.verdict === "violated" && alone.property === bug.expect && full.verdict === "violated";
    return { ...bug, caught, alone: aloneText, full: fullText };
  }));
}

type AtomItem = { text: string[]; kind: "name" | "text" }[];
type OracleModule = {
  match: (q: string[], fs: AtomItem) => Match;
  listing: (items: AtomItem[], q: string[], mode: "ranked" | "filtered") => number[];
};
type LibModule = { atoms: (bytes: Uint8Array) => string[] };

/// Copies of oracle.ts and lib.ts in `dir`, with `bug` planted in one of
/// them, loaded fresh.
async function loadPlanted(dir: string, bug?: OracleBug): Promise<{ oracle: OracleModule; lib: LibModule }> {
  mkdirSync(dir, { recursive: true });
  const here = import.meta.dirname;
  const tlcPath = pathToFileURL(join(here, "..", "lib", "tlc.ts")).href;
  let lib = readFileSync(join(here, "lib.ts"), "utf8").replace('from "../lib/tlc.ts"', `from "${tlcPath}"`);
  let oracle = readFileSync(join(here, "oracle.ts"), "utf8");
  if (bug?.file === "lib.ts") lib = plant(lib, bug.find, bug.replace, bug.id);
  if (bug?.file === "oracle.ts") oracle = plant(oracle, bug.find, bug.replace, bug.id);
  writeFileSync(join(dir, "lib.ts"), lib);
  writeFileSync(join(dir, "oracle.ts"), oracle);
  const stamp = `?v=${Date.now()}-${Math.random()}`;
  return {
    oracle: (await import(pathToFileURL(join(dir, "oracle.ts")).href + stamp)) as OracleModule,
    lib: (await import(pathToFileURL(join(dir, "lib.ts")).href + stamp)) as LibModule,
  };
}

export type OracleVerdict = { handMismatches: string[]; tlcMismatches: number; listingMismatches: number; listings: number; answers: Match[] };

/// Lists built from `random`: consecutive cases' field tuples as items, one
/// of their queries, alternating ranked and filtered. Every fourth list
/// repeats one item so equal matches must keep base order.
export function randomListings(random: Case[], maxItems = 6): { items: Field[][]; query: Uint8Array; mode: "ranked" | "filtered" }[] {
  const lists: { items: Field[][]; query: Uint8Array; mode: "ranked" | "filtered" }[] = [];
  for (let start = 0, n = 0; start + 2 <= random.length; n += 1) {
    const size = 2 + (n % (maxItems - 1));
    const group = random.slice(start, start + size);
    start += size;
    const items = group.map((c) => c.fields);
    if (n % 4 === 0) items.push(items[0]!);
    lists.push({ items, query: group[n % group.length]!.query, mode: n % 2 === 0 ? "ranked" : "filtered" });
  }
  return lists;
}

const isWordByte = (b: number) => b >= 0x80 || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a);

/// Lists that make R11 matter. For each ASCII query with two or more word
/// characters: an item that holds the query as typed, one that holds only
/// its word characters with a hyphen between each, so it matches by words
/// at best, and one that does not match. Every list has both of the first
/// two, in either order, or only the second, so a filtered listing must drop
/// the near-miss or fall back to it.
export function floorListings(random: Case[], count = 120): { items: Field[][]; query: Uint8Array; mode: "ranked" | "filtered" }[] {
  const lists: { items: Field[][]; query: Uint8Array; mode: "ranked" | "filtered" }[] = [];
  const name = (bytes: Uint8Array) => ({ bytes, kind: "name" as const });
  for (const c of random) {
    if (lists.length >= count) break;
    if (c.query.some((b) => b >= 0x80)) continue;
    const wordBytes = [...c.query].filter(isWordByte);
    if (wordBytes.length < 2) continue;
    const spread = new Uint8Array(wordBytes.flatMap((b, i) => (i === 0 ? [b] : [0x2d, b])));
    const asTyped = name(new Uint8Array([0x7e, ...c.query, 0x7e]));
    const nearMiss = name(spread);
    const other = name(new Uint8Array([0x23]));
    const n = lists.length;
    const items = n % 3 === 0 ? [[nearMiss], [asTyped], [other]] : n % 3 === 1 ? [[asTyped], [other], [nearMiss]] : [[other], [nearMiss]];
    lists.push({ items, query: c.query, mode: n % 2 === 0 ? "filtered" : "ranked" });
  }
  return lists;
}

/// The planted or real oracle's answers on `edge` and `random`, judged
/// against the hand expectations and, on the real encoding, by TLC: every
/// match, and the listings `randomListings` and `floorListings` build.
export async function judgeOracle(dir: string, edge: Case[], random: Case[], bug?: OracleBug): Promise<OracleVerdict> {
  const { oracle, lib } = await loadPlanted(join(dir, "copy"), bug);
  const atomItem = (fields: Field[]) => fields.map((f) => ({ text: lib.atoms(f.bytes), kind: f.kind }));
  const answer = (query: Uint8Array, fields: Field[]) => oracle.match(lib.atoms(query), atomItem(fields));
  const handMismatches: string[] = [];
  for (const c of edge) {
    const got = answer(c.query, c.fields);
    const want = modelMatch(c.expect!);
    if (got.tier !== want.tier || got.field !== want.field) handMismatches.push(c.id);
  }
  const all = [...edge, ...random];
  const answers = all.map((c) => answer(c.query, c.fields));
  const judged = await judgeCases(join(dir, "tlc"), all.map((c, i) => ({ query: c.query, fields: c.fields, expect: answers[i]! })));
  const lists = [...randomListings(random), ...floorListings(random)];
  const observations = lists.map((list) => {
    const shown = oracle.listing(list.items.map(atomItem), lib.atoms(list.query), list.mode);
    return { ...list, shown, count: shown.length };
  });
  const listed = await judgeListings(join(dir, "tlc-listings"), observations);
  return { handMismatches, tlcMismatches: judged.bad.length, listingMismatches: listed.bad.length, listings: lists.length, answers };
}

export type OracleBugResult = OracleBug & { caught: boolean; detail: string };

export async function oracleMutations(dir: string, edge: Case[], random: Case[], concurrency = 4): Promise<OracleBugResult[]> {
  const bugs = loadMutations().oracle;
  return await pool(concurrency, bugs.map((bug) => async () => {
    const verdict = await judgeOracle(join(dir, bug.id), edge, random, bug);
    const caught = verdict.handMismatches.length > 0 || verdict.tlcMismatches > 0 || verdict.listingMismatches > 0;
    return { ...bug, caught, detail: `${verdict.handMismatches.length} edge cases, ${verdict.tlcMismatches} TLC cases, and ${verdict.listingMismatches} of ${verdict.listings} listings disagree` };
  }));
}

