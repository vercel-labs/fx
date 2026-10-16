import assert from 'node:assert/strict'
import { test } from 'node:test'
import { POST } from '../node-chat/handler.mjs'

test('the Node demo streams a complete reply through the packaged engine', async (t) => {
  const previousKey = process.env.AI_GATEWAY_API_KEY
  process.env.AI_GATEWAY_API_KEY = 'example-test-key'
  t.after(() => {
    if (previousKey === undefined) delete process.env.AI_GATEWAY_API_KEY
    else process.env.AI_GATEWAY_API_KEY = previousKey
  })
  let calls = 0
  t.mock.method(globalThis, 'fetch', async (request) => {
    calls++
    assert.equal(request.url, 'https://ai-gateway.vercel.sh/v4/ai/language-model')
    assert.equal(request.headers.get('ai-language-model-id'), 'openai/gpt-4.1-nano')
    const body = await request.json()
    assert.equal(body.maxOutputTokens, 512)
    assert.ok(JSON.stringify(body.prompt).includes('Hello'))
    return new Response([
      'data: {"type":"text-delta","delta":"Hello back"}',
      'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":1},"outputTokens":{"total":2}}}',
      'data: [DONE]',
      '',
    ].join('\n\n'), { headers: { 'content-type': 'text/event-stream' } })
  })
  const response = await POST(new Request('http://localhost/api/chat', {
    method: 'POST', body: JSON.stringify({ prompt: 'Hello' }),
  }))
  assert.equal(response.status, 200)
  assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.equal(await response.text(), 'Hello back')
  assert.equal(calls, 1)
})
