import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

type Category =
  | "frame_commit"
  | "interactive_terminal_owner"
  | "initialization_teardown"
  | "terminal_reset"
  | "crash_recovery"
  | "terminal_probe"
  | "title_control"
  | "noninteractive_output"
  | "benchmark_output"
  | "acp_protocol_transport"
  | "subprocess_protocol_transport"
  | "tests";

type Site = {
  path: string;
  line: number;
  functionName: string;
  primitive: string;
  snippet: string;
  category: Category | "unclassified";
  reason: string;
};

type AllowRule = {
  path: string;
  functionName: RegExp;
  primitive: RegExp;
  category: Category;
  reason: string;
};

type StdioProvenance = {
  acquirers: Set<string>;
  handles: Set<string>;
};

const allowlist: AllowRule[] = [
  rule("src/ui/transcript/io.zig", "writeFrameBytes", /stdio_write/, "frame_commit", "normal interactive frame delivery"),
  rule("src/ui/transcript/runtime.zig", "<top-level>", /stdio_acquisition/, "interactive_terminal_owner", "stored interactive stdout handle"),
  rule("src/core/app/app_lifecycle.zig", "writeLifecycleTerminalBytes", /stdio_write/, "initialization_teardown", "interactive startup and teardown control"),
  rule("src/core/app/app_lifecycle.zig", "bootstrapInteractiveApp", /stdio_acquisition_write/, "initialization_teardown", "pre-raw-mode Keychain onboarding prompt"),
  rule("src/ui/shell_runtime.zig", "clearTmuxScreenAndHistory", /stdio_(?:acquisition|write)/, "terminal_reset", "tmux pane reset before history cleanup"),
  rule("src/ui/shell_runtime.zig", "enableThemeNotifications", /stdio_(?:acquisition|write)/, "initialization_teardown", "terminal theme notification control"),
  rule("src/core/app/app_lifecycle.zig", "abnormalExitHandlerWithRestore", /(?:fixed_descriptor|raw_fd_write)/, "crash_recovery", "async-signal-safe terminal restoration"),
  rule("src/core/hosts/wasm_panic.zig", "panicToStderr", /debug_print/, "crash_recovery", "WASM panic message before trap"),
  rule("src/ui/shell_runtime.zig", "ensureInteractive", /fixed_descriptor/, "terminal_probe", "TTY capability probe"),
  rule("src/ui/shell_runtime.zig", "(?:query|requestResize)CursorPosition", /stdio_(?:acquisition|write)/, "terminal_probe", "cursor-position query"),
  rule("src/ui/shell_runtime.zig", "(?:requestThemeColorScheme|requestThemeResponseFence|requestThemeBackground)", /stdio_(?:acquisition|write)/, "terminal_probe", "terminal theme query"),
  rule("src/ui/terminal/theme_detection.zig", "queryTerminalBackground", /stdio_(?:acquisition|write)/, "terminal_probe", "terminal background query"),
  rule("src/ui/ask_presentation.zig", "init", /fixed_descriptor/, "terminal_probe", "ask stdout geometry probe"),
  rule("src/ui/ask_presentation.zig", "init", /stdio_acquisition/, "interactive_terminal_owner", "stored ask presenter stdout handle"),
  rule("src/ui/ask_presentation.zig", "refreshGeometry", /fixed_descriptor/, "terminal_probe", "ask stdout geometry refresh"),
  rule("src/ui/ask_presentation.zig", "writeTerminalBytes", /stdio_write/, "initialization_teardown", "ask terminal prepare and restore control"),
  rule("src/ui/render.zig", "(?:setTerminalTitleLabel|clearTerminalTitleProvider)", /stdio_(?:acquisition|write)/, "title_control", "terminal title control"),
  rule("src/acp/jsonrpc.zig", ".+", /stdio_(?:acquisition|write)/, "acp_protocol_transport", "ACP JSON-RPC transport"),
  rule("src/core/execution/command_runner.zig", "(?:runForegroundSessionBootstrap|writeForegroundSessionReplaceFailure)", /stdio_acquisition_write/, "subprocess_protocol_transport", "foreground command bootstrap protocol"),
  rule("src/core/terminal/native_session.zig", "(?:acceptMarker|runLauncher)", /fixed_descriptor/, "subprocess_protocol_transport", "private native launcher PTY and control descriptors"),
  rule("src/core/terminal/tmux_session.zig", "runLauncher", /fixed_descriptor/, "subprocess_protocol_transport", "private tmux launcher PTY descriptor"),
  rule("src/core/terminal/client.zig", "(?:runFixture|writeFixtureJson)", /stdio_acquisition_write/, "tests", "private terminal client fixture output"),
  rule("src/terminal_client_fixture.zig", "(?:writeCompletionJson|writeJson)", /stdio_acquisition_write/, "tests", "private test-fixture output"),
  rule("src/core/shared/darwin_process_spawn.zig", "process_spawn", /fixed_descriptor/, "subprocess_protocol_transport", "child stdio file-action mapping"),
  rule("src/core/app/app_entry_runtime.zig", "(?:writeRealStdout|writeRealStderr)", /stdio_acquisition_write/, "noninteractive_output", "post-terminal handoff or failure output"),
  rule("src/core/app/app_upgrade_runtime.zig", "writeStderrDefault", /stdio_acquisition_write/, "noninteractive_output", "post-terminal upgrade relaunch failure output"),
  rule("src/core/upgrade/upgrade_runtime.zig", "progressWait", /stdio_(?:acquisition|write)/, "noninteractive_output", "upgrade progress output"),
  rule("src/core/cli/cli_ask.zig", "(?:writeRealStdout|writeRealStderr)", /stdio_acquisition_write/, "noninteractive_output", "workflow CLI output"),
  rule("src/core/cli/cli_ask.zig", "realStdoutIsTty", /stdio_acquisition/, "terminal_probe", "ask presentation TTY capability probe"),
  rule("src/core/cli/cli_ask.zig", "realStderrIsTty", /stdio_acquisition/, "terminal_probe", "notification fallback TTY capability probe"),
  rule("src/core/cli/cli_replay.zig", "(?:writeStdout|writeStderr)", /stdio_acquisition_write/, "noninteractive_output", "replay process output"),
  rule("src/core/cli/cli_surface.zig", "(?:writeRealStdout|writeRealStderr|writeFdAll)", /(?:stdio_acquisition_write|fixed_fd_write|raw_fd_write|delegated_fd_write)/, "noninteractive_output", "top-level CLI output"),
  rule("src/core/cli/cli_surface.zig", "(?:setupTerminalAvailableDefault|enable)", /fixed_descriptor/, "terminal_probe", "masked setup prompt TTY and raw-mode setup"),
  rule("src/core/auth/login_flow.zig", "(?:canUseInteractiveTeamPicker|enable)", /fixed_descriptor/, "terminal_probe", "auth login team-picker TTY probe"),
  rule("src/core/auth/login_flow.zig", "writeStdout", /stdio_acquisition_write/, "noninteractive_output", "CLI auth login output"),
  rule("src/core/auth/chatgpt_oauth.zig", "writeStdout", /stdio_acquisition_write/, "noninteractive_output", "Codex CLI login output"),
  rule("src/core/auth/grok_oauth.zig", "writeStdout", /stdio_acquisition_write/, "noninteractive_output", "Grok CLI login output"),
  rule("src/core/shared/debug_trace.zig", "(?:writeLine|writeNoninteractiveStderr)", /debug_print/, "noninteractive_output", "opt-in tracing"),
  rule("tests/json-schema/corpus_runner.zig", "printLine", /stdio_acquisition/, "noninteractive_output", "JSON Schema corpus report output"),
  rule("src/main.zig", "(?:writeStdoutFast|writeStderrFast)", /(?:stdio_acquisition_write|fixed_fd_write|raw_fd_write)/, "noninteractive_output", "top-level help and CLI validation output"),
  rule("src/main.zig", "(?:stdoutIsTerminal|stdoutTerminalColumns)", /fixed_descriptor/, "terminal_probe", "top-level help terminal capability probe"),
  rule("src/main.zig", "runExternalInteractive", /stdio_acquisition_write/, "initialization_teardown", "external CLI handoff spacing"),
  rule("benchmarks/activity_progress.zig", "main", /stdio_acquisition/, "benchmark_output", "benchmark report output"),
  rule("src/core/shell_command/command_effect.zig", "(?:expectDirect|expectNativePrintfEquivalent)", /debug_print/, "tests", "test diagnostics"),
  rule("src/core/app/app_worker_runtime.zig", "(?:printModelTrace|printLifecycleDrainTrace)", /debug_print/, "tests", "test diagnostics"),
];

