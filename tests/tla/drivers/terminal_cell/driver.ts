// Runs the built fx binary along tests/tla/terminal_cell/TerminalCell.tla and
// has TLC check every run of zero-width units it observes
// (TerminalCellTrace.tla).
//
// Each run is one base character and a stream of zero-width units (combining
// marks, zero-width spaces, tag characters) written as an fx tape and replayed
// with `fx replay --golden`, which feeds the bytes through the same terminal
// engine the screen uses. The tape is replayed twice: once with every unit in
// its own read, and once with two units to a read. Each replay's final screen
// shows how many bytes of suffix the cell kept and whether the character
// written after it landed in the next column. fx before the change exits at a
// full cell, which the run records as a process that did not stay alive.
//
// The cases are the edges of the 64-byte cell (a stream that fills it exactly,
// one unit short, one unit past, mixed unit sizes where a big unit is dropped
// and a smaller one after it fits) and seeded random streams, for a one-,
// three- and four-byte base.
//
// Usage:
//   bun tests/tla/drivers/terminal_cell/driver.ts [--self-check] [--seed N]
//
// The default run requires TLC to accept every observation against the
// design. --self-check also requires TLC to reject every observation against
// fx before the change and against each planted defect in the model, so a
// model that accepted anything would fail. Exits 0 when all hold, 1 when a
// check misses, 2 when a tool fails.
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { TLA_ROOT, fxBin, outDir, runTlc, sha256File, writeJson } from "../lib/tlc";

const CAP = 64;
const SPEC_DIR = join(TLA_ROOT, "terminal_cell");
const COLS = 80;
const ROWS = 4;
const TERMINATOR = "Z";

// A unit is one zero-width codepoint, named by its size in bytes.
const UNIT_TEXT: Record<number, string> = { 2: "\u0301", 3: "\u200b", 4: "\u{e0061}" };
// Narrow bases of one, three, and four bytes, so the next column is always 2.
const BASES = [
  { bytes: 1, text: "e" },
  { bytes: 3, text: "\u20ac" },
  { bytes: 4, text: "\u{10400}" },
];

type Observation = {
  base: number;
  units: number[];
  alive: boolean;
  aused: number;
  acol: number;
  bused: number;
  bcol: number;
};

function parseArgs(argv: string[]): { selfCheck: boolean; seed: number } {
  let selfCheck = false;
  let seed = 20261107;
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    if (arg === "--self-check") selfCheck = true;
    else if (arg === "--seed") seed = Number(argv[++index]);
    else throw new Error(`unknown argument ${arg}`);
  }
  return { selfCheck, seed };
}

/// A small seeded generator, so a failing run can be replayed.
function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function repeat(size: number, count: number): number[] {
  return Array<number>(count).fill(size);
}

/// Units that take exactly `room` bytes, from twos and at most one three.
function exactFill(room: number): number[] {
  return room % 2 === 0 ? repeat(2, room / 2) : [3, ...repeat(2, (room - 3) / 2)];
}

function edgeStreams(baseBytes: number): number[][] {
  const room = CAP - baseBytes;
  const threes = Math.floor(room / 3);
  return [
    exactFill(room),
    [...exactFill(room), 2],
    exactFill(room).slice(1),
    exactFill(room - 2),
    repeat(2, 40),
    repeat(2, 120),
    repeat(3, 30),
    repeat(4, 20),
    // Three-byte units fill the cell to within three bytes, the four-byte
    // unit does not fit, the two-byte unit after it does, and the next does not.
    [...repeat(3, threes), 4, 2, 2],
    [...repeat(3, threes), 3, 3, 2, 4],
    [4, ...repeat(4, 20), 2, 3],
    [2],
    [4, 4, 4],
  ];
}

function randomStreams(seed: number, count: number): number[][] {
  const next = mulberry32(seed);
  const streams: number[][] = [];
  for (let index = 0; index < count; index++) {
    const length = 10 + Math.floor(next() * 51);
    streams.push(Array.from({ length }, () => 2 + Math.floor(next() * 3)));
  }
  return streams;
}

