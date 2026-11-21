// Whether the process `pid` still runs, for tests that check one.
//
// Signal 0 to pid 0 or a negative pid reaches a whole process group, which is
// always alive, and a pid that is not a number makes `process.kill` throw as
// if the process had ended. So a missing pid, such as `Number(null)` or a pid
// file read too early, would pass either check. Only a real pid is checked;
// anything else is a test bug and throws.
export function processAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error(`not a process id: ${pid}`);
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// Whether any process in the group `pid` leads still runs. A hook that fx starts leads its own group, so its
// pid is the group id. A pid that is not a number throws, as `processAlive` does.
export function processGroupAlive(pid: number): boolean {
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error(`not a process id: ${pid}`);
  try {
    process.kill(-pid, 0);
    return true;
  } catch {
    return false;
  }
}
