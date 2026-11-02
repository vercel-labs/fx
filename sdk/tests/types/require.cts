// CommonJS: `require("libfx")` loads the generated node.cjs entry.
import libfx = require("libfx");
import nodeEntry = require("libfx/node");

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

const agent: libfx.FxAgent = libfx.createFxAgent({ model: "anthropic/claude-haiku-4.5" });
const turn = agent.session().prompt("Explain this project.");

export async function run(): Promise<void> {
  const result = await turn.result;
  assertType<Equal<typeof result, libfx.FxTurnResult>>();

  // The ESM durabilities work with the CommonJS agent: one Durability type.
  const { local } = await import("libfx/durable-local");
  const { world } = await import("libfx/durable-world");
  libfx.createFxAgent({ durability: local({ dir: ".fx/sessions" }) });
  libfx.createFxAgent({ durability: libfx.memory() });
  void world;

  const engine = await nodeEntry.createFxEngine({ apiKey: "key", persistence: libfx.createMemoryPersistence() });
  for (let open = engine.resume(); open; open = engine.resume()) await open.result;

  const info = await libfx.getBackendInfo({ backend: "native" });
  console.log(info.backend, libfx.libfxApiVersion, await libfx.listModels({ apiKey: "key" }));

  try {
    await engine.close();
  } catch (error) {
    if (error instanceof libfx.FxFencedError) assertType<Equal<typeof error.code, "FX_FENCED">>();
    if (error instanceof nodeEntry.FxJournalVersionError) assertType<Equal<typeof error.code, "FX_JOURNAL_VERSION">>();
  }

  // @ts-expect-error null is not a session id
  agent.session(null);
}
