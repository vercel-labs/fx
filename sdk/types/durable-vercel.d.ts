// `libfx/durable-vercel` (durable/vercel.mjs): sessions in Vercel's World,
// the store and queue behind Vercel Workflow, which libfx bundles.
import type { Durability } from "./libfx.cjs";

export type { Durability } from "./libfx.cjs";

/** Options for `vercel()`. */
export interface VercelOptions {
  /** How long before the function's deadline each delivery stops. Default 30000. */
  reserveMs?: number;
  /**
   * Renew a lease of this length in the session's log while a turn runs, every third of it, so a function that stopped
   * frees its session this long after its last renewal. Without it, nothing is renewed: a function holds its session
   * for as long as Vercel Queues keeps the turn's message for it, and a function that died frees its session when the
   * queue delivers that message again, about a second after its process exits, or once the queue's hold on it runs
   * out. At least 1000.
   */
  leaseMs?: number;
  /**
   * The wake route's key under `functions` in vercel.json, such as `"app/api/libfx/route.js"`. Vercel Queues then
   * holds a prompt that runs in the request for that route's trigger, and the request runs it as its message's first
   * delivery, with no backstop. Without it, or `holdConsumerGroup`, the queue keeps the prompt as a backstop until
   * after the request's deadline. Not with `leaseMs`.
   */
  holdFunction?: string;
  /** With `holdFunction`: the name of the Vercel service the wake route belongs to, when it belongs to one. */
  holdService?: string;
  /**
   * The wake route's consumer group, for a route whose trigger's group is not named after its vercel.json key, such as
   * `"default"` for a trigger in generated Build Output configuration. Not with `holdFunction` or `leaseMs`.
   */
  holdConsumerGroup?: string;
}

/** Keeps sessions in Vercel's World. A function holds its session while Vercel Queues keeps its message for it, and the next delivery of that message continues a turn whose function died. */
export declare function vercel(options?: VercelOptions): Durability;
