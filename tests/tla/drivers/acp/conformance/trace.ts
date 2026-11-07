// Shared pieces of the ACP conformance driver: an ACP stdio client that keeps
// every raw stdout line, the byte classes tests/tla/acp/AcpCommandOutput.tla
// uses, and TLC trace validation against the stop reason, config category,
// and command output models in tests/tla/acp/.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TLA_ROOT, runTlc, sha256Text, writeJson } from "../../lib/tlc";

const SPEC_DIR = join(TLA_ROOT, "acp");

// -------------------------------------------------------------- ACP client --

/// One line fx wrote to stdout: the parsed message, and whether its bytes
/// were valid UTF-8.
export type Line = { message: any; valid: boolean };

const strictUtf8 = new TextDecoder("utf-8", { fatal: true });
const looseUtf8 = new TextDecoder();

function lineOf(bytes: Uint8Array): Line {
  let valid = true;
  try {
    strictUtf8.decode(bytes);
  } catch {
    valid = false;
  }
  let message: any = null;
  try {
    message = JSON.parse(looseUtf8.decode(bytes));
  } catch {
    message = null;
  }
  return { message, valid };
}

export class Acp {
  readonly lines: Line[] = [];
  private cursor = 0;
  private wake: (() => void) | null = null;
  private closed = false;
  private nextId = 1;
  stderr = "";
  readonly exited: Promise<number>;

  constructor(readonly proc: ReturnType<typeof Bun.spawn>) {
    this.exited = (async () => {
      const code = await proc.exited;
      this.closed = true;
      this.wake?.();
      return code;
    })();
    (async () => {
      let pending = new Uint8Array(0);
      for await (const chunk of proc.stdout as ReadableStream<Uint8Array>) {
        const joined = new Uint8Array(pending.length + chunk.length);
        joined.set(pending);
        joined.set(chunk, pending.length);
        let start = 0;
        for (let index = 0; index < joined.length; index++) {
          if (joined[index] !== 0x0a) continue;
          if (index > start) this.lines.push(lineOf(joined.subarray(start, index)));
          start = index + 1;
        }
        pending = joined.slice(start);
        this.wake?.();
      }
    })();
    (async () => {
      for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) this.stderr += looseUtf8.decode(chunk);
    })();
  }

  private async nextLine(deadline: number): Promise<Line> {
    while (this.cursor >= this.lines.length) {
      if (this.closed) throw new Error(`fx acp exited: ${this.stderr}`);
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`fx acp read timeout: ${this.stderr}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, left);
        this.wake = () => { clearTimeout(timer); resolve(); };
      });
      this.wake = null;
    }
    return this.lines[this.cursor++]!;
  }

  send(id: number, method: string, params: Record<string, unknown>) {
    (this.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    (this.proc.stdin as any).flush?.();
  }

  notify(method: string, params: Record<string, unknown>) {
    (this.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
    (this.proc.stdin as any).flush?.();
  }

  /// Sends a request and reads until the response to each id in `ids`, or to
  /// the new request alone when `ids` is empty. Permission requests are
  /// answered as cancelled.
  async call(method: string, params: Record<string, unknown>, timeoutMs = 30_000): Promise<any> {
    const id = this.nextId++;
    this.send(id, method, params);
    return (await this.responses([id], timeoutMs)).get(id);
  }

  allocateId(): number {
    return this.nextId++;
  }

  async responses(ids: number[], timeoutMs = 30_000): Promise<Map<number, any>> {
    const deadline = Date.now() + timeoutMs;
    const found = new Map<number, any>();
    while (found.size < ids.length) {
      const { message } = await this.nextLine(deadline);
      if (!message) continue;
      if ("method" in message && "id" in message) {
        (this.proc.stdin as any).write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { outcome: { outcome: "cancelled" } } })}\n`);
        continue;
      }
      if (ids.includes(message.id) && ("result" in message || "error" in message)) found.set(message.id, message);
    }
    return found;
  }

  async close(): Promise<{ exit: number; stderr: string }> {
    if (!this.closed) (this.proc.stdin as any).end();
    const timer = setTimeout(() => this.proc.kill("SIGKILL"), 5_000);
    const exit = await this.exited;
    clearTimeout(timer);
    return { exit, stderr: this.stderr };
  }
}

// ----------------------------------------------------------- byte classes --

/// The class AcpCommandOutput.tla gives each byte of command output.
export function byteClass(byte: number): string {
  if (byte < 0x80) return "A";
  if (byte < 0xc0) return "C";
  if (byte < 0xe0) return "L2";
  if (byte < 0xf0) return "L3";
  if (byte < 0xf8) return "L4";
  return "X";
}

/// Merges each run of ASCII into one A, as AcpCommandOutputTrace.tla does.
export function collapse(classes: string[]): string[] {
  return classes.filter((value, index) => !(value === "A" && classes[index - 1] === "A"));
}

/// The classes of progress text as fx sent it: each \xNN escape is one E,
/// and each character is its UTF-8 bytes' classes.
export function textClasses(text: string): string[] {
  const classes: string[] = [];
  for (let index = 0; index < text.length;) {
    if (/^\\x[0-9a-f]{2}/.test(text.slice(index, index + 4))) {
      classes.push("E");
      index += 4;
      continue;
    }
    const point = text.codePointAt(index)!;
    const bytes = new TextEncoder().encode(String.fromCodePoint(point));
    for (const byte of bytes) classes.push(byteClass(byte));
    index += point > 0xffff ? 2 : 1;
  }
  return collapse(classes);
}

