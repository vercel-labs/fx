import { afterEach, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  heldFakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const children: ChildProcess[] = [];
const cleanups: Array<() => void> = [];

afterEach(async () => {
  const running = children.splice(0);
  for (const child of running) if (child.exitCode === null) child.kill("SIGTERM");
  await Bun.sleep(100);
  for (const child of running) if (child.exitCode === null) child.kill("SIGKILL");
  for (const cleanup of cleanups.splice(0)) cleanup();
});

function isolatedRoot(prefix: string) {
  // macOS reports /var/... for TMPDIR even though /var is a symlink. The Unix
  // listener deliberately rejects every symlink in its secure parent walk.
  const root = mkdtempSync(join(realpathSync(tmpdir()), prefix));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  chmodSync(join(home, ".fx"), 0o700);
  mkdirSync(workspace);
  cleanups.push(() => rmSync(root, { recursive: true, force: true }));
  return { root, home, workspace };
}

function gatewayEnv(root: ReturnType<typeof isolatedRoot>, gateway: ReturnType<typeof startFakeGateway>) {
  return {
    ...process.env,
    HOME: root.home,
    AI_GATEWAY_API_KEY: "fake-remote-key",
    VERCEL_OIDC_TOKEN: "",
    FX_GATEWAY_BASE_URL: gateway.baseUrl,
    FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_AUTO_UPGRADE: "0",
    NO_COLOR: "1",
  };
}

async function createSession(cwd: string, env: NodeJS.ProcessEnv): Promise<string> {
  const proc = spawn(FX_BIN, ["acp"], { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
  children.push(proc);
  let buffer = "";
  let sessionId = "";
  const finished = new Promise<string>((resolve, reject) => {
    proc.stdout!.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.id === 1) {
          proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd, mcpServers: [] } }) + "\n");
        } else if (message.id === 2) {
          sessionId = message.result.sessionId;
          proc.stdin!.end();
        }
      }
    });
    proc.on("close", (code) => sessionId ? resolve(sessionId) : reject(new Error(`ACP create failed ${code}`)));
  });
  proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } }) + "\n");
  return await finished;
}

async function attemptAcpLoad(cwd: string, env: NodeJS.ProcessEnv, sessionId: string): Promise<any> {
  const proc = spawn(FX_BIN, ["acp"], { cwd, env, stdio: ["pipe", "pipe", "pipe"] });
  children.push(proc);
  let buffer = "";
  const result = new Promise<any>((resolve, reject) => {
    proc.stdout!.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line) continue;
        const message = JSON.parse(line);
        if (message.id === 1) {
          proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "session/load", params: { sessionId, mcpServers: [] } }) + "\n");
        } else if (message.id === 2) {
          proc.stdin!.end();
          resolve(message);
        }
      }
    });
    proc.on("error", reject);
  });
  proc.stdin!.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } }) + "\n");
  return await result;
}

class RpcClient {
  private socket: Socket;
  private buffer = "";
  private messages: any[] = [];
  private waiters: Array<() => void> = [];
  private nextId = 1;

  private constructor(socket: Socket) {
    this.socket = socket;
    socket.on("data", (chunk) => {
      this.buffer += chunk.toString();
      const lines = this.buffer.split("\n");
      this.buffer = lines.pop() ?? "";
      for (const line of lines) if (line) this.messages.push(JSON.parse(line));
      for (const wake of this.waiters.splice(0)) wake();
    });
    socket.on("close", () => { for (const wake of this.waiters.splice(0)) wake(); });
  }

  static async connect(path: string): Promise<RpcClient> {
    const socket = createConnection(path);
    await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
    return new RpcClient(socket);
  }

  send(method: string, params: object): number {
    const id = this.nextId++;
    this.socket.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return id;
  }

  async request(method: string, params: object): Promise<any> {
    const id = this.send(method, params);
    return await this.waitFor((message) => message.id === id);
  }

  async waitFor(predicate: (message: any) => boolean, timeout = TIMEOUT): Promise<any> {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const index = this.messages.findIndex(predicate);
      if (index >= 0) return this.messages.splice(index, 1)[0];
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, Math.min(25, Math.max(1, deadline - Date.now())));
        this.waiters.push(() => { clearTimeout(timer); resolve(); });
      });
    }
    throw new Error("remote attach message timeout");
  }

  drain(): any[] { return this.messages.splice(0); }
  close(): void { this.socket.destroy(); }
}

