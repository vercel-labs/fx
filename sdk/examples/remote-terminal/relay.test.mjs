import test from "node:test";
import assert from "node:assert/strict";
import { connect as connectSocket } from "node:net";
import { createServer } from "node:http";
import { WebSocket } from "ws";
import { startBroker } from "./broker.mjs";
import { createTerminalRelay } from "./relay.mjs";

const origin = "http://127.0.0.1:3110";
const token = "b".repeat(48);
const sessionId = "authorized-session";
const transcript = (messages) => messages.filter((event) => event.type === "output").map((event) => Buffer.from(event.data, "base64").toString()).join("");
async function until(check) {
  for (let attempt = 0; attempt < 300; attempt++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("Timed out awaiting relay");
}

async function client(url, { cookie = "session=owned", requestOrigin = origin, position = 0 } = {}) {
  const socket = new WebSocket(url, { origin: requestOrigin, headers: { cookie } });
  const messages = [];
  socket.on("message", (data) => messages.push(JSON.parse(data.toString())));
  await new Promise((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
  socket.send(JSON.stringify({ type: "attach", version: 1, sessionId, cursor: position }));
  return { socket, messages };
}

async function app(broker, limits = {}) {
  let authorized = 0;
  const relay = createTerminalRelay({ origin, ...limits, resolveSession: async (request) => {
    authorized++;
    return request.headers.cookie === "session=owned" ? { url: `ws://127.0.0.1:${broker.port}/${token}`, sessionId } : null;
  } });
  const server = createServer();
  server.on("upgrade", relay.upgrade);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { url: `ws://127.0.0.1:${server.address().port}/api/fx`, authorized: () => authorized, async close() { relay.close(); await new Promise((resolve) => server.close(resolve)); } };
}

test("relay requires app auth and exact origin; reconnect keeps native process and query cannot choose target", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  const relay = await app(broker);
  try {
    await assert.rejects(client(relay.url, { cookie: "session=other" }), /403/);
    const before = relay.authorized();
    await assert.rejects(client(relay.url, { requestOrigin: "http://evil.example" }), /403/);
    assert.equal(relay.authorized(), before);
    const first = await client(relay.url + "?target=ws://evil.example");
    await until(() => first.messages.some((event) => event.type === "ready"));
    first.socket.send(JSON.stringify({ type: "input", data: "stty -echo; printf 'owned-pid:%s\\n' $$\n" }));
    await until(() => /owned-pid:\d+/.test(transcript(first.messages)));
    const pid = transcript(first.messages).match(/owned-pid:(\d+)/)[1];
    const position = first.messages.filter((event) => event.type === "output").at(-1).cursor;
    first.socket.close();
    await new Promise((resolve) => first.socket.once("close", resolve));
    await new Promise((resolve) => setTimeout(resolve, 30));
    const second = await client(relay.url, { position });
    await until(() => second.messages.some((event) => event.type === "ready"));
    second.socket.send(JSON.stringify({ type: "input", data: "printf 'same-pid:%s\\n' $$\n" }));
    await until(() => transcript(second.messages).includes(`same-pid:${pid}`));
    second.socket.close();
  } finally { await relay.close(); await broker.close(); }
});

test("relay bounds messages and closes only attachment on overflow", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  const relay = await app(broker, { maxPayloadBytes: 512, maxBufferedBytes: 2048 });
  try {
    const first = await client(relay.url);
    await until(() => first.messages.some((event) => event.type === "ready"));
    await until(() => first.messages.some((event) => event.type === "output"));
    const closed = new Promise((resolve) => first.socket.once("close", resolve));
    first.socket.send(JSON.stringify({ type: "input", data: "x".repeat(1000) }));
    await closed;
    assert.equal((await fetch(`http://127.0.0.1:${broker.port}/${token}/health`)).status, 200);
  } finally { await relay.close(); await broker.close(); }
});

test("malformed upgrade is rejected before authentication or opening a native connection", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  const relay = await app(broker);
  try {
    const url = new URL(relay.url);
    const response = await new Promise((resolve, reject) => {
      const socket = connectSocket({ host: url.hostname, port: Number(url.port) });
      let body = "";
      socket.on("data", (data) => { body += data; });
      socket.once("error", reject);
      socket.once("end", () => resolve(body));
      socket.once("connect", () => socket.write(`GET /api/fx HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: ${origin}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: invalid\r\n\r\n`));
    });
    assert.match(response, /403/);
    assert.equal(relay.authorized(), 0);
  } finally { await relay.close(); await broker.close(); }
});

test("send-buffer bound rejects a frame before forwarding it", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  const relay = await app(broker, { maxPayloadBytes: 2048, maxBufferedBytes: 256 });
  try {
    const first = await client(relay.url);
    await until(() => first.messages.some((event) => event.type === "output"));
    const closed = new Promise((resolve) => first.socket.once("close", resolve));
    first.socket.send(JSON.stringify({ type: "input", data: "x".repeat(500) }));
    await closed;
    assert.equal((await fetch(`http://127.0.0.1:${broker.port}/${token}/health`)).status, 200);
  } finally { await relay.close(); await broker.close(); }
});

test("invalid subprotocol upgrade cleans up its upstream without an unhandled error", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  const relay = await app(broker);
  try {
    const url = new URL(relay.url);
    const response = await new Promise((resolve, reject) => {
      const socket = connectSocket({ host: url.hostname, port: Number(url.port) });
      let body = "";
      socket.on("data", (data) => { body += data; });
      socket.once("error", reject);
      socket.once("end", () => resolve(body));
      socket.once("connect", () => socket.write(`GET /api/fx HTTP/1.1\r\nHost: localhost\r\nCookie: session=owned\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: ${origin}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: invalid protocol\r\n\r\n`));
    });
    assert.match(response, /400/);
    const valid = await client(relay.url);
    await until(() => valid.messages.some((event) => event.type === "ready"));
    valid.socket.close();
  } finally { await relay.close(); await broker.close(); }
});
