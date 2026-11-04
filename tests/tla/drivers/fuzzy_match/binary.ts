// The binary stage: drives the built fx's Models menu and skills menu in
// tmux, reads the rows each query shows, and has TLC judge them against
// FuzzyMatch!Listing: each menu must list exactly what the model lists, in
// the same order, with the same count.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context.ts";
import { utf8, type Field } from "./lib.ts";
import { judgeListings, type Observation } from "./tlc-cases.ts";

export const MODEL_IDS = [
  "anthropic/claude-opus-4.8", "anthropic/claude-sonnet-4.5", "anthropic/claude-haiku-4.5",
  "openai/gpt-5.4", "openai/gpt-5.4-mini", "openai/gpt-4o", "google/gemini-3-pro",
  "google/gemini-2.5-flash", "zai/glm-4.7", "xai/grok-4.6", "deepseek/deepseek-v4.1",
  "mistral/codestral-2", "acme/gpt5-lite", "meta/llama-4-scout",
];
export const MODEL_QUERIES = [
  "claude", "anthropic opus", "sonnet45", "cs45", "gpt5", "gpt-5.4", "openai/gpt-5.4", "GEMINI",
  "gem pro", "z.ai glm", "4.5", "mini", "lama", "-", "ds v4", "o4", "g", "nosuchmodel",
];

// Global sources only: their matched labels are unambiguous
// (`skillSourceShortLabel`, src/core/skills/skill_runtime.zig:1158). Six,
// because the skills menu shows six rows at most.
export const SKILLS = [
  { root: ".fx", label: "global .fx", dir: "fx-commit", name: "fx-commit", description: "Land work with a signed commit" },
  { root: ".fx", label: "global .fx", dir: "zig-best-practices", name: "zig-best-practices", description: "Write robust Zig code" },
  { root: ".fx", label: "global .fx", dir: "zqdir", name: "deploy-check", description: "Check a deploy before release" },
  { root: ".codex", label: "global .codex", dir: "workflow-helper", name: "workflow-helper", description: "Simplify workflows" },
  { root: ".codex", label: "global .codex", dir: "create-issue", name: "create-issue", description: "Open a ticket in the tracker" },
  { root: ".agents", label: "global .agents", dir: "release-notes", name: "release-notes", description: "Draft the changelog" },
];
export const SKILL_QUERIES = [
  "fx", "fx commit", "fxcommit", "commit", "zbp", "workflow", "ticket", "codex", "zqdir", "rn",
  "release notes", "-", "z", "nosuch",
];

type Menu = { header: RegExp; rowsEnd: RegExp };
const MODELS_MENU: Menu = { header: /^Models (\d+)\b/, rowsEnd: /^(Note:|Using |No models|─)/ };
const SKILLS_MENU: Menu = { header: /^Skills (\d+)\b/, rowsEnd: /^(No skills|─)/ };
// The `/` menu titles a list of commands alone `Commands` and one that mixes
// in skills `Results`.
const COMMANDS_MENU: Menu = { header: /^(?:Commands|Results) (\d+)\b/, rowsEnd: /^(No commands|─)/ };

/// The count in a menu's header and the first word of each row under it.
function readMenu(grid: string[], menu: Menu): { count: number; rows: string[] } | null {
  const at = grid.findIndex((line) => menu.header.test(line));
  if (at < 0) return null;
  const count = Number(menu.header.exec(grid[at]!)![1]);
  const rows: string[] = [];
  for (const line of grid.slice(at + 1)) {
    if (menu.rowsEnd.test(line.trimStart()) || (!line.trim() && rows.length > 0)) break;
    const first = /^\s{1,4}(\S+)/.exec(line)?.[1];
    if (first) rows.push(first);
  }
  return { count, rows };
}

type Session = {
  sendText(text: string): Promise<void>;
  sendLiteralText(text: string): Promise<void>;
  sendKeys(keys: string): Promise<void>;
  capturePaneGrid(): Promise<string[]>;
  waitForComposer(ms: number): Promise<string>;
  kill(): Promise<void>;
};

/// The menu once the composer shows `query` and two reads 150 ms apart agree.
async function settle(session: Session, menu: Menu, query: string, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let last = "";
  let grid: string[] = [];
  while (Date.now() < deadline) {
    grid = await session.capturePaneGrid();
    const composer = grid.find((line) => line.startsWith("┃")) ?? "";
    const text = grid.join("\n");
    if (composer.slice(1).trim() === query.trim() && readMenu(grid, menu) && text === last) return readMenu(grid, menu)!;
    last = text;
    await Bun.sleep(150);
  }
  throw new Error(`the menu did not settle on ${JSON.stringify(query)}:\n${grid.join("\n")}`);
}

/// Polls the screen until `ready` holds, so no step waits a guessed time.
async function waitForGrid(session: Session, ready: (grid: string[]) => boolean, what: string, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  let grid: string[] = [];
  while (Date.now() < deadline) {
    grid = await session.capturePaneGrid();
    if (ready(grid)) return grid;
    await Bun.sleep(25);
  }
  throw new Error(`timed out waiting for ${what}:\n${grid.join("\n")}`);
}

export type MenuRun = { surface: string; query: string; count: number; rows: string[] };

