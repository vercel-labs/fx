// Event waits for the hook E2E tests. Each wait resolves on the event it names, so a test never sleeps or
// polls. The test's own timeout is its deadline; the test passes it as its third argument.
import { type ChildProcess, spawnSync } from "node:child_process";
import { createReadStream, existsSync, readFileSync, watch } from "node:fs";

// Resolves true once `child` has exited, and at once when it already has.
export function childExited(child: ChildProcess): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => child.once("exit", () => resolve(true)));
}

// Creates a named pipe. A hook script opens it for writing with `exec 3> '<path>'`, so every process the
// script starts inherits fd 3.
export function makeFifo(path: string): void {
  const made = spawnSync("mkfifo", [path]);
  if (made.status !== 0) throw new Error(`mkfifo ${path} failed: ${made.stderr.toString()}`);
}

// Resolves true once every process that holds the pipe open for writing has exited, because a reader sees end
// of file only then. Call it before the hook starts: a writer's open waits for a reader.
export function untilWritersGone(fifo: string): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const reader = createReadStream(fifo);
    reader.on("data", () => {});
    reader.on("end", () => resolve(true));
    reader.on("error", reject);
  });
}

// Resolves once `ready()` holds. The watch starts before the first check, so a change between the check and
// the watch is caught by the check, and each later change in `dir` runs the check again.
export function untilChange(dir: string, ready: () => boolean): Promise<void> {
  return new Promise((resolve, reject) => {
    const watcher = watch(dir, () => {
      if (ready()) done();
    });
    watcher.on("error", reject);
    const done = () => {
      watcher.close();
      resolve();
    };
    if (ready()) done();
  });
}

// Whether a hook's `echo $$ > path` has written its whole pid line, not only created the file.
export function pidWritten(path: string): boolean {
  return existsSync(path) && readFileSync(path, "utf8").endsWith("\n");
}
