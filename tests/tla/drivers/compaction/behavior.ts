// Reads the behaviors TLC writes with `-simulate file=...`: each file is a
// TLA+ module of `STATE_n == /\ var = value ...` definitions. Values are the
// forms ProviderCompaction uses: numbers, strings, TRUE and FALSE, records
// `[k |-> v]`, sequences `<< ... >>`, and sets `{ ... }`.

export type Value = number | boolean | string | Value[] | { [key: string]: Value };
export type State = Record<string, Value>;

const TOKEN = /\s*(<<|>>|\|->|\/\\|"(?:[^"\\]|\\.)*"|-?\d+|[A-Za-z_][A-Za-z0-9_]*|[[\]{}(),=])/y;

function tokenize(text: string): string[] {
  const tokens: string[] = [];
  TOKEN.lastIndex = 0;
  while (TOKEN.lastIndex < text.length) {
    if (/^\s*$/.test(text.slice(TOKEN.lastIndex))) break;
    const start = TOKEN.lastIndex;
    const match = TOKEN.exec(text);
    if (!match) throw new Error(`unexpected TLA+ text at ${start}: ${text.slice(start, start + 40)}`);
    tokens.push(match[1]!);
  }
  return tokens;
}

function parseState(text: string): State {
  const tokens = tokenize(text);
  let at = 0;
  const next = () => {
    const token = tokens[at++];
    if (token === undefined) throw new Error("TLA+ value ended early");
    return token;
  };
  const expect = (want: string) => {
    const got = next();
    if (got !== want) throw new Error(`expected ${want}, found ${got}`);
  };
  const list = (close: string): Value[] => {
    const items: Value[] = [];
    if (tokens[at] === close) {
      at += 1;
      return items;
    }
    for (;;) {
      items.push(value());
      const sep = next();
      if (sep === close) return items;
      if (sep !== ",") throw new Error(`expected , or ${close}, found ${sep}`);
    }
  };
  const value = (): Value => {
    const token = next();
    if (token === "<<") return list(">>");
    if (token === "{") return list("}");
    if (token === "[") {
      const record: { [key: string]: Value } = {};
      for (;;) {
        const key = next();
        expect("|->");
        record[key] = value();
        const sep = next();
        if (sep === "]") return record;
        if (sep !== ",") throw new Error(`expected , or ], found ${sep}`);
      }
    }
    if (token === "(") {
      const inner = value();
      expect(")");
      return inner;
    }
    if (token.startsWith("\"")) return JSON.parse(token) as string;
    if (/^-?\d+$/.test(token)) return Number(token);
    if (token === "TRUE") return true;
    if (token === "FALSE") return false;
    throw new Error(`unexpected token ${token}`);
  };
  const state: State = {};
  while (at < tokens.length) {
    expect("/\\");
    const name = next();
    expect("=");
    state[name] = value();
  }
  return state;
}

/** The states of one behavior, in order. */
export function parseBehavior(text: string): State[] {
  const parts = text.split(/^STATE_\d+ ==\s*$/m).slice(1);
  return parts.map((part) => parseState(part.replace(/^=+\s*$/m, "").replace(/^-+.*$/gm, "")));
}
