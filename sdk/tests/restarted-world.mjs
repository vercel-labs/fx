// An app's World started again after a restart, for tests of libfx sessions
// in a World the app shares with the Workflow SDK. world-local, like
// world-postgres, queues one message `{ runId }` for every pending or running
// run when it starts (`reenqueueActiveRuns` in @workflow/world): on the queue
// of the namespace the run recorded when it was created, or on the starting
// process's default queue when it recorded none. The Workflow SDK takes that
// default queue. The stand-in consumer here does what it does with a run
// whose workflow it does not have, and fails the run with
// WorkflowNotRegisteredError; it runs the app's own workflow, `app/flow`, and
// leaves those runs running.
//
// `deliveries` lists every recovery message, one with no libfx prompt, that
// a consumer took, in order: the run, the consumer ("libfx" or "workflow"),
// the queue name, the delivery's attempt, the HTTP status the consumer
// answered, and for the Workflow SDK whether it ran the run or failed it.
// The test starts the World, with `start()`, once its libfx agents listen.
import { local } from "../durable/local.mjs";
import { world } from "../durable/world.mjs";

const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);

const appWorkflow = "app/flow";
const libfxPrefix = "__libfx_wkf_workflow_";

// The Workflow SDK's queue prefix for `namespace`, as @workflow/world names it.
const workflowPrefix = (namespace) => (namespace ? `__${namespace}_wkf_workflow_` : "__wkf_workflow_");

/**
 * A World at `dir` that recovers its active runs when the test calls
 * `start()`, unless `recover` is false, as libfx's own `local()` World is.
 * `namespace` is the starting process's WORKFLOW_QUEUE_NAMESPACE, whose
 * queue the Workflow SDK takes. `options` go to `world()` with the lease
 * settings `local()` gives a World on this machine.
 */
export async function restartedWorldAt(dir, { recover = true, namespace, ...options } = {}) {
  const instance = createWorld({ dataDir: dir, recoverActiveRuns: recover });
  const deliveries = [];
  // The runs the stand-in failed in the delivery under way.
  const failing = new Set();
  const register = instance.registerHandler.bind(instance);
  instance.registerHandler = (prefix, handler) => register(prefix, async (request) => {
    const body = await request.clone().json().catch(() => null);
    const response = await handler(request);
    if (body && typeof body === "object" && body.input === undefined && typeof body.runId === "string") {
      const consumer = prefix === libfxPrefix ? "libfx" : "workflow";
      deliveries.push({
        runId: body.runId,
        consumer,
        queueName: request.headers.get("x-vqs-queue-name"),
        attempt: Number(request.headers.get("x-vqs-message-attempt")),
        status: response.status,
        ...(consumer === "workflow" ? { outcome: failing.delete(body.runId) ? "failed" : "ran" } : {}),
      });
    }
    return response;
  });
  const workflowQueue = workflowPrefix(namespace);
  instance.registerHandler(workflowQueue, instance.createQueueHandler(workflowQueue, async ({ runId }) => {
    const run = await instance.runs.get(runId);
    if (run.workflowName === appWorkflow) return;
    await instance.events.create(runId, {
      eventType: "run_failed",
      ...(instance.specVersion === undefined ? {} : { specVersion: instance.specVersion }),
      eventData: { error: { name: "WorkflowNotRegisteredError", message: `Workflow "${run.workflowName}" is not registered in this deployment` }, errorCode: "RUNTIME_ERROR" },
    });
    failing.add(runId);
  }));
  const { world: _create, owned: _owned, name: _name, ...settings } = local({ dir });
  return {
    instance,
    deliveries,
    durability: world(instance, { name: "app", ...settings, ...options }),
    // Recovery reads WORKFLOW_QUEUE_NAMESPACE as it starts.
    async start() {
      const previous = process.env.WORKFLOW_QUEUE_NAMESPACE;
      if (namespace === undefined) delete process.env.WORKFLOW_QUEUE_NAMESPACE;
      else process.env.WORKFLOW_QUEUE_NAMESPACE = namespace;
      try {
        await instance.start();
      } finally {
        if (previous === undefined) delete process.env.WORKFLOW_QUEUE_NAMESPACE;
        else process.env.WORKFLOW_QUEUE_NAMESPACE = previous;
      }
    },
    // The run's status and the namespace it recorded, as the World holds them.
    async run(runId) {
      const run = await instance.runs.get(runId);
      return { status: run.status, namespace: run.executionContext?.queueNamespace ?? null };
    },
    close: () => instance.close().catch(() => {}),
  };
}

// A run id's ULID: the time, then randomness, in Crockford's base32.
function ulid(now = Date.now()) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = "";
  for (let rest = now, index = 0; index < 10; index += 1, rest = Math.floor(rest / 32)) time = alphabet[rest % 32] + time;
  let random = "";
  for (const byte of crypto.getRandomValues(new Uint8Array(16))) random += alphabet[byte % 32];
  return time + random;
}

/** Creates a run of the app's own workflow in `instance`, as the Workflow SDK starts one, and returns its id. */
export async function createAppRun(instance) {
  const spec = instance.specVersion === undefined ? {} : { specVersion: instance.specVersion };
  const runId = `wrun_${typeof instance.createRunId === "function" ? instance.createRunId({}) : ulid()}`;
  const deploymentId = typeof instance.getDeploymentId === "function" ? await instance.getDeploymentId() : "app";
  await instance.events.create(runId, { eventType: "run_created", ...spec, eventData: { deploymentId, workflowName: appWorkflow, input: new TextEncoder().encode("[]") } });
  await instance.events.create(runId, { eventType: "run_started", ...spec });
  return runId;
}
