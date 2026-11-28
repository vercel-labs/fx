// The checks of StreamTail.tla, run after each piece and after the end. At each
// step the driver asks two things: what the model says about an invariant at
// that point, and what the screen shows. The step fails when the two answers
// differ. The whole screen must also equal the model's screen (committed rows,
// then tail rows), row by row.
import { pieceOf } from "./encode";
import { finalRows, predictAfter, type Row, type Sequence, type Variant } from "./model";
import type { ObsRow, ObsScreen } from "./screen";

type Cellish = { k: string; n: number };
type Entry = { name: string; predicted: boolean; observed: boolean; extra?: string };

export type Failure = { step: number; invariant: string; message: string };

const NOT_WORD = new Set(["mark", "raw", "other"]);

const sameCell = (a: Cellish, b: Cellish) => a.k === b.k && (a.k === "mark" || a.n === b.n);
const sameRow = (a: Cellish[], b: Cellish[]) => a.length === b.length && a.every((c, j) => sameCell(c, b[j]!));
const prefixRow = (a: Cellish[], b: Cellish[]) => a.length <= b.length && a.every((c, j) => sameCell(c, b[j]!));
const prefixRows = (rows: Cellish[][], batch: Cellish[][]) =>
  rows.length <= batch.length && rows.every((row, j) => prefixRow(row, batch[j]!));
const keepsRows = (before: Cellish[][], now: Cellish[][]) =>
  before.every((row, j) => j < now.length && sameRow(row, now[j]!));
const sameRows = (a: Cellish[][], b: Cellish[][]) =>
  a.length === b.length && a.every((row, j) => sameRow(row, b[j]!));
// NoUnfinalMark: every mark cell on screen is a mark of the final output, on the same row.
// A predicted mark is identified by its source token (n). An observed mark carries no
// token, so it must sit between the same two words as a final mark on that row.
function marksFinal(rows: Cellish[][], batch: Cellish[][], exact: boolean): boolean {
  return rows.every((row, l) =>
    row.every((cell, j) => cell.k !== "mark" || (l < batch.length && markIsFinal(row, j, batch[l]!, exact))),
  );
}

const isWord = (cell: Cellish) => !NOT_WORD.has(cell.k);

function markIsFinal(row: Cellish[], j: number, final: Cellish[], exact: boolean): boolean {
  const marks = final.filter((cell) => cell.k === "mark");
  if (exact) return marks.some((mark) => mark.n === row[j]!.n);
  const before = row.slice(0, j).filter(isWord).map((cell) => cell.n).pop() ?? 0;
  const after = row.slice(j + 1).find(isWord)?.n ?? Infinity;
  return marks.some((mark) => mark.n > before && mark.n < after);
}
const subsetOf = (a: Set<number>, b: Set<number>) => [...a].every((n) => b.has(n));

function wordsOf(rows: Cellish[][]): Set<number> {
  const words = new Set<number>();
  for (const row of rows) for (const cell of row) if (!NOT_WORD.has(cell.k)) words.add(cell.n);
  return words;
}

function renderModel(rows: Row[]): string {
  if (rows.length === 0) return "(none)";
  return rows
    .map((row) => `[${row.map((c) => (c.k === "mark" ? "**" : `${c.k} w${c.n}`)).join(", ")}]`)
    .join(" ");
}

function renderScreen(rows: ObsRow[]): string {
  if (rows.length === 0) return "(none)";
  return rows.map((row) => `[${row.text}]`).join(" ");
}

export function checkSequence(seq: Sequence, variant: Variant, observed: ObsScreen[]): Failure | null {
  const batch = finalRows(seq);
  let previousHistory: Cellish[][] = [];
  let previousPredicted = new Set<number>();
  let previousObserved = new Set<number>();
  for (let k = 0; k <= seq.length; k++) {
    const finish = k === seq.length;
    const predicted = predictAfter(finish ? seq : seq.slice(0, k + 1), variant, finish);
    const screen = observed[k]!;
    const rows = screen.rows.map((row) => row.cells);
    const history = rows.slice(0, screen.history);
    const committedCount = predicted.committed.length;
    const modelScreen = [...predicted.committed, ...predicted.tail];
    const received = seq
      .slice(0, finish ? seq.length : k + 1)
      .flatMap((tok, i) => (tok === "w" ? [i + 1] : []));
    const predictedWords = wordsOf(modelScreen);
    const observedWords = wordsOf(rows);
    const missing = received.filter((n) => !observedWords.has(n));

    const entries: Entry[] = [
      {
        name: "CommittedIsPrefixOfFinal",
        predicted: prefixRows(predicted.committed, batch),
        observed: prefixRows(history, batch) && keepsRows(previousHistory, history),
      },
      { name: "HistoryOnlyCommitted", predicted: true, observed: screen.history <= committedCount },
      {
        name: "NoUnfinalMark",
        predicted: marksFinal(modelScreen, batch, true),
        observed: marksFinal(rows, batch, false),
      },
      {
        name: "EveryWordVisible",
        predicted: received.every((n) => predictedWords.has(n)),
        observed: missing.length === 0,
        extra: `words missing from the screen: ${missing.map((n) => `w${n}`).join(" ") || "none"}`,
      },
      {
        name: "VisibleNeverShrinks",
        predicted: subsetOf(previousPredicted, predictedWords),
        observed: subsetOf(previousObserved, observedWords),
      },
      { name: "ScreenEqualsModel", predicted: true, observed: sameRows(rows, modelScreen) },
    ];
    if (finish) {
      entries.push({
        name: "EndCommitsAll",
        predicted: predicted.tail.length === 0 && sameRows(predicted.committed, batch),
        observed: sameRows(rows, batch),
      });
    }

    const failed = entries.find((entry) => entry.predicted !== entry.observed);
    if (failed) {
      const when = finish ? "after finish" : `after piece ${k + 1} (${JSON.stringify(pieceOf(seq, k))})`;
      const message = [
        `sequence [${seq.join(" ")}] ${when}: ${failed.name}: model ${failed.predicted ? "holds" : "fails"}, screen ${failed.observed ? "holds" : "fails"}`,
        `  screen rows: ${renderScreen(screen.rows)}`,
        `  model screen: ${renderModel(modelScreen)}`,
        `  model committed: ${renderModel(predicted.committed)}`,
        ...(failed.extra ? [`  ${failed.extra}`] : []),
      ].join("\n");
      return { step: k + 1, invariant: failed.name, message };
    }

    previousHistory = history;
    previousPredicted = predictedWords;
    previousObserved = observedWords;
  }
  return null;
}
