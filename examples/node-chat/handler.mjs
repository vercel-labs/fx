import { createFxEngine } from 'libfx'
import { model } from '../shared/model.mjs'
import { errorResponse, gatewayFetch, readPrompt } from '../shared/gateway.mjs'

export async function POST(request) {
  try {
    const prompt = await readPrompt(request)
    const agent = await createFxEngine({ apiKey: process.env.AI_GATEWAY_API_KEY, model, fetch: gatewayFetch })
    async function* reply() {
      try {
        const turn = agent.prompt(prompt, { signal: request.signal })
        for await (const event of turn) {
          if (event.type === 'text_delta') yield event.delta
        }
        await turn.result
      } finally {
        await agent.close()
      }
    }
    return new Response(ReadableStream.from(reply()).pipeThrough(new TextEncoderStream()), {
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    })
  } catch (error) {
    return errorResponse(error)
  }
}
