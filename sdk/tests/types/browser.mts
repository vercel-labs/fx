// The browser entry and `libfx/wasm`: agents on this page, the terminal
// harness with xterm.js, and the WebAssembly SDK with explicit assets.
import {
  createFxAgent,
  createFxEngine,
  createFxTerminal,
  encodeXtermKeyEvent,
  libfxApiVersion,
  memory,
  supportsJspi,
  xtermAdapter,
  type FxTerminal,
  type FxWorkspace,
  type FxXtermLike,
} from "libfx/browser";
// @ts-expect-error getBackendInfo() is Node.js only
import { getBackendInfo } from "libfx/browser";
import * as wasm from "libfx/wasm";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
function assertType<T extends true>(): void {}

declare const term: FxXtermLike & { focus(): void };

// README "Interactive terminal".
export async function terminal(): Promise<FxTerminal> {
  const runtime = await createFxTerminal({
    terminal: xtermAdapter(term),
    env: { AI_GATEWAY_API_KEY: "<short-lived credential>" },
  });
  await runtime.interactive;
  const code = await runtime.exited;
  assertType<Equal<typeof code, number>>();
  runtime.write("hello\r");
  runtime.resize();
  runtime.abort();

  const workspace = {
    info: { version: 1, root: "/workspace", cwd: "/workspace", home: "/home/visitor", gitAvailable: false, ephemeral: true },
    permission: "allow-sandboxed",
    exec({ command, cwd, signal, timeoutMs, outputLimitBytes }) {
      return { exitCode: signal.aborted ? 130 : 0, stdout: `${command} ${cwd} ${timeoutMs} ${outputLimitBytes}`, stderr: "" };
    },
    async readFile({ path, signal }) {
      return signal.aborted || !path.endsWith("/AGENTS.md") ? null : new TextEncoder().encode("# Rules");
    },
  } satisfies FxWorkspace;

  await createFxTerminal({
    terminal: xtermAdapter(term),
    args: ["--fast"],
    workspace,
    clipboard: { writeText: (text) => navigator.clipboard.writeText(text) },
    openUrl: (url) => window.open(url) !== null,
    onEvent: (event) => console.log(event.type, event.timestamp),
    wasm: "/fx-term.wasm",
  });

  // @ts-expect-error a terminal needs its terminal adapter
  await createFxTerminal({ env: {} });
  // @ts-expect-error workspace version 1 is non-git
  await createFxTerminal({ terminal: xtermAdapter(term), workspace: { ...workspace, info: { ...workspace.info, gitAvailable: true } } });

  return runtime;
}

export function keys(event: KeyboardEvent): string | null {
  return encodeXtermKeyEvent(event);
}

export async function agents(): Promise<void> {
  assertType<Equal<typeof libfxApiVersion, 3>>();
  if (!supportsJspi()) return;
  const agent = createFxAgent({ apiKey: "<short-lived credential>", durability: memory() });
  const turn = agent.session().prompt("Hello");
  for await (const event of turn) if (event.type === "text_delta") console.log(event.delta);
  await agent.close();

  createFxAgent({ wasm: fetch("/fx-core.wasm") });
  const engine = await createFxEngine({ apiKey: "<short-lived credential>", wasm: await WebAssembly.compileStreaming(fetch("/fx-core.wasm")) });
  await engine.close();

  // @ts-expect-error backend selection is Node.js only
  createFxAgent({ backend: "native" });
  // @ts-expect-error nativeAddon is Node.js only
  createFxAgent({ nativeAddon: false });
}

export async function wasmEntry(): Promise<void> {
  const engine = await wasm.createFxEngine({ apiKey: "<short-lived credential>", wasm: "https://cdn.example.com/fx-core.wasm" });
  const result = await engine.prompt("Hello").result;
  console.log(result.stopReason, result.usage.outputTokens);
  await wasm.createFxTerminal({ terminal: wasm.xtermAdapter(term), wasm: new ArrayBuffer(8) });
  const persistence = wasm.createMemoryPersistence();
  await wasm.createFxEngine({ apiKey: "k", wasm: "/fx-core.wasm", persistence });
  console.log(wasm.fxSdkApiVersion, wasm.supportsJspi(), await wasm.listModels({ apiKey: "k" }));

  // @ts-expect-error libfx/wasm needs an explicit wasm asset
  await wasm.createFxEngine({ apiKey: "k" });
  // @ts-expect-error libfx/wasm has no durable agent
  wasm.createFxAgent();
  // @ts-expect-error libfx/wasm has no memory() durability
  wasm.memory();
}

void getBackendInfo;
