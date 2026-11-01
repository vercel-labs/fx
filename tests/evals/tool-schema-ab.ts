/**
 * Model-backed A/B eval of built-in tool schemas.
 *
 * Each arm is an fx binary plus an optional schema variant. A recording proxy
 * in front of AI Gateway swaps the variant's tool definitions into every
 * agent request, so two arms can share one binary and differ only in the
 * bytes the model sees, while fx's own decoders still judge every call. The
 * proxy refuses any key except AI_GATEWAY_TEST_API_KEY.
 *
 * Every task runs in a fresh repository and profile. Per run it records each
 * tool call, its arguments, whether fx answered with an error, the provider's
 * token usage, and whether the task's oracle passed.
 *
 * It makes billed calls and is not a pull request check. Run it through the
 * test lane: `~/.local/bin/aig test bun tool-schema-ab.ts run ...`.
 */
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const UPSTREAM = "https://ai-gateway.vercel.sh";

// ---------------------------------------------------------------------------
// Variants

/** Replacement definitions keyed by tool name, plus system-text swaps. */
export interface Variant {
  tools?: Record<string, { description?: string; inputSchema?: unknown }>;
  /** Text replaced once in each system message that contains it, such as provider-tool guidance or a system prompt line. */
  system?: Array<{ from: string; to: string }>;
}

export function loadVariant(path: string | undefined): Variant {
  if (!path || path === "none") return {};
  return JSON.parse(readFileSync(path, "utf8")) as Variant;
}

