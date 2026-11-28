// What the tests of the order of a session's UI lines share: a slow disk for
// a World's stream chunks, a record of the stream writes libfx makes, and a
// harness whose turns push their words in a burst. A test decides which
// chunk of a batch lands late and sees whether libfx handed the World one
// chunk at a time, and whether a viewer saw the words in order.
//
//   const slow = slowChunkWrites((text) => (text.includes('"delta":"w1 "') ? 400 : 0));
//   try { ...run a turn... } finally { slow.restore(); }
//   slow.delayed;                 // the delays applied, in ms
//
//   const durability = watchStreamWrites(local({ dir }), (event) => events.push(event));
//   // { op: "issue", call: "write" | "writeMulti", chunks: [...] } when libfx calls the World,
//   // { op: "return", call } when the World's promise settles.
//
// world-local writes each chunk to a temporary file in the stream's chunk
// folder and then puts the file in place, so a chunk is visible to a reader
// once its write ends. Delaying that write changes when a chunk lands and
// nothing else: the bytes are the ones the World was given.
import fsp from "node:fs/promises";
import { sep } from "node:path";

const chunkFolder = `${sep}streams${sep}chunks${sep}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Makes the write of a stream chunk file take `delayOf(text)` more
 * milliseconds, `text` being the chunk's content; 0 delays nothing. Patches
 * `writeFile` of `node:fs/promises` for the whole process until `restore()`.
 */
export function slowChunkWrites(delayOf) {
  const real = fsp.writeFile;
  const delayed = [];
  fsp.writeFile = async function writeFile(file, data, ...rest) {
    if (String(file).includes(chunkFolder)) {
      const ms = delayOf(Buffer.from(data).toString("utf8"));
      if (ms > 0) {
        delayed.push(ms);
        await sleep(ms);
      }
    }
    return real.call(this, file, data, ...rest);
  };
  return {
    delayed,
    restore() {
      fsp.writeFile = real;
    },
  };
}

/**
 * A World durability that tells `listen` about every stream write libfx
 * makes through it. A UI line is a string; an image's bytes are not
 * reported.
 */
export function watchStreamWrites(durability, listen) {
  const worldOf = durability.world;
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  const watch = (target, call) => (runId, name, chunks) => {
    const lines = (call === "write" ? [chunks] : chunks).filter((chunk) => typeof chunk === "string");
    const reported = lines.length > 0;
    if (reported) listen({ op: "issue", call, chunks: lines });
    const done = target[call](runId, name, chunks);
    if (reported) Promise.resolve(done).then(() => listen({ op: "return", call }), () => listen({ op: "return", call }));
    return done;
  };
  return {
    ...durability,
    async world() {
      const world = await worldOf();
      const streams = new Proxy(world.streams, {
        get(target, key) {
          if (key === "write" || (key === "writeMulti" && typeof target.writeMulti === "function")) return watch(target, key);
          return bound(target, key);
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "streams" ? streams : bound(target, key)) });
    },
  };
}

// A harness whose turns push their words in one tick, as a model's reply that
// arrives in a burst does, so libfx writes the lines in batches: the first
// line alone, and the lines pushed while it is written together. `waves` is
// the number of words in each wave, `gapMs` apart; word i of a turn is
// `burstWord(i)`.
export const burstWord = (index) => `u${String(index).padStart(2, "0")}`;

const encoder = new TextEncoder();

function burstTurn(body) {
  const queue = [];
  let wake = null;
  let finished = false;
  const result = body((event) => { queue.push(event); wake?.(); }).finally(() => { finished = true; wake?.(); });
  void result.catch(() => {});
  return {
    result,
    steer: async () => {},
    cancel() {},
    async *[Symbol.asyncIterator]() {
      for (;;) {
        while (queue.length) yield queue.shift();
        if (finished) return;
        await new Promise((resolve) => { wake = resolve; });
        wake = null;
      }
    },
  };
}

export function burstHarness({ waves, gapMs = 0 }) {
  return () => ({
    async open({ store }) {
      await store.load();
      let key = 0;
      const append = (record, marks) => store.append({ idempotencyKey: `burst:${key++}`, data: encoder.encode(JSON.stringify(record)), marks });
      return {
        prompt(_input, { turnId }) {
          const started = append({ turnId, start: true }, [{ start: turnId }]);
          return burstTurn(async (push) => {
            await started;
            let next = 0;
            for (const [wave, count] of waves.entries()) {
              if (wave > 0) await sleep(gapMs);
              for (let n = 0; n < count; n += 1) push({ type: "text_delta", delta: `${burstWord(next++)} ` });
            }
            await append({ turnId, end: true }, [{ end: true }]);
            return { stopReason: "end_turn" };
          });
        },
        resume() { throw new Error("a burst turn has nothing to resume"); },
        get openTurn() { return null; },
        settled: async () => {},
        saveCheckpoint: async () => {},
        exportCheckpoint: async () => encoder.encode("[]"),
        close: async () => {},
      };
    },
  });
}
