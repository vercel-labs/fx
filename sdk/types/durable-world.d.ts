// `libfx/durable-world` (durable/world.mjs): sessions kept in a World the app
// supplies, such as Workflow's Postgres World.
import type { Durability } from "./libfx.cjs";

export type { Durability } from "./libfx.cjs";

/**
 * What libfx uses of a World: its events, streams, and queue. Workflow's
 * Worlds fit. Methods are typed loosely so any conforming World is accepted.
 */
export interface World {
  readonly specVersion?: number;
  readonly events: {
    create(runId: string, data: unknown, params?: unknown): unknown;
    list(params: unknown): unknown;
  };
  readonly streams: {
    write(runId: string, name: string, chunk: string): unknown;
    writeMulti?(runId: string, name: string, chunks: string[]): unknown;
    get(runId: string, name: string, startIndex?: number): unknown;
    getInfo(runId: string, name: string): unknown;
  };
  queue(queueName: string, message: unknown, options?: unknown): unknown;
  createQueueHandler(prefix: string, handler: (message: unknown, meta: any) => Promise<unknown>): (request: Request) => Promise<Response>;
  /** A World with `registerHandler` delivers to the agent in its process; any other delivers over HTTP to `agent.wakeHandler()`. */
  registerHandler?(prefix: string, handler: (request: Request) => Promise<Response>): unknown;
  getRuntimeDeadline?(): unknown;
  getDeploymentId?(): unknown;
  createRunId?(options?: Readonly<Record<string, unknown>>): string;
  start?(): unknown;
  close?(): unknown;
}

/** A lease as `alive()` sees it: the fields `holderInfo()` returned when it was taken, beside libfx's own. */
export type WorldLease = Readonly<Record<string, unknown>>;

/** A World, or a function that creates one. libfx starts and closes a World it creates; a World passed in stays the app's. */
export type WorldSource = World | (() => World | Promise<World>);

/** What `world()` cannot learn from the World itself. */
export type WorldOptions = {
  /** The durability's name in errors. Default `"world"`. */
  name?: string;
  /** The queue keeps a message until a delivery acknowledges it, across crashes. When false, `prompt()` stores the prompt first. Default false. */
  queueDurable?: boolean;
  /** How often a waiting worker reads the session again. Default 1000. */
  pollMs?: number;
  /**
   * The queue keeps a message from every other delivery while one handles it, and delivers it again once that
   * delivery's process is gone, as Vercel Queues does. Without liveness, a worker then holds its session for as long as
   * its delivery runs, up to its deadline, and renews nothing: the next delivery of the same message takes the session
   * over. The World must pass each handler call the queue's `messageId` and delivery `attempt`. A worker with no
   * deadline renews its lease all the same. Default false.
   */
  queueLeases?: boolean;
  /**
   * With `queueLeases`: a prompt runs in the request that took it when no worker holds the session, and the queue keeps
   * the prompt as a backstop it delivers only after that request's deadline. The request's lease names the backstop, so
   * if the request died, the backstop takes the session over. Default true with `queueLeases`.
   */
  runInRequest?: boolean;
  /** Keeps the request alive until `work`, a turn it runs after its response, settles, such as Vercel's `waitUntil` or Next's `after()`. */
  waitUntil?(work: Promise<void>): void;
  /** Without liveness, how long a lease lasts after its worker took or last renewed it; renewed every third of that. At least 1000. Default 15000. */
  leaseMs?: number;
  /** Each delivery stops `reserveMs` before `maxDurationMs`, or before the World's `getRuntimeDeadline()`. No limit by default. */
  maxDurationMs?: number;
  /** Default 30000. */
  reserveMs?: number;
  /** What a worker puts in each lease it takes, for `alive()` to read. */
  holderInfo?(): Record<string, unknown>;
  /** The AI Gateway credential when the agent has no `apiKey`. */
  gatewayKey?(): string | Promise<string>;
} & (
  | {
    /** `alive(lease)` answers whether a lease's holder still runs, so a crashed worker's session frees at once. */
    livenessKnown: true;
    /** True when the holder runs, false when it does not, and null when unknown. */
    alive(lease: WorldLease): boolean | null;
  }
  | {
    /** Without liveness, a worker renews its lease while it runs, and the session of one that died frees `leaseMs` after its last renewal. */
    livenessKnown?: false;
    alive?(lease: WorldLease): boolean | null;
  }
);

/** Keeps sessions in a World the app supplies: its store, streams, and queue. */
export declare function world(source: WorldSource, options?: WorldOptions): Durability;