async function waitFor(condition: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (condition()) return;
    await Bun.sleep(20);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

async function startServer(root: ReturnType<typeof isolatedRoot>, env: NodeJS.ProcessEnv) {
  const socket = join(root.root, "agent.sock");
  const proc = spawn(FX_BIN, ["serve", "--listen", `unix://${socket}`], {
    cwd: root.workspace,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(proc);
  let stdout = "";
  let stderr = "";
  proc.stdout!.on("data", (chunk) => stdout += chunk.toString());
  proc.stderr!.on("data", (chunk) => stderr += chunk.toString());
  await waitFor(() => {
    if (proc.exitCode !== null || proc.signalCode !== null) {
      throw new Error(`fx serve exited code=${proc.exitCode} signal=${proc.signalCode}\nstdout:\n${stdout}\nstderr:\n${stderr}`);
    }
    return existsSync(socket) && stdout.includes("fx serve: listening");
  }, "serve socket").catch((cause) => {
    throw new Error(`${cause instanceof Error ? cause.message : cause}\nstdout:\n${stdout}\nstderr:\n${stderr}`);
  });
  return { socket, proc, stdout: () => stdout, stderr: () => stderr };
}

async function attach(path: string, sessionId: string, role: "controller" | "observer") {
  const client = await RpcClient.connect(path);
  const initialized = (await client.request("initialize", { protocolVersion: 1 })).result;
  expect(initialized._meta.fx.remoteAttach).toBe(true);
  expect(initialized.agentCapabilities.promptCapabilities.embeddedContext).toBe(true);
  expect(initialized.agentCapabilities.mcpCapabilities.http).toBe(true);
  expect(initialized.agentCapabilities.sessionCapabilities.resume).toEqual({});
  expect(typeof initialized.agentInfo.version).toBe("string");
  expect(initialized.authMethods).toEqual([]);
  const response = await client.request("fx/attach", { sessionId, role });
  expect(response.error).toBeUndefined();
  expect(response.result.snapshot.snapshotId).toBe(response.result.attachmentId);
  return { client, ...response.result };
}

function mutation(attachment: any) {
  return { attachmentId: attachment.attachmentId, controlEpoch: attachment.controlEpoch };
}

function eventMethod(message: any): string | undefined {
  return message.method === "fx/event" ? message.params?.event?.method : undefined;
}

test("semantic attach detaches without aborting and reconciles idempotently", async () => {
  const root = isolatedRoot("fx-remote-lifecycle-");
  const held = heldFakeGatewayFinalText("REMOTE_PARTIAL_RUNNING\n\n");
  const heldAbort = heldFakeGatewayFinalText();
  cleanups.push(() => held.dispose());
  cleanups.push(() => heldAbort.dispose());
  const gateway = startFakeGateway([() => held.response, () => heldAbort.response]);
  cleanups.push(() => gateway.stop());
  const env = gatewayEnv(root, gateway);
  const sessionId = await createSession(root.workspace, env);
  const server = await startServer(root, env);

  const controller = await attach(server.socket, sessionId, "controller");
  const malformedAttachClient = await RpcClient.connect(server.socket);
  await malformedAttachClient.request("initialize", { protocolVersion: 1 });
  const malformedAttach = await malformedAttachClient.request("fx/attach", {});
  expect(malformedAttach.error.message).toContain("Invalid mutation");
  const recoveredAttach = await malformedAttachClient.request("fx/attach", { sessionId, role: "observer" });
  expect(recoveredAttach.error).toBeUndefined();
  malformedAttachClient.close();
  const observer = await attach(server.socket, sessionId, "observer");
  const malformedInspect = await controller.client.request("fx/operation/inspect", {});
  expect(malformedInspect.error.message).toContain("Invalid mutation");
  const afterMalformed = await controller.client.request("fx/status", {});
  expect(afterMalformed.result.attachmentId).toBe(controller.attachmentId);
  const competingLoad = await attemptAcpLoad(root.workspace, env, sessionId);
  expect(competingLoad.error.message).toContain("busy");
  const duplicateServer = spawn(FX_BIN, ["serve", "--listen", `unix://${server.socket}`], {
    cwd: root.workspace,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const duplicateCode = await new Promise<number | null>((resolve) => duplicateServer.on("close", resolve));
  expect(duplicateCode).not.toBe(0);
  const beforeConfig = (await attach(server.socket, sessionId, "observer"));
  const initialMode = beforeConfig.snapshot.configuration.mode;
  beforeConfig.client.close();
  const rejectedConfig = await controller.client.request("fx/configure", {
    ...mutation(controller), kind: "mode", value: "invalid-remote-mode",
  });
  expect(rejectedConfig.error.message).toContain("Invalid configuration");
  const afterRejectedConfig = await attach(server.socket, sessionId, "observer");
  expect(afterRejectedConfig.snapshot.configuration.mode).toBe(initialMode);
  afterRejectedConfig.client.close();
  const configured = await controller.client.request("fx/configure", {
    ...mutation(controller), kind: "mode", value: "ask",
  });
  expect(configured.result.accepted).toBe(true);
  const prompt = [{ type: "text", text: "Continue \u001b[31mwhile detached" }];
  const accepted = await controller.client.request("fx/prompt", {
    ...mutation(controller), operationId: "operation-detach-1", prompt,
  });
  expect(accepted.result.operation.state).toBe("running");
  await waitFor(() => gateway.requestCount() === 1, "first provider request");
  await Bun.sleep(500);
  const duringRun = await attach(server.socket, sessionId, "observer");
  expect(duringRun.snapshot.runState).toBe("running");
  expect(duringRun.snapshot.assistantPartial).toContain("REMOTE_PARTIAL_RUNNING");

  const concurrent = await controller.client.request("fx/prompt", {
    ...mutation(controller), operationId: "operation-concurrent-2",
    prompt: [{ type: "text", text: "Must be rejected while first runs" }],
  });
  expect(concurrent.error.message).toContain("active");
  const stillRunning = await controller.client.request("fx/operation/inspect", { operationId: "operation-detach-1" });
  expect(stillRunning.result.state).toBe("running");
  const busyConfiguration = await controller.client.request("fx/configure", {
    ...mutation(controller), kind: "mode", value: "ask",
  });
  expect(busyConfiguration.error.message).toContain("idle session");

  const replayed = await controller.client.request("fx/prompt", {
    ...mutation(controller), operationId: "operation-detach-1", prompt,
  });
  expect(replayed.result.replayed).toBe(true);
  expect(gateway.requestCount()).toBe(1);
  const conflict = await controller.client.request("fx/prompt", {
    ...mutation(controller), operationId: "operation-detach-1", prompt: [{ type: "text", text: "different" }],
  });
  expect(conflict.error.message).toContain("conflicts");

  const observerMutation = await observer.client.request("fx/abort", mutation(observer));
  expect(observerMutation.error.message).toContain("Controller required");
  for (const [method, extra] of [
    ["fx/prompt", { operationId: "observer-op", prompt: [{ type: "text", text: "no" }] }],
    ["fx/respond", { interactionId: 1, result: {} }],
    ["fx/configure", { kind: "mode", value: "ask" }],
  ] as const) {
    const rejected = await observer.client.request(method, { ...mutation(observer), ...extra });
    expect(rejected.error.message).toContain("Controller required");
  }
  const oldIdentity = mutation(controller);
  controller.client.close();
  held.release("\u001b[31mREMOTE_CONTINUED_AFTER_DETACH\u001b[0m");
  const completion = await observer.client.waitFor((message: any) =>
    eventMethod(message) === "fx/operation" && message.params.event.params?.state === "completed"
  );
  expect(completion.params.event.params.operationId).toBe("operation-detach-1");
  expect(gateway.requestCount()).toBe(1);
  const observedEvents = [...observer.client.drain(), completion]
    .filter((message: any) => message.method === "fx/event");
  const revisions = observedEvents.map((message: any) => message.params.revision as number);
  expect(new Set(revisions).size).toBe(revisions.length);
  expect(revisions.every((revision) => revision > 0)).toBe(true);
  expect(JSON.stringify(observedEvents)).not.toContain("\u001b");
  const runStates = observedEvents
    .filter((message: any) => eventMethod(message) === "fx/run_state")
    .map((message: any) => message.params.event.params.state);
  expect(runStates).toContain("running");
  expect(runStates).toContain("idle");

  let replacement: Awaited<ReturnType<typeof attach>> | undefined;
  for (let attempt = 0; attempt < 50 && !replacement; attempt++) {
    try { replacement = await attach(server.socket, sessionId, "controller"); }
    catch { await Bun.sleep(20); }
  }
  expect(replacement).toBeDefined();
  const snapshot = replacement!.snapshot;
  expect(snapshot.configuration.mode).toBe("ask");
  expect(snapshot.history.some((item: any) => item.role === "user" && item.text === "Continue [31mwhile detached")).toBe(true);
  expect(snapshot.history.some((item: any) => item.role === "assistant" && item.text.includes("REMOTE_PARTIAL_RUNNING"))).toBe(true);
  expect(snapshot.history.some((item: any) => item.role === "assistant" && item.text.includes("REMOTE_CONTINUED_AFTER_DETACH"))).toBe(true);
  expect(JSON.stringify(snapshot)).not.toContain("\\u001b");
  const inspected = await replacement!.client.request("fx/operation/inspect", { operationId: "operation-detach-1" });
  expect(inspected.result.state).toBe("completed");
  const reconciled = await replacement!.client.request("fx/prompt", {
    ...mutation(replacement), operationId: "operation-detach-1", prompt,
  });
  expect(reconciled.result.replayed).toBe(true);
  expect(reconciled.result.operation.state).toBe("completed");
  expect(gateway.requestCount()).toBe(1);

  const abortPrompt = [{ type: "text", text: "Cancel this remote operation" }];
  await replacement!.client.request("fx/prompt", {
    ...mutation(replacement), operationId: "operation-abort-1", prompt: abortPrompt,
  });
  await waitFor(() => gateway.requestCount() === 2, "abort provider request");
  const aborted = await replacement!.client.request("fx/abort", mutation(replacement));
  expect(aborted.result.accepted).toBe(true);
  const cancelled = await replacement!.client.waitFor((message: any) =>
    eventMethod(message) === "fx/operation" &&
    message.params.event.params?.operationId === "operation-abort-1" &&
    message.params.event.params?.state === "cancelled"
  );
  expect(cancelled.params.event.params.state).toBe("cancelled");

  const stale = await replacement!.client.request("fx/abort", oldIdentity);
  expect(stale.error.message).toContain("Stale attachment");
  const staleEpoch = await replacement!.client.request("fx/abort", {
    attachmentId: replacement!.attachmentId,
    controlEpoch: oldIdentity.controlEpoch,
  });
  expect(staleEpoch.error.message).toContain("Stale control epoch");
  const staleDetach = await replacement!.client.request("fx/detach", { attachmentId: oldIdentity.attachmentId });
  expect(staleDetach.error.message).toContain("Stale attachment");

  replacement!.client.close();
  observer.client.close();
  duringRun.client.close();

  const clientHome = join(root.root, "unix-client-home");
  mkdirSync(clientHome);
  const presentation = spawn(FX_BIN, ["attach", `unix://${server.socket}`, "--session", sessionId, "--observe"], {
    cwd: root.root,
    env: { ...env, HOME: clientHome },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(presentation);
  let presentationOut = "";
  let presentationErr = "";
  presentation.stdout!.on("data", (chunk) => presentationOut += chunk.toString());
  presentation.stderr!.on("data", (chunk) => presentationErr += chunk.toString());
  await waitFor(() => presentationOut.includes("REMOTE_CONTINUED_AFTER_DETACH"), "Unix presentation history");
  presentation.stdin!.write("/detach\n");
  presentation.stdin!.end();
  const presentationCode = await new Promise<number | null>((resolve) => presentation.on("close", resolve));
  expect(presentationCode).toBe(0);
  expect(presentationOut).not.toContain("\u001b");
  expect(presentationErr).toBe("");
  expect(existsSync(join(clientHome, ".fx", "sessions"))).toBe(false);
  expect(server.stderr()).toBe("");

  server.proc.kill("SIGTERM");
  await new Promise<void>((resolve) => server.proc.once("close", () => resolve()));
  rmSync(server.socket, { force: true });
  const restarted = await startServer(root, env);
  const afterRestart = await attach(restarted.socket, sessionId, "observer");
  expect(afterRestart.snapshot.history.some((item: any) =>
    item.role === "assistant" && item.text.includes("REMOTE_CONTINUED_AFTER_DETACH")
  )).toBe(true);
  afterRestart.client.close();
  expect(restarted.stderr()).toBe("");
}, 60_000);

test("lost prompt response reconciles without duplicate provider work", async () => {
  const root = isolatedRoot("fx-remote-lost-response-");
  const held = heldFakeGatewayFinalText();
  cleanups.push(() => held.dispose());
  const gateway = startFakeGateway([() => held.response]);
  cleanups.push(() => gateway.stop());
  const env = gatewayEnv(root, gateway);
  const sessionId = await createSession(root.workspace, env);
  const server = await startServer(root, env);
  const first = await attach(server.socket, sessionId, "controller");
  const prompt = [{ type: "text", text: "accept exactly once" }];
  first.client.send("fx/prompt", {
    ...mutation(first), operationId: "operation-lost-response", prompt,
  });
  first.client.close();
  await waitFor(() => gateway.requestCount() === 1, "lost-response provider request");
  let replacement: Awaited<ReturnType<typeof attach>> | undefined;
  for (let attempt = 0; attempt < 50 && !replacement; attempt++) {
    try { replacement = await attach(server.socket, sessionId, "controller"); }
    catch { await Bun.sleep(20); }
  }
  const inspected = await replacement!.client.request("fx/operation/inspect", { operationId: "operation-lost-response" });
  expect(inspected.result.state).toBe("running");
  const replayed = await replacement!.client.request("fx/prompt", {
    ...mutation(replacement), operationId: "operation-lost-response", prompt,
  });
  expect(replayed.result.replayed).toBe(true);
  expect(gateway.requestCount()).toBe(1);
  held.release("lost response completed");
  const completed = await replacement!.client.waitFor((message: any) =>
    eventMethod(message) === "fx/operation" && message.params.event.params?.state === "completed"
  );
  expect(completed.params.event.params.operationId).toBe("operation-lost-response");
  replacement!.client.close();
  expect(server.stderr()).toBe("");
}, 60_000);

test("pending permission survives controller detach and rejects stale answers", async () => {
  const root = isolatedRoot("fx-remote-permission-");
  const external = join(root.root, "external");
  mkdirSync(external);
  const target = join(external, "approved.txt");
  writeFileSync(target, "before");
  const settingsPath = join(root.home, ".fx", "settings.json");
  writeFileSync(
    settingsPath,
    JSON.stringify({ permission: { edit: { [`${external}/**`]: "ask" } } }),
    { mode: 0o600 },
  );
  chmodSync(settingsPath, 0o600);
  const gateway = startFakeGateway([
    fakeGatewayToolCall("remote\u001b_write_1", "write_file", { path: target, content: "approved" }),
    fakeGatewayFinalText("permission completed"),
  ]);
  cleanups.push(() => gateway.stop());
  const env = { ...gatewayEnv(root, gateway), FX_PERMISSION_MODE: "ask" };
  const sessionId = await createSession(root.workspace, env);
  const server = await startServer(root, env);
  const controller = await attach(server.socket, sessionId, "controller");
  await controller.client.request("fx/prompt", {
    ...mutation(controller), operationId: "operation-permission-1",
    prompt: [{ type: "text", text: "Write the approved file" }],
  });
  const permission = await controller.client.waitFor((message: any) => eventMethod(message) === "session/request_permission");
  const interactionId = permission.params.event.id;
  controller.client.close();

  const pendingUi = spawn(FX_BIN, ["attach", `unix://${server.socket}`, "--session", sessionId, "--observe"], {
    cwd: root.workspace, env, stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(pendingUi);
  let pendingUiOut = "";
  pendingUi.stdout!.on("data", (chunk) => pendingUiOut += chunk.toString());
  await waitFor(() => pendingUiOut.includes("Choices:") && pendingUiOut.includes("Allow once"), "pending permission details");
  pendingUi.stdin!.write("/detach\n");
  pendingUi.stdin!.end();
  expect(await new Promise<number | null>((resolve) => pendingUi.on("close", resolve))).toBe(0);

  let replacement: Awaited<ReturnType<typeof attach>> | undefined;
  for (let attempt = 0; attempt < 50 && !replacement; attempt++) {
    try { replacement = await attach(server.socket, sessionId, "controller"); }
    catch { await Bun.sleep(20); }
  }
  expect(replacement!.snapshot.runState).toBe("waiting_input");
  expect(replacement!.snapshot.pendingInteraction.id).toBe(interactionId);
  expect(replacement!.snapshot.tools.find((tool: any) => tool.id === "remote_write_1")?.status).toBe("pending");
  expect(JSON.stringify(replacement!.snapshot)).not.toContain("\u001b");
  const stale = await replacement!.client.request("fx/respond", {
    ...mutation(replacement), interactionId: interactionId + 1,
    result: { outcome: { outcome: "selected", optionId: "allow_once" } },
  });
  expect(stale.error.message).toContain("Stale interaction");
  const allowed = await replacement!.client.request("fx/respond", {
    ...mutation(replacement), interactionId,
    result: { outcome: { outcome: "selected", optionId: "allow_once" } },
  });
  expect(allowed.result.accepted).toBe(true);
  await waitFor(() => existsSync(target) && readFileSync(target, "utf8") === "approved", "approved write");
  expect(readFileSync(target, "utf8")).toBe("approved");
  const finished = await replacement!.client.waitFor((message: any) =>
    eventMethod(message) === "fx/operation" && message.params.event.params?.state === "completed"
  );
  expect(finished.params.event.params.operationId).toBe("operation-permission-1");
  const permissionStates = replacement!.client.drain()
    .filter((message: any) => eventMethod(message) === "fx/run_state")
    .map((message: any) => message.params.event.params.state);
  expect(permissionStates).toContain("running");
  expect(permissionStates).toContain("idle");
  replacement!.client.close();
  const replay = await attach(server.socket, sessionId, "observer");
  const completedTool = replay.snapshot.tools.find((tool: any) => tool.id === "remote_write_1");
  expect(completedTool.status).toBe("completed");
  expect(completedTool.result).toContain("approved.txt");
  replay.client.close();
  expect(server.stderr()).toBe("");
}, 60_000);

test("fx attach is presentation-only through a capability-injecting WebSocket proxy", async () => {
  const root = isolatedRoot("fx-remote-client-");
  const gateway = startFakeGateway([]);
  cleanups.push(() => gateway.stop());
  const env = gatewayEnv(root, gateway);
  const sessionId = await createSession(root.workspace, env);
  const backendPort = await freePort();
  const backend = spawn(FX_BIN, ["serve", "--listen", `ws://127.0.0.1:${backendPort}/fx`], {
    cwd: root.workspace,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(backend);
  let backendStderr = "";
  backend.stderr!.on("data", (chunk) => backendStderr += chunk.toString());
  await Bun.sleep(150);

  const capability = JSON.stringify({
    "fx.sh/cap/remote-attach": [{ actions: ["observe"], sessions: [sessionId] }],
  });
  const proxy = createServer((clientSocket) => {
    let request = Buffer.alloc(0);
    const onData = (chunk: Buffer) => {
      request = Buffer.concat([request, chunk]);
      const boundary = request.indexOf("\r\n\r\n");
      if (boundary < 0) return;
      clientSocket.off("data", onData);
      const backendSocket = createConnection(backendPort, "127.0.0.1", () => {
        const head = request.subarray(0, boundary).toString();
        backendSocket.write(head + `\r\nTailscale-App-Capabilities: ${capability}\r\n\r\n`);
        const remainder = request.subarray(boundary + 4);
        if (remainder.length > 0) backendSocket.write(remainder);
        clientSocket.pipe(backendSocket);
        backendSocket.pipe(clientSocket);
      });
      backendSocket.on("error", () => clientSocket.destroy());
    };
    clientSocket.on("data", onData);
  });
  await new Promise<void>((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => proxy.close());
  const proxyPort = (proxy.address() as { port: number }).port;

  const emptyHome = join(root.root, "empty-client-home");
  mkdirSync(emptyHome);
  const client = spawn(FX_BIN, ["attach", `ws://127.0.0.1:${proxyPort}/fx`, "--session", sessionId, "--observe"], {
    cwd: root.root,
    env: { ...process.env, HOME: emptyHome, FX_AUTO_UPGRADE: "0", NO_COLOR: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(client);
  let stdout = "";
  let stderr = "";
  client.stdout!.on("data", (chunk) => stdout += chunk.toString());
  client.stderr!.on("data", (chunk) => stderr += chunk.toString());
  await waitFor(() => stdout.includes(`Attached to ${sessionId}`), "WebSocket attach snapshot");
  backend.kill("SIGTERM");
  const code = await new Promise<number | null>((resolve) => client.on("close", resolve));
  expect(code).toBe(0);
  expect(stderr).toBe("");
  expect(backendStderr).toBe("");
  expect(existsSync(join(emptyHome, ".fx", "sessions"))).toBe(false);
}, 30_000);

async function freePort(): Promise<number> {
  return await new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address() as { port: number };
      server.close(() => resolve(address.port));
    });
  });
}

async function exactInboundBoundaryAccepted(port: number, capability: string): Promise<boolean> {
  const socket = createConnection(port, "127.0.0.1");
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  const key = Buffer.alloc(16, 10).toString("base64");
  socket.write(
    `GET /fx HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
    `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nTailscale-App-Capabilities: ${capability}\r\n\r\n`,
  );
  await new Promise<void>((resolve) => socket.once("data", () => resolve()));
  const payload = Buffer.alloc(8 * 1024 * 1024, 0x20);
  Buffer.from('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}').copy(payload);
  const header = Buffer.alloc(14);
  header[0] = 0x81;
  header[1] = 0xff;
  header.writeBigUInt64BE(BigInt(payload.length), 2);
  header.writeUInt32BE(0, 10);
  socket.write(header);
  socket.write(payload);
  const accepted = await new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => resolve(false), TIMEOUT);
    socket.once("data", () => { clearTimeout(timer); resolve(true); });
    socket.once("close", () => { clearTimeout(timer); resolve(false); });
  });
  socket.destroy();
  return accepted;
}

async function malformedFrameCloses(port: number, capability: string, frame: Buffer): Promise<boolean> {
  const socket = createConnection(port, "127.0.0.1");
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  const key = Buffer.alloc(16, 9).toString("base64");
  socket.write(
    `GET /fx HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
    `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\nTailscale-App-Capabilities: ${capability}\r\n\r\n`,
  );
  await new Promise<void>((resolve) => socket.once("data", () => resolve()));
  socket.write(frame);
  return await new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => { socket.destroy(); resolve(false); }, 2000);
    socket.once("close", () => { clearTimeout(timer); resolve(true); });
    socket.once("end", () => { clearTimeout(timer); resolve(true); });
  });
}

async function rawUpgrade(port: number, capability?: string): Promise<string> {
  const socket = createConnection(port, "127.0.0.1");
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  const key = Buffer.alloc(16, 7).toString("base64");
  socket.write(
    `GET /fx HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
    `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n` +
    (capability === undefined ? "" : `Tailscale-App-Capabilities: ${capability}\r\n`) + "\r\n",
  );
  const response = await new Promise<string>((resolve) => socket.once("data", (data) => resolve(data.toString())));
  socket.destroy();
  return response;
}

test("split capability grants remain associated through attach authorization", async () => {
  const root = isolatedRoot("fx-remote-split-grant-");
  const gateway = startFakeGateway([]);
  cleanups.push(() => gateway.stop());
  const env = gatewayEnv(root, gateway);
  const sessionId = await createSession(root.workspace, env);
  const port = await freePort();
  const proc = spawn(FX_BIN, ["serve", "--listen", `ws://127.0.0.1:${port}/fx`], {
    cwd: root.workspace, env, stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(proc);
  await Bun.sleep(150);
  const split = JSON.stringify({
    "fx.sh/cap/remote-attach": [
      { actions: ["observe"], sessions: [sessionId] },
      { actions: ["control"], sessions: ["different-session"] },
    ],
  });
  const proxy = createServer((clientSocket) => {
    let request = Buffer.alloc(0);
    const onData = (chunk: Buffer) => {
      request = Buffer.concat([request, chunk]);
      const boundary = request.indexOf("\r\n\r\n");
      if (boundary < 0) return;
      clientSocket.off("data", onData);
      const backendSocket = createConnection(port, "127.0.0.1", () => {
        backendSocket.write(request.subarray(0, boundary).toString() +
          `\r\nTailscale-App-Capabilities: ${split}\r\n\r\n`);
        clientSocket.pipe(backendSocket);
        backendSocket.pipe(clientSocket);
      });
    };
    clientSocket.on("data", onData);
  });
  await new Promise<void>((resolve) => proxy.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => proxy.close());
  const proxyPort = (proxy.address() as { port: number }).port;
  const observer = spawn(FX_BIN, ["attach", `ws://127.0.0.1:${proxyPort}/fx`, "--session", sessionId, "--observe"], {
    cwd: root.workspace, env, stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(observer);
  let observerOut = "";
  observer.stdout!.on("data", (chunk) => observerOut += chunk.toString());
  await waitFor(() => observerOut.includes("Attached to"), "split-grant observer attach");
  observer.stdin!.write("/detach\n");
  observer.stdin!.end();
  expect(await new Promise<number | null>((resolve) => observer.on("close", resolve))).toBe(0);

  const controller = spawn(FX_BIN, ["attach", `ws://127.0.0.1:${proxyPort}/fx`, "--session", sessionId], {
    cwd: root.workspace, env, stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(controller);
  let controllerErr = "";
  controller.stderr!.on("data", (chunk) => controllerErr += chunk.toString());
  expect(await new Promise<number | null>((resolve) => controller.on("close", resolve))).not.toBe(0);
  expect(controllerErr).toContain("Not authorized");
}, 30_000);

test("WebSocket upgrade is loopback-only and fails closed on app capability", async () => {
  const root = isolatedRoot("fx-remote-websocket-");
  const port = await freePort();
  const proc = spawn(FX_BIN, ["serve", "--listen", `ws://127.0.0.1:${port}/fx`], {
    cwd: root.workspace,
    env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  children.push(proc);
  await Bun.sleep(150);
  expect(await rawUpgrade(port)).toContain("403 Forbidden");
  expect(await rawUpgrade(port, "{}")).toContain("403 Forbidden");
  expect(await rawUpgrade(port, "{}\r\nTailscale-App-Capabilities: {}" )).toContain("403 Forbidden");
  const valid = JSON.stringify({
    "fx.sh/cap/remote-attach": [{ actions: ["observe", "control"], sessions: ["session-a"] }],
  });
  expect(await rawUpgrade(port, valid)).toContain("101 Switching Protocols");
  expect(await exactInboundBoundaryAccepted(port, valid)).toBe(true);
  expect(await rawUpgrade(port, `${valid}\r\nConnection: Upgrade`)).toContain("403 Forbidden");
  expect(await malformedFrameCloses(port, valid, Buffer.from([0x81, 0x00]))).toBe(true);
  const oversized = Buffer.alloc(14);
  oversized[0] = 0x81;
  oversized[1] = 0xff;
  oversized.writeBigUInt64BE(BigInt(8 * 1024 * 1024 + 1), 2);
  oversized.writeUInt32BE(0, 10);
  expect(await malformedFrameCloses(port, valid, oversized)).toBe(true);
  const duplicateAction = JSON.stringify({
    "fx.sh/cap/remote-attach": [{ actions: ["observe", "observe"], sessions: ["session-a"] }],
  });
  expect(await rawUpgrade(port, duplicateAction)).toContain("403 Forbidden");

  const malformedUpgradeServer = createServer((socket) => {
    socket.once("data", () => {
      socket.end("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: invalid\r\n\r\n");
    });
  });
  await new Promise<void>((resolve) => malformedUpgradeServer.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => malformedUpgradeServer.close());
  const malformedPort = (malformedUpgradeServer.address() as { port: number }).port;
  const malformedClient = spawn(FX_BIN, ["attach", `ws://127.0.0.1:${malformedPort}/fx`, "--session", "session-a", "--observe"], {
    cwd: root.workspace,
    env: { ...process.env, HOME: root.home, FX_AUTO_UPGRADE: "0" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  expect(await new Promise<number | null>((resolve) => malformedClient.on("close", resolve))).not.toBe(0);

  const malformedFrameServer = createServer((socket) => {
    let request = "";
    socket.on("data", (chunk) => {
      request += chunk.toString();
      if (!request.includes("\r\n\r\n")) return;
      socket.removeAllListeners("data");
      const key = request.match(/Sec-WebSocket-Key: ([^\r\n]+)/i)?.[1] ?? "";
      const accept = createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      socket.write(Buffer.from([0x81, 0x7e, 0x00, 0x01, 0x78]));
    });
  });
  await new Promise<void>((resolve) => malformedFrameServer.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => malformedFrameServer.close());
  const malformedFramePort = (malformedFrameServer.address() as { port: number }).port;
  const malformedFrameClient = spawn(FX_BIN, ["attach", `ws://127.0.0.1:${malformedFramePort}/fx`, "--session", "session-a", "--observe"], {
    cwd: root.workspace,
    env: { ...process.env, HOME: root.home, FX_AUTO_UPGRADE: "0" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const malformedExit = await new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) =>
    malformedFrameClient.on("close", (code, signal) => resolve({ code, signal }))
  );
  expect(malformedExit.code).not.toBe(0);
  expect(malformedExit.signal).toBeNull();

  const rejected = spawn(FX_BIN, ["serve", "--listen", "ws://0.0.0.0:7741/fx"], {
    cwd: root.workspace,
    env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const code = await new Promise<number | null>((resolve) => rejected.on("close", resolve));
  expect(code).not.toBe(0);

  const insecureSocket = join(tmpdir(), `fx-insecure-${process.pid}.sock`);
  const insecure = spawn(FX_BIN, ["serve", "--listen", `unix://${insecureSocket}`], {
    cwd: root.workspace,
    env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const insecureCode = await new Promise<number | null>((resolve) => insecure.on("close", resolve));
  expect(insecureCode).not.toBe(0);
  expect(existsSync(insecureSocket)).toBe(false);

  const missingParent = join(root.root, "missing-parent");
  const missing = spawn(FX_BIN, ["serve", "--listen", `unix://${join(missingParent, "agent.sock")}`], {
    cwd: root.workspace, env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  expect(await new Promise<number | null>((resolve) => missing.on("close", resolve))).not.toBe(0);
  expect(existsSync(missingParent)).toBe(false);

  const liveSocket = join(root.root, "live.sock");
  const liveOwner = createServer();
  await new Promise<void>((resolve) => liveOwner.listen(liveSocket, resolve));
  cleanups.push(() => liveOwner.close());
  const liveConflict = spawn(FX_BIN, ["serve", "--listen", `unix://${liveSocket}`], {
    cwd: root.workspace, env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  expect(await new Promise<number | null>((resolve) => liveConflict.on("close", resolve))).not.toBe(0);
  expect(existsSync(liveSocket)).toBe(true);

  const existingFile = join(root.root, "existing.sock");
  writeFileSync(existingFile, "must remain");
  const existing = spawn(FX_BIN, ["serve", "--listen", `unix://${existingFile}`], {
    cwd: root.workspace, env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  expect(await new Promise<number | null>((resolve) => existing.on("close", resolve))).not.toBe(0);
  expect(readFileSync(existingFile, "utf8")).toBe("must remain");

  const privateDir = join(root.root, "private-runtime");
  mkdirSync(privateDir, { mode: 0o700 });
  const linkedDir = join(root.root, "linked-runtime");
  symlinkSync(privateDir, linkedDir, "dir");
  const linked = spawn(FX_BIN, ["serve", "--listen", `unix://${join(linkedDir, "agent.sock")}`], {
    cwd: root.workspace, env: { ...process.env, HOME: root.home, AI_GATEWAY_API_KEY: "fake", FX_AUTO_UPGRADE: "0" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  expect(await new Promise<number | null>((resolve) => linked.on("close", resolve))).not.toBe(0);
}, 30_000);
