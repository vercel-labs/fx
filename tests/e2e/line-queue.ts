/**
 * The lines a test client has read from a process but not yet taken, and the reads still waiting
 * for one. The ACP test clients use it for `fx acp`'s output.
 *
 * A read that times out takes its own waiter off the list, so the next line goes to the next read
 * or waits in the queue. A waiter left behind would take that line and drop it, which looks like a
 * reply fx never sent.
 *
 * `end` ends the queue when the process ends: a read that waits rejects with the error at once,
 * and so does every read after the queued lines are taken. The lines already queued stay readable.
 */
type Waiter = { resolve: (line: string) => void; reject: (error: Error) => void };

export class LineQueue {
  private queued: string[] = [];
  private waiting: Waiter[] = [];
  private ended: Error | null = null;

  /** Gives `line` to the oldest read that still waits, or keeps it for the next read. */
  push(line: string): void {
    const read = this.waiting.shift();
    if (read) read.resolve(line);
    else this.queued.push(line);
  }

  /**
   * The next line: the oldest queued one at once, or the next one to arrive within `timeoutMs`.
   * When none arrives it rejects with the error `onTimeout` makes, and the read is gone.
   */
  next(timeoutMs: number, onTimeout: () => Error): Promise<string> {
    const line = this.queued.shift();
    if (line !== undefined) return Promise.resolve(line);
    if (this.ended !== null) return Promise.reject(this.ended);
    return new Promise<string>((resolve, reject) => {
      const read: Waiter = {
        resolve: (arrived) => {
          clearTimeout(timer);
          resolve(arrived);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      };
      const timer = setTimeout(() => {
        const at = this.waiting.indexOf(read);
        if (at >= 0) this.waiting.splice(at, 1);
        reject(onTimeout());
      }, timeoutMs);
      this.waiting.push(read);
    });
  }

  /** Ends the queue: every read that waits rejects with `error`, and so does each later read. */
  end(error: Error): void {
    this.ended = error;
    for (const read of this.waiting.splice(0)) read.reject(error);
  }

  /** Every queued line, taken out of the queue. */
  drain(): string[] {
    return this.queued.splice(0);
  }
}
