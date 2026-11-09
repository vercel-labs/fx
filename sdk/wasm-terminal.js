// The fx terminal on WebAssembly.
import { instantiate } from "./wasm-runtime.js";

export async function createFxTerminal(options) {
  if (!options?.terminal) throw new TypeError("terminal is required");
  const emit = (type, detail = {}) => {
    try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
  };
  let resolveInteractive;
  let rejectInteractive;
  let interactiveScheduled = false;
  const interactive = new Promise((resolve, reject) => {
    resolveInteractive = resolve;
    rejectInteractive = reject;
  });
  const stdout = (bytes) => options.terminal.write(bytes);
  const onTerminalPoll = () => {
    if (interactiveScheduled) return;
    interactiveScheduled = true;
    queueMicrotask(async () => {
      try {
        await options.terminal.drain?.();
        resolveInteractive();
      } catch (error) {
        rejectInteractive(error);
      }
    });
  };
  emit("runtime.start", { surface: "terminal" });
  const runtime = await instantiate({ ...options, emit, stdout, onTerminalPoll });
  runtime.exited.then((code) => {
    if (!interactiveScheduled) rejectInteractive(new Error(`fx terminal exited with code ${code} before becoming interactive`));
  });
  emit("runtime.ready", { surface: "terminal" });
  const interruptKey = options.interruptKey ?? "\x03";
  const forwardData = (data) => {
    if (interruptKey && data.includes(interruptKey)) runtime.abortHostEffects();
    runtime.write(data);
  };
  const signalResize = () => {
    emit("terminal.resize", { cols: options.terminal.cols, rows: options.terminal.rows });
    runtime.wake();
  };
  let unsubscribeData;
  let unsubscribeKeyData;
  let unsubscribeResize;
  let subscriptionsReleased = false;
  const releaseSubscriptions = () => {
    if (subscriptionsReleased) return;
    subscriptionsReleased = true;
    try { unsubscribeData?.(); } catch (error) { emit("terminal.cleanup_error", { source: "data", error }); }
    try { unsubscribeKeyData?.(); } catch (error) { emit("terminal.cleanup_error", { source: "key_data", error }); }
    try { unsubscribeResize?.(); } catch (error) { emit("terminal.cleanup_error", { source: "resize", error }); }
  };
  runtime.exited.then((code) => {
    releaseSubscriptions();
    emit("runtime.exit", { surface: "terminal", code });
  });
  try {
    unsubscribeData = options.terminal.onData(forwardData);
    unsubscribeKeyData = options.terminal.onKeyData?.(forwardData);
    unsubscribeResize = options.terminal.onResize(signalResize);
  } catch (error) {
    // The rejected factory never transfers this promise to a caller.
    interactive.catch(() => {});
    releaseSubscriptions();
    runtime.abort();
    throw error;
  }
  return {
    interactive,
    exited: runtime.exited,
    write(data) {
      if (interruptKey && typeof data === "string" && data.includes(interruptKey)) runtime.abortHostEffects();
      runtime.write(data);
    },
    resize: signalResize,
    abort() { releaseSubscriptions(); runtime.abort(); },
  };
}
