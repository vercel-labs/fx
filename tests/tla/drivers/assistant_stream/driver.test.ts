// Runs the built fx along the token sequences of tests/tla/assistant_stream/
// StreamTail.tla. Each sequence is one `fx ask` reply on a terminal, streamed one
// token per piece through a held fake gateway. After every piece and after the
// end, the screen is read back as cells and checked against the model.
//
//   FX_TLA_ASSISTANT_STREAM_VARIANT   design_a (default) or current
//   FX_TLA_ASSISTANT_STREAM_ALL=1     every sequence up to 4 tokens, not the cover
//   FX_TLA_ASSISTANT_STREAM_SEQUENCES "w nl w|o c", a list of sequences to run instead
//   FX_WORKTREE, FX_BIN, FX_TLA_OUT   see ../lib/context.ts
import { beforeAll, describe, expect, test } from "bun:test";
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { TLA_ROOT, runTlc, writeJson } from "../lib/tlc";
import { checkSequence } from "./checks";
import { piecesOf } from "./encode";
import {
  TOKENS,
  coverSequences,
  isWellFormed,
  sourcesUpTo,
  windowsOf,
  type Sequence,
  type Tok,
  type Variant,
} from "./model";
import { PANE_HEIGHT, calibrate, streamReply } from "./run";
import { observedScreen, type Calibration, type ObsScreen } from "./screen";

// Sources of the model (WellFormed), counted with the model's own rule.
const SOURCES_UP_TO_4 = 160;
const SOURCES_UP_TO_5 = 579;
const WINDOWS_UP_TO_5 = 77;
const COVER_UP_TO_5 = 27;

function variantFromEnv(): Variant {
  const value = process.env.FX_TLA_ASSISTANT_STREAM_VARIANT ?? "design_a";
  if (value === "design_a" || value === "current") return value;
  throw new Error(`FX_TLA_ASSISTANT_STREAM_VARIANT must be design_a or current, got ${value}`);
}

function sequencesFromEnv(): Sequence[] | undefined {
  const value = process.env.FX_TLA_ASSISTANT_STREAM_SEQUENCES;
  if (!value) return undefined;
  return value.split("|").map((text) => {
    const seq = text.trim().split(/\s+/) as Tok[];
    if (!seq.every((tok) => TOKENS.includes(tok)) || !isWellFormed(seq)) {
      throw new Error(`FX_TLA_ASSISTANT_STREAM_SEQUENCES has a bad sequence: ${text}`);
    }
    return seq;
  });
}

const variant = variantFromEnv();
const sequences: Sequence[] = sequencesFromEnv() ?? (process.env.FX_TLA_ASSISTANT_STREAM_ALL === "1"
  ? sourcesUpTo(4)
  : coverSequences(5));

describe("model", () => {
  test(`sources have ${SOURCES_UP_TO_4} sequences up to 4 tokens and ${SOURCES_UP_TO_5} up to 5`, () => {
    expect(sourcesUpTo(4).length).toBe(SOURCES_UP_TO_4);
    expect(sourcesUpTo(5).length).toBe(SOURCES_UP_TO_5);
  });

  test(`the cover holds every adjacent pair and triple in ${COVER_UP_TO_5} sequences`, () => {
    const universe = new Set(sourcesUpTo(5).flatMap(windowsOf));
    expect(universe.size).toBe(WINDOWS_UP_TO_5);
    const chosen = coverSequences(5);
    expect(chosen.length).toBe(COVER_UP_TO_5);
    const covered = new Set(chosen.flatMap(windowsOf));
    expect([...universe].filter((window) => !covered.has(window))).toEqual([]);
  });

  test("TLC has the same number of initial states at MaxLen 5", async () => {
    const specDir = mkdtempSync(join(tmpdir(), "fx-assistant-stream-spec-"));
    copyFileSync(join(TLA_ROOT, "assistant_stream", "StreamTail.tla"), join(specDir, "StreamTail.tla"));
    const config = readFileSync(join(TLA_ROOT, "assistant_stream", "design-a.cfg"), "utf8");
    writeFileSync(join(specDir, "max5.cfg"), config.replace(/MaxLen\s*=\s*\d+/, "MaxLen = 5"));
    const run = await runTlc(
      join(artifacts, "tlc-max5"),
      "StreamTail",
      "max5.cfg",
      ["StreamTail.tla", "max5.cfg"],
      specDir,
    );
    expect(run.exitCode).toBe(0);
    const initial = /Finished computing initial states: (\d+) distinct/.exec(run.output)?.[1];
    expect(Number(initial)).toBe(sourcesUpTo(5).length);
  }, 300_000);
});

