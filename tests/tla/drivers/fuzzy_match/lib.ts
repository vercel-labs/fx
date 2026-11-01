// Shared pieces of the fuzzy match drivers: where the model and the engine
// live, turning bytes into the model's character atoms, printing TLA+ values,
// a seeded random source, and TLC runs on the pinned jar.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT, TLA_ROOT, runTlc, tlcToolchain, type TlcRun } from "../lib/tlc.ts";

export const MODEL_DIR = join(TLA_ROOT, "fuzzy_match");
export const SPEC_DIR = join(MODEL_DIR, "spec");
export const ENGINE_SOURCE = join(REPO_ROOT, "src", "core", "shared", "fuzzy_match.zig");
export const HARNESS_SOURCE = join(import.meta.dirname, "harness.zig");

// TLC 1.7.4 (TLC2 2.19 of 08 August 2024, rev 5a47802), the release the
// image route drivers pin, from
// https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
export const PINNED_JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88";
export const PINNED_TLC_VERSION = "TLC2 Version 2.19 of 08 August 2024 (rev: 5a47802)";

export type Kind = "name" | "text";
export type Tier = "none" | "fuzzy" | "words" | "substring" | "prefix" | "exact";
export const TIERS: Tier[] = ["none", "fuzzy", "words", "substring", "prefix", "exact"];
export const TIER_RANK: Record<Tier, number> = { none: 0, fuzzy: 1, words: 2, substring: 3, prefix: 4, exact: 5 };

/// A field as the engine takes it: raw bytes and a kind.
export type Field = { bytes: Uint8Array; kind: Kind };
/// A match as the model states it: `field` counts from 1, and 0 means none.
export type Match = { tier: Tier; field: number };

export type AtomField = { text: string[]; kind: Kind };

/// The pinned toolchain, or a reason it is not the pinned one.
export function pinnedToolchain() {
  const toolchain = tlcToolchain();
  if (toolchain.jarSha256 !== PINNED_JAR_SHA256) {
    throw new Error(
      `tla2tools.jar at ${toolchain.jar} has sha256 ${toolchain.jarSha256}, not the pinned ${PINNED_JAR_SHA256}. ` +
        "Download v1.7.4 from https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar " +
        "and point TLA2TOOLS_JAR at it.",
    );
  }
  return toolchain;
}

const encoder = new TextEncoder();
export const utf8 = (text: string) => encoder.encode(text);
const hex2 = (byte: number) => byte.toString(16).padStart(2, "0");

/// The length of the valid UTF-8 sequence at `index`, or 0 when the byte
/// there starts none. The same rules as `std.unicode.utf8ByteSequenceLength`
/// with `utf8Decode2`, `utf8Decode3`, and `utf8Decode4`, which
/// `display_width.decodeNextRune` uses: no overlong forms, no surrogates,
/// nothing above U+10FFFF, and a truncated sequence is invalid.
export function utf8SequenceLength(bytes: Uint8Array, index: number): number {
  const lead = bytes[index]!;
  const len = lead < 0x80 ? 1 : lead >= 0xc0 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xef ? 3 : lead >= 0xf0 && lead <= 0xf7 ? 4 : 0;
  if (len <= 1) return len;
  if (index + len > bytes.length) return 0;
  for (let k = 1; k < len; k += 1) if ((bytes[index + k]! & 0xc0) !== 0x80) return 0;
  const cp = codePointAt(bytes, index, len);
  if (len === 2 && cp < 0x80) return 0;
  if (len === 3 && (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff))) return 0;
  if (len === 4 && (cp < 0x10000 || cp > 0x10ffff)) return 0;
  return len;
}

function codePointAt(bytes: Uint8Array, index: number, len: number): number {
  const masks = [0, 0x7f, 0x1f, 0x0f, 0x07];
  let cp = bytes[index]! & masks[len]!;
  for (let k = 1; k < len; k += 1) cp = (cp << 6) | (bytes[index + k]! & 0x3f);
  return cp;
}

const isAsciiAlnum = (byte: number) =>
  (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a);

/// R8: the model's character atoms for `bytes`.
export function atoms(bytes: Uint8Array): string[] {
  const out: string[] = [];
  let index = 0;
  while (index < bytes.length) {
    const byte = bytes[index]!;
    if (byte < 0x80) {
      out.push(isAsciiAlnum(byte) ? String.fromCharCode(byte) : `s+${hex2(byte)}`);
      index += 1;
      continue;
    }
    const len = utf8SequenceLength(bytes, index);
    if (len >= 2) {
      out.push(`u+${codePointAt(bytes, index, len).toString(16)}`);
      index += len;
    } else {
      out.push(`b+${hex2(byte)}`);
      index += 1;
    }
  }
  return out;
}