// ---------------------------------------------------------------- TLC side --

const tla = (value: string) => JSON.stringify(value);
const tlaSeq = (values: string[]) => `<<${values.map(tla).join(", ")}>>`;

export type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

export type StopObservation = { reason: string; response: "prompt" | "steering"; wire: string };
export type OptionsObservation = { op: "new" | "load" | "set"; options: Array<{ id: string; category: string }> };
export type OutputEvent = { kind: "chunk" | "finish"; src: "stdout" | "stderr"; bytes: string[] };
export type OutputFrame = { text: string[]; valid: boolean };

function obsModule(name: string, body: string[]): string {
  return [
    `---- MODULE ${name} ----`,
    "(* Generated from one observed fx acp run. *)",
    ...body,
    "====",
    "",
  ].join("\n");
}

function stopObs(observations: StopObservation[]): string {
  const record = (o: StopObservation) => `[reason |-> ${tla(o.reason)}, response |-> ${tla(o.response)}, wire |-> ${tla(o.wire)}]`;
  return obsModule("AcpStopReasonsObs", [
    'TraceProtocol == "acp"',
    `TraceLog == <<${observations.map(record).join(",\n  ")}>>`,
  ]);
}

function optionsObs(observations: OptionsObservation[]): string {
  const option = (o: { id: string; category: string }) => `[id |-> ${tla(o.id)}, category |-> ${tla(o.category)}]`;
  const record = (o: OptionsObservation) => `[op |-> ${tla(o.op)}, options |-> <<${o.options.map(option).join(", ")}>>]`;
  return obsModule("AcpConfigCategoriesObs", [`TraceLog == <<${observations.map(record).join(",\n  ")}>>`]);
}

function outputObs(trace: { events: OutputEvent[]; frames: OutputFrame[] }): string {
  const event = (e: OutputEvent) => `[kind |-> ${tla(e.kind)}, src |-> ${tla(e.src)}, bytes |-> ${tlaSeq(e.bytes)}]`;
  const frame = (f: OutputFrame) => `[text |-> ${tlaSeq(f.text)}, valid |-> ${f.valid ? "TRUE" : "FALSE"}]`;
  return obsModule("AcpCommandOutputObs", [
    `TraceLog == <<${trace.events.map(event).join(",\n  ")}>>`,
    `Frames == <<${trace.frames.map(frame).join(",\n  ")}>>`,
  ]);
}

const TRACE_TAIL = ["INIT TraceInit", "NEXT TraceNext", "INVARIANT NotDone", "CHECK_DEADLOCK FALSE", ""];

const MODELS = {
  stop: {
    spec: "AcpStopReasons",
    obs: stopObs,
    cfg: ["CONSTANTS", "    Mapped = TRUE", "    LibfxMapped = FALSE", ...TRACE_TAIL],
    length: (o: StopObservation[]) => o.length,
  },
  options: {
    spec: "AcpConfigCategories",
    obs: optionsObs,
    cfg: ["CONSTANT Fixed = TRUE", ...TRACE_TAIL],
    length: (o: OptionsObservation[]) => o.length,
  },
  output: {
    spec: "AcpCommandOutput",
    obs: outputObs,
    cfg: [
      "CONSTANTS",
      '    Sources = {"stdout", "stderr"}',
      '    Classes = {"A", "C", "L2", "L3", "L4", "X"}',
      "    MaxLen = 1000000",
      "    MaxChunk = 1",
      "    Carry = TRUE",
      "    SharedTail = FALSE",
      "    Flush = TRUE",
      ...TRACE_TAIL,
    ],
    length: (o: { events: OutputEvent[] }) => o.events.length,
  },
} as const;

/// Asks TLC whether one observed run is a behavior of `model`'s spec.
export async function validate(
  model: keyof typeof MODELS,
  observations: any,
  dir: string,
): Promise<{ verdict: Verdict; length: number; tlc: object; obs_sha256: string }> {
  const { spec, obs, cfg, length } = MODELS[model];
  mkdirSync(dir, { recursive: true });
  const steps = (length as (o: any) => number)(observations);
  const text = (obs as (o: any) => string)(observations);
  writeFileSync(join(dir, `${spec}Obs.tla`), text);
  writeFileSync(join(dir, `${spec}Trace.cfg`), cfg.join("\n"));
  writeJson(join(dir, "observations.json"), observations);
  if (steps === 0) {
    const result = { verdict: "TOOL_ERROR" as Verdict, length: 0, tlc: { reason: "empty trace" }, obs_sha256: sha256Text(text) };
    writeJson(join(dir, "verdict.json"), result);
    return result;
  }
  const run = await runTlc(dir, `${spec}Trace.tla`, `${spec}Trace.cfg`, [`${spec}.tla`, `${spec}Trace.tla`], SPEC_DIR);
  const finalIndex = [...run.output.matchAll(/\/\\ i = (\d+)/g)].map((match) => Number(match[1])).at(-1) ?? null;
  let verdict: Verdict;
  if (run.exitCode === 12 && run.violated === "NotDone" && finalIndex === steps) verdict = "ACCEPTED";
  else if (run.exitCode === 0 && /No error has been found/.test(run.output)) verdict = "REJECTED";
  else verdict = "TOOL_ERROR";
  const result = {
    verdict,
    length: steps,
    tlc: { exitCode: run.exitCode, violated: run.violated, finalIndex, depth: run.depth, durationMs: run.durationMs },
    obs_sha256: sha256Text(text),
  };
  writeJson(join(dir, "verdict.json"), result);
  return result;
}