function rule(
  path: string,
  functionName: string,
  primitive: RegExp,
  category: Category,
  reason: string,
): AllowRule {
  return { path, functionName: new RegExp(`^${functionName}$`), primitive, category, reason };
}

function listZigFiles(root: string, directory = "src"): string[] {
  const absolute = join(root, directory);
  if (!existsSync(absolute)) return [];
  const files: string[] = [];
  for (const entry of readdirSync(absolute)) {
    const path = join(directory, entry);
    const metadata = statSync(join(root, path));
    if (metadata.isDirectory()) files.push(...listZigFiles(root, path));
    else if (entry.endsWith(".zig")) files.push(path);
  }
  return files;
}

function braceDelta(line: string): number {
  let delta = 0;
  for (const character of line) {
    if (character === "{") delta += 1;
    else if (character === "}") delta -= 1;
  }
  return delta;
}

function assignment(line: string): { target: string; expression: string } | null {
  const match = /\b(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:[^=;]+)?\s*=\s*([^;]+);/.exec(line);
  return match ? { target: match[1]!, expression: match[2]!.trim() } : null;
}

function hasVisibleName(
  local: Set<string>,
  topLevel: Set<string>,
  name: string,
): boolean {
  return local.has(name) || topLevel.has(name);
}

function callsVisibleName(
  line: string,
  isVisible: (name: string) => boolean,
): boolean {
  for (const match of line.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
    if (isVisible(match[1]!)) return true;
  }
  return false;
}

