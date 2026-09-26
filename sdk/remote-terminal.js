const maxFrameChars = 1024 * 1024;
const maxQueuedInputBytes = 64 * 1024;
const maxBufferedOutputBytes = 1024 * 1024;
const encoder = new TextEncoder();

function dimensions(terminal) {
  const { cols, rows } = terminal;
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols < 1 || rows < 1 || cols > 1000 || rows > 1000) {
    throw new RangeError("remote terminal dimensions must be integers from 1 to 1000");
  }
  return { cols, rows };
}

function decodeOutput(value) {
  if (typeof value !== "string" || value.length > maxFrameChars || value.length % 4 !== 0 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    throw new TypeError("invalid remote terminal output");
  }
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

export async function createRemoteTerminal(options) {
  const terminal = options?.terminal;
  const html = options?.presentation === "html";
  const remote = options?.remote;
  if (!terminal || typeof terminal.write !== "function" || typeof terminal.onData !== "function" ||
      typeof terminal.onResize !== "function") throw new TypeError("terminal adapter is required");
  dimensions(terminal);
  if (!remote || typeof remote.sessionId !== "string" || remote.sessionId.length < 1 || remote.sessionId.length > 256) {
    throw new TypeError("remote.sessionId is required");
  }
  let cursor = remote.cursor ?? 0;
  if (!Number.isSafeInteger(cursor) || cursor < 0) throw new TypeError("remote.cursor must be a nonnegative safe integer");
  let receivedCursor = cursor;
  const connectTimeoutMs = remote.connectTimeoutMs ?? 15_000;
  if (!Number.isInteger(connectTimeoutMs) || connectTimeoutMs < 1 || connectTimeoutMs > 60_000) {
    throw new RangeError("remote.connectTimeoutMs must be from 1 to 60000");
  }
  const Socket = remote.WebSocket ?? globalThis.WebSocket;
  if (typeof Socket !== "function") throw new TypeError("WebSocket is unavailable");
  remote.signal?.throwIfAborted();
  const endpoint = typeof remote.url === "function" ? await remote.url() : remote.url;
  remote.signal?.throwIfAborted();
  let url;
  try { url = new URL(endpoint); } catch { throw new TypeError("remote.url must be an absolute WebSocket URL"); }
  if (!["ws:", "wss:"].includes(url.protocol) || url.username || url.password || url.hash) {
    throw new TypeError("remote.url must use ws or wss without credentials or fragments");
  }
  const emit = (type, detail = {}) => {
    try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
  };
  let resolveInteractive;
  let rejectInteractive;
  let resolveExited;
  const interactive = new Promise((resolve, reject) => { resolveInteractive = resolve; rejectInteractive = reject; });
  const exited = new Promise((resolve) => { resolveExited = resolve; });
  interactive.catch(() => {});
  let connected = false;
  let transportClosed = false;
  let interactiveSettled = false;
  let exitReceived = false;
  let ended = false;
  let released = false;
  let bufferedBytes = 0;
  let queuedBytes = 0;
  let output = Promise.resolve();
  const queuedInput = [];
  const subscriptions = [];
  const socket = new Socket(url.href);
  const release = () => {
    if (released) return;
    released = true;
    clearTimeout(timer);
    remote.signal?.removeEventListener("abort", onAbort);
    for (const unsubscribe of subscriptions.splice(0)) {
      try { unsubscribe?.(); } catch { emit("terminal.cleanup_error"); }
    }
    socket.removeEventListener("open", onOpen);
    socket.removeEventListener("message", onMessage);
    socket.removeEventListener("error", onError);
    socket.removeEventListener("close", onClose);
    queuedInput.length = 0;
    queuedBytes = 0;
  };
  const finish = (code, error) => {
    if (ended) return;
    ended = true;
    release();
    if (!interactiveSettled) {
      interactiveSettled = true;
      rejectInteractive(error ?? new Error("remote terminal detached before becoming interactive"));
    }
    resolveExited(code);
    emit("runtime.exit", { surface: "remote-terminal", code, cursor });
    if (socket.readyState < 2) socket.close();
  };
  const fail = (error) => {
    emit("terminal.remote_error", { cursor, error: error.message });
    finish(255, error);
  };
  const send = (value) => {
    if (ended || socket.readyState !== 1) throw new Error("remote terminal is disconnected");
    const text = JSON.stringify(value);
    if (socket.bufferedAmount + encoder.encode(text).length > maxFrameChars) {
      throw new Error("remote terminal input buffer is full");
    }
    socket.send(text);
  };
  const write = (data) => {
    if (typeof data !== "string" && !(data instanceof Uint8Array)) throw new TypeError("terminal input must be a string or Uint8Array");
    if (ended || transportClosed) throw new Error("remote terminal is disconnected");
    const bytes = typeof data === "string" ? encoder.encode(data).length : data.length;
    if (bytes > maxQueuedInputBytes || queuedBytes + bytes > maxQueuedInputBytes) {
      throw new RangeError("remote terminal input exceeds 65536 bytes");
    }
    const message = typeof data === "string"
      ? { type: "input", data }
      : { type: "input", encoding: "base64", data: btoa(Array.from(data, (byte) => String.fromCharCode(byte)).join("")) };
    if (connected) send(message);
    else { queuedInput.push(message); queuedBytes += bytes; }
  };
  function onOpen() {
    try { send({ type: "attach", version: 1, sessionId: remote.sessionId, cursor, ...(html && { view: "html" }) }); }
    catch (error) { fail(error); }
  }
  function onMessage(event) {
    try {
      if (typeof event.data !== "string" || event.data.length > maxFrameChars) throw new Error("invalid remote terminal frame");
      const message = JSON.parse(event.data);
      if (!message || typeof message !== "object" || exitReceived) throw new Error("invalid remote terminal message");
      if (message.type === "ready") {
        if (connected || message.version !== 1 || message.sessionId !== remote.sessionId || message.cursor !== cursor) {
          throw new Error("remote terminal attachment mismatch");
        }
        connected = true;
        if (!html) clearTimeout(timer);
        if (!html) send({ type: "resize", ...dimensions(terminal) });
        for (const message of queuedInput) send(message);
        queuedInput.length = 0;
        queuedBytes = 0;
        output = output.then(async () => {
          await terminal.drain?.();
          if (!ended && !transportClosed && !html) {
            interactiveSettled = true;
            resolveInteractive();
            emit("runtime.ready", { surface: "remote-terminal", cursor });
          }
        }).catch(fail);
      } else if (message.type === "output") {
        if (!connected || !Number.isSafeInteger(message.cursor) || message.cursor !== receivedCursor + 1) {
          throw new Error("remote terminal output cursor gap");
        }
        const bytes = decodeOutput(message.data);
        bufferedBytes += bytes.length;
        if (bufferedBytes > maxBufferedOutputBytes) throw new Error("remote terminal output buffer is full");
        receivedCursor = message.cursor;
        const nextCursor = receivedCursor;
        output = output.then(async () => {
          if (ended) return;
          await terminal.write(bytes);
          await terminal.drain?.();
          if (ended) return;
          cursor = nextCursor;
          bufferedBytes -= bytes.length;
          emit("terminal.output", { cursor, bytes: bytes.length });
        }).catch(fail);
      } else if (message.type === "interaction") {
        if (!connected || !message.snapshot || message.snapshot.type !== "snapshot" || message.snapshot.version !== 1) {
          throw new Error("unsupported remote interaction snapshot");
        }
        options.onInteraction?.(message.snapshot);
        if (html && !interactiveSettled) {
          interactiveSettled = true;
          clearTimeout(timer);
          resolveInteractive();
          emit("runtime.ready", { surface: "remote-view" });
        }
      } else if (message.type === "exit") {
        if (!connected || !Number.isInteger(message.code) || message.code < 0 || message.code > 255) {
          throw new Error("invalid remote terminal exit");
        }
        exitReceived = true;
        output = output.then(() => finish(message.code));
      } else if (message.type === "error") {
        throw new Error("remote terminal rejected the connection or operation");
      } else throw new Error("unknown remote terminal message");
    } catch (error) { fail(error); }
  }
  function onError() { fail(new Error("remote terminal connection failed")); }
  function onClose() {
    transportClosed = true;
    output = output.then(() => {
      if (!ended) fail(new Error("remote terminal disconnected; reconnect explicitly with the last rendered cursor"));
    });
  }
  function onAbort() { finish(130, remote.signal.reason); }
  const timer = setTimeout(() => fail(new Error("remote terminal attachment timed out")), connectTimeoutMs);
  socket.addEventListener("open", onOpen);
  socket.addEventListener("message", onMessage);
  socket.addEventListener("error", onError);
  socket.addEventListener("close", onClose);
  remote.signal?.addEventListener("abort", onAbort, { once: true });
  try {
    subscriptions.push(terminal.onData((data) => { try { write(data); } catch (error) { fail(error); } }));
    subscriptions.push(terminal.onKeyData?.((data) => { try { write(data); } catch (error) { fail(error); } }));
    subscriptions.push(terminal.onResize(() => {
      try { if (connected && !ended) send({ type: "resize", ...dimensions(terminal) }); }
      catch (error) { fail(error); }
    }));
    if (remote.signal?.aborted) onAbort();
  } catch (error) {
    finish(255, error);
    throw error;
  }
  emit("runtime.start", { surface: "remote-terminal" });
  return {
    interactive,
    exited,
    write,
    resize() { if (connected && !ended) send({ type: "resize", ...dimensions(terminal) }); },
    interact(action) {
      if (!connected) throw new Error("remote terminal is not attached");
      if (!action || typeof action !== "object" || Array.isArray(action)) throw new TypeError("interaction action must be an object");
      const message = { type: "interaction", action };
      if (encoder.encode(JSON.stringify(message)).length > 64 * 1024) throw new RangeError("interaction action exceeds 65536 bytes");
      send(message);
    },
    interrupt() { send({ type: "interrupt" }); },
    abort() { finish(130); },
    get cursor() { return cursor; },
  };
}

export function createRemoteView(options) {
  if (typeof options?.onSnapshot !== "function") throw new TypeError("onSnapshot is required");
  return createRemoteTerminal({
    ...options,
    presentation: "html",
    onInteraction: options.onSnapshot,
    terminal: {
      cols: 80,
      rows: 24,
      write() {},
      onData() { return () => {}; },
      onResize() { return () => {}; },
    },
  });
}
