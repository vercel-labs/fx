export const maxCoreMessageBytes = 64 * 1024 * 1024;

// One ordered writer per core; a pending handler holds admission of the next message.
export class CoreOutput {
  constructor(handler) {
    this.handler = handler;
    this.decoder = new TextDecoder("utf-8", { fatal: true });
    this.buffer = new Uint8Array(0);
    this.bytes = 0;
    this.closed = false;
  }

  write(chunk) {
    let offset = 0;
    const consume = () => {
      while (offset < chunk.length) {
        if (this.closed) throw new Error("core output is closed");
        const newline = chunk.indexOf(10, offset);
        const end = newline < 0 ? chunk.length : newline;
        const fragment = chunk.subarray(offset, end);
        const length = this.bytes + fragment.length;
        if (length + (newline < 0 ? 0 : 1) > maxCoreMessageBytes) throw new RangeError("core output message exceeds 64 MiB");
        let data = fragment;
        if (this.bytes || newline < 0) {
          if (length > this.buffer.length) {
            const next = new Uint8Array(Math.min(maxCoreMessageBytes, Math.max(length, this.buffer.length * 2, 4096)));
            next.set(this.buffer.subarray(0, this.bytes));
            this.buffer = next;
          }
          this.buffer.set(fragment, this.bytes);
          data = this.buffer.subarray(0, length);
        }
        this.bytes = length;
        offset = newline < 0 ? end : end + 1;
        if (newline < 0) return;
        const line = this.decoder.decode(data);
        const size = length + 1;
        this.bytes = 0;
        if (this.buffer.length > 1024 * 1024) this.buffer = new Uint8Array(0);
        if (line) {
          const pending = this.handler(JSON.parse(line), size);
          if (pending) return Promise.resolve(pending).then(consume);
        }
      }
    };
    return consume();
  }

  finish() {
    if (this.bytes) throw new Error("core output ended within a message");
  }

  close() {
    this.closed = true;
    this.buffer = new Uint8Array(0);
    this.bytes = 0;
  }
}
