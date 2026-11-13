// Sessions kept in a World the app supplies: its store, streams and queue,
// such as Workflow's Postgres World. `local()` and `vercel()` are this with
// the World libfx bundles for each.

const durabilityTag = Symbol.for("libfx.durability");

// The consumer group Vercel subscribes a vercel.json `queue/v2beta` trigger
// with: its `functions` key, after its service's name and "~" when it has
// one, with "_" as "__", "/" as "_S", "." as "_D", letters, digits and "-"
// kept, and any other character as "_" and its code in hex. A copy of
// `vercelTriggerConsumerGroup` in `@workflow/world-vercel`.
function vercelTriggerConsumerGroup(pattern, service) {
  const name = service === undefined ? pattern : `${service}~${pattern}`;
  let group = "";
  for (const char of name) {
    if (char === "_") group += "__";
    else if (char === "/") group += "_S";
    else if (char === ".") group += "_D";
    else if (/^[A-Za-z0-9-]$/.test(char)) group += char;
    else group += `_${char.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return group;
}

/**
 * `source` is the World, or a function that creates it. libfx starts and
 * closes a World it creates. A World passed in stays the app's: the app
 * starts it before the agent's first prompt and closes it after
 * `agent.close()`, and gives it to one agent at a time, since the agent
 * registers the World's handler for libfx's queue.
 *
 * - `livenessKnown`: `alive(lease)` answers whether a lease's holder still
 *   runs, from what `holderInfo()` put in it, so a crashed worker's session
 *   frees at once. Otherwise its worker renews the lease while it runs, and
 *   a session frees `leaseMs` after a dead worker's last renewal.
 * - `queueLeases`: the queue keeps a message from other deliveries while one
 *   handles it, and delivers it again once that delivery's process is gone,
 *   as Vercel Queues does. A worker then holds its session for as long as
 *   its delivery runs, up to its deadline, and renews nothing: the next
 *   delivery of the same message takes the session over. The World must say
 *   which message and which delivery of it each handler call carries. A
 *   worker with no deadline renews its lease all the same.
 * - `runInRequest`: with `queueLeases`, a prompt runs in the request that
 *   took it when no worker holds the session, saving a queue hop. On a World
 *   whose queue holds a message for its sender
 *   (`capabilities.experimental_queueHold`), given `holdConsumerGroup` or
 *   `holdFunction`, the request sends the prompt
 *   asking for a hold and runs it as the message's first delivery, whose
 *   lease the queue renews while it runs; a prompt the queue does not hold,
 *   the queue delivers. On any other World, the queue keeps the prompt as a
 *   backstop it delivers only after that request's deadline. Either way the
 *   request's lease names the message, so if the request died the queue's
 *   next delivery of it takes the session over. Default true with
 *   `queueLeases`.
 * - `holdConsumerGroup`: the consumer group of the route the queue delivers
 *   libfx's messages to, which a hold is taken for, so a hold the request
 *   lets lapse is delivered to that route. Without it, or `holdFunction`,
 *   no prompt is held, and the queue keeps a backstop.
 * - `holdFunction`: that route's key under `functions` in vercel.json, such
 *   as "app/api/libfx/route.js", from which Vercel names its trigger's
 *   consumer group, with `holdService` its service's name, when it has one.
 *   Not with `holdConsumerGroup`.
 * - `waitUntil(work)`: keeps the request alive until `work`, a turn it runs
 *   after its response, settles, as Vercel's `waitUntil` or Next's `after()`.
 * - `leaseMs`: how long a lease lasts after it was taken or last renewed,
 *   when liveness is unknown. Default 15000.
 * - `queueDurable`: the queue keeps a message until a delivery acknowledges
 *   it, across crashes. `prompt()` stores the prompt first either way.
 * - `pollMs`: how often a waiting worker reads the session again.
 * - `maxDurationMs` and `reserveMs`: each delivery stops `reserveMs` before
 *   `maxDurationMs`, or before the World's `getRuntimeDeadline()`.
 * - `gatewayKey()`: the AI Gateway credential when the app passes none.
 * - `store`: names the store this World keeps sessions in; default its name.
 *   Queue messages name it, so a route delivers each to the agents on its
 *   store, and on one store an agent name belongs to one configuration. Give
 *   each customer of an app a store of its own.
 */
export function world(source, options = {}) {
  const owned = typeof source === "function";
  if (!owned && !(source && typeof source === "object")) throw new TypeError("world() takes a World or a function that creates one");
  if (!options || typeof options !== "object" || Array.isArray(options)) throw new TypeError("world() options must be an object");
  const { name = "world", store = name, livenessKnown = false, queueLeases = false, runInRequest = queueLeases, waitUntil, queueDurable = false, pollMs, leaseMs, maxDurationMs, reserveMs, alive, holderInfo, gatewayKey, holdConsumerGroup, holdFunction, holdService } = options;
  if (typeof name !== "string" || name.length === 0) throw new TypeError("world() name must be a non-empty string");
  if (typeof store !== "string" || store.length === 0) throw new TypeError(`${name}() store must be a non-empty string`);
  for (const [key, value] of Object.entries({ livenessKnown, queueLeases, runInRequest, queueDurable })) {
    if (typeof value !== "boolean") throw new TypeError(`${name}() ${key} must be a boolean`);
  }
  if (pollMs !== undefined && !(Number.isSafeInteger(pollMs) && pollMs > 0)) throw new TypeError(`${name}() pollMs must be a positive integer`);
  // Renewed every third of it, so a lease shorter than a second renews faster than a write lands.
  if (leaseMs !== undefined && !(Number.isSafeInteger(leaseMs) && leaseMs >= 1000)) throw new TypeError(`${name}() leaseMs must be an integer of at least 1000`);
  for (const [key, value] of Object.entries({ maxDurationMs, reserveMs })) {
    if (value !== undefined && !(Number.isSafeInteger(value) && value >= 0)) throw new TypeError(`${name}() ${key} must be a non-negative integer`);
  }
  for (const [key, value] of Object.entries({ alive, holderInfo, gatewayKey, waitUntil })) {
    if (value !== undefined && typeof value !== "function") throw new TypeError(`${name}() ${key} must be a function`);
  }
  if (livenessKnown && !alive) throw new TypeError(`${name}() livenessKnown needs alive()`);
  // Only the backstop's own message coming back continues a turn a dead
  // request ran.
  if (runInRequest && !queueLeases) throw new TypeError(`${name}() runInRequest needs queueLeases`);
  for (const [key, value] of Object.entries({ holdConsumerGroup, holdFunction, holdService })) {
    if (value !== undefined && !(typeof value === "string" && value.length > 0)) throw new TypeError(`${name}() ${key} must be a non-empty string`);
  }
  if (holdConsumerGroup !== undefined && holdFunction !== undefined) throw new TypeError(`${name}() takes holdConsumerGroup or holdFunction, not both`);
  if (holdService !== undefined && holdFunction === undefined) throw new TypeError(`${name}() holdService needs holdFunction`);
  const holdGroup = holdFunction === undefined ? holdConsumerGroup : vercelTriggerConsumerGroup(holdFunction, holdService);
  // Only a prompt the request runs is held.
  if (holdGroup !== undefined && !runInRequest) throw new TypeError(`${name}() ${holdFunction === undefined ? "holdConsumerGroup" : "holdFunction"} needs runInRequest`);
  return {
    [durabilityTag]: true,
    name,
    store,
    world: owned ? source : () => source,
    owned,
    livenessKnown,
    queueLeases,
    runInRequest,
    queueDurable,
    ...(pollMs === undefined ? {} : { pollMs }),
    ...(leaseMs === undefined ? {} : { leaseMs }),
    ...(maxDurationMs === undefined ? {} : { maxDurationMs }),
    ...(reserveMs === undefined ? {} : { reserveMs }),
    ...(alive === undefined ? {} : { alive }),
    ...(holderInfo === undefined ? {} : { holderInfo }),
    ...(gatewayKey === undefined ? {} : { gatewayKey }),
    ...(waitUntil === undefined ? {} : { waitUntil }),
    ...(holdGroup === undefined ? {} : { holdConsumerGroup: holdGroup }),
  };
}
