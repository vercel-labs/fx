// A second implementation of spec/FuzzyMatch.tla, operator by operator,
// over the model's character atoms. The drivers use it only to compute
// expectations fast for large and random runs; the `oracle` stage of
// verify.ts checks it against TLC on the edge table and seeded random cases,
// and every planted oracle bug in mutations.json must be caught there.
import { TIER_RANK, type AtomField, type Match, type Tier } from "./lib.ts";

const UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const WHITESPACE = new Set(["s+20", "s+09", "s+0a", "s+0d"]);

export const fold = (c: string) => (c.length === 1 && UPPER.includes(c) ? c.toLowerCase() : c);
export const same = (a: string, b: string) => fold(a) === fold(b);
export const isSep = (c: string) => c.startsWith("s+");
export const isWordChar = (c: string) => !isSep(c);
export const isDigit = (c: string) => c.length === 1 && c >= "0" && c <= "9";

function sameSeq(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) if (!same(a[i]!, b[i]!)) return false;
  return true;
}

export function startsWith(s: string[], p: string[]): boolean {
  return p.length <= s.length && sameSeq(s.slice(0, p.length), p);
}

export function contains(s: string[], n: string[]): boolean {
  for (let i = 0; i + n.length <= s.length; i += 1) {
    let ok = true;
    for (let j = 0; j < n.length; j += 1) {
      if (!same(s[i + j]!, n[j]!)) { ok = false; break; }
    }
    if (ok) return true;
  }
  return false;
}

export function trim(s: string[]): string[] {
  let start = 0;
  let end = s.length;
  while (start < end && WHITESPACE.has(s[start]!)) start += 1;
  while (end > start && WHITESPACE.has(s[end - 1]!)) end -= 1;
  return s.slice(start, end);
}

export function words(s: string[]): string[][] {
  const out: string[][] = [];
  let current: string[] = [];
  for (const c of s) {
    if (WHITESPACE.has(c)) {
      if (current.length > 0) out.push(current);
      current = [];
    } else {
      current.push(c);
    }
  }
  if (current.length > 0) out.push(current);
  return out;
}

export const compact = (s: string[]) => s.filter(isWordChar);
export const hasWordChar = (s: string[]) => s.some(isWordChar);

/// R9, with `i` counting from 0.
export function wordStart(f: string[], i: number): boolean {
  if (!isWordChar(f[i]!)) return false;
  if (i === 0) return true;
  if (isSep(f[i - 1]!)) return true;
  return isDigit(f[i - 1]!) !== isDigit(f[i]!);
}

export function runIn(f: string[], w: string[]): boolean {
  const cw = compact(w);
  return cw.length > 0 && contains(compact(f), cw);
}

export function fuzzyIn(f: string[], w: string[]): boolean {
  const cw = compact(w);
  if (cw.length === 0) return false;
  let anchor = -1;
  for (let i = 0; i < f.length; i += 1) {
    if (wordStart(f, i) && same(f[i]!, cw[0]!)) { anchor = i; break; }
  }
  if (anchor < 0) return false;
  let at = anchor + 1;
  for (const c of cw.slice(1)) {
    while (at < f.length && !same(f[at]!, c)) at += 1;
    if (at >= f.length) return false;
    at += 1;
  }
  return true;
}

export function wholeTier(fd: AtomField, t: string[]): Tier {
  if (fd.kind === "name" && sameSeq(fd.text, t)) return "exact";
  if (fd.kind === "name" && startsWith(fd.text, t)) return "prefix";
  if (contains(fd.text, t)) return "substring";
  return "none";
}

export function wordTier(fd: AtomField, w: string[]): Tier {
  if (fd.kind === "name") {
    if (runIn(fd.text, w)) return "words";
    if (fuzzyIn(fd.text, w)) return "fuzzy";
    return "none";
  }
  return contains(fd.text, w) ? "words" : "none";
}

function best(tiers: Tier[]): Tier {
  return tiers.reduce((a, b) => (TIER_RANK[b] > TIER_RANK[a] ? b : a));
}

function worst(tiers: Tier[]): Tier {
  return tiers.reduce((a, b) => (TIER_RANK[b] < TIER_RANK[a] ? b : a));
}

/// R1 to R7. `field` counts from 1, as in the model.
/// R12: the most characters a query can have and still match by words or
/// letters in order.
export const MAX_FUZZY_CHARS = 64;

export function match(q: string[], fs: AtomField[]): Match {
  const t = trim(q);
  if (t.length === 0) return { tier: "exact", field: 1 };
  const whole = fs.map((fd) => wholeTier(fd, t));
  const top = best(whole);
  if (TIER_RANK[top] >= TIER_RANK.substring) return { tier: top, field: whole.indexOf(top) + 1 };
  // R12: a longer query matches only as typed.
  if (t.length > MAX_FUZZY_CHARS) return { tier: "none", field: 0 };
  const ws = words(t).filter(hasWordChar);
  // R6: only punctuation, and no field holds it as typed.
  if (ws.length === 0) return { tier: "none", field: 0 };
  const per = ws.map((w) => fs.map((fd) => wordTier(fd, w)));
  const level = per.map(best);
  if (level.includes("none")) return { tier: "none", field: 0 };
  return { tier: worst(level), field: Math.min(...per.map((row, j) => row.indexOf(level[j]!) + 1)) };
}

/// R10 and R11: the 1-based indexes a listing shows, in order.
export function listing(items: AtomField[][], q: string[], mode: "ranked" | "filtered"): number[] {
  const matches = items.map((fs) => match(q, fs));
  const shown = items.map((_, i) => i + 1).filter((i) => matches[i - 1]!.tier !== "none");
  if (mode === "filtered") {
    // R11: the as-typed matches when there are any, otherwise every match.
    const asTyped = shown.filter((i) => TIER_RANK[matches[i - 1]!.tier] >= TIER_RANK.substring);
    return asTyped.length > 0 ? asTyped : shown;
  }
  return shown.sort((i, j) => {
    const a = matches[i - 1]!;
    const b = matches[j - 1]!;
    return TIER_RANK[b.tier] - TIER_RANK[a.tier] || a.field - b.field || i - j;
  });
}
