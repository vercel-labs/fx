/**
 * The lines a test client has read from a process but not yet taken, and the reads still waiting
 * for one. The ACP test clients use it for `fx acp`'s output.
 *
 * A read that times out takes its own waiter off the list, so the next line goes to the next read
 * or waits in the queue. A waiter left behind would take that line and drop it, which looks like a
 * reply fx never sent.
 */
export class LineQueue {
  private queued: string[] = [];
  private waiting: Array<(line: string) => void> = [];

  /** Gives `line` to the oldest read that still waits, or keeps it for the next read. */
  push(line: string): void {
    const read = this.waiting.shift();
    if (read) read(line);
    else this.queued.push(line);
  }

  /**
   * The next line: the oldest queued one at once, or the next one to arrive within `timeoutMs`.
   * When none arrives it rejects with the error `onTimeout` makes, and the read is gone.
   */
  next(timeoutMs: number, onTimeout: () => Error): Promise<string> {
    const line = this.queued.shift();
    if (line !== undefined) return Promise.resolve(line);
    return new Promise<string>((resolve, reject) => {
      const read = (arrived: string) => {
        clearTimeout(timer);
        resolve(arrived);
      };
      const timer = setTimeout(() => {
        const at = this.waiting.indexOf(read);
        if (at >= 0) this.waiting.splice(at, 1);
        reject(onTimeout());
      }, timeoutMs);
      this.waiting.push(read);
    });
  }

  /** Every queued line, taken out of the queue. */
  drain(): string[] {
    return this.queued.splice(0);
  }
}
