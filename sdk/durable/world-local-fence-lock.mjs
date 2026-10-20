// The file system world-local's in-band fence lock uses in the World libfx
// bundles, so a writer killed while it holds the lock does not hold up the
// next one (DUR-88).
//
// @workflow/world-local 5.1.1 runs each in-band write under a proper-lockfile
// lock on `.locks/runs/<runId>.in-band` (`withFenceLock`). proper-lockfile's
// lock is a directory that says nothing about who holds it, so when its
// holder is killed, the next in-band writer, the worker taking the session
// over, waits until the directory is 30 s old. bundle-durable.mjs gives that
// lock this file system instead of proper-lockfile's own:
//
// - Taking the lock also makes a directory in it that names the holder,
//   `holder-<pid>-<host>-<token>`, in the same synchronous step, so a process
//   killed while it takes the lock almost never leaves it unnamed. Both come
//   before proper-lockfile reads the lock's mtime, which the second changes.
// - A writer that finds the lock held reads that name. When it is a process
//   on this host that no longer runs, the writer removes the name, then the
//   empty lock, and takes the lock at once. Removing the name decides: it
//   succeeds only while the lock is still the dead holder's, and for one
//   writer only. Any other holder, or no name, leaves the lock to go stale
//   as before.
// - Removing the lock removes its name: a holder only its own, so a lock
//   another writer has taken and named since stays, and a writer removing a
//   stale lock every name in it.
//
// Written for proper-lockfile 4.1.2, which world-local pins: it calls
// `mkdir`, `rmdir`, `stat` and `utimes` with callbacks, and `rmdirSync` when
// the process exits. The same change is proposed to world-local; this goes
// when a world-local with it ships.
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, readlinkSync, rmdirSync, stat, utimes } from "node:fs";
import { readdir, rmdir } from "node:fs/promises";
import { hostname } from "node:os";
import { join } from "node:path";

const holderName = /^holder-([1-9][0-9]{0,9})-([0-9a-f]{16})-[0-9a-f]{32}$/;

// The machine a pid belongs to. On Linux, also its boot and PID namespace:
// two containers can share a hostname and a directory, and a pid from
// another namespace means nothing here.
const host = createHash("sha256").update([
  hostname(),
  optional(() => readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim()),
  optional(() => readlinkSync("/proc/self/ns/pid")),
].join("\n")).digest("hex").slice(0, 16);

function optional(read) {
  try {
    return read();
  } catch {
    return "";
  }
}

/** The file system for one proper-lockfile `lock()` call on the fence lock. */
export function fenceLockFs() {
  const own = `holder-${process.pid}-${host}-${randomBytes(16).toString("hex")}`;
  let held = false;
  const make = (dir) => {
    mkdirSync(dir);
    held = true;
    try {
      mkdirSync(join(dir, own));
    } catch {
      // The lock still excludes other writers; it only goes stale, as
      // before, if this process dies holding it.
    }
  };
  const take = async (dir) => {
    try {
      make(dir);
    } catch (error) {
      if (error?.code !== "EEXIST" || !(await removeIfHolderGone(dir))) throw error;
      make(dir);
    }
  };
  const remove = async (dir) => {
    const names = held ? [own] : (await readdir(dir).catch(() => [])).filter((name) => holderName.test(name));
    for (const name of names) await rmdir(join(dir, name)).catch(() => {});
    await rmdir(dir);
  };
  // proper-lockfile's callbacks run outside the promise, as fs's own do.
  const settle = (work, callback) => work.then(() => process.nextTick(callback, null), (error) => process.nextTick(callback, error));
  return {
    stat,
    utimes,
    mkdir: (dir, callback) => settle(take(dir), callback),
    rmdir: (dir, callback) => settle(remove(dir), callback),
    rmdirSync(dir) {
      try {
        rmdirSync(join(dir, own));
      } catch {}
      rmdirSync(dir);
    },
  };
}

// Removes the lock `dir` when the holder it names is a process on this host
// that no longer runs, and says whether it did. Anything unexpected leaves
// the lock alone.
async function removeIfHolderGone(dir) {
  try {
    const names = (await readdir(dir)).filter((name) => holderName.test(name));
    if (names.length !== 1) return false;
    const [, pid, holderHost] = holderName.exec(names[0]);
    if (holderHost !== host || !gone(Number(pid))) return false;
    await rmdir(join(dir, names[0]));
    await rmdir(dir);
    return true;
  } catch {
    return false;
  }
}

// A pid that names no process: one in use again by another process counts
// as running, so its lock goes stale as before.
function gone(pid) {
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    return error?.code === "ESRCH";
  }
}
