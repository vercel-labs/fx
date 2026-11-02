// A real xterm `Terminal` fits `xtermAdapter()`. Checked only when the
// headless terminal suite's dependencies are installed (`npm ci --prefix sdk/node`).
import { Terminal } from "@xterm/headless";
import { createFxTerminal, xtermAdapter } from "libfx/browser";

export async function run(): Promise<void> {
  const term = new Terminal({ cols: 100, rows: 30, allowProposedApi: true });
  const runtime = await createFxTerminal({ terminal: xtermAdapter(term), wasm: "/fx-term.wasm" });
  await runtime.interactive;
  runtime.abort();
}
