import { randomUUID } from "node:crypto";

export const runtime = "nodejs";

export async function POST(request) {
  const token = process.env.LIBFX_SMOKE_TOKEN;
  if (token && request.headers.get("authorization") !== `Bearer ${token}`) {
    return new Response(null, { status: 401 });
  }
  const { id, method, params } = await request.json();
  let result;
  if (method === "tools/list") {
    result = { tools: [{
      name: "lookup",
      description: "Get the verification value. Call once with key alpha, then repeat the returned value.",
      inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
    }] };
  } else if (method === "tools/call" && params?.name === "lookup") {
    result = { content: [{ type: "text", text: `verified:${randomUUID()}` }] };
  } else {
    return Response.json({ jsonrpc: "2.0", id, error: { code: -32601, message: "Unknown method" } });
  }
  return Response.json({ jsonrpc: "2.0", id, result });
}
