import { createFxAgent } from "libfx";

export const runtime = "nodejs";

function stream(events) {
  const data = [...events, "[DONE]"].map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
  return new Response(data, { headers: { "content-type": "text/event-stream" } });
}

// One agent for the server, as an app holds it; its sessions live in the
// durability the environment picks.
const agent = createFxAgent({
  apiKey: "fixture-unused-key",
  model: "fixture/model",
  async fetch(_url, init) {
    if (init?.method === "GET") return Response.json({ data: [{ id: "fixture/model", type: "language" }] });
    const body = JSON.parse(init.body);
    const users = body.prompt.filter((message) => message.role === "user").length;
    return stream([
      { type: "text-delta", delta: `durable answer ${users}` },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } },
    ]);
  },
});

function authorized(request) {
  const token = process.env.LIBFX_SMOKE_TOKEN;
  return !token || request.headers.get("authorization") === `Bearer ${token}`;
}

export async function POST(request) {
  if (!authorized(request)) return new Response(null, { status: 401 });
  const sessionId = new URL(request.url).searchParams.get("sessionId") ?? undefined;
  const session = agent.session(sessionId);
  const turn = session.prompt(await request.text());
  await turn.accepted;
  return new Response(turn.readable, { headers: { "content-type": "application/x-ndjson", "x-libfx-session": session.id } });
}

// Reconnects from any server.
export async function GET(request) {
  if (!authorized(request)) return new Response(null, { status: 401 });
  const params = new URL(request.url).searchParams;
  return new Response(agent.session(params.get("sessionId")).stream(Number(params.get("cursor") ?? 0)), {
    headers: { "content-type": "application/x-ndjson" },
  });
}
