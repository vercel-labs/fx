// Sessions kept in files on this machine, through Workflow's local World.
// libfx bundles that World into this module when it is packaged, so an app
// installs nothing more.
import { realpath } from "node:fs/promises";
import { hostname } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
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
  const durability = world(() => createWorld({ ...(dir === undefined ? {} : { dataDir: dir }), recoverActiveRuns: false }), {
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
  // world-local's start creates its folder's version file and then writes
  // it, so a start that reads it between the two finds it empty and fails.
  // The Worlds of one folder start one at a time, however `dir` names it.
  // world-local picks the folder of a local() without `dir` once per
  // process, which this cannot see, so those Worlds share a key of their own.
  durability.startTurnKey = async () => `local:${dir === undefined ? "" : await realFolder(dir)}`;
  return durability;
}

// `dir` with its symlinks resolved, as far as it exists: a start creates the rest.
async function realFolder(dir) {
  const path = resolve(dir);
  try {
    return await realpath(path);
  } catch {
    const parent = dirname(path);
    return parent === path ? path : join(await realFolder(parent), basename(path));
  }
}
