import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";
import { startBroker } from "./broker.mjs";

const token = "a".repeat(48);
const origin = "http://localhost:3000";
const sessionId = "owned-session";

async function connect(port, position = 0, view) {
  const socket = new WebSocket(`ws://127.0.0.1:${port}/${token}`, { origin });
  const messages = [];
  socket.on("message", (data) => messages.push(JSON.parse(data.toString())));
  await new Promise((resolve, reject) => { socket.once("open", resolve); socket.once("error", reject); });
  socket.send(JSON.stringify({ type: "attach", version: 1, sessionId, cursor: position, view }));
  return { socket, messages };
}

async function until(check) {
  for (let attempt = 0; attempt < 300; attempt++) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("Timed out awaiting native terminal output");
}

const transcript = (messages) => messages.filter((event) => event.type === "output").map((event) => Buffer.from(event.data, "base64").toString()).join("");

test("native PTY retains process across reconnect, resizes, interrupts, and authenticates", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  try {
    assert.equal((await fetch(`http://127.0.0.1:${broker.port}/wrong/health`)).status, 404);
    const denied = new WebSocket(`ws://127.0.0.1:${broker.port}/${token}`, { origin: "http://evil.example" });
    await new Promise((resolve) => denied.on("error", resolve));
    const first = await connect(broker.port);
    await until(() => first.messages.some((event) => event.type === "ready"));
    first.socket.send(JSON.stringify({ type: "input", data: "stty -echo\nMARKER=survived\nprintf 'pid:%s\\n' $$\n" }));
    await until(() => /pid:\d+/.test(transcript(first.messages)));
    const pid = transcript(first.messages).match(/pid:(\d+)/)[1];
    const position = first.messages.filter((event) => event.type === "output").at(-1).cursor;
    first.socket.close();
    await new Promise((resolve) => first.socket.once("close", resolve));
    const second = await connect(broker.port, position);
    await until(() => second.messages.some((event) => event.type === "ready"));
    second.socket.send(JSON.stringify({ type: "resize", cols: 91, rows: 31 }));
    second.socket.send(JSON.stringify({ type: "input", data: "printf '%s:%s\\n' \"$MARKER\" $$; stty size\n" }));
    await until(() => transcript(second.messages).includes(`survived:${pid}`) && transcript(second.messages).includes("31 91"));
    second.socket.send(JSON.stringify({ type: "input", data: "sleep 60\n" }));
    await new Promise((resolve) => setTimeout(resolve, 100));
    second.socket.send(JSON.stringify({ type: "interrupt" }));
    second.socket.send(JSON.stringify({ type: "input", data: "printf 'after-interrupt\\n'\n" }));
    await until(() => transcript(second.messages).includes("after-interrupt"));
    second.socket.close();
  } finally {
    await broker.close();
  }
});

test("interaction snapshots and actions use a separate inherited socket", async () => {
  const program = "import os,socket,json; s=socket.socket(fileno=int(os.environ['FX_INTERACTION_FD'])); f=s.makefile('r'); s.sendall(b'{\"type\":\"snapshot\",\"value\":\"initial\"}\\n'); a=json.loads(f.readline()); s.sendall((json.dumps({'type':'snapshot','value':a['text']})+'\\n').encode()); f.readline()";
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "python3", args: ["-c", program] });
  try {
    const first = await connect(broker.port);
    await until(() => first.messages.some((event) => event.snapshot?.value === "initial"));
    const other = await connect(broker.port);
    await until(() => other.messages.some((event) => event.type === "error"));
    assert.match(other.messages.find((event) => event.type === "error").message, /writer/);
    first.socket.send(JSON.stringify({ type: "interaction", action: { type: "input", text: "native-state" } }));
    await until(() => first.messages.some((event) => event.snapshot?.value === "native-state"));
    first.socket.close();
    await new Promise((resolve) => first.socket.once("close", resolve));
    const second = await connect(broker.port);
    await until(() => second.messages.some((event) => event.snapshot?.value === "native-state"));
    second.socket.close();
  } finally { await broker.close(); }
});

test("large paste does not prevent interrupt while foreground process ignores stdin", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
  try {
    const client = await connect(broker.port);
    await until(() => client.messages.some((event) => event.type === "ready"));
    client.socket.send(JSON.stringify({ type: "input", data: "stty -echo; sleep 60\n" }));
    await new Promise((resolve) => setTimeout(resolve, 100));
    client.socket.send(JSON.stringify({ type: "input", data: "x".repeat(16384) }));
    client.socket.send(JSON.stringify({ type: "interrupt" }));
    await new Promise((resolve) => setTimeout(resolve, 100));
    client.socket.send(JSON.stringify({ type: "input", data: "printf 'responsive\\n'\n" }));
    await until(() => transcript(client.messages).includes("responsive"));
    client.socket.close();
  } finally { await broker.close(); }
});

