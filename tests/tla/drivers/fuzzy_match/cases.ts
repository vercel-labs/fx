// The cases the drivers check: the hand-written edge table in
// tests/tla/fuzzy_match/cases/edge.json, and seeded random cases in five
// families, so a failing run can be replayed from its seed.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { MODEL_DIR, seededRandom, utf8, type Field, type Kind, type Tier } from "./lib.ts";

export type Case = {
  id: string;
  query: Uint8Array;
  fields: Field[];
  /// The engine's answer: `field` counts from 0, and null means no match.
  expect?: { tier: Tier; field: number | null };
  rules?: string[];
};

type TextSpec = string | { hex: string };

function bytesOf(spec: TextSpec): Uint8Array {
  if (typeof spec === "string") return utf8(spec);
  if (!/^([0-9a-f]{2})*$/.test(spec.hex)) throw new Error(`bad hex ${spec.hex}`);
  return Uint8Array.from(spec.hex.match(/../g) ?? [], (pair) => parseInt(pair, 16));
}

export function edgeCases(path = join(MODEL_DIR, "cases", "edge.json")): Case[] {
  const raw = JSON.parse(readFileSync(path, "utf8")) as {
    cases: {
      id: string;
      rules: string[];
      query?: TextSpec;
      repeat?: { query: [string, number]; field: [string, number] };
      fields: { text?: TextSpec; kind: Kind }[];
      expect: { tier: Tier; field: number | null };
    }[];
  };
  return raw.cases.map((entry) => {
    const query = entry.repeat ? utf8(entry.repeat.query[0].repeat(entry.repeat.query[1])) : bytesOf(entry.query!);
    const fields = entry.fields.map((field) => ({
      kind: field.kind,
      bytes: entry.repeat ? utf8(entry.repeat.field[0].repeat(entry.repeat.field[1])) : bytesOf(field.text!),
    }));
    return { id: entry.id, rules: entry.rules, query, fields, expect: entry.expect };
  });
}

// Realistic items: model ids, skill names and descriptions, command names,
// session titles, MCP tools, settings labels, and team slugs.
const NAMES = [
  "anthropic/claude-sonnet-4.5", "anthropic/claude-opus-4.8", "openai/gpt-5.4", "openai/gpt-4o-mini",
  "google/gemini-3-pro", "zai/glm-4.7", "xai/grok-4.6", "deepseek/deepseek-v4.1-flash-1017",
  "fx-commit", "zig-best-practices", "workflow-helper", "/model", "/mcp", "/fast-mode", "/image",
  "Fix renderer", "Add OAuth login", "create_issue", "list_projects", "Startup scrollback",
  "acme-corp", "Acme Corp", "xhigh", "ultrafast", "修复渲染器", "café-crème", "🚀 launch plan",
];
const TEXTS = [
  "Land vercel-labs/fx work with a signed commit", "global .codex", "workspace skills/",
  "/Users/example/.codex/skills/fx-commit/SKILL.md", "/Users/example/projects/fx",
  "inspect footer state", "Create an issue in a project", "Show earlier conversation when fx starts",
  "on", "off", "choose what model and reasoning effort to use", "Make a ticket", "",
];
const ATOMS_TINY = ["a", "A", "b", "1", "-", " ", "é"];
const UNICODE = ["é", "É", "渲", "染", "🚀", "\u00a0", "\u0301", "ß", "İ", "ﬁ", "\u200b", "a", "-", " "];
const PUNCT = ["-", "_", ".", "/", ":", " ", "\t", "@", "#", "(", ")", "a", "1"];

function pick<T>(rand: () => number, list: readonly T[]): T {
  return list[Math.floor(rand() * list.length)]!;
}

function int(rand: () => number, lo: number, hi: number): number {
  return lo + Math.floor(rand() * (hi - lo + 1));
}

function fromList(rand: () => number, list: readonly string[], maxLen: number): string {
  let out = "";
  const len = int(rand, 0, maxLen);
  for (let i = 0; i < len; i += 1) out += pick(rand, list);
  return out;
}

