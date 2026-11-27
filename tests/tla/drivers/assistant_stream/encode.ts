// Token to bytes. Each piece carries at most one leading space, so one piece is
// one token and the streamed text reads as the model's source.
import type { Sequence, Tok } from "./model";

export function bytesOf(tok: Tok, index: number): string {
  switch (tok) {
    case "w":
      return `w${index}`;
    case "o":
    case "c":
      return "**";
    case "nl":
      return "\n";
    case "u":
      return "===";
  }
}

// No space next to a line break, none before a closing mark, none after an
// opening mark: CommonMark would not close or open the emphasis otherwise.
export function pieceOf(seq: Sequence, index: number): string {
  const tok = seq[index]!;
  const prev = index > 0 ? seq[index - 1] : undefined;
  const space = prev !== undefined && prev !== "nl" && prev !== "o" && tok !== "nl" && tok !== "c";
  return `${space ? " " : ""}${bytesOf(tok, index + 1)}`;
}

export function piecesOf(seq: Sequence): string[] {
  return seq.map((_, index) => pieceOf(seq, index));
}
