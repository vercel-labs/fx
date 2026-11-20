// Runtime bridge for the join driver: a follower's persistent client on the
// leader socket, the frames a connection receives in arrival order, and the
// mapping from what fx wrote to the items AcpJoinTrace.tla validates. Frames
// are notifications and answers that fx wrote; the driver never writes text
// for fx to echo.
import { createConnection } from "node:net";

/// One message of a session's sequence: the k-th update of turn t. The join's
/// answer and the notice are messages of no turn, as AcpJoin.tla models them.
export type Item = { t: number; k: number };
export const ANS: Item = { t: 0, k: 0 };
export const NOTE: Item = { t: 0, k: 1 };
/// Text that no model step takes: a run that writes it is rejected.
export const OTHER: Item = { t: 0, k: 9 };

/// The notice fx writes when a copy dropped part of a turn (server.zig,
/// partial_copy_notice).
export const NOTICE_TEXT = "fx kept only the start of this turn's output, so part of it isn't shown.";

const LABEL = /T(\d+)K(\d+)\./g;

function otherFragment(text: string): Item[] {
  const piece = text.trim();
  if (piece === "") return [];
  return [piece === NOTICE_TEXT ? NOTE : OTHER];
}

/// The items of one agent text, in order. Each label T<t>K<k>. is an item; a
/// notice is Note; any other text is OTHER.
export function textItems(text: string): Item[] {
  const items: Item[] = [];
  let at = 0;
  for (const match of text.matchAll(LABEL)) {
    const index = match.index ?? 0;
    items.push(...otherFragment(text.slice(at, index)));
    items.push({ t: Number(match[1]), k: Number(match[2]) });
    at = index + match[0].length;
  }
  items.push(...otherFragment(text.slice(at)));
  return items;
}

export function isAgentText(frame: any): boolean {
  return frame?.method === "session/update" && frame.params?.update?.sessionUpdate === "agent_message_chunk";
}

export function isAnswer(frame: any): boolean {
  return frame !== undefined && "id" in frame && ("result" in frame || "error" in frame);
}

/// The items of the frames, in order. An answer to `answerId` is ANS. Other
/// notifications and answers are not items, and tails are not text, so the
/// driver never maps them.
export function framesItems(frames: any[], answerId: number | null): Item[] {
  const items: Item[] = [];
  for (const frame of frames) {
    if (isAgentText(frame)) items.push(...textItems(frame.params.update.content?.text ?? ""));
    else if (answerId !== null && isAnswer(frame) && frame.id === answerId) items.push(ANS);
  }
  return items;
}

/// The frames a connection received, in arrival order, with waits on them. The
/// waits only read what arrived: a wait ends when a frame that fx wrote makes
/// its predicate true, or when the connection closes.
export class FrameStream {
  readonly frames: any[] = [];
  closed = false;
  private waiters: Array<() => void> = [];

  push(frame: any) {
    this.frames.push(frame);
    this.wake();
  }

  end() {
    this.closed = true;
    this.wake();
  }

  async until(predicate: (frames: any[]) => boolean, label: string, timeoutMs = 60_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!predicate(this.frames)) {
      if (this.closed) throw new Error(`the connection closed before ${label}`);
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`timed out waiting for ${label}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(remaining, 200));
        this.waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  private wake() {
    for (const wakeWaiter of this.waiters.splice(0)) wakeWaiter();
  }
}

/// A JSON-RPC client over a leader socket that stays connected. `request` waits
/// for the answer to its id; every frame the socket sends goes to `stream`.
export class SocketClient {
  readonly stream = new FrameStream();
  private buffer = "";
  private nextId = 1;

  private constructor(private readonly socket: ReturnType<typeof createConnection>) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      this.buffer += chunk;
      let end = this.buffer.indexOf("\n");
      while (end !== -1) {
        const line = this.buffer.slice(0, end);
        this.buffer = this.buffer.slice(end + 1);
        if (line.trim()) this.stream.push(JSON.parse(line));
        end = this.buffer.indexOf("\n");
      }
    });
    socket.on("close", () => this.stream.end());
    socket.on("error", () => this.stream.end());
  }

  static connect(socketPath: string): Promise<SocketClient> {
    return new Promise((resolve, reject) => {
      const socket = createConnection({ path: socketPath });
      socket.once("error", reject);
      socket.once("connect", () => {
        socket.removeListener("error", reject);
        resolve(new SocketClient(socket));
      });
    });
  }

  /// Writes one request and returns its id, without waiting.
  send(method: string, params: object): number {
    const id = this.nextId++;
    this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    return id;
  }

  /// Sends one request and waits for its answer. It returns the answer and its
  /// index among the frames received, so the caller can take what came before it.
  async request(method: string, params: object): Promise<{ id: number; answer: any; index: number }> {
    const id = this.send(method, params);
    const answered = (frames: any[]) => frames.some((frame) => isAnswer(frame) && frame.id === id);
    await this.stream.until(answered, `the answer to ${method}`);
    const index = this.stream.frames.findIndex((frame) => isAnswer(frame) && frame.id === id);
    return { id, answer: this.stream.frames[index], index };
  }

  close() {
    this.socket.destroy();
  }
}

export function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise;
  });
  return { promise, resolve };
}