test("expired replay cursor fails instead of restarting or returning incomplete terminal bytes", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-i"], replayBytes: 256 });
  try {
    const first = await connect(broker.port);
    await until(() => first.messages.some((event) => event.type === "ready"));
    first.socket.send(JSON.stringify({ type: "input", encoding: "base64", data: Buffer.from("stty -echo; printf '%0500d\\n' 0\n").toString("base64") }));
    await until(() => transcript(first.messages).includes("0".repeat(400)));
    first.socket.send(JSON.stringify({ type: "input", data: "printf 'end-marker\\n'\n" }));
    await until(() => transcript(first.messages).includes("end-marker"));
    first.socket.close();
    await new Promise((resolve) => first.socket.once("close", resolve));
    const stale = await connect(broker.port, 0);
    await until(() => stale.messages.some((event) => event.type === "error"));
    assert.match(stale.messages.find((event) => event.type === "error").message, /cursor unavailable/);
    assert.equal(stale.messages.some((event) => event.type === "ready"), false);
  } finally { await broker.close(); }
});

test("HTML attachment receives native snapshots after byte replay expires, without ANSI output", async () => {
  const program = "import os,socket,time; s=socket.socket(fileno=int(os.environ['FX_INTERACTION_FD'])); s.sendall(b'{\"type\":\"snapshot\",\"value\":\"html-state\"}\\n'); print('x'*1000,flush=True); time.sleep(.1); print('tail',flush=True); s.recv(1000)";
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "python3", args: ["-c", program], replayBytes: 256 });
  try {
    await new Promise((resolve) => setTimeout(resolve, 200));
    const client = await connect(broker.port, 0, "html");
    await until(() => client.messages.some((event) => event.snapshot?.value === "html-state"));
    assert.equal(client.messages.some((event) => event.type === "output"), false);
    assert.equal(client.messages.some((event) => event.type === "ready"), true);
    client.socket.close();
  } finally { await broker.close(); }
});

test("helper rejects rapid queue overflow without terminating the native process", async () => {
  const child = spawn("python3", [fileURLToPath(new URL("native-pty.py", import.meta.url))]);
  const messages = [];
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => messages.push(JSON.parse(line)));
  child.stderr.resume();
  const exited = new Promise((resolve) => child.once("close", resolve));
  const send = (message) => child.stdin.write(JSON.stringify(message) + "\n");
  try {
    send({ cwd: "/tmp", command: "/bin/sh", args: ["-i"] });
    await until(() => messages.some((event) => event.type === "started"));
    const pid = messages.find((event) => event.type === "started").pid;
    send({ type: "input", writerId: 1, data: "stty -echo; printf 'waiting\\n'; sleep 60\n" });
    await until(() => transcript(messages).includes("\r\nwaiting\r\n"));
    child.stdin.write(JSON.stringify({ type: "input", writerId: 1, data: "x".repeat(65536) }) + "\n" + JSON.stringify({ type: "input", writerId: 1, data: "y".repeat(65536) }) + "\n");
    await until(() => messages.some((event) => event.type === "input_rejected"));
    assert.equal(messages.some((event) => event.type === "exit"), false);
    process.kill(pid, 0);
    send({ type: "interrupt", writerId: 2 });
    await new Promise((resolve) => setTimeout(resolve, 100));
    send({ type: "input", writerId: 2, data: "printf 'still-alive:%s\\n' $$\n" });
    await until(() => transcript(messages).includes(`still-alive:${pid}`));
  } finally {
    child.stdin.end(JSON.stringify({ type: "close" }) + "\n");
    await exited;
    lines.close();
  }
});

test("helper exits on initial EOF and broker reports executable failure as unhealthy", async () => {
  const child = spawn("python3", [fileURLToPath(new URL("native-pty.py", import.meta.url))]);
  const exited = new Promise((resolve) => child.once("close", resolve));
  child.stdin.end();
  assert.equal(await exited, 0);
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/nonexistent/fx" });
  try {
    const client = await connect(broker.port);
    await until(() => client.messages.some((event) => event.type === "exit"));
    const event = client.messages.find((message) => message.type === "exit");
    assert.ok(event.code >= 1 && event.code <= 255);
    assert.equal((await fetch(`http://127.0.0.1:${broker.port}/${token}/health`)).status, 503);
    client.socket.close();
  } finally { await broker.close(); }
});

test("native process has terminal dimensions before executing its first statement", async () => {
  const broker = await startBroker({ token, origin, sessionId, cwd: "/tmp", command: "/bin/sh", args: ["-c", "stty size"] });
  try {
    const client = await connect(broker.port);
    await until(() => client.messages.some((event) => event.type === "exit"));
    assert.match(transcript(client.messages), /32 100/);
    assert.equal(client.messages.find((event) => event.type === "exit").code, 0);
    client.socket.close();
  } finally { await broker.close(); }
});