/** Applies a variant to one gateway request body in place. */
export function applyVariant(body: Record<string, unknown>, variant: Variant): void {
  if (Array.isArray(body.tools) && variant.tools) {
    body.tools = (body.tools as Array<Record<string, unknown>>).map((tool) => {
      const swap = typeof tool.name === "string" ? variant.tools?.[tool.name] : undefined;
      if (!swap || tool.type !== "function") return tool;
      return {
        ...tool,
        ...(swap.description !== undefined ? { description: swap.description } : {}),
        ...(swap.inputSchema !== undefined ? { inputSchema: swap.inputSchema } : {}),
      };
    });
  }
  if (Array.isArray(body.prompt) && variant.system?.length) {
    for (const message of body.prompt as Array<Record<string, unknown>>) {
      if (message.role !== "system" || typeof message.content !== "string") continue;
      for (const { from, to } of variant.system) {
        if (message.content.includes(from)) message.content = message.content.replace(from, to);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Recording proxy

export interface Usage {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
}

export interface RecordedRequest {
  seq: number;
  agent: boolean;
  toolsHash: string | null;
  toolsBytes: number;
  /** Property names of each advertised function tool, as sent. */
  toolProps: Record<string, string[]>;
  prompt: Array<Record<string, unknown>> | null;
  usage: Usage | null;
  /** The response ran a provider-executed web search. */
  providerSearch: boolean;
  status: number;
}

export function parseStreamUsage(stream: string): Usage | null {
  let usage: Usage | null = null;
  for (const line of stream.split("\n")) {
    if (!line.startsWith("data: ") || !line.includes('"finish"')) continue;
    try {
      const part = JSON.parse(line.slice(6));
      if (part.type !== "finish") continue;
      const input = part.usage?.inputTokens ?? {};
      const output = part.usage?.outputTokens ?? {};
      usage = {
        input: Number(typeof input === "number" ? input : (input.total ?? 0)),
        cacheRead: Number(input.cacheRead ?? 0),
        cacheWrite: Number(input.cacheWrite ?? 0),
        output: Number(typeof output === "number" ? output : (output.total ?? 0)),
      };
    } catch {}
  }
  return usage;
}

function startProxy(variant: Variant, testKey: string) {
  const requests: RecordedRequest[] = [];
  const pending: Promise<void>[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if ((req.headers.get("authorization") ?? "") !== `Bearer ${testKey}`) {
        return new Response("tool-schema-ab: refusing a key other than AI_GATEWAY_TEST_API_KEY", { status: 401 });
      }
      let raw = req.method === "GET" || req.method === "HEAD" ? undefined : await req.text();
      const record: RecordedRequest = { seq: requests.length + 1, agent: false, toolsHash: null, toolsBytes: 0, toolProps: {}, prompt: null, usage: null, providerSearch: false, status: 0 };
      if (raw) {
        try {
          const body = JSON.parse(raw) as Record<string, unknown>;
          const tools = body.tools as Array<Record<string, unknown>> | undefined;
          record.agent = Array.isArray(tools) && tools.some((t) => t.name === "read_file");
          if (record.agent) {
            applyVariant(body, variant);
            raw = JSON.stringify(body);
            const toolsJson = JSON.stringify(body.tools);
            record.toolsBytes = toolsJson.length;
            record.toolsHash = createHash("sha256").update(toolsJson).digest("hex").slice(0, 12);
            for (const tool of body.tools as Array<Record<string, unknown>>) {
              const schema = tool.inputSchema as { properties?: Record<string, unknown> } | undefined;
              if (tool.type === "function" && typeof tool.name === "string") record.toolProps[tool.name] = Object.keys(schema?.properties ?? {});
            }
            record.prompt = body.prompt as Array<Record<string, unknown>>;
          }
        } catch {}
        requests.push(record);
      }
      const headers = new Headers(req.headers);
      for (const name of ["host", "content-length", "accept-encoding"]) headers.delete(name);
      const response = await fetch(UPSTREAM + url.pathname + url.search, { method: req.method, headers, body: raw });
      record.status = response.status;
      const outHeaders = new Headers(response.headers);
      for (const name of ["content-encoding", "content-length"]) outHeaders.delete(name);
      if (!response.body) return new Response(null, { status: response.status, headers: outHeaders });
      const [toClient, toRecord] = response.body.tee();
      pending.push(
        new Response(toRecord)
          .text()
          .then((text) => {
            record.usage = parseStreamUsage(text);
            record.providerSearch = /"toolName":"(exa_search|perplexity_search|parallel_search|web_search)"/.test(text);
          })
          .catch(() => {}),
      );
      return new Response(toClient, { status: response.status, headers: outHeaders });
    },
  });
  return {
    url: `http://127.0.0.1:${server.port}`,
    requests,
    async stop() {
      await Promise.allSettled(pending);
      server.stop(true);
    },
  };
}

// ---------------------------------------------------------------------------
// Fixture

const INVENTORY_LINES = (() => {
  const lines: string[] = ['"""Warehouse inventory records."""', ""];
  for (let i = 3; i <= 150; i++) {
    if (i === 87) lines.push('WAREHOUSE_CODE = "QX-4471"');
    else if (i === 123) lines.push("BIN_SEED = 'zeta-19'");
    else if (i % 10 === 0) lines.push(`# section ${i / 10}`);
    else lines.push(`SLOT_${i} = ${i * 3}`);
  }
  return lines;
})();

export const FIXTURE_FILES: Record<string, string> = {
  "README.md": "# ledger\n\nSmall bookkeeping toolkit. See docs/design.md for the module layout.\n",
  "src/ledger/__init__.py": '"""ledger: small bookkeeping toolkit."""\n',
  "src/ledger/pricing.py": [
    '"""Prices, discounts, and tax."""',
    "",
    "TAX_RATE = 0.07",
    "",
    "",
    "def apply_discount(amount, percent, legacy_mode=False):",
    "    if legacy_mode:",
    "        return round(amount - percent, 2)",
    "    return round(amount * (100 - percent) / 100, 2)",
    "",
    "",
    "def with_tax(amount):",
    "    # TODO: support per-region tax tables",
    "    return round(amount * (1 + TAX_RATE), 2)",
    "",
  ].join("\n"),
  "src/ledger/inventory.py": INVENTORY_LINES.join("\n") + "\n",
  "src/ledger/reports.py": [
    '"""Report builders."""',
    "",
    "from .pricing import apply_discount",
    "",
    "",
    "def build_summary(rows):",
    "    total = sum(apply_discount(r, 0, legacy_mode=True) for r in rows)",
    '    return {"rows": len(rows), "total": total}',
    "",
    "",
    "def print_summary(rows):",
    "    # Deprecated: callers should format the summary themselves.",
    "    print(build_summary(rows))",
    "",
  ].join("\n"),
  "src/ledger/utils/__init__.py": "",
  "src/ledger/utils/strings.py": [
    '"""String helpers."""',
    "",
    "",
    "def slugify(text):",
    '    """DEPRECATED: use slugify_v2."""',
    '    return text.lower().replace(" ", "-")',
    "",
    "",
    "def slugify_v2(text):",
    '    return "-".join(text.lower().split())',
    "",
    "",
    "# This deprecated alias stays for old imports.",
    "make_slug = slugify",
    "",
  ].join("\n"),
  "tests/test_pricing.py": [
    "import os",
    "import sys",
    "import unittest",
    "",
    "sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'src'))",
    "",
    "from ledger.pricing import apply_discount, with_tax",
    "",
    "",
    "class PricingTest(unittest.TestCase):",
    "    def test_discount(self):",
    "        self.assertEqual(apply_discount(100, 10), 90.0)",
    "",
    "    def test_legacy_discount(self):",
    "        self.assertEqual(apply_discount(100, 10, legacy_mode=True), 90.0)",
    "",
    "    def test_tax(self):",
    "        self.assertEqual(with_tax(100), 107.0)",
    "",
    "",
    "if __name__ == '__main__':",
    "    unittest.main()",
    "",
  ].join("\n"),
  "docs/design.md": "# Design\n\nTax calculation lives in the pricing module. Reports only aggregate.\n",
  "docs/notes.md": "# Notes\n\n- TODO: document the legacy discount\n- TODO: add a CSV exporter\n- Done: inventory slots\n- TODO: decide the warehouse code format\n",
  "docs/roadmap.md": "# Roadmap\n\n1. Regional tax tables\n2. TODO: pick a report format\n",
  "scripts/slow_report.sh": [
    "#!/bin/sh",
    "i=1",
    "while [ $i -le 8 ]; do",
    '  echo "step $i of 8"',
    "  sleep 5",
    "  i=$((i + 1))",
    "done",
    'echo "REPORT_DONE total=1287"',
    "",
  ].join("\n"),
  "scripts/confirm.sh": [
    "#!/bin/sh",
    'printf "Delete the cache? [y/N] "',
    "read answer",
    'if [ "$answer" = "y" ]; then echo "CACHE-CLEARED"; else echo "ABORTED"; fi',
    "",
  ].join("\n"),
  "scripts/big_report.py": [
    "import time",
    "",
    "time.sleep(2)",
    "for i in range(1, 3001):",
    "    if i == 1500:",
    "        print('CHECKSUM: 7f3a91c2')",
    "    else:",
    "        print(f'row {i}: value={i * 7 % 1000:04d} status=ok')",
    "",
  ].join("\n"),
  "vendor/skills/poem-writer/SKILL.md":
    "---\nname: poem-writer\ndescription: Write a short poem about a code change. Use when asked for a poem.\n---\n\n# Poem writer\n\nWrite exactly three lines in 5-7-5 syllables. End with the word POEM-DONE.\n",
};

/** A small PNG that reads "CODE K7-PLUM", for the vision task. */
const BADGE_PNG_BASE64 = [
  "iVBORw0KGgoAAAANSUhEUgAAAZAAAABQCAYAAAA3ICPMAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3Cc",
  "ulE8AAAARGVYSWZNTQAqAAAACAABh2kABAAAAAEAAAAaAAAAAAADoAEAAwAAAAEAAQAAoAIABAAAAAEAAAGQoAMABAAAAAEAAABQAAAAADl4VLIAAAHLaVRY",
  "dFhNTDpjb20uYWRvYmUueG1wAAAAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJYTVAgQ29yZSA2LjAuMCI+CiAgIDxy",
  "ZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgICAgIDxyZGY6RGVzY3JpcHRpb24gcmRm",
  "OmFib3V0PSIiCiAgICAgICAgICAgIHhtbG5zOmV4aWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vZXhpZi8xLjAvIj4KICAgICAgICAgPGV4aWY6Q29sb3JTcGFj",
  "ZT4xPC9leGlmOkNvbG9yU3BhY2U+CiAgICAgICAgIDxleGlmOlBpeGVsWERpbWVuc2lvbj42MDA8L2V4aWY6UGl4ZWxYRGltZW5zaW9uPgogICAgICAgICA8",
  "ZXhpZjpQaXhlbFlEaW1lbnNpb24+MTIwPC9leGlmOlBpeGVsWURpbWVuc2lvbj4KICAgICAgPC9yZGY6RGVzY3JpcHRpb24+CiAgIDwvcmRmOlJERj4KPC94",
  "OnhtcG1ldGE+CncGs+4AABtWSURBVHgB7Z0F8NzEF8e3uLtrgUJxLy7FpVhxd4oXikNhkAKDU4qXUlwKFHcpxYsWihZ3d/f895P/7PGyl7tLcsn9JO/N3CSX",
  "ZO2b3X26my6BJaOkCCgCioAioAikRGCclM/r44qAIqAIKAKKQIiAMhDtCIqAIqAIKAKZEFAGkgk2TaQIKAKKgCKgDET7gCKgCCgCikAmBJSBZIJNEykCioAi",
  "oAgoA9E+oAgoAoqAIpAJAWUgmWDTRIqAIqAIKALKQLQPKAKKgCKgCGRCQBlIJtg0kSKgCCgCioAyEO0DioAioAgoApkQUAaSCTZNpAgoAoqAIqAMRPuAIqAI",
  "KAKKQCYElIFkgk0TKQKKgCKgCCgD0T6gCCgCioAikAkBZSCZYNNEioAioAgoAspAtA8oAoqAIqAIZEJAGUgm2DSRIqAIKAKKgDIQ7QOKgCKgCCgCmRBQBpIJ",
  "Nk2kCCgCioAioAxE+4AioAgoAopAJgTGy5Qqx0Sffvqpef31183XX39tvvzyyzDn8ccf30w55ZSma9euZtFFFzWTTjppjiX+P6t///3XvPfee+bjjz82n3/+",
  "ufnmm2/MX3/9ZSaZZBIzwwwzmGmnndZ069bNzDTTTLmXrRkqAoqAItAZEGgTBvLhhx+a+++/39xyyy3m2WefNT///LP5+++/wwncgTreeOOZiSaayEw99dRm",
  "pZVWMttuu61ZffXVwwnePZPl+Oqrr5qHHnrIDB8+3Lz88svmjz/+CMuFeUBdunQxE0wwgaF8mEmPHj3MxhtvHNZhwQUXTFXk5ZdfbkaNGhXmlSRhEARhmTPO",
  "OKOZeeaZzdxzz23mn3/+EIMk6d0z5HP22Webd955J2yPu97s8Z9//gnrdOCBBxqYfFYaO3asufDCC0PcwXvcccc1hx56qJltttlSZ3n11VebJ554IszDJead",
  "LrPMMmaPPfZwl9rt8a233jLnn39+BYs0FaV/TjfddIZ+2b17dzPvvPM2TH7DDTeYhx9+OMSL9znPPPOYfffd10w88cQN0yZ54IUXXjBDhgwx44wzjqEf8m4P",
  "OuigUBhMkt5/hroOGzYsHEPkN/nkk5t+/foZxogkBMHzzjvP/PTTT5E+Txv3228/s9BCC8nHU53/+eef5qKLLgoFXdrjiLyZk7bYYgt3qXTHLvalBK1qNS+C",
  "SfX00083b7/9dupiV1ttNTNgwACz4oorpk777bffmhNPPNFcccUVhvO0xEDdbbfdYjtvrbx69+5tbr311lq3G16HiS2xxBJm5ZVXDgfBXHPN1TAND6BdLbnk",
  "kuall15K9HyahxZZZJFwwmYgZ6U77rjDbLTRRpHkMIEVVlghcq3Rn7POOsscccQREcGDNLPPPruBsayyyioGDffee+9tlFXi+2A7yyyzmHXXXTecJBMnrPEg",
  "gtQ666xT427yy65OTK4LL7xwbEKG+s4772yuvPLKyn3e54gRI0JGVLnYxAl577TTTpEcHn300bAPRy4m/HPyySeb/v37V56G0T399NOGekt65plnwsn8l19+",
  "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",
  "Oxe58QAAAABJRU5ErkJggg==",
].join("");

const RELEASE_NOTES_SKILL =
  "---\nname: release-notes\ndescription: Draft release notes for a change. Use when asked to write or draft release notes.\n---\n\n" +
  "# Release notes\n\nStart the notes with the line `RELEASE-NOTES v2`. Then follow the format in `template.md` from this skill exactly.\n";
const RELEASE_NOTES_TEMPLATE = "# Template\n\nAfter the first line, write a `### Highlights` heading and one bullet per change.\n";

const TRACKER_MCP = `
import { appendFileSync } from "node:fs";
const log = process.env.TRACKER_LOG;
const tools = [
  { name: "create_ticket", description: "Create a ticket in the team tracker.", inputSchema: { type: "object", properties: { title: { type: "string" }, priority: { type: "string", enum: ["low", "medium", "high"] } }, required: ["title"] } },
  { name: "close_ticket", description: "Close a ticket by id.", inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } },
  { name: "list_tickets", description: "List open tickets.", inputSchema: { type: "object", properties: {} } },
];
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\\n")) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    const send = (result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\\n");
    if (message.method === "initialize") send({ protocolVersion: message.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "tracker", version: "1.0.0" } });
    else if (message.method === "tools/list") send({ tools });
    else if (message.method === "tools/call") {
      appendFileSync(log, JSON.stringify(message.params) + "\\n");
      const args = message.params?.arguments ?? {};
      const text = message.params?.name === "create_ticket" ? "Created ticket T-31: " + args.title
        : message.params?.name === "close_ticket" ? "Closed ticket " + args.id
        : "T-12 Fix tax rounding (open)";
      send({ content: [{ type: "text", text }] });
    } else if (message.id !== undefined) send({});
  }
});
`;

function git(cwd: string, ...args: string[]): void {
  const result = spawnSync("git", args, { cwd, stdio: "ignore" });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")} failed in ${cwd}`);
}

/**
 * Replaces the shared fixture in `repo` with `files` and makes it look like a
 * real clone of `remote`: a commit history and an up-to-date origin/main.
 */
function seedClone(repo: string, remote: string, files: Record<string, string>, subjects: string[]): void {
  const id = ["-c", "user.email=dev@example.com", "-c", "user.name=dev"];
  rmSync(repo, { recursive: true, force: true });
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(join(repo, path, ".."), { recursive: true });
    writeFileSync(join(repo, path), text);
  }
  git(repo, "init", "-q", "-b", "main");
  git(repo, "remote", "add", "origin", remote);
  subjects.forEach((subject, index) => {
    writeFileSync(join(repo, "HISTORY.log"), subjects.slice(0, index + 1).join("\n") + "\n");
    git(repo, ...id, "add", "-A");
    git(repo, ...id, "commit", "-q", "-m", subject);
  });
  git(repo, "update-ref", "refs/remotes/origin/main", "HEAD");
  git(repo, "branch", "-q", "--set-upstream-to=origin/main", "main");
}

let fxClone: string | null = null;
/** Replaces `repo` with a shallow clone of the real fx repository, cloned once per process. */
function seedFxClone(repo: string): void {
  const remote = "https://github.com/vercel-labs/fx.git";
  if (!fxClone) {
    fxClone = join(mkdtempSync(join(tmpdir(), "fx-schema-ab-fx-")), "fx");
    git(tmpdir(), "clone", "-q", "--depth", "20", "--single-branch", remote, fxClone);
  }
  rmSync(repo, { recursive: true, force: true });
  git(tmpdir(), "clone", "-q", fxClone, repo);
  git(repo, "remote", "set-url", "origin", remote);
}

const V0_FILES: Record<string, string> = {
  "README.md": "# v0\n\nThe v0 web app.\n",
  "package.json": JSON.stringify({ name: "v0", private: true, scripts: { release: "node scripts/release.mjs" } }, null, 2) + "\n",
  "CHANGELOG.md": "# Changelog\n\n## 1.0.0\n\n- Add the release notes page.\n\n## 0.9.0\n\n- Set up the v0 web app.\n",
  "apps/www/release-notes.ts": "// Renders CHANGELOG.md on the release notes page.\nexport const changelogPath = '../../CHANGELOG.md';\n",
  "scripts/release.mjs": "// Moves the Unreleased section of CHANGELOG.md under the new version, then tags the release.\n",
  "docs/changelog.md": "# Writing changelog entries\n\nAdd one line per user-facing change under Unreleased in CHANGELOG.md. The release script stamps the version.\n",
};
const V0_SUBJECTS = [
  "Set up the v0 web app",
  "Add the release notes page",
  "Generate the changelog during release",
  "Document how changelog entries are written",
  "Release 1.0.0",
];

export function writeFixture(root: string): { repo: string; home: string; trackerLog: string } {
  const repo = join(root, "repo");
  const home = join(root, "home");
  for (const [path, text] of Object.entries(FIXTURE_FILES)) {
    mkdirSync(join(repo, path, ".."), { recursive: true });
    writeFileSync(join(repo, path), text);
  }
  writeFileSync(join(repo, "docs/badge.png"), Buffer.from(BADGE_PNG_BASE64, "base64"));
  chmodSync(join(repo, "scripts/slow_report.sh"), 0o755);
  git(repo, "init", "-q", "-b", "main");
  git(repo, "-c", "user.email=eval@example.com", "-c", "user.name=eval", "add", "-A");
  git(repo, "-c", "user.email=eval@example.com", "-c", "user.name=eval", "commit", "-q", "-m", "fixture");

  const fx = join(home, ".fx");
  mkdirSync(join(fx, "skills", "release-notes"), { recursive: true, mode: 0o700 });
  writeFileSync(join(fx, "settings.json"), JSON.stringify({ permission_mode: "full-access" }) + "\n", { mode: 0o600 });
  writeFileSync(join(fx, "skills", "release-notes", "SKILL.md"), RELEASE_NOTES_SKILL);
  writeFileSync(join(fx, "skills", "release-notes", "template.md"), RELEASE_NOTES_TEMPLATE);
  const trackerScript = join(root, "tracker-mcp.mjs");
  const trackerLog = join(root, "tracker.log");
  writeFileSync(trackerScript, TRACKER_MCP);
  writeFileSync(trackerLog, "");
  writeFileSync(
    join(fx, "mcp.json"),
    JSON.stringify({ mcp: { tracker: { type: "local", command: [process.execPath, trackerScript], enabled: true, environment: { TRACKER_LOG: trackerLog } } } }),
  );
  return { repo, home, trackerLog };
}

// ---------------------------------------------------------------------------
// Tool calls

export interface ToolCallRecord {
  id: string;
  name: string;
  input: Record<string, unknown> | null;
  inputRaw: string;
  providerExecuted: boolean;
  resultType: string | null;
  resultText: string;
  error: boolean;
}

function partText(output: unknown): string {
  if (output == null) return "";
  if (typeof output === "string") return output;
  const value = (output as { value?: unknown }).value;
  if (typeof value === "string") return value;
  return JSON.stringify(value ?? output);
}

/** Every tool call and result in one prompt, in order. */
export function extractToolCalls(prompt: Array<Record<string, unknown>>): ToolCallRecord[] {
  const calls: ToolCallRecord[] = [];
  const byId = new Map<string, ToolCallRecord>();
  for (const message of prompt) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, unknown>>) {
      if (part.type === "tool-call") {
        const raw = typeof part.input === "string" ? part.input : JSON.stringify(part.input ?? null);
        let input: Record<string, unknown> | null = null;
        try {
          const parsed = typeof part.input === "string" ? JSON.parse(part.input) : part.input;
          if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) input = parsed as Record<string, unknown>;
        } catch {}
        const record: ToolCallRecord = {
          id: String(part.toolCallId),
          name: String(part.toolName),
          input,
          inputRaw: raw,
          providerExecuted: part.providerExecuted === true,
          resultType: null,
          resultText: "",
          error: false,
        };
        calls.push(record);
        byId.set(record.id, record);
      } else if (part.type === "tool-result") {
        const record = byId.get(String(part.toolCallId));
        if (!record) continue;
        const output = part.output as { type?: string } | undefined;
        record.resultType = output?.type ?? null;
        record.resultText = partText(output).slice(0, 2000);
        record.error = output?.type === "error-text" || output?.type === "error-json" || output?.type === "execution-denied";
      }
    }
  }
  return calls;
}