describe("checker", () => {
  const seq: Sequence = ["w", "o", "w"];
  const word = (n: number, kind: "plain" | "bold") => ({ k: kind, n, text: `w${n}` });
  const screen = (rows: ObsScreen["rows"]): ObsScreen => ({ rows, history: 0 });
  const clean: ObsScreen[] = [
    screen([{ cells: [word(1, "plain")], text: "w1" }]),
    screen([{ cells: [word(1, "plain")], text: "w1" }]),
    screen([{ cells: [word(1, "plain"), word(3, "bold")], text: "w1 w3" }]),
    screen([{
      cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }, word(3, "plain")],
      text: "w1 **w3",
    }]),
  ];

  test("a clean screen passes every step", () => {
    expect(checkSequence(seq, "design_a", clean)).toBeNull();
  });

  test("an opener that the final output closes is not shown as a mark", () => {
    const closed: Sequence = ["w", "o", "w", "c"];
    const shown: ObsScreen[] = [
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      screen([{
        cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }],
        text: "w1 **",
      }]),
    ];
    const failure = checkSequence(closed, "design_a", shown);
    expect(failure?.invariant).toBe("NoUnfinalMark");
    expect(failure?.step).toBe(2);
  });

  test("a stray closer is a mark once a token other than a closer follows it", () => {
    const stray: Sequence = ["w", "c", "w"];
    const marked = screen([{
      cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }, word(3, "plain")],
      text: "w1 ** w3",
    }]);
    const shown: ObsScreen[] = [
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      marked,
      marked,
    ];
    expect(checkSequence(stray, "design_a", shown)).toBeNull();
  });

  test("a closer run at the end of the open text is hidden, and final once the end comes", () => {
    const closers: Sequence = ["w", "c", "c"];
    const marked = screen([{
      cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }, { k: "mark" as const, n: 0, text: "**" }],
      text: "w1 ****",
    }]);
    const shown: ObsScreen[] = [
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      marked,
    ];
    expect(checkSequence(closers, "design_a", shown)).toBeNull();
  });

  test("a closer run followed by an opener is a mark while the line is open", () => {
    const closerThenOpener: Sequence = ["w", "c", "o"];
    const marked = screen([{
      cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }],
      text: "w1**",
    }]);
    const bothMarks = screen([{
      cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }, { k: "mark" as const, n: 0, text: "**" }],
      text: "w1****",
    }]);
    const shown: ObsScreen[] = [
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      marked,
      bothMarks,
    ];
    expect(checkSequence(closerThenOpener, "design_a", shown)).toBeNull();
  });

  test("an open line of only marks shows nothing until the end comes", () => {
    const marksOnly: Sequence = ["nl", "c", "o"];
    const finished = screen([{
      cells: [{ k: "mark" as const, n: 0, text: "**" }, { k: "mark" as const, n: 0, text: "**" }],
      text: "****",
    }]);
    const shown: ObsScreen[] = [screen([]), screen([]), screen([]), finished];
    expect(checkSequence(marksOnly, "design_a", shown)).toBeNull();
  });

  test("a mark the final output does not have fails NoUnfinalMark at its step", () => {
    const newline: Sequence = ["w", "nl", "w"];
    const held: ObsScreen[] = [
      screen([{ cells: [word(1, "plain")], text: "w1" }]),
      screen([{ cells: [word(1, "plain"), { k: "mark" as const, n: 0, text: "**" }], text: "w1 **" }]),
    ];
    const failure = checkSequence(newline, "design_a", held);
    expect(failure?.invariant).toBe("NoUnfinalMark");
    expect(failure?.step).toBe(2);
  });
});

describe(`assistant_stream as ${variant}`, () => {
  let calibration: Calibration;

  beforeAll(async () => {
    calibration = await calibrate();
  }, 120_000);

  for (const seq of sequences) {
    const name = seq.join(" ");
    test(`sequence [${name}]`, async () => {
      const streamed = await streamReply(piecesOf(seq));
      const observed = streamed.captures.map((capture) => observedScreen(capture, calibration, PANE_HEIGHT));
      const failure = checkSequence(seq, variant, observed);
      if (failure || streamed.stderr !== "") {
        writeJson(join(artifacts, `${seq.join("-")}.json`), {
          sequence: seq,
          variant,
          pieces: piecesOf(seq),
          captures: streamed.captures,
          stderr: streamed.stderr,
        });
      }
      expect(streamed.stderr).toBe("");
      if (failure) throw new Error(failure.message);
    }, 120_000);
  }
});
