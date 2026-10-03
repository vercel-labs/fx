// Pure core for the durable libfx harnesses (bench-durable.mjs,
// crash-matrix.mjs, bench-parallel.mjs). Everything here is data in, data
// out: no I/O, clocks, timers or hidden randomness. The drivers own effects.

export const durableModel = "durable/model";

export const durableCatalog = {
  object: "list",
  data: [{ id: durableModel, type: "language", tags: ["tool-use"], context_window: 1_000_000, max_tokens: 4096 }],
};

// Tool behavior as data: whether each tool writes, and whether a resumed
// turn may run it again.
export const durableTools = {
  read_item: { writes: false, replay: "safe" },
  list_files: { writes: false, replay: "safe" },
  read_file: { writes: false, replay: "safe" },
  write_file: { writes: true, replay: "safe" },
  write_item: { writes: true, replay: "safe" },
  send_email: { writes: true, replay: "never" },
};

const integers = Array.from({ length: 200 }, (_, index) => String(index + 1));

// Each workload is the model's scripted side of one turn: steps run in
// order, and a step with calls waits for every call's result.
export const durableWorkloads = {
  "no-tool": [{ text: ["done"] }],
  "one-safe": [{ calls: [{ name: "read_item", input: { key: "alpha" } }] }, { text: ["done"] }],
  "one-never": [{ calls: [{ name: "send_email", input: { to: "team" } }] }, { text: ["sent"] }],
  "list-then-read": [
    { calls: [{ name: "list_files", input: { dir: "." } }, { name: "read_file", input: { path: "a.txt" } }] },
    { text: ["done"] },
  ],
  "write-then-read": [
    { calls: [{ name: "write_file", input: { path: "a.txt", text: "v2" } }, { name: "read_file", input: { path: "a.txt" } }] },
    { text: ["done"] },
  ],
  "stream-200": [{ text: integers.map((value, index) => (index === 0 ? value : ` ${value}`)) }],
};

const steeringMarker = "<user_steering>";

function textOf(message) {
  if (typeof message?.content === "string") return message.content;
  if (!Array.isArray(message?.content)) return "";
  return message.content.filter((part) => part?.type === "text").map((part) => part.text ?? "").join("");
}

// Index of the message that started the current turn: the last user
// message that is not mid-turn steering.
export function turnStartIndex(prompt) {
  for (let index = prompt.length - 1; index >= 0; index -= 1) {
    const message = prompt[index];
    if (message?.role === "user" && !textOf(message).includes(steeringMarker)) return index;
  }
  return -1;
}

// Number of turns so far, counted as non-steering user messages.
export function turnNumber(prompt) {
  return prompt.filter((message) => message?.role === "user" && !textOf(message).includes(steeringMarker)).length;
}

// The tool results the current turn has produced, in request order.
export function toolResultIds(prompt) {
  const start = turnStartIndex(prompt);
  const ids = [];
  for (const message of prompt.slice(start + 1)) {
    if (!Array.isArray(message?.content)) continue;
    for (const part of message.content) if (part?.type === "tool-result") ids.push(part.toolCallId);
  }
  return ids;
}

// Directives travel in the prompt text as `key=value` words, so the
// scripted gateway is a function of the request body alone and answers the
// same way after a restore.
export function promptDirectives(prompt) {
  const text = textOf(prompt[turnStartIndex(prompt)]);
  const directives = {};
  for (const word of text.split(/\s+/)) {
    const match = /^([a-z]+)=(\S+)$/.exec(word);
    if (match) directives[match[1]] = match[2];
  }
  return directives;
}

export function callId(turn, step, index) {
  return `t${turn}_s${step}_c${index}`;
}

// Which scripted step answers this request, given the results so far.
export function stepFor(steps, resultCount) {
  let remaining = resultCount;
  let step = 0;
  while (step < steps.length && steps[step].calls && remaining >= steps[step].calls.length) {
    remaining -= steps[step].calls.length;
    step += 1;
  }
  if (remaining !== 0) throw new Error(`partial tool results: ${remaining} beyond step ${step}`);
  if (step >= steps.length) throw new Error("the scripted turn has no step left");
  return step;
}

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };

// The SSE frames for one model request.
export function framesFor(steps, prompt) {
  const turn = turnNumber(prompt);
  const step = stepFor(steps, toolResultIds(prompt).length);
  const current = steps[step];
  if (current.calls) {
    return [
      ...current.calls.map((call, index) => ({
        type: "tool-call",
        toolCallId: callId(turn, step, index),
        toolName: call.name,
        input: call.input,
      })),
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
    ];
  }
  return [
    ...current.text.map((delta, index) => ({ type: "text-delta", id: String(index), delta })),
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
  ];
}

export function sseBody(frames) {
  return frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n";
}

// Deterministic PRNG (mulberry32): the seed goes in, a value and the next
// seed come out.
export function nextRandom(seed) {
  const next = (seed + 0x6d2b79f5) >>> 0;
  let t = next;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return { value: ((t ^ (t >>> 14)) >>> 0) / 4294967296, seed: next };
}

