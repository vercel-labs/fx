import { createFxEngine, supportsJspi } from 'libfx/browser'
import { model } from '../shared/model.mjs'

const form = document.querySelector('form')
const button = document.querySelector('button')
const reply = document.querySelector('#reply')
const status = document.querySelector('#status')
const keyInput = document.querySelector('#api-key')
let agent
let activeKey

if (!supportsJspi()) {
  status.textContent = 'This browser does not support WebAssembly JSPI. Try desktop Chrome or Edge.'
  button.disabled = true
}

form.addEventListener('submit', async (event) => {
  event.preventDefault()
  const apiKey = keyInput.value.trim()
  button.disabled = true
  keyInput.disabled = true
  reply.value = ''
  status.textContent = 'Replying…'
  try {
    if (apiKey !== activeKey) {
      await agent?.close()
      agent = undefined
    }
    agent ??= await createFxEngine({
      apiKey: apiKey || 'demo', model,
      fetch(url, init) {
        if (apiKey) return fetch(url, init)
        const path = new URL(url).pathname
        return fetch(`/api/gateway?path=${encodeURIComponent(path)}`, init)
      },
    })
    activeKey = apiKey
    const turn = agent.prompt(new FormData(form).get('prompt'))
    for await (const event of turn) {
      if (event.type === 'text_delta') reply.value += event.delta
    }
    const { stopReason } = await turn.result
    status.textContent = stopReason === 'refused' ? 'Request failed. See the reply for details.' : 'Reply complete.'
  } catch (error) {
    status.textContent = error.message === 'HostStreamFailed'
      ? 'Unable to connect to AI Gateway. Check your key and connection.'
      : error.message
  } finally {
    button.disabled = false
    keyInput.disabled = false
  }
})

window.addEventListener('pagehide', () => { void agent?.close() })
button.disabled = !supportsJspi()