function userText(message: Record<string, unknown>): string {
  if (typeof message.content === "string") return message.content;
  if (!Array.isArray(message.content)) return "";
  return (message.content as Array<Record<string, unknown>>).map((p) => (typeof p.text === "string" ? p.text : "")).join("\n");
}

/** The last root-agent request: the agent request whose user turn is the task. */
export function rootRequest(requests: RecordedRequest[], taskPrompt: string): RecordedRequest | null {
  const needle = taskPrompt.slice(0, 80);
  let found: RecordedRequest | null = null;
  for (const request of requests) {
    if (!request.agent || !request.prompt) continue;
    if (request.prompt.some((m) => m.role === "user" && userText(m).includes(needle))) found = request;
  }
  return found;
}

// ---------------------------------------------------------------------------
// Tasks

export interface TaskContext {
  output: string;
  calls: ToolCallRecord[];
  /** The `tool_calls` fx itself reports in its JSON output. */
  fxToolCalls: Array<{ name: string; status: string }>;
  /** fx's stderr, which shows progress lines for provider-executed tools. */
  stderr: string;
  /** Some response in the run ran a provider-executed web search. */
  webSearched: boolean;
  repo: string;
  home: string;
  trackerLog: string;
  port: number;
}

export interface Task {
  id: string;
  /** The tool whose schema this task exercises. */
  tool: string;
  prompt: (ctx: { port: number }) => string;
  check: (ctx: TaskContext) => { pass: boolean; reason: string };
  timeoutSec?: number;
  /** Changes the fresh repository before fx starts. */
  setup?: (repo: string) => void;
  cleanup?: (ctx: { port: number }) => void;
}

