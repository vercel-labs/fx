// The model's rules for the two variants the driver checks, ported from
// tests/tla/assistant_stream/StreamTail.tla. The model is the reference: when a
// rule here disagrees with it, change this file to match the model.
//
// Blank rows are not compared. The model's empty lines add no cells, and fx
// draws paragraph breaks that the model does not have.
//
// A held line whose newline has come shows its final cells. Only the open line
// (no newline yet) shows repaired cells. Rule A: an open line whose tokens are only
// "o" and "c" shows nothing. Rule B: an "o" opens bold, and a run of "c" with no open
// "o" before it shows as marks once a token other than "c" follows the run on the line.

export const TOKENS = ["w", "o", "c", "nl", "u"] as const;
export type Tok = (typeof TOKENS)[number];
export type Sequence = readonly Tok[];
export type Variant = "design_a" | "current";
export type CellKind = "plain" | "bold" | "heading" | "mark";
export type Cell = { k: CellKind; n: number };
export type Row = Cell[];
export type Predicted = { committed: Row[]; tail: Row[] };

type Token = { tok: Tok; n: number };

const MARKS: ReadonlySet<string> = new Set(["o", "c"]);

// The input domain of WellFormed in StreamTail.tla.
export function isWellFormed(seq: Sequence): boolean {
  for (let i = 0; i < seq.length; i++) {
    if (seq[i] === "u") {
      if (!(i > 0 && seq[i - 1] === "nl" && i < seq.length - 1 && seq[i + 1] === "nl")) return false;
      if (!wordEndingAt(seq, i - 2)) return false;
    }
    if (seq[i] === "o" && seq[i + 1] === "c") return false;
    if (isMarkOnlyLineAt(seq, i)) return false;
  }
  return true;
}

// Whether the line that ends at `end` has a word: scans back to the line start.
function wordEndingAt(seq: Sequence, end: number): boolean {
  for (let k = end; k >= 0 && seq[k] !== "nl"; k--) {
    if (seq[k] === "w") return true;
  }
  return false;
}

// Whether a line starts at `start` and holds only "o" and "c" tokens.
function isMarkOnlyLineAt(seq: Sequence, start: number): boolean {
  if (!MARKS.has(seq[start]!) || (start > 0 && seq[start - 1] !== "nl")) return false;
  for (let j = start; j < seq.length && seq[j] !== "nl"; j++) {
    if (!MARKS.has(seq[j]!)) return false;
  }
  return true;
}

/** Every well-formed sequence of 1 to maxLen tokens, in lexicographic order of token index. */
export function sourcesUpTo(maxLen: number): Sequence[] {
  const out: Sequence[] = [];
  for (let len = 1; len <= maxLen; len++) {
    for (let code = 0; code < TOKENS.length ** len; code++) {
      const seq = new Array<Tok>(len);
      let rest = code;
      for (let i = len - 1; i >= 0; i--) {
        seq[i] = TOKENS[rest % TOKENS.length]!;
        rest = Math.floor(rest / TOKENS.length);
      }
      if (isWellFormed(seq)) out.push(seq);
    }
  }
  return out;
}

/** The adjacent pairs and triples of a sequence, each as its tokens joined by spaces. */
export function windowsOf(seq: Sequence): string[] {
  const out: string[] = [];
  for (let len = 2; len <= 3; len++) {
    for (let i = 0; i + len <= seq.length; i++) out.push(seq.slice(i, i + len).join(" "));
  }
  return out;
}

/** Greedy cover: sequences that together contain every pair and triple of the sources up to maxLen. */
export function coverSequences(maxLen: number): Sequence[] {
  const all = sourcesUpTo(maxLen);
  const uncovered = new Set(all.flatMap(windowsOf));
  const chosen: Sequence[] = [];
  while (uncovered.size > 0) {
    let best: Sequence | undefined;
    let bestGain = 0;
    for (const seq of all) {
      const gain = new Set(windowsOf(seq).filter((window) => uncovered.has(window))).size;
      if (gain > bestGain) {
        best = seq;
        bestGain = gain;
      }
    }
    if (best === undefined) break;
    chosen.push(best);
    for (const window of windowsOf(best)) uncovered.delete(window);
  }
  return chosen;
}

