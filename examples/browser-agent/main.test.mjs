import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import { createContext, SourceTextModule, SyntheticModule } from 'node:vm'

const source = await readFile(new URL('./main.js', import.meta.url), 'utf8')

async function page({ key = '', fail = false, stopReason = 'stop', duringFetch } = {}) {
  const elements = Object.fromEntries(['form', 'button', '#reply', '#status', '#api-key'].map(
    (name) => [name, { value: '', textContent: '', disabled: false }],
  ))
  elements['#api-key'].value = key
  let submit
  elements.form.addEventListener = (name, handler) => { if (name === 'submit') submit = handler }
  const calls = []
  const agents = []
  const storage = { setItem() { assert.fail('Keys must not be saved') } }
  const context = createContext({
    URL,
    document: { querySelector: (name) => elements[name] },
    window: { addEventListener() {} },
    localStorage: storage,
    sessionStorage: storage,
    FormData: class { get() { return 'hello' } },
    fetch: async (url, init) => {
      calls.push({ url, init })
      duringFetch?.(elements)
      if (fail) throw new Error(typeof fail === 'string' ? fail : 'Invalid key')
      return 'hello'
    },
  })
  const sdk = new SyntheticModule(['createFxEngine', 'supportsJspi'], function () {
    this.setExport('supportsJspi', () => true)
    this.setExport('createFxEngine', async (options) => {
      const agent = {
        options, closed: false,
        async close() { this.closed = true },
        prompt() {
          return {
            result: Promise.resolve({ stopReason }),
            async *[Symbol.asyncIterator]() {
              await options.fetch('https://ai-gateway.vercel.sh/v4/ai/language-model', {
                method: 'POST', headers: { authorization: `Bearer ${options.apiKey}` },
              })
              yield { type: 'text_delta', delta: 'hello' }
            },
          }
        },
      }
      agents.push(agent)
      return agent
    })
  }, { context })
  const model = new SyntheticModule(['model'], function () {
    this.setExport('model', 'test/model')
  }, { context })
  const module = new SourceTextModule(source, { context })
  await module.link((name) => name === 'libfx/browser' ? sdk : model)
  await module.evaluate()
  return { elements, calls, agents, submit: () => submit({ preventDefault() {} }) }
}

test('a blank key keeps the free proxy and reuses the conversation', async () => {
  const app = await page()
  await app.submit()
  await app.submit()
  assert.equal(app.agents.length, 1)
  assert.equal(app.agents[0].options.apiKey, 'demo')
  assert.equal(app.calls[0].url, '/api/gateway?path=%2Fv4%2Fai%2Flanguage-model')
  assert.equal(app.elements['#reply'].value, 'hello')
})

test('an entered key goes directly to Gateway without touching the proxy', async () => {
  const app = await page({ key: '  test-user-key  ' })
  await app.submit()
  assert.equal(app.agents[0].options.apiKey, 'test-user-key')
  assert.equal(app.calls.length, 1)
  assert.equal(app.calls[0].url, 'https://ai-gateway.vercel.sh/v4/ai/language-model')
  assert.equal(app.calls[0].init.headers.authorization, 'Bearer test-user-key')
})

test('changing or clearing a key closes the old conversation and changes the route', async () => {
  const app = await page()
  await app.submit()
  app.elements['#api-key'].value = 'test-user-key'
  await app.submit()
  app.elements['#api-key'].value = ''
  await app.submit()
  assert.equal(app.agents.length, 3)
  assert.equal(app.agents[0].closed, true)
  assert.equal(app.agents[1].closed, true)
  assert.equal(app.agents[2].closed, false)
  assert.equal(app.calls[1].url, 'https://ai-gateway.vercel.sh/v4/ai/language-model')
  assert.equal(app.calls[2].url, '/api/gateway?path=%2Fv4%2Fai%2Flanguage-model')
})

test('a rejected personal key never falls back to the free proxy', async () => {
  const app = await page({ key: 'invalid-key', fail: true })
  await app.submit()
  assert.equal(app.calls.length, 1)
  assert.equal(app.calls[0].url, 'https://ai-gateway.vercel.sh/v4/ai/language-model')
  assert.equal(app.elements['#status'].textContent, 'Invalid key')
  assert.equal(app.elements.button.disabled, false)
  assert.equal(app.elements['#api-key'].disabled, false)
})

test('the key field is locked during the request and restored afterward', async () => {
  const app = await page({ key: 'test-user-key', duringFetch(elements) {
    assert.equal(elements['#api-key'].disabled, true)
    assert.equal(elements.button.disabled, true)
  } })
  await app.submit()
  assert.equal(app.elements['#api-key'].disabled, false)
  assert.equal(app.elements['#reply'].value, 'hello')
})

test('a refused request is not reported as a successful reply', async () => {
  const app = await page({ key: 'test-user-key', stopReason: 'refused' })
  await app.submit()
  assert.equal(app.elements['#status'].textContent, 'Request failed. See the reply for details.')
})

test('a browser transport failure explains what the visitor can try', async () => {
  const app = await page({ key: 'test-user-key', fail: 'HostStreamFailed' })
  await app.submit()
  assert.equal(app.elements['#status'].textContent, 'Unable to connect to AI Gateway. Check your key and connection.')
})