export function atomFields(fields: Field[]): AtomField[] {
  return fields.map((field) => ({ text: atoms(field.bytes), kind: field.kind }));
}

/// A JSON value as TLA+: objects are records, arrays are sequences.
export function toTla(value: unknown): string {
  if (Array.isArray(value)) return `<<${value.map(toTla).join(", ")}>>`;
  if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
  if (typeof value === "number") return String(value);
  if (typeof value === "string") {
    if (!/^[A-Za-z0-9+]*$/.test(value)) throw new Error(`refusing to print ${JSON.stringify(value)} as a TLA+ string`);
    return `"${value}"`;
  }
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
    return `[${entries.map(([k, v]) => `${k} |-> ${toTla(v)}`).join(", ")}]`;
  }
  throw new Error(`cannot print ${String(value)} as TLA+`);
}

/// Mulberry32: a small seeded generator, so a failing run can be replayed.
export function seededRandom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export type CheckedTlc = TlcRun & { verdict: "pass" | "violated" | "error"; property: string | null; tlcVersion: string | null };

/// Runs TLC on `module` with `cfg` in `dir`, after writing `files` there.
export async function checkTlc(
  dir: string,
  module: string,
  cfg: string,
  files: Record<string, string>,
  extraArgs: string[] = [],
): Promise<CheckedTlc> {
  pinnedToolchain();
  mkdirSync(dir, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text);
  const run = await runTlc(dir, module, cfg, [], dir, ["-deadlock", ...extraArgs]);
  const tlcVersion = /^(TLC2 Version [^\n]*?)\s*$/m.exec(run.output)?.[1] ?? null;
  const property = (/Error: (?:Invariant|Action property) ([\w!]+) is violated/.exec(run.output) ?? /Error: The invariant of ([\w!]+) is equal to FALSE/.exec(run.output))?.[1]?.replace(/^\w+!/, "") ?? null;
  const passed = run.exitCode === 0 && /Model checking completed\. No error has been found\./.test(run.output);
  const verdict = passed ? "pass" : property ? "violated" : "error";
  return { ...run, verdict, property, tlcVersion };
}

/// Every file in spec/, keyed by name, with `FuzzyMatch.tla` optionally
/// replaced by a planted-bug copy.
export function specFiles(fuzzyMatch?: string): Record<string, string> {
  const files: Record<string, string> = {};
  for (const name of readdirSync(SPEC_DIR)) {
    if (name.endsWith(".tla") || name.endsWith(".cfg")) files[name] = readFileSync(join(SPEC_DIR, name), "utf8");
  }
  if (fuzzyMatch !== undefined) files["FuzzyMatch.tla"] = fuzzyMatch;
  return files;
}

/// The module and invariants a config in spec/ checks.
export function configInfo(cfg: string, text = readFileSync(join(SPEC_DIR, cfg), "utf8")) {
  const module = cfg.startsWith("MCListing") ? "MCListing" : "MCFuzzyMatch";
  const invariants: string[] = [];
  let inInvariants = false;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\\\*.*$/, "").trim();
    if (!line) continue;
    if (/^[A-Z_]+$/.test(line.split(/\s+/)[0]!)) {
      inInvariants = line.startsWith("INVARIANT");
      continue;
    }
    if (inInvariants) invariants.push(...line.split(/\s+/));
  }
  return { module, invariants };
}

/// `cfg` with its INVARIANT section cut to `property` alone.
export function onlyInvariant(cfgText: string, property: string): string {
  const head = cfgText.split(/^INVARIANT\s*$/m)[0]!;
  return `${head}INVARIANT\n    ${property}\n`;
}

/// Applies a planted bug: `find` must occur exactly once in `text`.
export function plant(text: string, find: string, replace: string, id: string): string {
  const first = text.indexOf(find);
  if (first < 0 || text.indexOf(find, first + 1) >= 0) {
    throw new Error(`${id}: the text to replace must occur exactly once`);
  }
  return text.slice(0, first) + replace + text.slice(first + find.length);
}

export function engineExists(): boolean {
  return existsSync(ENGINE_SOURCE);
}
