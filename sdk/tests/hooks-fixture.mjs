import { strict as assert } from "node:assert";

const enabled = process.env.LIBFX_TEST_HOOKS === "1" || process.argv.includes("--hooks");
const turns = new Map();
const errors = [];
let seen = 0;

/** Opt-in observation for the existing durability/steering conformance drivers. */
export const testHooks = enabled
  ? {
      onEvent(event) {
        seen++;
        assert.equal(event.version, 1);
        assert.equal(typeof event.sessionId, "string");
        if (event.executionId !== null) {
          assert.equal(typeof event.turnId, "string");
          assert.ok(event.turnId.length > 0);
          const previous = turns.get(event.executionId);
          if (previous !== undefined) assert.equal(event.turnId, previous, event.type);
          turns.set(event.executionId, event.turnId);
        }
      },
      onError(error) {
        errors.push(error);
      },
    }
  : undefined;

process.once("exit", () => {
  if (!enabled) return;
  assert.equal(errors.length, 0, errors.map((error) => error.stack ?? String(error)).join("\n"));
  assert.ok(seen > 0, "hooks-enabled conformance run observed no events");
});