// A random batch of 2 to 8 calls with writer flags, latencies and faults.
export function randomBatch(seed, { writerRate = 0.3, throwRate = 0.1, maxLatencyMs = 4 } = {}) {
  let state = seed >>> 0;
  const draw = () => {
    const result = nextRandom(state);
    state = result.seed;
    return result.value;
  };
  const size = 2 + Math.floor(draw() * 7);
  const calls = Array.from({ length: size }, () => {
    const writes = draw() < writerRate;
    return {
      name: writes ? "write_item" : "read_item",
      writes,
      latencyMs: Math.floor(draw() * (maxLatencyMs + 1)),
      fault: draw() < throwRate ? "throw" : null,
    };
  });
  return { calls, seed: state };
}

// The scripted turn for a batch: one step with every call, then text.
export function batchSteps(batch) {
  return [
    { calls: batch.calls.map((call, index) => ({ name: call.name, input: { call: index, latencyMs: call.latencyMs, fault: call.fault } })) },
    { text: ["done"] },
  ];
}

// Start and end positions of each call in an observed trace of
// { call, kind: "start" | "end" } entries in real-time order.
function intervals(trace, size) {
  const spans = Array.from({ length: size }, () => ({ start: null, end: null, starts: 0, ends: 0 }));
  trace.forEach((entry, position) => {
    const span = spans[entry.call];
    if (!span) return;
    if (entry.kind === "start") {
      span.starts += 1;
      span.start ??= position;
    } else if (entry.kind === "end") {
      span.ends += 1;
      span.end ??= position;
    }
  });
  return spans;
}

// A parallel batch's rules, checked on a real run: a writer runs alone,
// and results reach the model in call order. `resultOrder`
// is the tool call ids in the order the next model request carried them.
export function checkBatch({ writes, trace, resultOrder, expectedOrder }) {
  const violations = [];
  if (expectedOrder.length !== writes.length) {
    return [`ScriptedBatch: the model asked for ${expectedOrder.length} calls, expected ${writes.length}`];
  }
  const spans = intervals(trace, writes.length);
  spans.forEach((span, index) => {
    if (span.starts !== 1 || span.ends !== 1) violations.push(`Completeness: call ${index} started ${span.starts} and ended ${span.ends} times`);
  });
  if (violations.length) return violations;
  const overlaps = (a, b) => a.start < b.end && b.start < a.end;
  writes.forEach((isWriter, index) => {
    if (!isWriter) return;
    spans.forEach((other, otherIndex) => {
      if (otherIndex !== index && overlaps(spans[index], other)) violations.push(`WriterRunsAlone: writer ${index} overlaps call ${otherIndex}`);
      if (otherIndex > index && other.start < spans[index].end) violations.push(`NothingPassesWriter: call ${otherIndex} started before writer ${index} ended`);
      if (otherIndex < index && other.end > spans[index].start) violations.push(`WriterAfterEarlier: writer ${index} started before call ${otherIndex} ended`);
    });
  });
  if (JSON.stringify(resultOrder) !== JSON.stringify(expectedOrder)) {
    violations.push(`ResultsInModelOrder: got ${JSON.stringify(resultOrder)}, expected ${JSON.stringify(expectedOrder)}`);
  }
  return violations;
}

// Highest number of calls running at once in a trace.
export function maxConcurrency(trace) {
  let running = 0;
  let peak = 0;
  for (const entry of trace) {
    running += entry.kind === "start" ? 1 : entry.kind === "end" ? -1 : 0;
    peak = Math.max(peak, running);
  }
  return peak;
}

// What must hold after a crash and restore, for one crash-matrix cell.
export function checkCrashCell({ workload, neverEffects, completed, rememberedSetup, resultCounts }) {
  const violations = [];
  const steps = durableWorkloads[workload];
  if (!steps) throw new Error(`unknown workload: ${workload}`);
  if (neverEffects > 1) violations.push(`NeverRunsTwice: a replay "never" tool ran ${neverEffects} times`);
  if (!completed) violations.push("TurnCompletes: the restored session did not finish the turn");
  if (!rememberedSetup) violations.push("KeepsCommittedHistory: the restored session lost the committed setup turn");
  for (const [id, count] of Object.entries(resultCounts)) {
    if (count !== 1) violations.push(`OneOutcome: call ${id} has ${count} results`);
  }
  return violations;
}

// What a host that makes libfx durable from outside pays today: four sequential
// acknowledged writes per tool call, plus the checkpoint after each turn.
export function todayAdapterWrites(toolCalls) {
  return { perToolBefore: 2, perToolAfter: 2, perTurn: 1, awaited: 4 * toolCalls + 1 };
}

export function toolCallsIn(steps) {
  return steps.reduce((total, step) => total + (step.calls?.length ?? 0), 0);
}
