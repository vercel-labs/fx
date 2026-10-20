// Where the bundled world-local puts a stream's chunk: after every chunk the
// stream holds when it lands, so never ahead of one a reader may already
// have (DUR-38; `tests/tla/sdk/UiStream.tla` Placement).
//
// world-local 5.1.1 names a chunk `chnk_<ULID>` when its write is called,
// writes it to a temporary file and renames that into place, and every
// reader orders a stream's chunks by name. A write that stalls before its
// rename, as a frozen process's does, lands under a name that sorts ahead of
// the chunks other writers landed meanwhile. A replay puts it there, and
// every later chunk moves one place on under a live reader that already had
// them.
//
// Here a chunk is named as it lands: the successor, in name order, of the
// stream's newest chunk, created with link(), which never replaces a file. A
// writer that named its chunk and then stalled finds the name taken when it
// goes on, and takes the next one, so no lock is needed. A stream's first
// chunk is `chnk_0…01`, the successor of the tombstone a purge leaves, which
// still sorts first. One World's writes to a stream land in the order they
// were called, as world-local's did.
//
// A World remembers the last chunk it landed in each stream and tries the
// next name first; a writer elsewhere that landed there makes the link fail,
// and the World then lists the stream. So the names stay contiguous only
// while every writer of a stream names chunks this way. On a file system
// that makes no hard links, every writer renames a chunk into place under a
// name minted as it lands, which narrows the old window to the moment
// between the two; a world-local without this change still names a chunk
// when its write is called.
//
// bundle-durable.mjs puts `placedStreamWrites()` in place of world-local's
// `write`, `writeMulti` and `close`.
import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const chunkFile = /^chnk_([0-9A-HJKMNP-TV-Z]{26})(?![0-9A-Za-z])/;
const firstId = `${"0".repeat(25)}1`;
// What link() fails with on a file system that makes no hard links. On
// Windows, EPERM can also mean a file is busy for a moment, which `retry`
// waits out, so there it stays an error.
const noHardLinks = new Set(["ENOTSUP", "EOPNOTSUPP", "ENOSYS", "EXDEV", ...(process.platform === "win32" ? [] : ["EPERM"])]);

/** The 26-character ULID right after `id` in name order. */
export function chunkSuccessor(id) {
  const digits = id.split("");
  for (let at = digits.length - 1; at >= 0; at -= 1) {
    const value = alphabet.indexOf(digits[at]);
    if (value < 0) throw new Error(`not a chunk id: ${id}`);
    if (value < alphabet.length - 1) {
      digits[at] = alphabet[value + 1];
      return digits.join("");
    }
    digits[at] = alphabet[0];
  }
  throw new Error(`no chunk id follows ${id}`);
}

/** The id of the newest chunk in `dir`, of any tag or format, or null. */
export async function newestChunkId(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  let newest = null;
  for (const entry of entries) {
    const id = chunkFile.exec(entry)?.[1];
    if (id !== undefined && (newest === null || id > newest)) newest = id;
  }
  return newest;
}

/**
 * Lands chunks in a World's stream directories. `writeFile(path, data)`
 * writes a whole file, making its directory; `retry(fn)` retries a file
 * operation the platform can fail for a moment; `mint()` returns a new ULID.
 */
