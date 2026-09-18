import assert from 'node:assert/strict';
import { createFxTerminal as createBrowserTerminal, createFxView, xtermAdapter } from '../browser.js';
import { createFxTerminal as createNodeTerminal } from '../node.js';

class Socket extends EventTarget {
  static instances = [];
  readyState = 0;
  bufferedAmount = 0;
  sent = [];
  constructor(url) { super(); this.url = url; Socket.instances.push(this); }
  open() { this.readyState = 1; this.dispatchEvent(new Event('open')); }
  receive(message) { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(message) })); }
  send(message) { this.sent.push(JSON.parse(message)); }
  close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
}

function fixture(extra = {}) {
  const handlers = new Map();
  const released = [];
  const output = [];
  const terminal = {
    cols: 80, rows: 24,
    write(bytes) { output.push(new TextDecoder().decode(bytes)); },
    onData(fn) { handlers.set('data', fn); return () => released.push('data'); },
    onKeyData(fn) { handlers.set('key', fn); return () => released.push('key'); },
    onResize(fn) { handlers.set('resize', fn); return () => released.push('resize'); },
    ...extra,
  };
  return { terminal, output, handlers, released };
}
const remote = { url: 'wss://example.test/terminal', sessionId: 'session', WebSocket: Socket };
const tick = () => new Promise((resolve) => setImmediate(resolve));
function ready(socket, cursor = 0) {
  socket.open();
  socket.receive({ type: 'ready', version: 1, sessionId: 'session', cursor });
}

for (const create of [createBrowserTerminal, createNodeTerminal]) {
  const f = fixture();
  const runtime = await create({ terminal: f.terminal, remote, wasm: '/missing.wasm', backend: 'native' });
  const socket = Socket.instances.at(-1);
  f.handlers.get('data')('before-ready');
  ready(socket);
  await runtime.interactive;
  assert.deepEqual(socket.sent, [
    { type: 'attach', version: 1, sessionId: 'session', cursor: 0 },
    { type: 'resize', cols: 80, rows: 24 },
    { type: 'input', data: 'before-ready' },
  ]);
  socket.receive({ type: 'output', cursor: 1, data: btoa('hello') });
  socket.receive({ type: 'output', cursor: 2, data: btoa(' world') });
  await tick();
  assert.equal(f.output.join(''), 'hello world');
  assert.equal(runtime.cursor, 2);
  f.terminal.cols = 100;
  f.handlers.get('resize')();
  runtime.interrupt();
  assert.deepEqual(socket.sent.slice(-2), [{ type: 'resize', cols: 100, rows: 24 }, { type: 'interrupt' }]);
  runtime.abort();
  assert.equal(await runtime.exited, 130);
  runtime.abort();
  assert.deepEqual(f.released.sort(), ['data', 'key', 'resize']);
  assert.equal(socket.sent.filter((message) => message.type === 'interrupt').length, 1, 'detach does not interrupt');
}

{
  const f = fixture();
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote: { ...remote, cursor: 3 } });
  const socket = Socket.instances.at(-1);
  ready(socket, 3);
  await runtime.interactive;
  socket.receive({ type: 'output', cursor: 4, data: btoa('continued') });
  socket.receive({ type: 'exit', code: 0 });
  assert.equal(await runtime.exited, 0);
  assert.deepEqual(f.output, ['continued']);
  assert.equal(runtime.cursor, 4);
}

for (const invalid of [
  { type: 'ready', version: 2, sessionId: 'session', cursor: 0 },
  { type: 'ready', version: 1, sessionId: 'other', cursor: 0 },
  { type: 'output', cursor: 1, data: btoa('too early') },
]) {
  const f = fixture();
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  Socket.instances.at(-1).receive(invalid);
  await assert.rejects(runtime.interactive);
  assert.equal(await runtime.exited, 255);
  assert.equal(f.output.length, 0);
}

for (const invalid of [
  { type: 'output', cursor: 2, data: btoa('gap') },
  { type: 'output', cursor: 1, data: '!!!!' },
  { type: 'exit', code: -1 },
]) {
  const f = fixture();
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  const socket = Socket.instances.at(-1);
  ready(socket);
  await runtime.interactive;
  socket.receive(invalid);
  assert.equal(await runtime.exited, 255);
  assert.equal(runtime.cursor, 0);
}

{
  let release;
  const f = fixture({ write: () => new Promise((resolve) => { release = resolve; }) });
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  const socket = Socket.instances.at(-1);
  ready(socket);
  await runtime.interactive;
  socket.receive({ type: 'output', cursor: 1, data: btoa('pending') });
  await tick();
  assert.equal(runtime.cursor, 0, 'cursor advances after renderer drains');
  release();
  await tick();
  assert.equal(runtime.cursor, 1);
  socket.close();
  assert.equal(await runtime.exited, 255);
  assert.equal(socket.sent.filter((message) => message.type === 'input').length, 0);
}

