import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";

export function createRtkFixture(rtk?: boolean, exitCode = 0) {
  const home = createIsolatedTestHome();
  const workspace = join(home, "workspace");
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    rtk,
    session_titles: false,
    permission: { bash: { "./cargo test": "allow", "git status": "allow" } },
  }));
  const raw = Array.from({ length: 80 }, (_, index) =>
    `test suite::rtk_pass_${index} ... ok\n`,
  ).join("") + "test result: ok. 80 passed\n";
  writeFileSync(join(workspace, "test-output.txt"), raw);
  // A deterministic first-party fixture, not a Cargo installation.
  writeFileSync(join(workspace, "cargo"),
    `#!/bin/sh\nprintf 'run\\n' >> runs\ncat test-output.txt\nprintf 'RTK_DIAGNOSTIC: retain this warning\\n' >&2\nexit ${exitCode}\n`);
  chmodSync(join(workspace, "cargo"), 0o755);
  return { home, workspace, raw, cleanup: () => cleanupIsolatedTestHome(home) };
}

export function toolResultText(request: any, id: string): string {
  const part = request.prompt.flatMap((message: any) =>
    Array.isArray(message.content) ? message.content : [],
  ).find((value: any) => value.type === "tool-result" && value.toolCallId === id);
  const value = part?.output?.value;
  return typeof value === "string" ? value : JSON.stringify(value ?? null);
}