const has = (text: string, ...needles: string[]) => needles.every((n) => text.toLowerCase().includes(n.toLowerCase()));
const ok = (pass: boolean, reason: string) => ({ pass, reason });
const file = (ctx: TaskContext, path: string) => (existsSync(join(ctx.repo, path)) ? readFileSync(join(ctx.repo, path), "utf8") : null);
// A whole number, not part of a longer number or a decimal; "42." at the end of a sentence counts.
/** `n` appears in `text` as a whole number, so 42 matches "42." but not "142", "42.5", or "1.42". */
export const numberIn = (text: string, n: number) => new RegExp(`(^|[^0-9.])${n}(?![0-9]|\\.[0-9])`).test(text);
const used = (ctx: TaskContext, name: string) => ctx.calls.filter((c) => c.name === name);
// Commands fx started that execute `script`: a call fx rejected before running
// is not a rerun, and reading the script with cat, head, or wc is not running it.
const commandsMatching = (ctx: TaskContext, script: string) => {
  const runs = new RegExp(`(^|[;&|(]\\s*|\\s)(python3?|sh|bash|zsh)\\s+(\\./)?scripts/${script.replace(".", "\\.")}|(^|[;&|(]\\s*)\\./scripts/${script.replace(".", "\\.")}`);
  return used(ctx, "shell").filter((s) => runs.test(String(s.input?.command ?? "")) && !s.error);
};

function killPort(port: number): void {
  spawnSync("sh", ["-c", `lsof -ti tcp:${port} | xargs kill 2>/dev/null`], { stdio: "ignore" });
}