async function runMenu(session: Session, menu: Menu, open: () => Promise<void>, queries: string[], surface: string) {
  await open();
  const base = await settle(session, menu, "");
  if (base.rows.length !== base.count) throw new Error(`${surface}: the empty query shows ${base.rows.length} of ${base.count} rows; the fixture must fit on screen`);
  const runs: MenuRun[] = [];
  for (const query of queries) {
    await session.sendKeys("C-u");
    await settle(session, menu, "");
    await session.sendLiteralText(query);
    const seen = await settle(session, menu, query);
    runs.push({ surface, query, ...seen });
  }
  await session.sendKeys("Escape");
  await waitForGrid(session, (grid) => readMenu(grid, menu) === null, `the ${surface} menu to close`);
  await session.sendKeys("C-u");
  return { base: base.rows, runs };
}

export type BinaryResult = {
  ok: boolean;
  observations: number;
  bad: { surface: string; query: string; shown: string[]; model: string[] }[];
};

export async function binaryStage(dir: string): Promise<BinaryResult> {
  const helpers = await targetHelpers();
  if (!helpers.tmuxAvailable()) throw new Error("tmux is not available");
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fzm-")));
  const home = join(root, "h");
  const workspace = join(root, "w");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}\n");
  const skillFields = new Map<string, Field[]>();
  for (const skill of SKILLS) {
    const folder = join(home, skill.root, "skills", skill.dir);
    mkdirSync(folder, { recursive: true });
    writeFileSync(join(folder, "SKILL.md"), `---\nname: ${skill.name}\ndescription: ${skill.description}\n---\n\nBody\n`);
    // `Skill.path` is the realpath of SKILL.md (skill_runtime.zig:811).
    skillFields.set(skill.name, [
      { bytes: utf8(skill.name), kind: "name" },
      { bytes: utf8(skill.description), kind: "text" },
      { bytes: utf8(skill.label), kind: "text" },
      { bytes: utf8(realpathSync(join(folder, "SKILL.md"))), kind: "text" },
    ]);
  }
  const gateway = helpers.startFakeGateway([], {
    models: MODEL_IDS.map((id, index) => ({ id, type: "language", released: 1000 - index, tags: ["tool-use"], context_window: 128000 })),
  });
  let session: Session | null = null;
  try {
    session = await helpers.TmuxSession.create({
      cmd: binary, cwd: workspace, width: 120, height: 48,
      env: {
        ...testEnvironment({
          HOME: home, AI_GATEWAY_API_KEY: "fake-fuzzy-key", FX_GATEWAY_BASE_URL: gateway.baseUrl,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl, FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
          FX_MODEL: MODEL_IDS[3]!,
        }),
        VERCEL_OIDC_TOKEN: undefined,
      },
    }) as Session;
    await session.waitForComposer(15000);
    const s = session;
    const models = await runMenu(s, MODELS_MENU, () => s.sendText("/model"), MODEL_QUERIES, "models");
    const skills = await runMenu(s, SKILLS_MENU, async () => {
      await s.sendLiteralText("/sk");
      await waitForGrid(s, (grid) => readMenu(grid, COMMANDS_MENU)?.rows[0] === "/skills", "the / menu to list /skills first");
      await s.sendKeys("Enter");
    }, SKILL_QUERIES, "skills");

    const surfaces = [
      // `modelIdMatch` in src/core/app/model_cache_runtime.zig: the full id,
      // then the model's own name after the last `/`.
      { name: "models", base: models.base, runs: models.runs, fields: (id: string) => {
        const slash = id.lastIndexOf("/");
        const full = { bytes: utf8(id), kind: "name" as const };
        return slash < 0 ? [full] : [full, { bytes: utf8(id.slice(slash + 1)), kind: "name" as const }];
      } },
      { name: "skills", base: skills.base, runs: skills.runs, fields: (name: string) => skillFields.get(name) ?? [] },
    ];
    const observations: Observation[] = [];
    const labels: { surface: string; query: string; base: string[]; shown: string[] }[] = [];
    for (const surface of surfaces) {
      const items = surface.base.map((name) => {
        const fields = surface.fields(name);
        if (fields.length === 0) throw new Error(`${surface.name}: the menu lists ${name}, which the fixture does not have`);
        return fields;
      });
      for (const run of surface.runs) {
        const shown = run.rows.map((row) => {
          const index = surface.base.indexOf(row);
          if (index < 0) throw new Error(`${surface.name} ${JSON.stringify(run.query)}: row ${row} is not in the base list`);
          return index + 1;
        });
        observations.push({ items, query: utf8(run.query), mode: "ranked", shown, count: run.count });
        labels.push({ surface: surface.name, query: run.query, base: surface.base, shown: run.rows });
      }
    }
    const judged = await judgeListings(join(dir, "tlc"), observations);
    const bad = judged.bad.map((i) => {
      const label = labels[i - 1]!;
      return { surface: label.surface, query: label.query, shown: label.shown, model: (judged.expected.get(i) ?? []).map((k) => label.base[k - 1]!) };
    });
    const result = { ok: judged.ok, observations: observations.length, bad };
    writeFileSync(join(dir, "binary-report.json"), `${JSON.stringify(result, null, 2)}\n`);
    return result;
  } finally {
    if (session) await session.kill();
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}
