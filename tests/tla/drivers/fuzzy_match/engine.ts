// The engine stages: the harness built from the real
// src/core/shared/fuzzy_match.zig (or a planted-bug copy) answers the edge
// table, seeded random cases checked against the oracle and by TLC, random
// listings built by its `Ranking` and `Filter`, the laws on its own answers,
// and the stress budgets in design/GOAL.md.
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT } from "../lib/tlc.ts";
import { hex, randomCases, type Case } from "./cases.ts";
import { ENGINE_SOURCE, HARNESS_SOURCE, TIER_RANK, atomFields, atoms, plant, seededRandom, utf8, utf8SequenceLength, type Field, type Tier } from "./lib.ts";
import * as oracle from "./oracle.ts";
import { floorListings, randomListings } from "./mutations.ts";
import { judgeCases, judgeListings, modelMatch } from "./tlc-cases.ts";

const SHARED = join(REPO_ROOT, "src", "core", "shared");
// The engine and the files it imports, copied so a planted bug never
// touches src/.
const ENGINE_FILES = ["fuzzy_match.zig", "ascii_case.zig", "display_width.zig", "unicode_display_data.zig"];

export type Answer = { tier: Tier; field: number | null };

/// Builds the harness from a copy of the engine in `dir`, with an optional
/// replacement for fuzzy_match.zig. Throws with the compiler's output.
export function buildHarness(dir: string, optimize: "Debug" | "ReleaseSafe" = "Debug", engineText?: string): string {
  const src = join(dir, "engine");
  mkdirSync(src, { recursive: true });
  for (const name of ENGINE_FILES) copyFileSync(join(SHARED, name), join(src, name));
  if (engineText !== undefined) writeFileSync(join(src, "fuzzy_match.zig"), engineText);
  const bin = join(dir, `fuzzy-match-harness-${optimize}`);
  const build = Bun.spawnSync([
    "zig", "build-exe", `-O${optimize}`,
    "--dep", "fuzzy_match", `-Mroot=${HARNESS_SOURCE}`, `-Mfuzzy_match=${join(src, "fuzzy_match.zig")}`,
    `-femit-bin=${bin}`, "--cache-dir", join(REPO_ROOT, ".zig-cache"),
  ], { cwd: REPO_ROOT, stdout: "pipe", stderr: "pipe" });
  if (build.exitCode !== 0 || !existsSync(bin)) {
    throw new Error(`harness build failed:\n${build.stderr.toString()}${build.stdout.toString()}`);
  }
  return bin;
}

const fieldJson = (fields: Field[]) => fields.map((f) => ({ h: hex(f.bytes), k: f.kind }));

