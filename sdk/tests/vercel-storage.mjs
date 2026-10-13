// Vercel's World for runs, events and streams, with world-local's queue in
// this process, for tests that drive libfx from one machine: they and the
// processes they crash receive their own messages, while every record, lease
// and stream line goes through Vercel. Delivery through Vercel Queues is
// covered by the deployed demo.
//
// Needs a Vercel access token in WORKFLOW_VERCEL_AUTH_TOKEN (or, inside a
// deployment, its OIDC token), and VERCEL_PROJECT_ID, VERCEL_PROJECT_NAME,
// VERCEL_TEAM_ID and a VERCEL_DEPLOYMENT_ID of that project.
import { local } from "../durable/local.mjs";

const { createWorld } = await import(new URL("../durable/node_modules/@workflow/world-vercel/dist/index.js", import.meta.url).href);

/** `local()` with Vercel's World holding what `local()` keeps in files. */
export function vercelStorage(options) {
  const base = local(options);
  return {
    ...base,
    name: "vercel",
    world() {
      const queued = base.world();
      // The deadline the test sets, not a function's.
      const { getRuntimeDeadline, ...stored } = createWorld({
        ...(process.env.WORKFLOW_VERCEL_AUTH_TOKEN ? { token: process.env.WORKFLOW_VERCEL_AUTH_TOKEN } : {}),
        projectConfig: {
          projectId: process.env.VERCEL_PROJECT_ID,
          projectName: process.env.VERCEL_PROJECT_NAME,
          teamId: process.env.VERCEL_TEAM_ID,
        },
      });
      return { ...stored, queue: queued.queue, createQueueHandler: queued.createQueueHandler, registerHandler: queued.registerHandler };
    },
  };
}
