// Sessions kept in Vercel's World, the store and queue behind Vercel
// Workflow. libfx bundles that World into this module when it is packaged,
// so an app installs nothing more and ignores any copy it has.
import { getVercelOidcToken } from "@vercel/oidc";
import { createWorld } from "@workflow/world-vercel";
import { world } from "./world.mjs";

/**
 * Vercel Queues keeps a message from other deliveries while a function
 * handles it, and delivers it again once the function lets it go without
 * acknowledging it: its handler failed, or it stopped and its hold on the
 * message ran out. A function whose process exits mid-delivery has the same
 * delivery run again about a second later. So a worker holds its session
 * for as long as its function runs, and nothing is written to show it
 * lives: when a function dies, the next delivery of its message takes the
 * session over and continues the turn. With `leaseMs`, each worker also
 * renews a lease of that length in the session's log while it runs, so a
 * function that stops without its process exiting frees its session
 * `leaseMs` after its last renewal rather than when the queue's hold runs
 * out. A worker stops `reserveMs` before its function's deadline, and the
 * next invocation continues the turn.
 */
export function vercel({ reserveMs, leaseMs } = {}) {
  return world(() => createWorld(), {
    name: "vercel",
    // The deployment's own AI Gateway credential, fresh for each request.
    gatewayKey: () => getVercelOidcToken(),
    livenessKnown: false,
    queueLeases: leaseMs === undefined,
    // A turn the request runs after its response keeps the function alive,
    // through the request context `@vercel/functions` reads.
    waitUntil: (work) => globalThis[Symbol.for("@vercel/request-context")]?.get?.()?.waitUntil?.(work),
    // Vercel Queues keeps a message until a delivery acknowledges it.
    queueDurable: true,
    pollMs: 1000,
    reserveMs,
    leaseMs,
  });
}