const shellCommands = (ctx: TaskContext) => used(ctx, "shell").map((s) => String(s.input?.command ?? "").trim());
// grep_files also prints "Searching", so read the provider's own stream.
const searchedWeb = (ctx: TaskContext) => ctx.webSearched || ctx.calls.some((call) => call.providerExecuted);
/** A shell command that reaches the network: gh, curl, wget, or a git command that talks to a remote. */
export const isRemoteCommand = (command: string) =>
  /(^|[;&|(]\s*)(gh|curl|wget)\s/.test(command.trim()) || /\bgit\s+(clone|fetch|pull|ls-remote)\b/.test(command);
const isRemoteCall = (call: ToolCallRecord) =>
  call.providerExecuted || call.name === "web_fetch" || (call.name === "shell" && isRemoteCommand(String(call.input?.command ?? "")));

export const TASKS: Task[] = [
  // The two local-first cases from github-routing.test.ts, with full call capture.
  {
    id: "gh-history-local",
    tool: "shell",
    prompt: () => "look for changes/last commits in the fx",
    setup: (repo) => seedFxClone(repo),
    check: (c) => {
      const commands = shellCommands(c);
      const usedGh = commands.some((command) => /^gh\s+/.test(command));
      const usedGit = commands.some((command) => /^git\s+(log|status|branch)\b/.test(command));
      return ok(!usedGh && usedGit && !searchedWeb(c), `local git, no gh, no web search (gh=${usedGh} git=${usedGit})`);
    },
  },
  {
    id: "gh-url-metadata",
    tool: "shell",
    prompt: () => "For https://github.com/vercel/next.js, use GitHub metadata to tell me how many open pull requests it currently has. Do not answer from the URL alone.",
    setup: (repo) => git(repo, "remote", "add", "origin", "https://github.com/vercel-labs/fx.git"),
    check: (c) => {
      // gh is signed out in the fresh profile, so a fallback after gh is fine; reaching past gh first is not.
      const remote = c.calls.find(isRemoteCall);
      const viaGh = remote?.name === "shell" && /(^|[;&|(]\s*)gh\s/.test(String(remote.input?.command ?? "").trim());
      return ok(viaGh, `first remote action is gh (${remote?.name ?? "none"}: ${String(remote?.input?.command ?? remote?.input?.url ?? "").slice(0, 40)})`);
    },
  },
  {
    id: "gh-local-first",
    tool: "read_file",
    prompt: () => "investigate how the v0 changelog works in the v0 GitHub repo",
    setup: (repo) => seedClone(repo, "https://github.com/vercel/v0.git", V0_FILES, V0_SUBJECTS),
    check: (c) => {
      // Any local first step counts: a file tool, or a shell command that stays on this machine.
      const first = c.calls.find((call) => !call.providerExecuted);
      const local = first !== undefined && !isRemoteCall(first) && ["glob_files", "grep_files", "read_file", "shell"].includes(first.name);
      return ok(local && !searchedWeb(c) && has(c.output, "changelog"), `first action local (${first?.name}), no web search`);
    },
  },
  // Held out: no tool text was tuned on these two.
  {
    id: "gh-upstream-local",
    tool: "shell",
    prompt: () => "What changed upstream since my last pull? Summarize the new commits.",
    setup: (repo) => {
      const upstream = join(repo, "..", "upstream.git");
      const peer = join(repo, "..", "peer");
      const id = ["-c", "user.email=eval@example.com", "-c", "user.name=eval"];
      git(join(repo, ".."), "init", "-q", "--bare", "-b", "main", upstream);
      git(repo, "remote", "add", "origin", upstream);
      git(repo, "push", "-q", "origin", "main");
      git(join(repo, ".."), "clone", "-q", upstream, peer);
      writeFileSync(join(peer, "rate_limit.py"), "MAX_REQUESTS_PER_MINUTE = 120\n");
      git(peer, ...id, "add", "rate_limit.py");
      git(peer, ...id, "commit", "-q", "-m", "Add a rate limiter to the API client");
      git(peer, "push", "-q", "origin", "main");
    },
    check: (c) => {
      const commands = shellCommands(c);
      const usedGh = commands.some((command) => /(^|[;&|]\s*)gh\s/.test(command));
      return ok(has(c.output, "rate limit") && !usedGh && !searchedWeb(c) && used(c, "web_fetch").length === 0, `names the upstream commit, local git only (gh=${usedGh})`);
    },
  },
  {
    id: "repo-release-workflow",
    tool: "read_file",
    prompt: () => "Where is the release workflow defined in this repo, and what triggers it?",
    setup: (repo) => {
      git(repo, "remote", "add", "origin", "https://github.com/vercel-labs/fx.git");
      mkdirSync(join(repo, ".github", "workflows"), { recursive: true });
      writeFileSync(join(repo, ".github", "workflows", "release.yml"), "name: Release\non:\n  push:\n    tags: ['v*']\njobs:\n  publish:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo publish\n");
    },
    check: (c) => {
      const first = c.calls.find((call) => !call.providerExecuted);
      const local = first !== undefined && !isRemoteCall(first);
      const remote = c.calls.some(isRemoteCall);
      return ok(local && !remote && has(c.output, "release.yml") && has(c.output, "tag"), `answers from the checkout without going remote (first=${first?.name}, remote=${remote})`);
    },
  },
  {
    id: "read-line-range",
    tool: "read_file",
    prompt: () => "Read lines 120 through 125 of src/ledger/inventory.py and quote line 123 exactly.",
    check: (c) => ok(has(c.output, "zeta-19"), "quotes BIN_SEED line"),
  },
  {
    id: "read-two-files",
    tool: "read_file",
    prompt: () => "Read README.md and docs/design.md, then tell me in one sentence which module owns tax calculation.",
    check: (c) => ok(has(c.output, "pricing"), "names the pricing module"),
  },
  {
    id: "glob-count",
    tool: "glob_files",
    prompt: () => "Exactly how many Python (.py) files are in this repository? Answer with just the number.",
    check: (c) => ok(numberIn(c.output, 8), "counts 8 .py files"),
  },
  {
    id: "glob-list",
    tool: "glob_files",
    prompt: () => "List every markdown file under docs/.",
    check: (c) => ok(has(c.output, "design.md", "notes.md", "roadmap.md"), "lists 3 docs files"),
  },
  {
    id: "grep-files",
    tool: "grep_files",
    prompt: () => "Which files mention legacy_mode? List the file paths only.",
    check: (c) => ok(has(c.output, "pricing.py", "reports.py") && !has(c.output, "strings.py"), "pricing.py and reports.py only"),
  },
  {
    id: "grep-count",
    tool: "grep_files",
    prompt: () => "How many lines under docs/ contain the word TODO? Answer with just the number.",
    check: (c) => ok(numberIn(c.output, 4), "counts 4 TODO lines in docs"),
  },
  {
    id: "grep-case",
    tool: "grep_files",
    prompt: () => "How many lines under src/ mention 'deprecated' in any letter case? Give the number and the files.",
    check: (c) => ok(numberIn(c.output, 3) && has(c.output, "strings.py", "reports.py"), "3 lines in strings.py and reports.py"),
  },
  {
    id: "grep-context",
    tool: "grep_files",
    prompt: () => "Find where apply_discount is defined and show me the two lines that come right after the def line.",
    check: (c) => ok(has(c.output, "if legacy_mode", "return round(amount - percent, 2)"), "shows the two following lines"),
  },
  {
    id: "edit-constant",
    tool: "edit_file",
    prompt: () => "Change TAX_RATE in src/ledger/pricing.py from 0.07 to 0.0825. Do not change anything else.",
    check: (c) => {
      const expected = FIXTURE_FILES["src/ledger/pricing.py"].replace("TAX_RATE = 0.07", "TAX_RATE = 0.0825");
      return ok(file(c, "src/ledger/pricing.py") === expected, "only TAX_RATE changed");
    },
  },
  {
    id: "edit-rename",
    tool: "edit_file",
    prompt: () => "In src/ledger/reports.py rename the function build_summary to build_report_summary, and update its call site in the same file.",
    check: (c) => {
      const text = file(c, "src/ledger/reports.py") ?? "";
      return ok(!/\bbuild_summary\b/.test(text) && (text.match(/build_report_summary/g) ?? []).length === 2 && text.includes("def print_summary"), "renamed def and call");
    },
  },
  {
    id: "write-new",
    tool: "write_file",
    prompt: () => "Create CHANGELOG.md at the repository root containing exactly these two lines:\n## 0.2.0\n- Added a tax override",
    check: (c) => ok((file(c, "CHANGELOG.md") ?? "").trim() === "## 0.2.0\n- Added a tax override", "exact content"),
  },
  {
    id: "write-json",
    tool: "write_file",
    prompt: () => 'Create config/feature_flags.json holding a JSON object with "tax_override" set to true and "beta_reports" set to false.',
    check: (c) => {
      try {
        const value = JSON.parse(file(c, "config/feature_flags.json") ?? "null");
        return ok(value?.tax_override === true && value?.beta_reports === false && Object.keys(value).length === 2, "exact flags");
      } catch {
        return ok(false, "invalid JSON");
      }
    },
  },
  {
    id: "shell-tests",
    tool: "shell",
    prompt: () => "Run the unit tests with `python3 -m unittest discover -s tests` and tell me how many tests ran.",
    check: (c) => ok(numberIn(c.output, 3), "3 tests ran"),
  },
  {
    id: "shell-slow",
    tool: "shell",
    prompt: () => "Run `sh scripts/slow_report.sh` once. It takes about 40 seconds. Tell me the exact final line it prints.",
    check: (c) => ok(has(c.output, "REPORT_DONE total=1287") && commandsMatching(c, "slow_report.sh").length === 1, "final line, started once"),
    timeoutSec: 360,
  },
  {
    id: "shell-service",
    tool: "shell",
    prompt: ({ port }) =>
      `Start a static file server for this repository with \`python3 -m http.server ${port}\` so that it keeps running after you finish, and confirm it serves README.md.`,
    check: (c) => {
      const probe = spawnSync("curl", ["-sf", "--max-time", "3", `http://127.0.0.1:${c.port}/README.md`], { encoding: "utf8" });
      return ok(probe.status === 0 && probe.stdout.includes("ledger"), "server still running after fx exits");
    },
    cleanup: ({ port }) => killPort(port),
  },
  {
    id: "shell-tty-repl",
    tool: "shell",
    prompt: () => "Start python3 in an interactive terminal session, type print(6*7) into it, tell me what it printed, then quit python.",
    check: (c) => {
      const tty = used(c, "shell").some((s) => s.input?.tty === true && !s.error);
      const typed = used(c, "shell").some((s) => String(s.input?.chars ?? "").includes("6*7") && !s.error);
      return ok(numberIn(c.output, 42) && tty && typed, "tty run, typed input, read 42");
    },
  },
  {
    id: "shell-tty-confirm",
    tool: "shell",
    prompt: () => "Run `sh scripts/confirm.sh` and answer y to its prompt. Tell me what it printed at the end.",
    check: (c) => ok(has(c.output, "CACHE-CLEARED"), "answered the prompt"),
  },
  {
    id: "rtr-big-output",
    tool: "read_tool_result",
    prompt: () =>
      "Run `python3 scripts/big_report.py` exactly once (it is slow and expensive, so do not rerun it, pipe it, or filter it) and tell me the CHECKSUM value it prints.",
    check: (c) => ok(has(c.output, "7f3a91c2") && commandsMatching(c, "big_report.py").length === 1, "checksum, ran once"),
  },
  {
    id: "rtr-row",
    tool: "read_tool_result",
    prompt: () =>
      "Run `python3 scripts/big_report.py` exactly once (it is slow and expensive, so do not rerun it, pipe it, or filter it) and tell me the value printed on row 1234.",
    check: (c) => ok(has(c.output, "0638") && commandsMatching(c, "big_report.py").length === 1, "row 1234 value, ran once"),
  },
  {
    id: "subagent-run",
    tool: "subagent",
    prompt: () => "Use a subagent to find which file defines WAREHOUSE_CODE, and report the path it found.",
    check: (c) => ok(used(c, "subagent").some((s) => !s.error) && has(c.output, "inventory.py"), "subagent ran, path reported"),
  },
  {
    id: "subagent-message",
    tool: "subagent",
    prompt: () => "Create a persistent subagent named notes-helper and ask it to count the TODO lines in docs/notes.md. Report its answer.",
    check: (c) => ok(used(c, "subagent").some((s) => !s.error && s.input?.agent === "notes-helper") && numberIn(c.output, 3), "named child answered 3"),
  },
  {
    id: "skill-use",
    tool: "skill",
    prompt: () => "Use the release-notes skill to draft release notes for adding a tax override.",
    // Outcome only: reading the skill's files another way still follows it.
    // Whether the skill tool itself was used shows as a missed target.
    check: (c) => ok(has(c.output, "RELEASE-NOTES v2", "### Highlights"), "skill and template followed"),
  },
  {
    id: "cap-create-ticket",
    tool: "capability_search",
    prompt: () => "Create a ticket titled 'Fix tax rounding' with high priority in our team tracker.",
    check: (c) => {
      const log = readFileSync(c.trackerLog, "utf8");
      return ok(log.includes('"create_ticket"') && log.includes("Fix tax rounding"), "tracker create_ticket called");
    },
  },
  {
    id: "mcp-select-close",
    tool: "mcp_select_tool",
    prompt: () => "Close ticket T-12 using the tracker's close_ticket tool.",
    check: (c) => {
      const log = readFileSync(c.trackerLog, "utf8");
      return ok(log.includes('"close_ticket"') && log.includes("T-12"), "tracker close_ticket called");
    },
  },
  {
    id: "install-local",
    tool: "install_skill",
    prompt: () => "Install the skill in ./vendor/skills/poem-writer.",
    check: (c) => {
      const found = spawnSync("sh", ["-c", `find "${c.home}/.fx" -path '*poem-writer*' -name SKILL.md | head -1`], { encoding: "utf8" }).stdout.trim();
      return ok(found.length > 0 && used(c, "install_skill").some((s) => !s.error), "skill installed");
    },
  },
  {
    id: "ask-choice",
    tool: "ask_user_question",
    prompt: () => "I want to add a cache layer. Before doing anything, ask me which backend I prefer, Redis, Memcached, or SQLite, as a multiple-choice question.",
    // fx ask cannot show a question, so the right result is the question in
    // the reply. A tool call there costs a step but is not wrong, and reading
    // the workspace first is not acting; changing it is.
    check: (c) => ok(has(c.output, "Redis", "Memcached", "SQLite") && c.calls.every((s) => ["ask_user_question", "read_file", "glob_files", "grep_files"].includes(s.name)), "asked in the reply without changing anything"),
  },
  {
    id: "vision-text",
    tool: "vision",
    prompt: () => "What code is written in the image docs/badge.png? Answer with just the code.",
    check: (c) => ok(has(c.output, "K7-PLUM"), "reads the code in the image"),
  },
  {
    id: "fetch-page",
    tool: "web_fetch",
    prompt: () => "Fetch https://example.com and tell me the exact text of its main heading.",
    check: (c) => ok(has(c.output, "Example Domain") && used(c, "web_fetch").some((s) => !s.error), "heading from fetch"),
  },
  {
    id: "search-web",
    tool: "web_search",
    prompt: () => "Search the web for the current stable release of the Zig programming language and cite the page you used.",
    // The provider runs the search inside one model step, so it never reaches
    // the prompt history or fx's tool_calls; fx prints its progress line.
    check: (c) => ok(searchedWeb(c) && /https?:\/\//.test(c.output), "web search used and cited"),
  },
];

// ---------------------------------------------------------------------------
// Runs

export interface Arm {
  name: string;
  bin: string;
  variant: Variant;
  variantPath: string;
}

export interface RunResult {
  arm: string;
  model: string;
  task: string;
  tool: string;
  trial: number;
  exit: number | null;
  timedOut: boolean;
  pass: boolean;
  reason: string;
  output: string;
  calls: ToolCallRecord[];
  fxToolCalls: Array<{ name: string; status: string }>;
  webSearched?: boolean;
  targetCalls: number;
  targetErrors: number;
  allErrors: number;
  offSchemaFields: string[];
  agentRequests: number;
  inputTokens: number;
  outputTokens: number;
  toolsBytes: number;
  toolsHash: string | null;
  usageMissing: number;
  durationMs: number;
  stderrTail: string;
}

let nextPort = 18700 + Math.floor(Math.random() * 500);

export async function runOne(arm: Arm, model: string, task: Task, trial: number, testKey: string, noSave = false): Promise<RunResult> {
  const root = mkdtempSync(join(tmpdir(), `fx-schema-ab-${task.id}-`));
  const { repo, home, trackerLog } = writeFixture(root);
  const port = nextPort++;
  task.setup?.(repo);
  const proxy = startProxy(arm.variant, testKey);
  const prompt = task.prompt({ port });
  const timeoutSec = task.timeoutSec ?? 300;
  const started = Date.now();
  const env: Record<string, string | undefined> = {
    ...process.env,
    HOME: home,
    NO_COLOR: "1",
    FX_SOUND: "0",
    FX_DISABLE_KEYCHAIN: "1",
    FX_SKIP_ONBOARDING: "1",
    FX_AUTO_UPGRADE: "0",
    FX_MODEL: model,
    FX_MAX_AGENT_STEPS: "30",
    FX_GATEWAY_BASE_URL: proxy.url,
    FX_GATEWAY_CHAT_URL: `${proxy.url}/v4/ai/language-model`,
  };
  const askArgs = ["ask", "--full-access", "--json", ...(noSave ? ["--no-save"] : []), "--timeout", String(timeoutSec), "--", prompt];
  const child = spawn(arm.bin, askArgs, {
    cwd: repo,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
  child.stderr.on("data", (chunk: Buffer) => (stderr += chunk.toString()));
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill("SIGKILL");
  }, (timeoutSec + 60) * 1000);
  const exit: number | null = await new Promise((done) => child.on("close", (code) => done(code)));
  clearTimeout(timer);
  await Bun.sleep(300);
  await proxy.stop();

  let output = "";
  let fxToolCalls: Array<{ name: string; status: string }> = [];
  try {
    const doc = JSON.parse(stdout.slice(stdout.indexOf("{")));
    output = String(doc.final_output ?? doc.output ?? "");
    fxToolCalls = (doc.tool_calls ?? []).map((c: { name?: string; status?: string }) => ({ name: String(c.name), status: String(c.status) }));
  } catch {}
  const root_request = rootRequest(proxy.requests, prompt);
  const calls = extractToolCalls(root_request?.prompt ?? []);
  let check = { pass: false, reason: "oracle threw" };
  try {
    const webSearched = proxy.requests.some((r) => r.providerSearch);
    check = task.check({ output, calls, fxToolCalls, stderr, webSearched, repo, home, trackerLog, port });
  } catch (error) {
    check = { pass: false, reason: `oracle threw: ${error}` };
  }
  task.cleanup?.({ port });
  const agent = proxy.requests.filter((r) => r.agent);
  const props = root_request?.toolProps ?? agent[0]?.toolProps ?? {};
  const offSchema = new Set<string>();
  for (const call of calls) {
    if (!call.input || call.providerExecuted || !props[call.name]) continue;
    for (const key of Object.keys(call.input)) if (!props[call.name].includes(key)) offSchema.add(`${call.name}.${key}`);
  }
  const targetCalls = task.tool === "web_search" ? (proxy.requests.some((r) => r.providerSearch) ? [{ error: false }] : []) : calls.filter((c) => c.name === task.tool);
  const result: RunResult = {
    arm: arm.name,
    model,
    task: task.id,
    tool: task.tool,
    trial,
    exit,
    timedOut,
    pass: check.pass,
    reason: check.reason,
    output: output.slice(0, 1500),
    calls,
    fxToolCalls,
    webSearched: proxy.requests.some((r) => r.providerSearch),
    targetCalls: targetCalls.length,
    targetErrors: targetCalls.filter((c) => c.error).length,
    allErrors: calls.filter((c) => c.error).length,
    offSchemaFields: [...offSchema],
    agentRequests: agent.length,
    inputTokens: agent.reduce((sum, r) => sum + (r.usage?.input ?? 0), 0),
    outputTokens: agent.reduce((sum, r) => sum + (r.usage?.output ?? 0), 0),
    toolsBytes: agent[0]?.toolsBytes ?? 0,
    toolsHash: agent[0]?.toolsHash ?? null,
    usageMissing: agent.filter((r) => r.usage === null).length,
    durationMs: Date.now() - started,
    stderrTail: stderr.slice(-600),
  };
  rmSync(root, { recursive: true, force: true });
  return result;
}

export async function pool<T>(items: Array<() => Promise<T>>, size: number): Promise<T[]> {
  const results: T[] = new Array(items.length);
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (next < items.length) {
        const index = next++;
        results[index] = await items[index]();
      }
    }),
  );
  return results;
}