function tapeBytes(frames: string[]): Buffer {
  const version = Buffer.from("terminal-cell-driver");
  const head = Buffer.alloc(5 + 2 + 2 + 8 + 1);
  head.write("FXTP\x01", 0, "binary");
  head.writeUInt16LE(COLS, 5);
  head.writeUInt16LE(ROWS, 7);
  head.writeBigUInt64LE(0n, 9);
  head.writeUInt8(version.length, 17);
  const parts: Buffer[] = [head, version];
  for (const text of frames) {
    const payload = Buffer.from(text, "utf8");
    const header = Buffer.alloc(9);
    header.writeInt32LE(0, 0);
    header.writeUInt8(1, 4);
    header.writeUInt32LE(payload.length, 5);
    parts.push(header, payload);
  }
  return Buffer.concat(parts);
}

type Replay = { alive: boolean; used: number; col: number };

/// Replays `frames` with the built fx and reads the first screen row.
function replay(work: string, bin: string, base: string, frames: string[]): Replay {
  const tape = join(work, "run.fxtape");
  const golden = join(work, "golden.txt");
  writeFileSync(tape, tapeBytes(frames));
  const home = join(work, "home");
  mkdirSync(home, { recursive: true });
  const result = spawnSync(bin, ["replay", tape, "--golden", golden], {
    encoding: "utf8",
    env: {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      HOME: home,
      FX_HOME: join(home, "fx"),
      FX_SOUND: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_AUTO_UPGRADE: "0",
    },
  });
  if (result.status !== 0) {
    // fx before the change exits at a full cell with this message.
    if (result.stderr.includes("combining pool capacity exceeded")) {
      return { alive: false, used: 0, col: 0 };
    }
    throw new Error(`fx replay exited ${result.status}: ${result.stderr}`);
  }
  const row = readFileSync(golden, "utf8").split("\n")[0]!.replace(/^\|/, "").replace(/\|$/, "");
  const units = new Set(Object.values(UNIT_TEXT));
  const chars = [...row];
  if (chars[0] !== [...base][0]) throw new Error(`the row does not start with the base: ${JSON.stringify(row)}`);
  let index = 1;
  let used = 0;
  while (index < chars.length && units.has(chars[index]!)) used += Buffer.byteLength(chars[index++]!);
  let spaces = 0;
  while (index < chars.length && chars[index] === " ") {
    spaces++;
    index++;
  }
  if (chars[index] !== TERMINATOR) throw new Error(`the terminator is missing from ${JSON.stringify(row)}`);
  // The terminator sits in the column after the base, plus any gap a unit left.
  return { alive: true, used, col: 2 + spaces };
}

function observe(work: string, bin: string, base: { bytes: number; text: string }, units: number[]): Observation {
  const texts = units.map((size) => UNIT_TEXT[size]!);
  const oneAtATime = [base.text, ...texts, TERMINATOR];
  const twoAtATime: string[] = [base.text];
  for (let index = 0; index < texts.length; index += 2) twoAtATime.push(texts.slice(index, index + 2).join(""));
  twoAtATime.push(TERMINATOR);
  const a = replay(work, bin, base.text, oneAtATime);
  const b = replay(work, bin, base.text, twoAtATime);
  return {
    base: base.bytes,
    units,
    alive: a.alive && b.alive,
    aused: a.used,
    acol: a.col,
    bused: b.used,
    bcol: b.col,
  };
}

