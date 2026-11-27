// What a 2026 input_required round looks like on the wire when its bytes are hostile, and what the retry must give
// back. The keys are raw JSON tokens that a JSON reader would decode: an escape, a non-ASCII character, an astral code
// point, a quote and a slash. The state holds whitespace, escapes and a JSON text that a normalizing writer would
// change. The `mrtr_raw` mode of fixtures/mcp-modern-stdio.mjs sends them as written, and writes each tools/call line
// it gets to FX_MCP_RAW_LINES as it arrived.

import { expect } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

export const RAW_KEYS = ['"\\u0061b"', '"caf\\u00e9 \\ud83d\\ude00 é 😀"', '"q\\"u\\\\o\\/te"'];
export const RAW_STATE = '"{\\"b\\": 1,  \\"a\\":[2 , 3]}\\t \\u0061 é \\ud83d\\ude00 \\n  "';

/** An `elicitation/create` request with one boolean field, `field`, as the server writes it. */
export const rawForm = (field: string) =>
  `{"method":"elicitation/create","params":{"message":"Question ${field}","requestedSchema":{"type":"object","properties":{"${field}":{"type":"boolean"}},"required":["${field}"],"additionalProperties":false}}}`;

/** An `inputRequests` object whose nth key, as written, asks the form `f<n>`. */
export const rawRequests = (keys: string[]) => `{${keys.map((key, index) => `${key}:${rawForm(`f${index + 1}`)}`).join(",")}}`;

/** What the retry writes for each answer: the fx wording of an answer, as the server receives it. */
export const RAW_ANSWER = {
  accept: (field: string) => `{"action":"accept","content":{"${field}":true}}`,
  decline: '{"action":"decline"}',
  cancel: '{"action":"cancel"}',
};

/** The tools/call lines a fixture got, exactly as they arrived. */
export function rawLinesAt(path: string): string[] {
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter(Boolean) : [];
}

/** The retry's own bytes: its inputResponses under the raw keys in order, then the raw requestState, or neither. */
export function expectRawRetry(line: string | undefined, keys: string[], answers: string[], state: string | undefined) {
  const responses = `"inputResponses":{${keys.map((key, index) => `${key}:${answers[index]}`).join(",")}}`;
  expect(line, "the retry line").toBeDefined();
  expect(line!.endsWith(state === undefined ? `${responses}}}` : `${responses},"requestState":${state}}}`), line).toBe(true);
}