// ---------------------------------------------------------------------------
// Summary

export interface GroupSummary {
  group: string;
  runs: number;
  pass: number;
  targetCalls: number;
  targetErrors: number;
  allErrors: number;
  missedTarget: number;
  offSchema: number;
  meanInputTokens: number;
  meanOutputTokens: number;
  meanRequests: number;
  toolsBytes: number;
}

export function summarize(results: RunResult[], key: (r: RunResult) => string): Record<string, GroupSummary> {
  const groups: Record<string, RunResult[]> = {};
  for (const r of results) (groups[key(r)] ??= []).push(r);
  const out: Record<string, GroupSummary> = {};
  for (const name of Object.keys(groups).sort()) {
    const rs = groups[name];
    const mean = (f: (r: RunResult) => number) => Math.round(rs.reduce((s, r) => s + f(r), 0) / rs.length);
    out[name] = {
      group: name,
      runs: rs.length,
      pass: rs.filter((r) => r.pass).length,
      targetCalls: rs.reduce((s, r) => s + r.targetCalls, 0),
      targetErrors: rs.reduce((s, r) => s + r.targetErrors, 0),
      allErrors: rs.reduce((s, r) => s + r.allErrors, 0),
      missedTarget: rs.filter((r) => r.targetCalls === 0).length,
      offSchema: rs.reduce((s, r) => s + r.offSchemaFields.length, 0),
      meanInputTokens: mean((r) => r.inputTokens),
      meanOutputTokens: mean((r) => r.outputTokens),
      meanRequests: Math.round((rs.reduce((s, r) => s + r.agentRequests, 0) / rs.length) * 10) / 10,
      toolsBytes: Math.max(...rs.map((r) => r.toolsBytes)),
    };
  }
  return out;
}

