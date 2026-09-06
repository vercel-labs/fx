import { readFile } from "node:fs/promises";
import { basename } from "node:path";

function parseFrontmatter(source) {
  if (!source.startsWith("---\n")) return { metadata: {}, body: source };
  const end = source.indexOf("\n---\n", 4);
  if (end < 0) throw new Error("SKILL.md has unterminated frontmatter");
  const metadata = {};
  for (const line of source.slice(4, end).split("\n")) {
    const separator = line.indexOf(":");
    if (separator < 0) continue;
    metadata[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
  }
  return { metadata, body: source.slice(end + 5).trim() };
}

export async function loadSkillFile(path, options = {}) {
  const source = await (options.readFile ?? readFile)(path, "utf8");
  const { metadata, body } = parseFrontmatter(source);
  return {
    name: metadata.name || basename(path).replace(/\.md$/i, ""),
    description: metadata.description || "",
    instructions: body,
    resources: options.resources ?? [],
    tools: options.tools ?? [],
  };
}

export { createSkillsAdapter } from "./skills.js";