/// Runs every request through one harness process, in order.
async function ask(bin: string, requests: unknown[]): Promise<string[]> {
  const proc = Bun.spawn([bin], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  const stdin = proc.stdin as import("bun").FileSink;
  for (const request of requests) stdin.write(`${JSON.stringify(request)}\n`);
  stdin.end();
  const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(`the harness exited ${code}: ${err.slice(-2000)}`);
  const lines = out.split("\n").filter(Boolean);
  if (lines.length !== requests.length) throw new Error(`the harness answered ${lines.length} of ${requests.length} requests`);
  return lines;
}

export async function engineAnswers(bin: string, cases: Case[]): Promise<Answer[]> {
  const lines = await ask(bin, cases.map((c) => ({ case: { q: hex(c.query), f: fieldJson(c.fields) } })));
  return lines.map((line) => JSON.parse(line) as Answer);
}

const same = (a: Answer, b: { tier: Tier; field: number | null }) => a.tier === b.tier && (a.field ?? null) === (b.field ?? null);

export function oracleAnswer(c: Case): Answer {
  const m = oracle.match(atoms(c.query), atomFields(c.fields));
  return m.tier === "none" ? { tier: "none", field: null } : { tier: m.tier, field: m.field - 1 };
}

type List = { items: Field[][]; query: Uint8Array; mode: "ranked" | "filtered" };
type ListingAnswer = { shown: number[]; at: number[]; count: number; rank_of: number[] };

async function engineListings(bin: string, lists: List[]): Promise<ListingAnswer[]> {
  const lines = await ask(bin, lists.map((l) => ({ listing: { items: l.items.map(fieldJson), q: hex(l.query), mode: l.mode } })));
  return lines.map((line) => JSON.parse(line) as ListingAnswer);
}

/// How many listings differ from the oracle's, and how many disagree with
/// themselves: `at` and `count` must read back what the walk shows, and
/// `rankOf` must give each shown row its place.
function compareListings(lists: List[], answers: ListingAnswer[]) {
  let inconsistent = 0;
  let differ = 0;
  answers.forEach((a, k) => {
    const list = lists[k]!;
    const readBack = a.count === a.shown.length && a.at.length === a.shown.length && a.at.every((p, i) => p === a.shown[i]);
    const ranks = list.mode === "filtered" ? a.rank_of.length === 0 : a.rank_of.length === a.shown.length && a.rank_of.every((r, i) => r === i);
    if (!readBack || !ranks) inconsistent += 1;
    const want = oracle.listing(list.items.map(atomFields), atoms(list.query), list.mode);
    if (want.join(",") !== a.shown.map((p) => p + 1).join(",")) differ += 1;
  });
  return { inconsistent, differ };
}

/// The real `Ranking` and `Filter` on seeded random listings and on lists
/// built to make R11 matter: each agrees with itself and with the oracle,
/// and TLC judges the first `tlcSample`.
export async function listingsThroughEngine(dir: string, bin: string, seed: number, tlcSample: number) {
  const random = randomCases(seed, 3000, 32);
  const lists = [...floorListings(random, 400), ...randomListings(random)];
  const answers = await engineListings(bin, lists);
  const { inconsistent, differ } = compareListings(lists, answers);
  const sample = lists.slice(0, tlcSample).map((l, k) => ({ ...l, shown: answers[k]!.shown.map((p) => p + 1), count: answers[k]!.count }));
  const judged = await judgeListings(join(dir, "tlc"), sample);
  return { listings: lists.length, inconsistent, differ, tlcListings: sample.length, tlcBad: judged.bad.length };
}

/// The edge table through the engine: every answer must be the expected one.
export async function edgeThroughEngine(bin: string, edge: Case[]) {
  const answers = await engineAnswers(bin, edge);
  const wrong = edge.flatMap((c, i) => (same(answers[i]!, c.expect!) ? [] : [{ id: c.id, got: answers[i]!, want: c.expect! }]));
  return { cases: edge.length, wrong };
}

/// Seeded random cases: the engine against the oracle on all of them, and
/// TLC on the first `tlcSample` with the edge table.
export async function randomThroughEngine(dir: string, bin: string, edge: Case[], seed: number, count: number, tlcSample: number) {
  const random = randomCases(seed, count, 64);
  const answers = await engineAnswers(bin, random);
  const differ = random.flatMap((c, i) => {
    const want = oracleAnswer(c);
    return same(answers[i]!, want) ? [] : [{ id: c.id, query: hex(c.query), got: answers[i]!, oracle: want }];
  });
  const sample = [...edge, ...random.slice(0, tlcSample)];
  const sampleAnswers = await engineAnswers(bin, sample);
  const judged = await judgeCases(join(dir, "tlc"), sample.map((c, i) => ({ query: c.query, fields: c.fields, expect: modelMatch(sampleAnswers[i]!) })));
  return { cases: random.length, differ, tlcCases: sample.length, tlcBad: judged.bad.length };
}

/// The query's prefixes, one character at a time, as the model counts them.
function characterPrefixes(bytes: Uint8Array): Uint8Array[] {
  const out: Uint8Array[] = [];
  let index = 0;
  while (index < bytes.length) {
    const len = bytes[index]! < 0x80 ? 1 : utf8SequenceLength(bytes, index) || 1;
    index += len;
    out.push(bytes.slice(0, index));
  }
  return out;
}

const UPPER_ASCII = (bytes: Uint8Array) => bytes.map((b) => (b >= 0x61 && b <= 0x7a ? b - 32 : b));
const WHITESPACE = new Set([0x20, 0x09, 0x0a, 0x0d]);
/// L2 covers prefixes with a word character, and blank ones.
const narrowingApplies = (bytes: Uint8Array) =>
  bytes.every((b) => WHITESPACE.has(b)) || bytes.some((b) => b >= 0x80 || (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a));

/// L2, L3, and L4 checked on the engine's own answers, independent of the
/// oracle: narrowing over every prefix, substring hits kept, and case.
export async function lawsOnEngine(bin: string, seed: number, count: number) {
  const base = randomCases(seed, count, 48);
  const probes: Case[] = [];
  const kinds: { kind: "narrow" | "upper"; of: number }[] = [];
  base.forEach((c, i) => {
    for (const prefix of characterPrefixes(c.query)) {
      if (!narrowingApplies(prefix)) continue;
      probes.push({ ...c, query: prefix });
      kinds.push({ kind: "narrow", of: i });
    }
    probes.push({ ...c, query: UPPER_ASCII(c.query) }); kinds.push({ kind: "upper", of: i });
  });
  const baseAnswers = await engineAnswers(bin, base);
  const probeAnswers = await engineAnswers(bin, probes);
  const broken: { law: string; id: string; query: string }[] = [];
  // L2: when the whole query matches, so does every prefix it covers.
  probeAnswers.forEach((answer, k) => {
    const { kind, of } = kinds[k]!;
    const c = base[of]!;
    if (kind === "narrow" && baseAnswers[of]!.tier !== "none" && answer.tier === "none") broken.push({ law: "Narrowing", id: c.id, query: hex(probes[k]!.query) });
    if (kind === "upper" && !same(answer, baseAnswers[of]!)) broken.push({ law: "CaseInsensitive", id: c.id, query: hex(c.query) });
  });
  // L3: a field that holds the whole trimmed query keeps the item at substring or better.
  base.forEach((c, i) => {
    const t = oracle.trim(atoms(c.query));
    const holds = c.fields.some((f) => oracle.contains(atoms(f.bytes), t));
    if (holds && TIER_RANK[baseAnswers[i]!.tier] < TIER_RANK.substring) broken.push({ law: "KeepsSubstringMatches", id: c.id, query: hex(c.query) });
  });
  return { cases: base.length, probes: probes.length, broken };
}

/// The words B1's items are made of.
const B1_WORDS = ["fix", "renderer", "add", "oauth", "login", "flow", "update", "skills", "menu", "fuzzy", "search", "session", "model", "picker", "cache", "test", "e2e", "zig", "release", "notes"];
const EVERYDAY_WORDS = "the quick brown fox jumps over the lazy dog while a model renders the session and fixes login flow before release notes ship to every user who searches".split(" ");

function realisticItems(rand: () => number, n: number): Field[][] {
  const phrase = (bytes: number) => {
    let out = "";
    while (out.length < bytes) out += `${B1_WORDS[Math.floor(rand() * B1_WORDS.length)]}${rand() < 0.2 ? "-" : " "}`;
    return out.slice(0, bytes);
  };
  return Array.from({ length: n }, () => [
    { bytes: utf8(phrase(60)), kind: "name" as const },
    { bytes: utf8(`/Users/example/projects/${phrase(200).replaceAll(" ", "/")}`.slice(0, 240)), kind: "text" as const },
    { bytes: utf8(phrase(240)), kind: "text" as const },
  ]);
}

const REALISTIC_QUERIES = ["fix", "oauth login", "fzsr", "renderer", "release notes", "model picker", "e2e", "zig", "cache test", "skills menu",
  "fuzzy", "sesion", "upd", "notes flow", "add", "picker", "login", "test", "rn", "mp"];

/// `fastestNs` is the quickest of `passes` runs of every query over every
/// item: on a shared machine the minimum is the measure load disturbs least.
async function bench(bin: string, items: Field[][], queries: Uint8Array[], passes: number, legacy = false): Promise<{ fastestNs: number; matches: number }> {
  const [line] = await ask(bin, [{ bench: { items: items.map(fieldJson), queries: queries.map(hex), passes, legacy } }]);
  const parsed = JSON.parse(line!) as { ns: number; min_ns: number; passes: number; matches: number };
  return { fastestNs: parsed.min_ns, matches: parsed.matches / passes };
}

/// B1 to B5 from design/GOAL.md, on a ReleaseSafe harness. Times are the
/// fastest of several runs; today's scan runs on the same input beside the
/// engine for scale.
export async function stress(bin: string, seed: number) {
  const rand = seededRandom(seed);
  const queries = REALISTIC_QUERIES.map(utf8);
  const results: Record<string, unknown> = {};
  const failures: string[] = [];

  // B1: 5,000 realistic items, 20 queries; one pass is one query over all items.
  const items5k = realisticItems(rand, 5000);
  const b1 = await bench(bin, items5k, queries, 7);
  const b1Today = await bench(bin, items5k, queries, 7, true);
  const b1PerPassMs = b1.fastestNs / queries.length / 1e6;
  results.B1 = { perPassMs: b1PerPassMs, todayPerPassMs: b1Today.fastestNs / queries.length / 1e6, matchesPerPass: b1.matches / queries.length, todayMatchesPerPass: b1Today.matches / queries.length, budgetMs: 5 };
  if (!(b1PerPassMs < 5)) failures.push(`B1: ${b1PerPassMs.toFixed(3)} ms per pass, budget 5 ms`);

  // B2: adversarial repeats against today's substring scan on the same
  // input. The query is shorter than the fields so today's scan compares at
  // every position instead of stopping at once, and each field holds every
  // query character so no character filter can skip the work.
  const field = () => utf8(`b${"a".repeat(239)}`);
  const adversarial = Array.from({ length: 1000 }, () => [
    { bytes: field(), kind: "name" as const }, { bytes: field(), kind: "text" as const }, { bytes: field(), kind: "text" as const },
  ]);
  const adversarialQuery = [utf8(`${"a".repeat(119)}b`)];
  const engine = await bench(bin, adversarial, adversarialQuery, 7);
  const legacy = await bench(bin, adversarial, adversarialQuery, 7, true);
  const ratio = engine.fastestNs / Math.max(1, legacy.fastestNs);
  results.B2 = { engineMs: engine.fastestNs / 1e6, todayMs: legacy.fastestNs / 1e6, ratio, budget: 4 };
  if (!(ratio <= 4)) failures.push(`B2: ${ratio.toFixed(2)} times today's scan, budget 4`);

  // B3: linear growth.
  const growth: { items: number; perPassMs: number }[] = [];
  for (const n of [1000, 2000, 4000, 8000]) {
    const items = realisticItems(rand, n);
    const run = await bench(bin, items, queries, 7);
    growth.push({ items: n, perPassMs: run.fastestNs / queries.length / 1e6 });
  }
  results.B3 = growth;
  for (let i = 1; i < growth.length; i += 1) {
    const step = growth[i]!.perPassMs / Math.max(1e-9, growth[i - 1]!.perPassMs);
    if (step > 2.5) failures.push(`B3: ${growth[i - 1]!.items} to ${growth[i]!.items} items took ${step.toFixed(2)} times longer, budget 2.5`);
  }

  // B4: random bytes up to 4 KiB; every answer well formed.
  const huge = randomCases(seed + 1, 400, 4096).map((c) => ({ ...c, query: c.query.slice(0, 4096) }));
  const answers = await engineAnswers(bin, huge);
  const malformed = answers.filter((a, i) => !(a.tier in TIER_RANK) || (a.tier === "none") !== (a.field === null) || (a.field !== null && (a.field < 0 || a.field >= huge[i]!.fields.length)));
  results.B4 = { cases: huge.length, malformed: malformed.length };
  if (malformed.length > 0) failures.push(`B4: ${malformed.length} malformed answers`);

  // B5: 64 KiB pastes over B1's items. Words from B1's own vocabulary are
  // the worst case, since every item holds most of them and every query
  // word must match (R4); R12 is what keeps each item's cost to its fields.
  const paste = (pieces: string[]) => {
    let out = "";
    for (let i = 0; out.length < 65536; i += 1) out += `${pieces[i % pieces.length]} `;
    return utf8(out.slice(0, 65536));
  };
  const pastes = { token: utf8("ab".repeat(32768)), everyday: paste(EVERYDAY_WORDS), itemWords: paste(B1_WORDS) };
  const b5: Record<string, number> = {};
  for (const [name, query] of Object.entries(pastes)) {
    const run = await bench(bin, items5k, [query], 3);
    b5[name] = run.fastestNs / 1e6;
    if (!(b5[name]! < 5)) failures.push(`B5: a 64 KiB ${name} paste took ${b5[name]!.toFixed(3)} ms per pass, budget 5 ms`);
  }
  results.B5 = { perPassMs: b5, budgetMs: 5 };
  return { results, failures };
}

/// Each planted engine bug, built and run on the edge table and random
/// cases: it must change at least one answer.
export async function codeMutations(dir: string, edge: Case[], seed: number, bugs: { id: string; find: string; replace: string }[]) {
  const original = readFileSync(ENGINE_SOURCE, "utf8");
  const random = randomCases(seed, 1500, 48);
  const lists = [...floorListings(random, 200), ...randomListings(random)];
  const out: { id: string; caught: boolean; detail: string }[] = [];
  for (const bug of bugs) {
    const bin = buildHarness(join(dir, bug.id), "Debug", plant(original, bug.find, bug.replace, bug.id));
    const edgeRun = await edgeThroughEngine(bin, edge);
    const answers = await engineAnswers(bin, random);
    const differ = random.filter((c, i) => !same(answers[i]!, oracleAnswer(c))).length;
    const listed = compareListings(lists, await engineListings(bin, lists));
    const changed = listed.differ + listed.inconsistent;
    out.push({
      id: bug.id,
      caught: edgeRun.wrong.length > 0 || differ > 0 || changed > 0,
      detail: `${edgeRun.wrong.length} edge cases, ${differ} random cases, and ${changed} of ${lists.length} listings changed`,
    });
  }
  return out;
}