function linesOf(seq: Sequence): Token[][] {
  const lines: Token[][] = [[]];
  seq.forEach((tok, i) => {
    if (tok === "nl") lines.push([]);
    else lines[lines.length - 1]!.push({ tok, n: i + 1 });
  });
  return lines;
}

const isUnderline = (line: readonly Token[]) => line.length === 1 && line[0]!.tok === "u";

// Rule A: a line that holds tokens, all of them "o" or "c".
const marksOnly = (line: readonly Token[]) => line.length > 0 && line.every((t) => MARKS.has(t.tok));

// A line is a setext heading when the line after it is an underline that has ended
// (its newline came). Until then the line is shown as text.
const headingAt = (i: number, lines: Token[][]) => i + 1 < lines.length - 1 && isUnderline(lines[i + 1]!);

// A line is final when the stream has ended, or the line after it has ended (its
// newline came). The open line is the last one, so it has not ended.
function isFinal(i: number, lines: Token[][], end: boolean): boolean {
  return end || i + 1 < lines.length - 1;
}

// The model's Cells rule. "final" hides a paired mark and shows an unpaired "o"
// or a lone "c" as a mark cell. "tail" opens bold at an "o"; a "c" with no open
// "o" before it is a mark only when a token other than "c" follows it on the line.
function cellsOf(line: readonly Token[], heading: boolean, mode: "final" | "tail"): Row {
  const out: Row = [];
  let bold = false;
  for (let j = 0; j < line.length; j++) {
    const { tok, n } = line[j]!;
    const hasClose = line.slice(j + 1).some((t) => t.tok === "c");
    if (tok === "w") {
      out.push({ k: heading ? "heading" : bold ? "bold" : "plain", n });
    } else if (tok === "o" && mode === "tail") {
      bold = true;
    } else if (tok === "o" && (bold || !hasClose)) {
      out.push({ k: "mark", n });
    } else if (tok === "o") {
      bold = true;
    } else if (tok === "c" && mode !== "final" && !bold && line.slice(j + 1).some((t) => t.tok !== "c")) {
      out.push({ k: "mark", n });
    } else if (tok === "c" && (mode !== "final" || bold)) {
      bold = false;
    } else if (tok === "c") {
      out.push({ k: "mark", n });
    }
  }
  return out;
}

type LineState = { final: boolean; ended: boolean; skip: boolean; shown: Row; pending: Row };

function linesState(seq: Sequence, end: boolean): LineState[] {
  const lines = linesOf(seq);
  const last = lines.length - 1;
  return lines.map((line, i) => ({
    final: isFinal(i, lines, end),
    ended: i < last,
    skip: isUnderline(line) || (i === last && line.length === 0),
    shown: cellsOf(line, headingAt(i, lines), "final"),
    pending: i === last && marksOnly(line) ? [] : cellsOf(line, headingAt(i, lines), "tail"),
  }));
}

const nonEmpty = (rows: Row[]) => rows.filter((row) => row.length > 0);

export function committedRows(seq: Sequence, end: boolean): Row[] {
  return nonEmpty(linesState(seq, end).filter((line) => line.final && !line.skip).map((line) => line.shown));
}

export function heldRows(seq: Sequence, end: boolean, variant: Variant): Row[] {
  if (variant === "current") return [];
  return nonEmpty(
    linesState(seq, end)
      .filter((line) => !line.final && !line.skip)
      .map((line) => (line.ended ? line.shown : line.pending)),
  );
}

export function finalRows(seq: Sequence): Row[] {
  return committedRows(seq, true);
}

export function predictAfter(seq: Sequence, variant: Variant, end: boolean): Predicted {
  return { committed: committedRows(seq, end), tail: heldRows(seq, end, variant) };
}
