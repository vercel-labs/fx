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
  const durability = world(() => explainRefusals(createWorld()), {
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
  // Vercel's World stores a batch of stream lines with one request, in
  // order, so libfx writes a turn's lines in batches there; on a World it
  // knows no such thing of, it writes them one after another.
  return { ...durability, [Symbol.for("libfx.batchesInOrder")]: true };
}

// Vercel's World answers a request without a deployment's credentials with
// a bare "Unauthorized", which doesn't tell an app what it lacks. Its error
// keeps the World's code and status, and the World's error is its cause.
const unauthorized = (error) => error?.status === 401 || error?.code === "unauthorized";
function explained(error) {
  if (!unauthorized(error)) return error;
  return Object.assign(new Error(
    "Vercel's World refused the request as unauthorized: vercel() keeps sessions in a Vercel project and needs a deployment's credentials. " +
    "Run on Vercel, or elsewhere set VERCEL_OIDC_TOKEN to the project's OIDC token, as `vercel env pull` writes it.",
    { cause: error },
  ), { name: error.name, code: error.code, status: error.status });
}

// The World with each call's unauthorized refusal explained: its functions,
// and those of the plain objects that group them.
function explainRefusals(created) {
  const wrap = (target) => Object.fromEntries(Object.entries(target).map(([key, value]) => {
    if (typeof value === "function") {
      return [key, (...args) => {
        const result = value.apply(target, args);
        return typeof result?.then === "function" ? result.then(undefined, (error) => { throw explained(error); }) : result;
      }];
    }
    const plain = value !== null && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype;
    return [key, plain && target === created ? wrap(value) : value];
  }));
  return wrap(created);
}