/// A query a person might type for `target`: a slice, its words, a typo,
/// swapped case or separators, or something unrelated.
function realisticQuery(rand: () => number, target: string): string {
  const choice = int(rand, 0, 7);
  const chars = [...target];
  switch (choice) {
    case 0: {
      const start = int(rand, 0, Math.max(0, chars.length - 1));
      return chars.slice(start, start + int(rand, 1, 8)).join("");
    }
    case 1:
      return target.split(/[^A-Za-z0-9]+/).filter(() => rand() < 0.6).join(" ");
    case 2: {
      const at = int(rand, 0, Math.max(0, chars.length - 1));
      return chars.filter((_, i) => i !== at).join("");
    }
    case 3:
      return chars.map((c) => (rand() < 0.4 ? c.toUpperCase() : c)).join("");
    case 4:
      return target.replace(/[-_/.]/g, () => pick(rand, [" ", "", "-", "_"]));
    case 5:
      return target.split(/[^A-Za-z0-9]+/).map((w) => w.slice(0, int(rand, 1, 3))).join("");
    case 6:
      return fromList(rand, ["a", "e", "o", "s", "t", "4", "-", " "], 4);
    default:
      return pick(rand, NAMES).slice(0, int(rand, 1, 6));
  }
}

function randomBytes(rand: () => number, maxLen: number): Uint8Array {
  const len = int(rand, 0, maxLen);
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i += 1) {
    // Mostly bytes that matter to the rules: letters, separators, and the
    // edges of UTF-8 sequences.
    out[i] = rand() < 0.5
      ? pick(rand, [0x61, 0x41, 0x62, 0x31, 0x2d, 0x20, 0x09, 0xc3, 0xa9, 0xe2, 0x82, 0xac, 0xf0, 0x9f, 0x80, 0xff, 0xc0])
      : int(rand, 0, 255);
  }
  return out;
}

export type Family = "tiny" | "realistic" | "unicode" | "punct" | "bytes";
export const FAMILIES: Family[] = ["tiny", "realistic", "unicode", "punct", "bytes"];

/// `count` cases from `seed`, cycling through the families. `maxBytes`
/// bounds each field for the `bytes` family.
export function randomCases(seed: number, count: number, maxBytes = 48): Case[] {
  const rand = seededRandom(seed);
  const out: Case[] = [];
  for (let n = 0; n < count; n += 1) {
    const family = FAMILIES[n % FAMILIES.length]!;
    const fieldCount = int(rand, 1, 4);
    const kinds: Kind[] = Array.from({ length: fieldCount }, (_, i) => (i === 0 || rand() < 0.4 ? "name" : "text"));
    let query: Uint8Array;
    let fields: Field[];
    switch (family) {
      case "tiny":
        fields = kinds.map((kind) => ({ kind, bytes: utf8(fromList(rand, ATOMS_TINY, 6)) }));
        query = utf8(fromList(rand, ATOMS_TINY, 5));
        break;
      case "realistic": {
        fields = kinds.map((kind) => ({ kind, bytes: utf8(kind === "name" ? pick(rand, NAMES) : pick(rand, TEXTS)) }));
        const target = new TextDecoder().decode(pick(rand, fields).bytes) || pick(rand, NAMES);
        query = utf8(realisticQuery(rand, target));
        break;
      }
      case "unicode":
        fields = kinds.map((kind) => ({ kind, bytes: utf8(fromList(rand, UNICODE, 8)) }));
        query = utf8(fromList(rand, UNICODE, 4));
        break;
      case "punct":
        fields = kinds.map((kind) => ({ kind, bytes: utf8(fromList(rand, PUNCT, 8)) }));
        query = utf8(fromList(rand, PUNCT, 5));
        break;
      case "bytes":
        fields = kinds.map((kind) => ({ kind, bytes: randomBytes(rand, maxBytes) }));
        query = randomBytes(rand, Math.min(16, maxBytes));
        break;
    }
    out.push({ id: `${family}-${seed}-${n}`, query, fields });
  }
  return out;
}

export const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
