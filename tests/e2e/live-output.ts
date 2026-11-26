// Reads a child process's stderr as it arrives, so a test waits for a line the
// process printed, not for a fixed delay. A deadline is set by the caller, and
// it only ends a run that never prints the line.
export class LiveOutput {
  text = "";
  readonly done: Promise<void>;
  private waiters: Array<{ needle: string; resolve: () => void }> = [];

  constructor(stream: ReadableStream<Uint8Array>) {
    this.done = this.pump(stream);
  }

  waitFor(needle: string, timeoutMs: number): Promise<void> {
    if (this.text.includes(needle)) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`timed out waiting for ${JSON.stringify(needle)} on stderr; got ${JSON.stringify(this.text)}`));
      }, timeoutMs);
      this.waiters.push({
        needle,
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
      });
    });
  }

  private async pump(stream: ReadableStream<Uint8Array>): Promise<void> {
    const decoder = new TextDecoder();
    for await (const chunk of stream) {
      this.text += decoder.decode(chunk, { stream: true });
      this.waiters = this.waiters.filter((waiter) => {
        if (!this.text.includes(waiter.needle)) return true;
        waiter.resolve();
        return false;
      });
    }
    this.text += decoder.decode();
  }
}
