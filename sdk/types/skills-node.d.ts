// `libfx/skills/node` (skills-node.js): loads a `SKILL.md` explicitly in
// Node.js or Bun.
import type { FxAgentTool } from "./libfx.cjs";
import type { SkillRecord, SkillResource } from "./skills.js";

export { createSkillsAdapter } from "./skills.js";
export type { SkillRecord, SkillResource, SkillsAdapter } from "./skills.js";

/** Options for `loadSkillFile()`. */
export interface LoadSkillFileOptions {
  /** Replaces `fs.promises.readFile`. */
  readFile?: (path: string, encoding: "utf8") => string | Promise<string>;
  resources?: readonly SkillResource[];
  tools?: readonly FxAgentTool[];
}

/** A skill read from a `SKILL.md`: its frontmatter `name` and `description`, and its body as instructions. */
export interface LoadedSkill extends SkillRecord {
  description: string;
  resources: readonly SkillResource[];
  tools: readonly FxAgentTool[];
}

/** Reads one `SKILL.md`. Without a frontmatter `name`, the file name is the skill's name. */
export declare function loadSkillFile(path: string, options?: LoadSkillFileOptions): Promise<LoadedSkill>;
