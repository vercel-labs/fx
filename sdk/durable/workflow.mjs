// The Vercel adapter's persisted run arguments use Workflow's own codec.
// Keep its dependencies out of durable.js and the browser entry point.
import { dehydrateWorkflowArguments, hydrateWorkflowArguments } from "@workflow/core/serialization";
import { deriveRunPayloadKeys } from "@workflow/core/serialization-format";

export const workflowCodec = {
  encode: (args, runId) => dehydrateWorkflowArguments(args, runId, undefined),
  async decode(run, world) {
    const rawKey = await world.getEncryptionKeyForRun?.(run);
    const key = rawKey ? await deriveRunPayloadKeys(rawKey) : undefined;
    return hydrateWorkflowArguments(run.input, run.runId, key);
  },
};
