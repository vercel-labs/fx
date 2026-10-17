// Sessions kept in files on this machine, through Workflow's local World.
// libfx bundles that World into this module when it is packaged, so an app
// installs nothing more.
import { hostname } from "node:os";
import { resolve } from "node:path";
import { createWorld } from "@workflow/world-local";
import { world } from "./world.mjs";

const host = hostname();

// The process's working directory, or null when it no longer exists.
const workingDir = () => {
  try {
    return process.cwd();
  } catch {
    return null;
  }
};

/**
 * `dir` is where the sessions live. Workers on this machine hold a session
 * while their process runs, so a crashed worker's session frees at once.
 * With `maxDurationMs`, each delivery runs as if its function stopped after
 * that long, stopping `reserveMs` before, as on Vercel.
 *
 * The queue lives in the process, so a process that dies takes the turn it
 * ran with it, and any prompt it had not yet delivered. With `recover`, on
 * by default, an agent that starts continues that work: each session of its
 * name that a process on this machine, started in the same directory, last
 * wrote before it died. World-local's own recovery stays off, since it would
 * deliver libfx's sessions as Workflow runs.
 */
export function local({ dir, maxDurationMs, reserveMs, recover = true } = {}) {
  if (dir !== undefined && (typeof dir !== "string" || dir.length === 0)) throw new TypeError("local() dir must be a path");
  if (typeof recover !== "boolean") throw new TypeError("local() recover must be a boolean");
  return world(() => createWorld({ ...(dir === undefined ? {} : { dataDir: dir }), recoverActiveRuns: false }), {
    name: "local",
    // Each folder is a store of its own.
    store: `local:${dir === undefined ? "" : resolve(dir)}`,
    livenessKnown: true,
    // world-local keeps its queue in memory, so a message dies with the process.
    queueDurable: false,
    pollMs: 250,
    maxDurationMs,
    reserveMs,
    holderInfo: () => ({ pid: process.pid, host, cwd: workingDir() }),
    alive(lease) {
      if (lease.host !== host || !Number.isSafeInteger(lease.pid)) return null;
      try {
        process.kill(lease.pid, 0);
        return true;
      } catch (error) {
        return error?.code === "EPERM";
      }
    },
    // A folder is one store, but it is not always one app's: every app on
    // the machine that names no durability keeps its sessions in the same
    // folder under the temporary directory. Only a process started in this
    // one's working directory counts as this app's, so another app's agent
    // of the same name never continues a turn with its own tools and key.
    ...(recover ? { recover: (writer) => writer.host === host && typeof writer.cwd === "string" && writer.cwd === workingDir() } : {}),
  });
}