{
  const f = fixture({ drain: async () => { throw new Error('render failed'); } });
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  ready(Socket.instances.at(-1));
  await assert.rejects(runtime.interactive, /render failed/);
  assert.equal(await runtime.exited, 255);
}

{
  const f = fixture();
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote: { ...remote, connectTimeoutMs: 5 } });
  await assert.rejects(runtime.interactive, /timed out/);
  assert.equal(await runtime.exited, 255);
  assert.deepEqual(f.released.sort(), ['data', 'key', 'resize']);
}

{
  const f = fixture();
  const controller = new AbortController();
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote: { ...remote, signal: controller.signal } });
  controller.abort();
  await assert.rejects(runtime.interactive);
  assert.equal(await runtime.exited, 130);
}

await assert.rejects(createBrowserTerminal({ terminal: fixture().terminal, remote: { ...remote, url: 'https://example.test' } }));
await assert.rejects(createBrowserTerminal({ terminal: fixture().terminal, remote: { ...remote, cursor: -1 } }));
{
  let release;
  const f = fixture({ drain: () => new Promise((resolve) => { release = resolve; }) });
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  ready(Socket.instances.at(-1));
  await tick();
  runtime.abort();
  await assert.rejects(runtime.interactive);
  release();
  assert.equal(await runtime.exited, 130);
  assert.equal(runtime.cursor, 0);
}

{
  let release;
  const f = fixture({ drain: () => new Promise((resolve) => { release = resolve; }) });
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  const socket = Socket.instances.at(-1);
  ready(socket);
  await tick();
  socket.close();
  release();
  await assert.rejects(runtime.interactive);
  assert.equal(await runtime.exited, 255);
}

{
  const f = fixture({ write: async () => { throw new Error('write failed'); } });
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  const socket = Socket.instances.at(-1);
  ready(socket);
  await runtime.interactive;
  socket.receive({ type: 'output', cursor: 1, data: btoa('unseen') });
  assert.equal(await runtime.exited, 255);
  assert.equal(runtime.cursor, 0);
}

{
  const f = fixture();
  const runtime = await createBrowserTerminal({ terminal: f.terminal, remote });
  const socket = Socket.instances.at(-1);
  ready(socket);
  await runtime.interactive;
  const paste = '\x1b'.repeat(64 * 1024);
  runtime.write(paste);
  assert.equal(socket.sent.at(-1).data, paste);
  runtime.write(new Uint8Array([0, 128, 255]));
  assert.deepEqual(socket.sent.at(-1), { type: 'input', encoding: 'base64', data: 'AID/' });
  assert.throws(() => runtime.write('x'.repeat(64 * 1024 + 1)), /65536/);
  runtime.abort();
}

{
  let complete;
  const values = [];
  const term = { write(bytes, callback) { values.push(bytes); complete = callback; } };
  const adapter = xtermAdapter(term);
  const first = new Uint8Array([0xf0, 0x9f]);
  adapter.write(first);
  assert.equal(values[0], first, 'xterm receives raw split UTF-8 bytes');
  let drained = false;
  const pending = adapter.drain().then(() => { drained = true; });
  await tick();
  assert.equal(drained, false);
  complete();
  await pending;
  assert.equal(drained, true);
}

{
  const snapshots = [];
  const runtime = await createFxView({ remote, onSnapshot: (snapshot) => snapshots.push(snapshot) });
  const socket = Socket.instances.at(-1);
  ready(socket);
  let interactive = false;
  runtime.interactive.then(() => { interactive = true; });
  await tick();
  assert.equal(interactive, false, 'HTML waits for native semantic state');
  assert.deepEqual(socket.sent, [{ type: 'attach', version: 1, sessionId: 'session', cursor: 0, view: 'html' }]);
  const snapshot = { type: 'snapshot', version: 1, composer: { text: '' }, commands: [] };
  socket.receive({ type: 'interaction', snapshot });
  await runtime.interactive;
  assert.deepEqual(snapshots, [snapshot]);
  runtime.interact({ type: 'input', text: '/model' });
  assert.deepEqual(socket.sent.at(-1), { type: 'interaction', action: { type: 'input', text: '/model' } });
  runtime.abort();
  assert.equal(await runtime.exited, 130);
}

console.log('remote terminal lifecycle, replay, cancellation, validation, and entry-point tests passed');
