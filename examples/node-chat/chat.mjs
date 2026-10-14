import { createInterface } from 'node:readline'
import { stdin, stdout } from 'node:process'
import { createFxAgent } from 'libfx'
import { model } from '../shared/model.mjs'

const agent = await createFxAgent({
  apiKey: process.env.AI_GATEWAY_API_KEY,
  model,
})
const input = createInterface({ input: stdin, output: stdout, prompt: 'You: ' })

try {
  input.prompt()
  for await (const prompt of input) {
    if (prompt.trim() === '/exit') break
    if (!prompt.trim()) { input.prompt(); continue }
    stdout.write('Agent: ')
    const turn = agent.prompt(prompt)
    for await (const event of turn) {
      if (event.type === 'text_delta') stdout.write(event.delta)
    }
    await turn.result
    stdout.write('\n\n')
    input.prompt()
  }
} finally {
  input.close()
  await agent.close()
}
