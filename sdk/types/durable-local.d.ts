// `libfx/durable-local` (durable/local.mjs): sessions in files on this
// machine, through the Workflow local World libfx bundles.
import type { Durability } from "./libfx.cjs";

export type { Durability } from "./libfx.cjs";

/** Options for `local()`. */
export interface LocalOptions {
  /** Where the sessions live. */
  dir?: string;
  /** Each delivery runs as if its function stopped after this long, as on Vercel. No limit by default. */
  maxDurationMs?: number;
  /** How long before the deadline each delivery stops. Default 30000. */
  reserveMs?: number;
  /**
   * When an agent starts, it continues the turns, and the prompts not yet delivered, that a process on this machine
   * started in the same directory left in the agent's sessions when it died. False leaves them for the session's next
   * prompt or `session.resume()`. Default true.
   */
  recover?: boolean;
}

/** Keeps sessions in files on this machine. A session held by a process that died is free at once. */
export declare function local(options?: LocalOptions): Durability;
