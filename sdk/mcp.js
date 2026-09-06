const maxTools = 64;
const maxInstructionsBytes = 64 * 1024;

function contentText(content, mode = "tool") {
  if (typeof content === "string") return content;
  const blocks = Array.isArray(content) ? content : content && typeof content === "object" ? [content] : [];
  return blocks.map((item) => {
    if (item?.type === "text" && typeof item.text === "string") return item.text;
    if (item?.type === "resource" && typeof item.resource?.text === "string") return item.resource.text;
    if (typeof item?.text === "string") return item.text;
    if (item?.type === "resource_link" && typeof item.uri === "string") return `${item.name ?? "Resource"}: ${item.uri}`;
    if (mode === "instructions" && (item?.type === "image" || item?.type === "audio" || typeof item?.blob === "string" || typeof item?.resource?.blob === "string")) return "[Non-text MCP context is not included in these text instructions.]";
    return "";
  }).filter(Boolean).join("\n");
}

function resultText(result) {
  const text = contentText(result?.content);
  if (result?.structuredContent !== undefined) {
    const structured = JSON.stringify(result.structuredContent);
    return text && text !== structured ? `${text}\n${structured}` : structured;
  }
  return text;
}

function appendInstruction(parts, label, text) {
  if (!text) return;
  parts.push(`<${label}>\n${text}\n</${label}>`);
}

export async function createMcpAdapter(client, options = {}) {
  if (!client || typeof client.listTools !== "function" || typeof client.callTool !== "function") {
    throw new TypeError("MCP client must provide listTools() and callTool()");
  }
  const prefix = options.prefix ?? "";
  if (typeof prefix !== "string" || !/^[A-Za-z0-9_-]*$/.test(prefix)) {
    throw new TypeError("MCP prefix must contain only letters, digits, underscore, or hyphen");
  }
  const catalog = [];
  const cursors = new Set();
  let cursor;
  for (let page = 0; ; page += 1) {
    if (page >= maxTools) throw new RangeError("MCP tool pagination exceeded its page limit");
    const listed = await client.listTools(cursor === undefined ? undefined : { cursor });
    const tools = Array.isArray(listed) ? listed : listed?.tools;
    if (!Array.isArray(tools) || tools.length > maxTools - catalog.length) throw new TypeError("MCP listTools() returned an invalid tool catalog");
    catalog.push(...tools);
    cursor = Array.isArray(listed) ? undefined : listed.nextCursor;
    if (cursor === undefined || cursor === null) break;
    if (typeof cursor !== "string" || cursor.length > 4096 || cursors.has(cursor)) throw new TypeError("MCP listTools() returned an invalid pagination cursor");
    cursors.add(cursor);
  }
  const names = new Set();
  const tools = catalog.map((tool, index) => {
    if (!tool || typeof tool.name !== "string" || tool.name.length === 0 || tool.name.length > 256 || (tool.description !== undefined && typeof tool.description !== "string")) {
      throw new TypeError(`MCP tool ${index} is invalid`);
    }
    if (catalog.some((previous, previousIndex) => previousIndex < index && previous?.name === tool.name)) throw new TypeError(`MCP tool ${tool.name} is duplicated`);
    const base = `${prefix}${tool.name}`.replace(/[^A-Za-z0-9_-]/g, "_");
    let name = base.slice(0, 64);
    for (let suffix = 2; names.has(name); suffix += 1) {
      const tail = `_${suffix}`;
      name = `${base.slice(0, 64 - tail.length)}${tail}`;
    }
    names.add(name);
    return {
      name,
      description: tool.description || "MCP tool",
      inputSchema: tool.inputSchema ?? { type: "object", properties: {} },
      async execute(input, { signal }) {
        const result = await client.callTool({ name: tool.name, arguments: input }, undefined, { signal });
        const text = resultText(result);
        const images = (Array.isArray(result?.content) ? result.content : []).flatMap((item) => item?.type === "image" ? [item] : item?.type === "resource" && item.resource?.mimeType?.startsWith("image/") && typeof item.resource?.blob === "string" ? [{ type: "image", mimeType: item.resource.mimeType, data: item.resource.blob }] : []).map((item) => ({
          type: "image", mimeType: item.mimeType, data: item.data,
        }));
        const rich = images.length ? { type: "libfx.tool-result", text, images } : null;
        if (result?.isError) {
          const error = new Error(text || `MCP tool ${tool.name} failed`);
          if (rich) error.toolResult = rich;
          throw error;
        }
        return rich ?? text;
      },
    };
  });

  const instructions = [];
  for (const uri of options.resources ?? []) {
    if (typeof client.readResource !== "function") throw new TypeError("MCP client does not provide readResource()");
    const result = await client.readResource({ uri });
    appendInstruction(instructions, "mcp_resource", contentText(result?.contents ?? result?.content, "instructions"));
  }
  for (const prompt of options.prompts ?? []) {
    if (typeof client.getPrompt !== "function") throw new TypeError("MCP client does not provide getPrompt()");
    const request = typeof prompt === "string" ? { name: prompt } : prompt;
    const result = await client.getPrompt(request);
    appendInstruction(
      instructions,
      "mcp_prompt",
      (result?.messages ?? []).map((message) => contentText(message.content, "instructions")).filter(Boolean).join("\n"),
    );
  }
  const instructionText = instructions.join("\n\n");
  if (new TextEncoder().encode(instructionText).length > maxInstructionsBytes) {
    throw new RangeError(`MCP instructions exceed the ${maxInstructionsBytes} byte libfx limit`);
  }

  let closed = false;
  return {
    tools,
    instructions: instructionText,
    async close() {
      if (closed) return;
      closed = true;
      await client.close?.();
    },
  };
}
