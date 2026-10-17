// Sessions kept in files on this machine, through Workflow's local World.
// libfx bundles that World into this module when it is packaged, so an app
// installs nothing more.
import { link, lstat, mkdir, readdir, readFile, unlink } from "node:fs/promises";
import { hostname } from "node:os";
import { join, resolve } from "node:path";
import { createWorld } from "@workflow/world-local";
import { world } from "./world.mjs";

const host = hostname();

/**
 * `dir` is where the sessions live. Workers on this machine hold a session
 * while their process runs, so a crashed worker's session frees at once.
 * With `maxDurationMs`, each delivery runs as if its function stopped after
 * that long, stopping `reserveMs` before, as on Vercel.
 */
export function local({ dir, maxDurationMs, reserveMs } = {}) {
  if (dir !== undefined && (typeof dir !== "string" || dir.length === 0)) throw new TypeError("local() dir must be a path");
  return world(() => {
    // world-local's own default, named here so the move below reads the
    // directory the World opens.
    const dataDir = dir ?? (process.env.WORKFLOW_LOCAL_DATA_DIR || ".workflow-data");
    const created = createWorld({ dataDir, recoverActiveRuns: false });
    const start = created.start;
    created.start = async () => {
      await moveToRunDirectories(dataDir);
      await start.call(created);
    };
    return created;
  }, {
    name: "local",
    // Each folder is a store of its own.
    store: `local:${dir === undefined ? "" : resolve(dir)}`,
    livenessKnown: true,
    // world-local keeps its queue in memory, so a message dies with the process.
    queueDurable: false,
    pollMs: 250,
    maxDurationMs,
    reserveMs,
    holderInfo: () => ({ pid: process.pid, host }),
    alive(lease) {
      if (lease.host !== host || !Number.isSafeInteger(lease.pid)) return null;
      try {
        process.kill(lease.pid, 0);
        return true;
      } catch (error) {
        return error?.code === "EPERM";
      }
    },
  });
}

// world-local 5.1 keeps a run's event and step files in a folder of the
// run's own, `events/<runId>/`, under the names 5.0 gave them at the top of
// `events/` and `steps/`. Opening a directory that holds only the old layout,
// 5.1 deletes all of it. So the sessions a libfx that bundled 5.0 saved are
// moved into the new layout first, and keep their history (DUR-23). When a
// file cannot move, `local()` fails with an error before it moves any, and
// nothing is deleted (DUR-46, DUR-78). The pattern is world-local's own for
// the old layout.
const oldLayoutFile = /^(wrun_[0-9A-Za-z]+)-[^/\\]+\.json$/;

async function moveToRunDirectories(dataDir) {
  const moves = [];
  for (const entity of ["events", "steps"]) {
    let entries;
    try {
      entries = await readdir(join(dataDir, entity), { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    for (const entry of entries) {
      const runId = entry.isFile() ? oldLayoutFile.exec(entry.name)?.[1] : undefined;
      if (!runId) continue;
      const runDir = join(dataDir, entity, runId);
      moves.push({ file: join(entity, entry.name), from: join(dataDir, entity, entry.name), runDir, to: join(runDir, entry.name) });
    }
  }
  const stuck = [];
  for (const move of moves) {
    const reason = await blocked(move);
    if (reason) stuck.push({ file: move.file, reason });
  }
  if (stuck.length > 0) throw layoutError(dataDir, stuck);
  for (const { file, from, runDir, to } of moves) {
    try {
      await mkdir(runDir, { recursive: true });
      // A link, unlike a rename, never replaces a file already there.
      await link(from, to);
    } catch (error) {
      // Another process moved it first.
      if (error?.code === "ENOENT") continue;
      if (error?.code !== "EEXIST" || !(await sameBytes(from, to))) throw layoutError(dataDir, [{ file, reason: String(error?.message ?? error) }]);
    }
    await unlink(from).catch((error) => {
      if (error?.code !== "ENOENT") throw error;
    });
  }
}

// Why a file cannot move into its run's folder, or null when it can.
async function blocked({ from, runDir, to }) {
  const missing = (error) => (error?.code === "ENOENT" ? null : Promise.reject(error));
  // world-local refuses a run folder that is a link elsewhere.
  const folder = await lstat(runDir).catch(missing);
  if (folder && !folder.isDirectory()) return "its run's folder is not a folder";
  const there = await lstat(to).catch(missing);
  if (there && !(await sameBytes(from, to))) return "a different file of that name is already in its run's folder";
  return null;
}

function layoutError(dataDir, stuck) {
  const shown = stuck.slice(0, 3).map(({ file, reason }) => `${file}: ${reason}`).join("; ");
  return Object.assign(new Error(
    `local() can't open ${resolve(dataDir)}: ${stuck.length} session file(s) an older libfx saved can't be moved into the layout this libfx reads (${shown}${stuck.length > 3 ? "; …" : ""}). ` +
    "Nothing was deleted. Stop any older libfx that uses this directory, then move those files out of it, or give local() another dir.",
  ), { code: "FX_LOCAL_STORE_LAYOUT", dir: resolve(dataDir), files: stuck.map(({ file }) => file) });
}

async function sameBytes(a, b) {
  try {
    const [left, right] = await Promise.all([readFile(a), readFile(b)]);
    return left.equals(right);
  } catch {
    return false;
  }
}
