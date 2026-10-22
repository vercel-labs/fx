<script setup>
import { readReply } from '../../shared/read-reply.mjs'

const prompt = ref('Explain Vue reactivity in two sentences.')
const reply = ref('')
const status = ref('')
const busy = ref(false)
const ready = ref(false)
onMounted(() => { ready.value = true })
useHead({ title: 'Nuxt agent · fx examples', htmlAttrs: { lang: 'en' } })

async function send() {
  busy.value = true
  reply.value = ''
  status.value = 'Replying…'
  try {
    const response = await fetch('/api/chat', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ prompt: prompt.value }),
    })
    if (!response.ok) throw new Error(response.status === 429 ? 'Request limit reached. Try again later.' : await response.text())
    for await (const text of readReply(response)) reply.value += text
    status.value = 'Reply complete.'
  } catch (error) {
    status.value = error.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <main>
    <h1>Nuxt agent</h1>
    <p>A native libfx agent in a Nitro route. Each request starts a new conversation.</p>
    <form @submit.prevent="send">
      <label for="prompt">Prompt</label><br>
      <textarea id="prompt" v-model="prompt" name="prompt" rows="3" cols="30" required maxlength="2000" /><br>
      <button :disabled="!ready || busy">Send</button>
    </form>
    <p role="status">{{ status }}</p>
    <label for="reply">Reply</label><br>
    <textarea id="reply" :value="reply" rows="12" cols="30" readonly />
    <p><a href="https://github.com/vercel-labs/fx/blob/390d74646f4fd211bdab8a03057cde6008417f86/examples/README.md#run-an-example">Code and setup</a></p>
  </main>
</template>
