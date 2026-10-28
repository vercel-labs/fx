'use client'

import { useEffect, useState } from 'react'
import { readReply } from '../../shared/read-reply.mjs'

export default function Page() {
  const [reply, setReply] = useState('')
  const [status, setStatus] = useState('')
  const [busy, setBusy] = useState(false)
  const [ready, setReady] = useState(false)
  useEffect(() => setReady(true), [])

  async function send(event) {
    event.preventDefault()
    const prompt = new FormData(event.currentTarget).get('prompt')
    setBusy(true)
    setReply('')
    setStatus('Replying…')
    try {
      const response = await fetch('/api/chat', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ prompt }),
      })
      if (!response.ok) throw new Error(response.status === 429 ? 'Request limit reached. Try again later.' : await response.text())
      for await (const text of readReply(response)) setReply((previous) => previous + text)
      setStatus('Reply complete.')
    } catch (error) {
      setStatus(error.message)
    } finally {
      setBusy(false)
    }
  }

  return <main>
    <h1>Next.js agent</h1>
    <p>A native libfx agent in an App Router route. Each request starts a new conversation.</p>
    <form onSubmit={send}>
      <label htmlFor="prompt">Prompt</label><br />
      <textarea id="prompt" name="prompt" rows={3} cols={30} required maxLength={2000} defaultValue="Explain server components in two sentences." /><br />
      <button disabled={!ready || busy}>Send</button>
    </form>
    <p role="status">{status}</p>
    <label htmlFor="reply">Reply</label><br />
    <textarea id="reply" rows={12} cols={30} readOnly value={reply} />
    <p><a href="https://github.com/vercel-labs/fx/blob/390d74646f4fd211bdab8a03057cde6008417f86/examples/README.md#run-an-example">Code and setup</a></p>
  </main>
}