export function table(rows: Record<string, GroupSummary>): string {
  const header = "| group | runs | pass | target calls | target errors | all errors | missed target | off-schema | mean input tok | mean output tok | mean requests | tools bytes |";
  const rule = "|" + " --- |".repeat(12);
  const lines = Object.values(rows).map(
    (s) =>
      `| ${[s.group, s.runs, s.pass, s.targetCalls, s.targetErrors, s.allErrors, s.missedTarget, s.offSchema, s.meanInputTokens, s.meanOutputTokens, s.meanRequests, s.toolsBytes].join(" | ")} |`,
  );
  return [header, rule, ...lines].join("\n");
}

// ---------------------------------------------------------------------------
// Token measurement

/** Provider-counted input tokens of `body` per model, with and without tools. */
export async function measureTokens(
  body: Record<string, unknown>,
  models: string[],
  testKey: string,
): Promise<Record<string, { none: number; all: number; tools: number }>> {
  async function count(model: string, tools: unknown[] | null): Promise<number> {
    const request: Record<string, unknown> = { ...body, maxOutputTokens: 64 };
    delete request.providerOptions;
    if (tools === null) {
      delete request.tools;
      delete request.toolChoice;
    } else request.tools = tools;
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(`${UPSTREAM}/v4/ai/language-model`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${testKey}`,
          "content-type": "application/json",
          "ai-gateway-protocol-version": "0.0.1",
          "ai-language-model-specification-version": "4",
          "ai-language-model-id": model,
          "ai-language-model-streaming": "false",
        },
        body: JSON.stringify(request),
      });
      const text = await res.text();
      if (res.ok) {
        const input = JSON.parse(text).usage?.inputTokens;
        return Number(typeof input === "number" ? input : input?.total);
      }
      if (attempt >= 3) throw new Error(`${model}: HTTP ${res.status} ${text.slice(0, 200)}`);
      await Bun.sleep(2000 * (attempt + 1));
    }
  }
  const out: Record<string, { none: number; all: number; tools: number }> = {};
  await Promise.all(
    models.map(async (model) => {
      const none = await count(model, null);
      const all = await count(model, body.tools as unknown[]);
      out[model] = { none, all, tools: all - none };
    }),
  );
  return out;
}

// ---------------------------------------------------------------------------
// Probes: one model step from a captured interactive request, for tools that
// `fx ask` cannot run, such as ask_user_question.

export interface ProbeCall {
  name: string;
  input: Record<string, unknown> | null;
}

export interface Probe {
  id: string;
  tool: string;
  prompt: string;
  check: (calls: ProbeCall[]) => { pass: boolean; reason: string };
}

function validQuestions(input: Record<string, unknown> | null, count: number): boolean {
  const qs = input?.questions;
  return (
    Array.isArray(qs) &&
    qs.length === count &&
    qs.every(
      (q: any) =>
        typeof q?.question === "string" &&
        q.question.length > 0 &&
        Array.isArray(q?.options) &&
        q.options.length >= 2 &&
        q.options.length <= 6 &&
        q.options.every((o: any) => typeof o?.label === "string" && o.label.length > 0 && Object.keys(o).every((k) => k === "label" || k === "description")),
    )
  );
}

const noQuestion = (calls: ProbeCall[]) => ok(!calls.some((c) => c.name === "ask_user_question"), "did not ask the user");

export const PROBES: Probe[] = [
  // Over-asking: each of these is answerable from the workspace or needs no decision.
  { id: "ask-not-handle", tool: "ask_user_question", prompt: "Open a draft pull request for the current branch.", check: noQuestion },
  { id: "ask-not-discoverable", tool: "ask_user_question", prompt: "Add a test for the pricing module using whatever test framework this project already uses.", check: noQuestion },
  { id: "ask-not-trivial", tool: "ask_user_question", prompt: "Fix the typo in README.md: 'bookeeping' should be 'bookkeeping'.", check: noQuestion },
  {
    id: "ask-one",
    tool: "ask_user_question",
    prompt: "I want to add a cache layer to this project. Before doing anything, ask me which backend I prefer: Redis, Memcached, or SQLite.",
    check: (calls) => ok(calls[0]?.name === "ask_user_question" && validQuestions(calls[0].input, 1), "one valid question"),
  },
  {
    id: "ask-two",
    tool: "ask_user_question",
    prompt: "Before you start on the cache layer, ask me two things: the backend (Redis, Memcached, or SQLite) and the eviction policy (LRU or LFU).",
    check: (calls) => ok(calls[0]?.name === "ask_user_question" && validQuestions(calls[0].input, 2), "two valid questions"),
  },
];

async function probeOnce(body: Record<string, unknown>, model: string, prompt: string, testKey: string): Promise<{ calls: ProbeCall[]; usage: Usage | null; text: string; error?: string }> {
  const request: Record<string, unknown> = structuredClone(body);
  const messages = request.prompt as Array<Record<string, unknown>>;
  messages[messages.length - 1] = { role: "user", content: [{ type: "text", text: prompt }] };
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(`${UPSTREAM}/v4/ai/language-model`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${testKey}`,
        "content-type": "application/json",
        "ai-gateway-protocol-version": "0.0.1",
        "ai-language-model-specification-version": "4",
        "ai-language-model-id": model,
        "ai-language-model-streaming": "false",
      },
      body: JSON.stringify(request),
    });
    const raw = await res.text();
    if (!res.ok) {
      if (attempt >= 3) return { calls: [], usage: null, text: "", error: `HTTP ${res.status} ${raw.slice(0, 200)}` };
      await Bun.sleep(2000 * (attempt + 1));
      continue;
    }
    const json = JSON.parse(raw);
    const content = (json.content ?? []) as Array<Record<string, unknown>>;
    const calls = content
      .filter((p) => p.type === "tool-call")
      .map((p) => {
        let input: Record<string, unknown> | null = null;
        try {
          input = typeof p.input === "string" ? JSON.parse(p.input) : (p.input as Record<string, unknown>);
        } catch {}
        return { name: String(p.toolName), input };
      });
    const text = content.filter((p) => p.type === "text").map((p) => String(p.text)).join("");
    const input = json.usage?.inputTokens;
    const output = json.usage?.outputTokens;
    return {
      calls,
      text,
      usage: { input: Number(typeof input === "number" ? input : input?.total), cacheRead: 0, cacheWrite: 0, output: Number(typeof output === "number" ? output : output?.total) },
    };
  }
}

// ---------------------------------------------------------------------------
// CLI

