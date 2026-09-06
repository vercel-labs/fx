const maxSkills = 64;
const maxInstructionsBytes = 64 * 1024;

function escapeAttribute(value) {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
}

export function createSkillsAdapter(records) {
  if (!Array.isArray(records) || records.length > maxSkills) {
    throw new TypeError("skills must be an array with at most 64 records");
  }
  const names = new Set();
  const sections = [];
  const tools = [];
  for (const [index, record] of records.entries()) {
    if (!record || typeof record.name !== "string" || typeof record.instructions !== "string") {
      throw new TypeError(`skill ${index} requires name and instructions`);
    }
    if (names.has(record.name)) throw new TypeError(`duplicate skill name: ${record.name}`);
    names.add(record.name);
    const resources = (record.resources ?? []).map((resource) => {
      if (typeof resource?.uri !== "string" || typeof resource?.text !== "string") {
        throw new TypeError(`skill ${record.name} has an invalid resource`);
      }
      return `<resource uri="${escapeAttribute(resource.uri)}">\n${resource.text}\n</resource>`;
    }).join("\n");
    sections.push([
      `<skill name="${escapeAttribute(record.name)}">`,
      record.description ? `<description>${record.description}</description>` : "",
      record.instructions,
      resources,
      "</skill>",
    ].filter(Boolean).join("\n"));
    if (record.tools !== undefined) {
      if (!Array.isArray(record.tools)) throw new TypeError(`skill ${record.name} tools must be an array`);
      tools.push(...record.tools);
    }
  }
  const instructions = sections.join("\n\n");
  if (new TextEncoder().encode(instructions).length > maxInstructionsBytes) {
    throw new RangeError(`skill instructions exceed the ${maxInstructionsBytes} byte libfx limit`);
  }
  return { instructions, tools };
}