export function createChunkPlacer({ tagSuffix = "", writeFile, retry = (fn) => fn(), mint }) {
  // Each stream's last turn, by name, so writes land in call order.
  const turns = new Map();
  // The newest chunk this World landed in each directory.
  const newest = new Map();
  let hardLinks = true;

  const nameOf = (dir, id) => path.join(dir, `chnk_${id}${tagSuffix}.bin`);

  // Links `temp` in as `target`; resolves the error it failed with, or null.
  const linkInto = (temp, target) => retry(() => fs.link(temp, target)).then(() => null, (error) => error);

  const successorOf = (id) => (id === null ? firstId : chunkSuccessor(id));

  // The newest chunk in `dir` once `taken` turned out to be taken.
  async function newestSince(dir, taken) {
    const listed = await newestChunkId(dir);
    return listed !== null && listed > taken ? listed : taken;
  }

  // A link that failed for a reason other than its name being taken.
  function linkFailed(error) {
    if (!noHardLinks.has(error?.code)) throw error;
    hardLinks = false;
  }

  async function place(dir, temp, data) {
    let id = newest.has(dir) ? newest.get(dir) : await newestChunkId(dir);
    let rewritten = false;
    while (hardLinks) {
      const next = successorOf(id);
      const error = await linkInto(temp, nameOf(dir, next));
      if (error === null) {
        newest.set(dir, next);
        return `chnk_${next}`;
      }
      if (error?.code === "EEXIST") {
        // Another writer landed a chunk there: try after the newest.
        id = await newestSince(dir, next);
      } else if (error?.code === "ENOENT" && !rewritten) {
        // The directory went away, as an outside cleanup can make it.
        rewritten = true;
        await writeFile(temp, data);
      } else {
        linkFailed(error);
      }
    }
    return renamedInto(dir, temp);
  }

  // Without hard links a rename may replace a chunk of the same name, so the
  // name is a new ULID unless the stream's newest is later.
  async function renamedInto(dir, temp) {
    const listed = await newestChunkId(dir);
    const minted = mint();
    const id = listed === null || minted > listed ? minted : chunkSuccessor(listed);
    await retry(() => fs.rename(temp, nameOf(dir, id)));
    newest.set(dir, id);
    return `chnk_${id}`;
  }

  async function land(dir, chunks, landed, before) {
    const temps = chunks.map(() => path.join(dir, `.${randomUUID()}.tmp`));
    const left = new Set(temps);
    try {
      const written = await Promise.allSettled(chunks.map((data, index) => writeFile(temps[index], data)));
      const failed = written.find((result) => result.status === "rejected");
      if (failed) throw failed.reason;
      await before;
      const ids = [];
      for (const [index, temp] of temps.entries()) {
        const id = await place(dir, temp, chunks[index]);
        ids.push(id);
        left.delete(temp);
        await retry(() => fs.unlink(temp)).catch(() => {});
        landed?.(id, index);
      }
      return ids;
    } finally {
      for (const temp of left) await retry(() => fs.unlink(temp)).catch(() => {});
    }
  }

  return {
    /**
     * Takes a write's turn in its stream, when the write is called. `land`
     * writes the chunks, waits for the turns before, and lands them in order,
     * calling `landed(id, index)` after each; `done()` ends the turn, landed
     * or not, and the caller must call it.
     */
    turn(name) {
      const before = turns.get(name);
      let done;
      const mine = new Promise((resolve) => { done = resolve; });
      turns.set(name, mine);
      void mine.then(() => { if (turns.get(name) === mine) turns.delete(name); });
      return { land: (dir, chunks, landed) => land(dir, chunks, landed, before), done };
    },
  };
}

/**
 * world-local's `streams.write`, `writeMulti` and `close`, each landing its
 * chunks through a placer. The rest is world-local's own, from inside
 * `createStreamer()`.
 */
export function placedStreamWrites({ basedir, tagSuffix, streamEmitter, registerStreamForRun, toBuffer, serializeChunk, chunkDirForStream, writeFile, retry, mint }) {
  const placer = createChunkPlacer({ tagSuffix, writeFile, retry, mint });
  const chunksDir = path.join(basedir, "streams", "chunks");
  return {
    async write(_runId, name, chunk) {
      const turn = placer.turn(name);
      try {
        const runId = await _runId;
        await registerStreamForRun(runId, name);
        const chunkBuffer = toBuffer(chunk);
        const [chunkId] = await turn.land(chunkDirForStream(chunksDir, name), [serializeChunk({ chunk: chunkBuffer, eof: false })]);
        streamEmitter.emit(`chunk:${name}`, { streamName: name, chunkData: Uint8Array.from(chunkBuffer), chunkId });
      } finally {
        turn.done();
      }
    },
    async writeMulti(_runId, name, chunks) {
      if (chunks.length === 0) return;
      const turn = placer.turn(name);
      try {
        const runId = await _runId;
        await registerStreamForRun(runId, name);
        const chunkBuffers = chunks.map((chunk) => toBuffer(chunk));
        await turn.land(chunkDirForStream(chunksDir, name), chunkBuffers.map((chunk) => serializeChunk({ chunk, eof: false })), (chunkId, index) => {
          streamEmitter.emit(`chunk:${name}`, { streamName: name, chunkData: Uint8Array.from(chunkBuffers[index]), chunkId });
        });
      } finally {
        turn.done();
      }
    },
    async close(_runId, name) {
      const turn = placer.turn(name);
      try {
        const runId = await _runId;
        await registerStreamForRun(runId, name, { verify: true });
        await turn.land(chunkDirForStream(chunksDir, name), [serializeChunk({ chunk: Buffer.from([]), eof: true })]);
        streamEmitter.emit(`close:${name}`, { streamName: name });
      } finally {
        turn.done();
      }
    },
  };
}
