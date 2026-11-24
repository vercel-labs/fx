/** The `tools[].name` of a chat request body, in the order the request offers them. */
export function requestToolNames(body: string): string[] {
  const parsed = JSON.parse(body) as { tools?: Array<{ name?: unknown }> };
  return (parsed.tools ?? []).map((tool) => String(tool.name));
}

/** The text the model reads back for call `callId` in one request body, or "" when it has none. */
export function toolResultText(body: string, callId: string): string {
  const request = JSON.parse(body) as { prompt?: Array<{ role: string; content?: unknown }> };
  for (const message of request.prompt ?? []) {
    if (message.role !== "tool" || !Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.toolCallId === callId) return JSON.stringify(part.output ?? part.result ?? part);
    }
  }
  return "";
}
