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
}

/** Keeps sessions in Vercel's World. A function holds its session while Vercel Queues keeps its message for it, and the next delivery of that message continues a turn whose function died. */
export declare function vercel(options?: VercelOptions): Durability;
