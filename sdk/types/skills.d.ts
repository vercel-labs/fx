// `libfx/skills` (skills.js): instructions and tools from already-loaded
// skill records.
import type { FxAgentTool } from "./libfx.cjs";

/** A resource whose text joins its skill's instructions. */
export interface SkillResource {
  uri: string;
  text: string;
}

/** An already-loaded skill. */
export interface SkillRecord {
  name: string;
  instructions: string;
  description?: string;
  resources?: readonly SkillResource[];
  /** Each host tool sets `idempotent`, as `createFxAgent()` requires. */
  tools?: readonly FxAgentTool[];
}

/** What `createSkillsAdapter()` returns: spread it into the agent options. */
export interface SkillsAdapter {
  instructions: string;
  tools: FxAgentTool[];
}

/** Turns up to 64 skill records into instructions and tools. */
export declare function createSkillsAdapter(records: readonly SkillRecord[]): SkillsAdapter;
