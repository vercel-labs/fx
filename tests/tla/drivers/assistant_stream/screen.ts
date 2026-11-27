// Screen to cells. The escaped history of one run is read line by line. A line
// that carries a token (a word, "**", "===" or a backtick) is a row, and so is
// a thematic break. A word's kind comes from its SGR style, calibrated once per
// binary.

export type ObsKind = "plain" | "bold" | "heading" | "mark" | "raw" | "other";
export type ObsCell = { k: ObsKind; n: number; text: string };
export type ObsRow = { cells: ObsCell[]; text: string };
export type ObsScreen = { rows: ObsRow[]; history: number };
export type Style = { key: string; bold: boolean };
export type Calibration = { headingKey: string };

type State = {
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
  reverse: boolean;
  fg: string;
  bg: string;
};
type Glyph = { ch: string; style: Style };

const PLAIN: State = { bold: false, dim: false, italic: false, underline: false, reverse: false, fg: "", bg: "" };

const ESCAPE = /\x1b\[([0-9;]*)m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]|\x1b./g;

function applySgr(state: State, params: string): State {
  const codes = params === "" ? [0] : params.split(";").map(Number);
  let next = { ...state };
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i]!;
    if (code === 0) next = { ...PLAIN };
    else if (code === 1) next.bold = true;
    else if (code === 2) next.dim = true;
    else if (code === 3) next.italic = true;
    else if (code === 4) next.underline = true;
    else if (code === 7) next.reverse = true;
    else if (code === 22) {
      next.bold = false;
      next.dim = false;
    } else if (code === 23) next.italic = false;
    else if (code === 24) next.underline = false;
    else if (code === 27) next.reverse = false;
    else if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) next.fg = String(code);
    else if (code === 39) next.fg = "";
    else if ((code >= 40 && code <= 47) || (code >= 100 && code <= 107)) next.bg = String(code);
    else if (code === 49) next.bg = "";
    else if (code === 38 || code === 48) {
      const width = codes[i + 1] === 5 ? 2 : codes[i + 1] === 2 ? 4 : 0;
      const value = codes.slice(i, i + 1 + width).join(";");
      if (code === 38) next.fg = value;
      else next.bg = value;
      i += width;
    }
  }
  return next;
}

function styleOf(state: State): Style {
  const flags = [
    state.bold && "b",
    state.dim && "d",
    state.italic && "i",
    state.underline && "u",
    state.reverse && "r",
  ].filter(Boolean).join("");
  return { key: `${flags}|${state.fg}|${state.bg}`, bold: state.bold };
}

function glyphsOf(line: string): Glyph[] {
  const out: Glyph[] = [];
  let state = PLAIN;
  let last = 0;
  for (const match of line.matchAll(ESCAPE)) {
    const at = match.index ?? 0;
    for (const ch of line.slice(last, at)) out.push({ ch, style: styleOf(state) });
    if (match[1] !== undefined) state = applySgr(state, match[1]);
    last = at + match[0].length;
  }
  for (const ch of line.slice(last)) out.push({ ch, style: styleOf(state) });
  return out;
}

const TOKEN = /w\d+|\*\*|===|`/;
// A thematic break that fx draws for a line made of marks only.
const RULE = /^\s*[─━═]{3,}\s*$/;

function kindOf(style: Style, calibration: Calibration): ObsKind {
  if (style.key === calibration.headingKey) return "heading";
  return style.bold ? "bold" : "plain";
}

function cellsOf(glyphs: Glyph[], text: string, calibration: Calibration): ObsCell[] {
  const cells: ObsCell[] = [];
  let i = 0;
  while (i < text.length) {
    const rest = text.slice(i);
    const word = /^w\d+/.exec(rest);
    if (word) {
      cells.push({ k: kindOf(glyphs[i]!.style, calibration), n: Number(word[0].slice(1)), text: word[0] });
      i += word[0].length;
    } else if (rest.startsWith("**")) {
      cells.push({ k: "mark", n: 0, text: "**" });
      i += 2;
    } else if (rest.startsWith("===")) {
      cells.push({ k: "raw", n: 0, text: "===" });
      i += 3;
    } else if (text[i] === "`") {
      cells.push({ k: "raw", n: 0, text: "`" });
      i += 1;
    } else {
      if (text[i] !== " ") cells.push({ k: "other", n: 0, text: text[i]! });
      i += 1;
    }
  }
  return cells;
}

/**
 * The assistant rows of one capture, in screen order. `history` counts the rows
 * that sit above a pane of `paneHeight` rows, in scrollback.
 */
export function observedScreen(capture: string, calibration: Calibration, paneHeight: number): ObsScreen {
  const lines = capture.replace(/\n$/, "").split("\n");
  const historyLines = Math.max(0, lines.length - paneHeight);
  const rows: ObsRow[] = [];
  let history = 0;
  lines.forEach((line, index) => {
    const glyphs = glyphsOf(line);
    const text = glyphs.map((glyph) => glyph.ch).join("");
    let row: ObsRow | undefined;
    if (RULE.test(text)) {
      row = { cells: [{ k: "other", n: 0, text: text.trim() }], text: text.trim() };
    } else if (TOKEN.test(text)) {
      row = { cells: cellsOf(glyphs, text, calibration), text: text.trimEnd() };
    }
    if (row === undefined) return;
    rows.push(row);
    if (index < historyLines) history += 1;
  });
  return { rows, history };
}

/** The style of the first glyph of `word` on the screen, or undefined when it is not there. */
export function styleOfWord(capture: string, word: string): Style | undefined {
  for (const line of capture.split("\n")) {
    const glyphs = glyphsOf(line);
    const at = glyphs.map((glyph) => glyph.ch).join("").indexOf(word);
    if (at >= 0) return glyphs[at]!.style;
  }
  return undefined;
}