function observedModule(observations: Observation[]): string {
  const records = observations.map(
    (o) =>
      `    [base |-> ${o.base}, units |-> <<${o.units.join(", ")}>>, alive |-> ${o.alive ? "TRUE" : "FALSE"}, ` +
      `aused |-> ${o.aused}, acol |-> ${o.acol}, bused |-> ${o.bused}, bcol |-> ${o.bcol}]`,
  );
  return [
    "---- MODULE TerminalCellObserved ----",
    "EXTENDS Naturals, Sequences",
    "Observed == <<",
    records.join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
}

type Variant = { name: string; rule: string; capIncludesBase: boolean; bug: string };

const DESIGN: Variant = { name: "design", rule: "drop", capIncludesBase: true, bug: "none" };
const REJECTED_MODELS: Variant[] = [
  { name: "fx before the change", rule: "fail", capIncludesBase: false, bug: "none" },
  { name: "cap on the suffix alone", rule: "drop", capIncludesBase: false, bug: "none" },
  { name: "dropped unit moves the cursor", rule: "drop", capIncludesBase: true, bug: "drop-moves-cursor" },
  { name: "read dropped whole", rule: "drop", capIncludesBase: true, bug: "call-atomic" },
  { name: "drop everything after the first drop", rule: "drop", capIncludesBase: true, bug: "stop-at-first" },
  { name: "unit that does not fit evicts earlier ones", rule: "drop", capIncludesBase: true, bug: "evict-earlier" },
];

type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

async function check(
  observations: Observation[],
  variant: Variant,
  parent: string,
): Promise<{ verdict: Verdict; states: number | null; dir: string }> {
  const dir = mkdtempSync(join(parent, "trace-"));
  for (const file of ["TerminalCell.tla", "TerminalCellTrace.tla"]) copyFileSync(join(SPEC_DIR, file), join(dir, file));
  writeFileSync(join(dir, "TerminalCellObserved.tla"), observedModule(observations));
  writeFileSync(
    join(dir, "trace.cfg"),
    [
      "SPECIFICATION TraceSpec",
      "CONSTANTS",
      "    UnitSizes = {2, 3, 4}",
      "    BaseSizes = {1, 3, 4}",
      "    N = 1",
      `    Cap = ${CAP}`,
      `    Rule = "${variant.rule}"`,
      `    CapIncludesBase = ${variant.capIncludesBase ? "TRUE" : "FALSE"}`,
      `    Bug = "${variant.bug}"`,
      "INVARIANT NotAllMatched",
      "CHECK_DEADLOCK FALSE",
      "",
    ].join("\n"),
  );
  const run = await runTlc(dir, "TerminalCellTrace", "trace.cfg", [], dir);
  if (run.violated === "NotAllMatched") return { verdict: "ACCEPTED", states: run.distinctStates, dir };
  if (run.exitCode === 0 && /No error has been found/.test(run.output)) {
    return { verdict: "REJECTED", states: run.distinctStates, dir };
  }
  return { verdict: "TOOL_ERROR", states: run.distinctStates, dir };
}

/// The first observation `variant` rejects, by bisection on prefixes.
async function firstRejected(observations: Observation[], variant: Variant, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await check(observations.slice(0, middle), variant, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  const { selfCheck, seed } = parseArgs(process.argv.slice(2));
  const bin = fxBin();
  const out = outDir("terminal-cell");
  const work = mkdtempSync(join(tmpdir(), "fx-terminal-cell-"));
  console.log(`binary ${bin} sha256 ${sha256File(bin).slice(0, 12)}; seed ${seed}; output ${out}`);

  const observations: Observation[] = [];
  for (const base of BASES) {
    for (const units of [...edgeStreams(base.bytes), ...randomStreams(seed + base.bytes, 24)]) {
      observations.push(observe(work, bin, base, units));
    }
  }
  const crashed = observations.filter((o) => !o.alive).length;
  console.log(`observed ${observations.length} runs of the built fx; ${crashed} did not stay alive`);
  writeJson(join(out, "observations.json"), observations);

  const design = await check(observations, DESIGN, out);
  console.log(`design: ${design.verdict}, ${design.states ?? "?"} states (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const first = await firstRejected(observations, DESIGN, out);
    console.log(`the model rejects a run of the built fx; first: ${JSON.stringify(first)}`);
    return 1;
  }
  if (selfCheck) {
    for (const variant of REJECTED_MODELS) {
      const result = await check(observations, variant, out);
      console.log(`self-check, ${variant.name}: ${result.verdict} (must be REJECTED)`);
      if (result.verdict !== "REJECTED") return result.verdict === "TOOL_ERROR" ? 2 : 1;
    }
  }
  console.log("ok");
  return 0;
}

process.exit(await main());
