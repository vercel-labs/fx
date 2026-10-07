import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  isComposerLine,
  startFakeGateway,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const tmuxTest = test.skipIf(!tmuxAvailable());
const TIMEOUT = 60_000;
// The defaults keep the deterministic suite fast. The PGSO training corpus
// raises both so file search reaches the hot part of the release profile.
const FILE_COUNT = boundedEnvInt("FX_E2E_FILE_SEARCH_FILES", 2_000, 500, 100_000);
const ROUNDS = boundedEnvInt("FX_E2E_FILE_SEARCH_ROUNDS", 1, 1, 50);

const PACKAGES = [
  "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
  "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
];
const AREAS = ["src/lib", "src/views", "src/state", "test/unit", "test/fixtures", "scripts"];
const STEMS = ["quick", "brown", "lazy", "jumping", "silent", "bright", "nimble", "steady"];
const NOUNS = ["Widget", "Store", "Reducer", "Loader", "Format", "Bridge", "Cache", "Queue"];
const EXTENSIONS = [".ts", ".tsx", ".zig", ".md", ".json", ".go"];

// Targeted queries name one file that must be listed. Broad queries match
// thousands of files, like the first letters a user types, and must list
// results containing the word.
const TARGETS = [
  { query: "@authroute", path: "packages/auth/src/routes/AuthRouteHandler.ts" },
  { query: "@invoice", path: "packages/billing/src/export/billing_invoice_export.zig" },
  { query: "@cmdpal", path: "packages/editor/src/commands/command-palette.tsx" },
  { query: "@readme", path: "docs/README.md" },
  { query: "@ärger", path: "packages/locales/de/Ärger-übersetzung.md" },
  { query: "@srcstorequeue", path: "packages/kilo/src/state/StoreQueue.ts" },
] as const;
const BROAD_QUERIES = ["@store", "@cache", "@test", "@quick"] as const;

function boundedEnvInt(name: string, fallback: number, minimum: number, maximum: number): number {
  const raw = process.env[name];
  if (raw === undefined) return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer in [${minimum}, ${maximum}]`);
  }
  return value;
}

function bulkPath(index: number): string {
  const pkg = PACKAGES[index % PACKAGES.length]!;
  const area = AREAS[Math.floor(index / PACKAGES.length) % AREAS.length]!;
  const stem = STEMS[Math.floor(index / 7) % STEMS.length]!;
  const noun = NOUNS[Math.floor(index / 11) % NOUNS.length]!;
  const extension = EXTENSIONS[index % EXTENSIONS.length]!;
  const name = index % 3 === 0
    ? `${stem}${noun}${index}`
    : index % 3 === 1
    ? `${stem}-${noun.toLowerCase()}-${index}`
    : `${stem}_${noun.toLowerCase()}_${index}`;
  return `packages/${pkg}/${area}/${name}${extension}`;
}

function createWorkspace(root: string): string {
  const workspace = join(root, "workspace");
  const paths = new Set<string>(TARGETS.map((target) => target.path));
  for (let index = 0; paths.size < FILE_COUNT; index += 1) paths.add(bulkPath(index));
  for (const relativePath of paths) {
    const absolute = join(workspace, relativePath);
    mkdirSync(join(absolute, ".."), { recursive: true });
    writeFileSync(absolute, `${relativePath}\n`);
  }
  execFileSync("git", ["init", "--quiet"], { cwd: workspace, stdio: "pipe" });
  execFileSync("git", ["--no-optional-locks", "add", "."], { cwd: workspace, stdio: "pipe" });
  return realpathSync(workspace);
}

function composerText(pane: string): string {
  return pane.split("\n")
    .filter(isComposerLine)
    .map((line) => line.replace(/^[ \t]*(?:┃|❯)[ \t]?/, ""))
    .join("")
    .trimEnd();
}

function listsResultContaining(pane: string, word: string): boolean {
  return pane.split("\n").some((line) =>
    !isComposerLine(line) && line.includes("packages/") && line.toLowerCase().includes(word)
  );
}

let root: string | null = null;
let session: TmuxSession | null = null;
let gateway: ReturnType<typeof startFakeGateway> | null = null;

afterEach(async () => {
  await session?.kill();
  session = null;
  gateway?.stop();
  gateway = null;
  if (root) rmSync(root, { recursive: true, force: true });
  root = null;
}, TIMEOUT);

describe("@ file search load", () => {
  tmuxTest(
    "ranks typed queries across a large workspace",
    async () => {
      root = realpathSync(mkdtempSync(join(tmpdir(), "fx-file-search-load-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });
      const stderrPath = join(root, "stderr.log");
      writeFileSync(stderrPath, "");
      const workspace = createWorkspace(root);
      gateway = startFakeGateway([]);
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: workspace,
        env: {
          HOME: home,
          AI_GATEWAY_API_KEY: "fake-file-search-key",
          VERCEL_OIDC_TOKEN: undefined,
          FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
          FX_MODEL: FAKE_GATEWAY_MODEL,
          FX_AUTO_UPGRADE: "0",
        },
        isolated: true,
        width: 112,
        height: 32,
        stderrPath,
      });
      const active = session;
      await active.waitForComposer(TIMEOUT);

      // Wait for each keystroke to paint before the next, so every prefix runs
      // its own search, as it does at human typing speed on any machine.
      const search = async (query: string, listed: (pane: string) => boolean): Promise<void> => {
        const characters = Array.from(query);
        for (let typed = 1; typed < characters.length; typed += 1) {
          active.sendLiteralImmediate(characters[typed - 1]!);
          const prefix = characters.slice(0, typed).join("");
          await active.waitForPane((pane) => composerText(pane) === prefix, TIMEOUT);
        }
        active.sendLiteralImmediate(characters[characters.length - 1]!);
        await active.waitForPane((pane) => composerText(pane) === query && listed(pane), TIMEOUT);
        await active.sendKeys("C-u");
        await active.waitForPane((pane) => composerText(pane) === "", TIMEOUT);
      };
      for (let round = 0; round < ROUNDS; round += 1) {
        for (const target of TARGETS) {
          await search(target.query, (pane) => pane.includes(target.path));
        }
        for (const query of BROAD_QUERIES) {
          await search(query, (pane) => listsResultContaining(pane, query.slice(1)));
        }
      }

      await active.sendText("/quit");
      await active.waitForSessionEnd(TIMEOUT);
      expect(active.paneStatus()).toEqual({ dead: true, status: 0 });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
      expect(gateway.requests).toHaveLength(0);
    },
    TIMEOUT * 10,
  );
});