function arg(name: string, fallback?: string): string {
  const index = process.argv.indexOf(`--${name}`);
  if (index >= 0 && index + 1 < process.argv.length) return process.argv[index + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`missing --${name}`);
}

function list(value: string): string[] {
  return value
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

async function main(): Promise<void> {
  const command = process.argv[2];
  const testKey = process.env.AI_GATEWAY_TEST_API_KEY ?? "";
  if (!testKey) throw new Error("AI_GATEWAY_TEST_API_KEY is empty; run through ~/.local/bin/aig test");

  if (command === "tokens") {
    // tokens --body captured.json --variants none,a.json --models m1,m2 [--out report.json]
    const captured = JSON.parse(readFileSync(arg("body"), "utf8"));
    const base = (captured.body ?? captured) as Record<string, unknown>;
    const models = list(arg("models"));
    const report: Record<string, unknown> = {};
    for (const path of list(arg("variants", "none"))) {
      const body = structuredClone(base);
      applyVariant(body, loadVariant(path));
      const counts = await measureTokens(body, models, testKey);
      report[path] = { bytes: JSON.stringify(body.tools).length, counts };
      console.log(path, JSON.stringify(report[path]));
    }
    if (process.argv.includes("--out")) writeFileSync(arg("out"), JSON.stringify(report, null, 2));
    return;
  }

  if (command === "run") {
    // run --arms A=bin[@variant.json],B=bin@variant.json --models m1,m2 [--tools t1|--tasks id1] --trials 2 --out dir --concurrency 8
    const arms: Arm[] = list(arg("arms")).map((spec) => {
      const [name, rest] = spec.split("=");
      const [bin, variantPath = "none"] = rest.split("@");
      return { name, bin: resolve(bin), variant: loadVariant(variantPath), variantPath };
    });
    const models = list(arg("models"));
    const toolFilter = list(arg("tools", ""));
    const taskFilter = list(arg("tasks", ""));
    const tasks = TASKS.filter((t) => (toolFilter.length === 0 || toolFilter.includes(t.tool)) && (taskFilter.length === 0 || taskFilter.includes(t.id)));
    if (tasks.length === 0) throw new Error("no tasks selected");
    const trials = Number(arg("trials", "2"));
    const outDir = arg("out");
    const concurrency = Number(arg("concurrency", "8"));
    const noSave = process.argv.includes("--no-save");
    mkdirSync(outDir, { recursive: true });
    writeFileSync(
      join(outDir, "config.json"),
      JSON.stringify({ arms: arms.map((a) => ({ name: a.name, bin: a.bin, variantPath: a.variantPath, variant: a.variant })), models, tasks: tasks.map((t) => t.id), trials }, null, 2),
    );

    const jobs: Array<() => Promise<RunResult>> = [];
    for (let trial = 0; trial < trials; trial++) {
      for (const model of models) {
        for (const task of tasks) {
          // Alternate which arm goes first so neither always warms the cache.
          const order = trial % 2 === 0 ? arms : [...arms].reverse();
          for (const arm of order) {
            jobs.push(async () => {
              const result = await runOne(arm, model, task, trial, testKey, noSave);
              writeFileSync(join(outDir, `${model.replaceAll("/", "_")}-${task.id}-${arm.name}-${trial}.json`), JSON.stringify(result, null, 2));
              const calls = result.calls.map((c) => c.name + (c.error ? "!" : "")).join(",");
              console.log(
                `${result.pass ? "PASS" : "FAIL"} ${arm.name.padEnd(9)} ${model.padEnd(28)} ${task.id.padEnd(18)} t${trial} in=${result.inputTokens} calls=${calls} ${result.pass ? "" : result.reason}`,
              );
              return result;
            });
          }
        }
      }
    }
    const results = await pool(jobs, concurrency);
    writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 2));
    const report = [
      "## By arm",
      table(summarize(results, (r) => r.arm)),
      "",
      "## By arm and model",
      table(summarize(results, (r) => `${r.arm} ${r.model}`)),
      "",
      "## By arm and task",
      table(summarize(results, (r) => `${r.arm} ${r.task}`)),
    ].join("\n");
    writeFileSync(join(outDir, "summary.md"), report + "\n");
    console.log(report);
    console.log(`artifacts: ${outDir}`);
    return;
  }

  if (command === "rescore") {
    // rescore --out dir --tasks id1,id2: re-judge stored runs of tasks whose oracle reads only
    // the output and tool calls, after an oracle fix, without new model calls.
    const outDir = arg("out");
    const wanted = new Set(list(arg("tasks")));
    const results = JSON.parse(readFileSync(join(outDir, "results.json"), "utf8")) as RunResult[];
    let changed = 0;
    for (const r of results) {
      const task = TASKS.find((t) => t.id === r.task);
      if (!task || !wanted.has(r.task)) continue;
      const verdict = task.check({
        output: r.output,
        calls: r.calls,
        fxToolCalls: r.fxToolCalls ?? [],
        stderr: r.stderrTail,
        webSearched: r.webSearched ?? false,
        repo: "/nonexistent",
        home: "/nonexistent",
        trackerLog: "/dev/null",
        port: 0,
      });
      if (verdict.pass !== r.pass) changed++;
      r.pass = verdict.pass;
      r.reason = verdict.reason;
    }
    writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 2));
    const report = [
      "## By arm",
      table(summarize(results, (r) => r.arm)),
      "",
      "## By arm and model",
      table(summarize(results, (r) => `${r.arm} ${r.model}`)),
      "",
      "## By arm and task",
      table(summarize(results, (r) => `${r.arm} ${r.task}`)),
    ].join("\n");
    writeFileSync(join(outDir, "summary.md"), report + "\n");
    console.log(`rescored ${changed} changed verdicts`);
    console.log(report);
    return;
  }

  if (command === "probe") {
    // probe --body tui-body.json --arms A=none,B=variant.json --models m1,m2 --trials 3 --out dir
    const captured = JSON.parse(readFileSync(arg("body"), "utf8"));
    const base = (captured.body ?? captured) as Record<string, unknown>;
    const arms = list(arg("arms")).map((spec) => {
      const [name, path] = spec.split("=");
      const body = structuredClone(base);
      applyVariant(body, loadVariant(path));
      return { name, body };
    });
    const models = list(arg("models"));
    const trials = Number(arg("trials", "3"));
    const outDir = arg("out");
    const probeFilter = list(arg("probes", ""));
    const probes = PROBES.filter((p) => probeFilter.length === 0 || probeFilter.includes(p.id));
    mkdirSync(outDir, { recursive: true });
    const jobs: Array<() => Promise<Record<string, unknown>>> = [];
    for (let trial = 0; trial < trials; trial++)
      for (const model of models)
        for (const probe of probes)
          for (const arm of arms)
            jobs.push(async () => {
              const result = await probeOnce(arm.body, model, probe.prompt, testKey);
              const verdict = result.error ? ok(false, result.error) : probe.check(result.calls);
              const line = { arm: arm.name, model, probe: probe.id, trial, ...verdict, calls: result.calls, text: result.text.slice(0, 300), usage: result.usage };
              console.log(`${verdict.pass ? "PASS" : "FAIL"} ${arm.name.padEnd(6)} ${model.padEnd(28)} ${probe.id} t${trial} ${verdict.pass ? "" : verdict.reason + " " + JSON.stringify(result.calls).slice(0, 200)}`);
              return line;
            });
    const results = await pool(jobs, Number(arg("concurrency", "8")));
    writeFileSync(join(outDir, "probe-results.json"), JSON.stringify(results, null, 2));
    const tally: Record<string, { pass: number; runs: number; input: number }> = {};
    for (const r of results as Array<any>) {
      const key = `${r.arm} ${r.model}`;
      tally[key] ??= { pass: 0, runs: 0, input: 0 };
      tally[key].runs++;
      if (r.pass) tally[key].pass++;
      tally[key].input += r.usage?.input ?? 0;
    }
    for (const [key, t] of Object.entries(tally).sort()) console.log(`${key}: ${t.pass}/${t.runs} pass, mean input ${Math.round(t.input / t.runs)}`);
    return;
  }

  throw new Error("usage: tool-schema-ab.ts run|rescore|tokens|probe ...");
}

if (import.meta.main) await main();