function recordStdioProvenance(
  line: string,
  scope: StdioProvenance,
  topLevel: StdioProvenance,
): boolean {
  const value = assignment(line);
  if (!value) return false;

  if (/^std\.Io\.File\.(?:stdout|stderr)$/.test(value.expression)) {
    scope.acquirers.add(value.target);
    return true;
  }
  if (/^std\.Io\.File\.(?:stdout|stderr)\s*\(\s*\)$/.test(value.expression)) {
    scope.handles.add(value.target);
    return true;
  }

  const called = /^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)$/.exec(value.expression)?.[1];
  if (called && hasVisibleName(scope.acquirers, topLevel.acquirers, called)) {
    scope.handles.add(value.target);
    return true;
  }

  const source = /^([A-Za-z_][A-Za-z0-9_]*)$/.exec(value.expression)?.[1];
  if (!source) return false;
  if (hasVisibleName(scope.acquirers, topLevel.acquirers, source)) {
    scope.acquirers.add(value.target);
    return true;
  }
  if (hasVisibleName(scope.handles, topLevel.handles, source)) {
    scope.handles.add(value.target);
  }
  return false;
}

function detectPrimitive(
  path: string,
  line: string,
  functionName: string,
  isStdioAcquirer: (name: string) => boolean,
  isStdioHandle: (name: string) => boolean,
  aliasedAcquisition: boolean,
): string | null {
  const snippet = line.trim();

  const stdio = /std\.Io\.File\.(?:stdout|stderr)\b(?:\s*\(\s*\))?/.test(snippet);
  const acquirerCall = callsVisibleName(snippet, isStdioAcquirer);
  const streamingWrite = /\.writeStreaming(?:All)?\(/.test(snippet);
  if (stdio || aliasedAcquisition || acquirerCall) {
    return streamingWrite ? "stdio_acquisition_write" : "stdio_acquisition";
  }

  if (/std\.posix\.(?:STDOUT|STDERR)_FILENO/.test(snippet)) {
    return /std\.c\.write\(|\bwriteFdAll\(/.test(snippet)
      ? "fixed_fd_write"
      : "fixed_descriptor";
  }
  if (/std\.debug\.print\(/.test(snippet)) return "debug_print";
  if (/std\.c\.write\(/.test(snippet) && functionName === "writeFdAll") return "raw_fd_write";
  if (/\bwriteFdAll\(/.test(snippet)) return "delegated_fd_write";
  if (/\bflush_writer\(/.test(snippet)) return "buffered_stdio_write";

  if (/\.initStreaming\(/.test(snippet)) {
    const source = /\.initStreaming\(\s*([A-Za-z_][A-Za-z0-9_]*)/.exec(snippet)?.[1];
    if (source && isStdioHandle(source)) return "buffered_stdio_acquisition";
  }
  if (/\.(?:stdout|stderr)\s*=\s*&[A-Za-z_][A-Za-z0-9_.]*\.interface/.test(snippet)) {
    return "writer_delegation";
  }
  if (streamingWrite) {
    const receiver = /([A-Za-z_][A-Za-z0-9_.?]*)\.writeStreaming(?:All)?\(/.exec(snippet)?.[1];
    const name = receiver?.split(".").at(-1);
    if (name && (isStdioHandle(name) || /^(?:stdout|stderr|stdout_file|stderr_file)$/.test(name))) {
      return "stdio_write";
    }
  }
  return null;
}

function classify(path: string, functionName: string, primitive: string): Pick<Site, "category" | "reason"> {
  const match = allowlist.find((entry) =>
    entry.path === path &&
    entry.functionName.test(functionName) &&
    entry.primitive.test(primitive)
  );
  return match
    ? { category: match.category, reason: match.reason }
    : { category: "unclassified", reason: "no matching ownership exception" };
}

function scanFile(root: string, path: string): Site[] {
  if (/(?:^|\/)[^/]*_tests\.zig$/.test(path)) return [];
  const lines = readFileSync(join(root, path), "utf8").split(/\r?\n/);
  const sites: Site[] = [];
  let depth = 0;
  let testDepth: number | null = null;
  let pendingFunction: string | null = null;
  const topLevel: StdioProvenance = { acquirers: new Set(), handles: new Set() };
  let activeFunction: { name: string; depth: number; provenance: StdioProvenance } | null = null;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]!;
    if (testDepth === null && /^\s*test(?:\s+"[^"]*"|\s*)\s*\{/.test(line)) {
      testDepth = depth;
    }
    if (testDepth !== null) {
      depth += braceDelta(line);
      if (depth <= testDepth) testDepth = null;
      continue;
    }

    const functionMatch = /^\s*(?:pub\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)/.exec(line);
    if (functionMatch) pendingFunction = functionMatch[1]!;
    if (pendingFunction && line.includes("{")) {
      activeFunction = {
        name: pendingFunction,
        depth,
        provenance: { acquirers: new Set(), handles: new Set() },
      };
      pendingFunction = null;
    }
    const functionName = activeFunction?.name ?? "<top-level>";
    const provenance = activeFunction?.provenance ?? topLevel;
    const aliasedAcquisition = recordStdioProvenance(line, provenance, topLevel);
    const isStdioAcquirer = (name: string) =>
      hasVisibleName(provenance.acquirers, topLevel.acquirers, name);
    const isStdioHandle = (name: string) =>
      hasVisibleName(provenance.handles, topLevel.handles, name);

    const primitive = detectPrimitive(
      path,
      line,
      functionName,
      isStdioAcquirer,
      isStdioHandle,
      aliasedAcquisition,
    );
    if (primitive) {
      sites.push({
        path,
        line: index + 1,
        functionName,
        primitive,
        snippet: line.trim(),
        ...classify(path, functionName, primitive),
      });
    }

    depth += braceDelta(line);
    if (activeFunction && depth <= activeFunction.depth) activeFunction = null;
  }
  return sites;
}

function parseRepoRoot(): string {
  const index = process.argv.indexOf("--repo-root");
  return index >= 0 ? process.argv[index + 1] ?? "." : ".";
}

const root = parseRepoRoot();
const sites = listZigFiles(root).flatMap((path) => scanFile(root, path));
const failures = sites.filter((site) => site.category === "unclassified");
for (const site of failures) {
  console.error(
    `unclassified_direct_write ${site.path}:${site.line} ` +
      `function=${site.functionName} primitive=${site.primitive}: ${site.snippet}`,
  );
}
if (failures.length > 0) {
  throw new Error(`direct-write audit found ${failures.length} unclassified site(s)`);
}

const frameCommits = sites.filter((site) => site.category === "frame_commit");
if (frameCommits.length !== 1) {
  console.error(`frame_commit expected=1 actual=${frameCommits.length}`);
  throw new Error("direct-write audit requires exactly one normal interactive frame commit");
}

if (process.argv.includes("--inventory")) {
  for (const site of sites) {
    if (site.category === "tests") continue;
    console.log(
      `direct_write path=${site.path} line=${site.line} function=${site.functionName} ` +
        `primitive=${site.primitive} category=${site.category} reason=${JSON.stringify(site.reason)}`,
    );
  }
}

console.log(
  `direct-write audit passed ${relative(process.cwd(), root) || "."} ` +
    `frame_commit=1 classified=${sites.length} unclassified=0`,
);
