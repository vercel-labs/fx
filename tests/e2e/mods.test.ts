import { describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { completion, createConfiguredProviderFixture as fixture, toolCompletion } from "./fixtures/chat-completions";
import { collectFiles, runGit, waitForCondition } from "./fixtures/shared-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT_MS = 30_000;
const MODEL = "glm-model";
const MODEL_METADATA = { [MODEL]: { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } };

type Fixture = ReturnType<typeof fixture>;

/** The profile's mods folder (`src/core/config/config_runtime.zig` `modsDirFromPaths`). */
function modsDir(f: Fixture): string {
  return join(f.home, ".fx", "mods");
}

function writeFile(dir: string, rel: string, data: string, executable = false): void {
  const path = join(dir, rel);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, data);
  if (executable) chmodSync(path, 0o755);
}

/** A sign-in program that prints `tok-1`, `tok-2`, ... one per run, and records each run in `countFile`. */
function signInBody(countFile: string, extra = ""): string {
  return [
    `n=$(cat "${countFile}" 2>/dev/null || echo 0)`,
    "n=$((n+1))",
    `echo "$n" > "${countFile}"`,
    extra,
    `printf '{"token":"tok-%s"}\\n' "$n"`,
  ].join("\n");
}

/** A mod's manifest with one `glm` provider that sends its requests to `base`. */
function glmManifest(base: string, command: string[] | null, version = "1.0.0", description = "Coding plan"): Record<string, unknown> {
  const auth = command === null ? { type: "none" } : { type: "command", command };
  return {
    name: "glm",
    version,
    description,
    providers: {
      glm: { protocol: "openai-chat-completions", base_url: base, auth, model_metadata: MODEL_METADATA },
    },
  };
}

/** A mod folder under the fixture's `sources`, with `mod.json` and any extra files. */
function makeModFolder(f: Fixture, dirName: string, manifest: Record<string, unknown>, files: Record<string, string> = {}, executable: string[] = []): string {
  const dir = join(f.home, "sources", dirName);
  mkdirSync(dir, { recursive: true });
  writeFile(dir, "mod.json", JSON.stringify(manifest));
  for (const [rel, body] of Object.entries(files)) writeFile(dir, rel, body, executable.includes(rel));
  return realpathSync(dir);
}

/** A git repository under the fixture's `repos` with one commit holding `mod.json` and any extra files. */
function makeRepo(f: Fixture, dirName: string, manifest: Record<string, unknown>, files: Record<string, string> = {}, executable: string[] = []): string {
  const dir = join(f.home, "repos", dirName);
  mkdirSync(dir, { recursive: true });
  writeFile(dir, "mod.json", JSON.stringify(manifest));
  for (const [rel, body] of Object.entries(files)) writeFile(dir, rel, body, executable.includes(rel));
  runGit(dir, ["init", "--quiet", "--initial-branch=main"]);
  runGit(dir, ["config", "user.name", "Fixture"]);
  runGit(dir, ["config", "user.email", "fixture@example.com"]);
  runGit(dir, ["add", "-A"]);
  runGit(dir, ["commit", "--quiet", "-m", "first"]);
  return realpathSync(dir);
}

function commitRepo(repo: string, message: string): void {
  runGit(repo, ["add", "-A"]);
  runGit(repo, ["commit", "--quiet", "-m", message]);
}

function head(repo: string): string {
  return runGit(repo, ["rev-parse", "HEAD"]).trim();
}

function fxMod(f: Fixture, args: string[], timeoutMs = 20000) {
  return runFx(["mod", ...args], { cwd: f.workspace, env: f.env, timeoutMs });
}

function fxAsk(f: Fixture, args: string[]) {
  return runFx(["ask", "--json", "--no-save", ...args], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
}

function askGlm(f: Fixture, prompt: string) {
  return fxAsk(f, ["--provider", "glm", "--model", MODEL, prompt]);
}

async function listJson(f: Fixture): Promise<{ kind: string; count: number; over_limit: boolean; mods: Array<Record<string, any>> }> {
  const result = await fxMod(f, ["list", "--json"]);
  expect(result.code, result.stderr).toBe(0);
  return JSON.parse(result.stdout);
}

/** Whether the mod's link exists, enabled or not is decided by the caller's name. */
function isModLink(f: Fixture, name: string): boolean {
  try {
    return lstatSync(join(modsDir(f), name)).isSymbolicLink();
  } catch {
    return false;
  }
}

function shellQuote(text: string): string {
  return `'${text.replaceAll("'", `'\\''`)}'`;
}

/** The fx command in a shell that prints an exit marker, so a tmux test can wait for the outcome. */
function terminalCommand(args: string[]): string {
  const fx = [FX_BIN, ...args].map(shellQuote).join(" ");
  const script = `${fx}; code=$?; printf '\\n__FX_EXIT_%s__\\n' "$code"; exit "$code"`;
  return `/bin/sh -c ${shellQuote(script)}`;
}

describe("fx mod add", () => {
  test("a folder installs as an enabled mod and records the folder as its source", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      const added = await fxMod(f, ["add", "--yes", folder]);
      expect(added.code, added.stderr).toBe(0);
      expect(added.stdout).toContain("Installed glm (1.0.0).");
      expect(lstatSync(join(modsDir(f), "glm")).isSymbolicLink()).toBe(true);

      const listed = await listJson(f);
      expect(listed.count).toBe(1);
      expect(listed.mods[0]).toMatchObject({ name: "glm", version: "1.0.0", status: "on", on: true, source: folder, pinned: false });
    } finally { f.close(); }
  }, 60000);

  test("a local git repository installs its default branch and records the commit", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const repo = makeRepo(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      const added = await fxMod(f, ["add", "--yes", `file://${repo}`]);
      expect(added.code, added.stderr).toBe(0);

      const listed = await listJson(f);
      expect(listed.mods[0]).toMatchObject({ name: "glm", pinned: false, commit: head(repo) });
    } finally { f.close(); }
  }, 60000);

  test("a git ref after @ pins the mod at that tag", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const repo = makeRepo(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      runGit(repo, ["-c", "tag.gpgsign=false", "tag", "v1"]);
      const added = await fxMod(f, ["add", "--yes", `file://${repo}@v1`]);
      expect(added.code, added.stderr).toBe(0);

      const shown = await fxMod(f, ["show", "glm", "--json"]);
      expect(shown.code, shown.stderr).toBe(0);
      expect(JSON.parse(shown.stdout)).toMatchObject({ kind: "mod_show", name: "glm", pinned: true, ref: "v1", commit: head(repo) });
    } finally { f.close(); }
  }, 60000);

  test("without a terminal and without --yes, add prints the screen, refuses, and installs nothing", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      const refused = await fxMod(f, ["add", folder]);
      expect(refused.code).toBe(1);
      expect(refused.stderr).toContain("Mod: glm (1.0.0)");
      expect(refused.stderr).toContain("Cannot confirm installation without a terminal. Re-run with --yes to install.");
      expect(isModLink(f, "glm")).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test.skipIf(!tmuxAvailable())("the install screen names the mod, its providers, and the program on the runs line before the question; n installs nothing", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    let session: TmuxSession | null = null;
    try {
      const helper = join(f.home, "tools", "sign-in");
      writeFile(join(f.home, "tools"), "sign-in", `#!/bin/sh\n${signInBody(join(f.home, "count"))}\n`, true);
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", [helper, "token"]));

      session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["mod", "add", folder]),
        cwd: f.workspace,
        env: f.env,
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      await session.waitForText("Install glm? [y/N]", TIMEOUT_MS);
      const pane = await session.capturePane();
      expect(pane).toContain("Mod: glm (1.0.0)");
      expect(pane).toContain("Coding plan");
      expect(pane).toContain("providers    1");
      expect(pane).toContain(`runs ${helper} token`);
      expect(pane.indexOf(`runs ${helper} token`)).toBeLessThan(pane.indexOf("Install glm? [y/N]"));

      await session.sendLiteral("n");
      await session.sendKeys("Enter");
      await session.waitForText("__FX_EXIT_1__", TIMEOUT_MS);
      expect(await session.capturePane()).toContain("Cancelled.");
      expect(isModLink(f, "glm")).toBe(false);
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 60000);

  test.skipIf(!tmuxAvailable())("the install screen answered with y installs the mod", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    let session: TmuxSession | null = null;
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["mod", "add", folder]),
        cwd: f.workspace,
        env: f.env,
        width: 120,
        height: 40,
        remainOnExit: true,
      });
      await session.waitForText("Install glm? [y/N]", TIMEOUT_MS);
      await session.sendLiteral("y");
      await session.sendKeys("Enter");
      await session.waitForText("__FX_EXIT_0__", TIMEOUT_MS);
      expect(await session.capturePane()).toContain("Installed glm (1.0.0).");
      expect(isModLink(f, "glm")).toBe(true);
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 60000);

  test("--yes without a terminal prints the install screen and installs", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      const added = await fxMod(f, ["add", "--yes", folder]);
      expect(added.code, added.stderr).toBe(0);
      expect(added.stdout).toContain("Installed glm (1.0.0).");
      expect(added.stderr).toContain("Mod: glm (1.0.0)");
    } finally { f.close(); }
  }, 60000);
});

describe("fx mod list, show, ls and rm", () => {
  test("list and show report each mod, and --json carries the mod_list and mod_show kinds", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const a = makeModFolder(f, "alpha", { ...glmManifest("http://127.0.0.1:1/v1", null), name: "alpha", providers: undefined });
      const b = makeModFolder(f, "beta", { ...glmManifest("http://127.0.0.1:1/v1", null), name: "beta", providers: undefined });
      expect((await fxMod(f, ["add", "--yes", a])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", b])).code).toBe(0);

      const text = await fxMod(f, ["list"]);
      expect(text.code).toBe(0);
      expect(text.stdout).toMatch(/^NAME\s+VERSION\s+STATUS\s+SOURCE/);
      expect(text.stdout).toMatch(/alpha\s+1\.0\.0\s+on/);
      expect(text.stdout).toMatch(/beta\s+1\.0\.0\s+on/);

      const listed = await listJson(f);
      expect(listed.kind).toBe("mod_list");
      expect(listed.mods.map(mod => mod.name)).toEqual(["alpha", "beta"]);

      const shown = await fxMod(f, ["show", "alpha", "--json"]);
      expect(shown.code).toBe(0);
      expect(JSON.parse(shown.stdout)).toMatchObject({ kind: "mod_show", name: "alpha", status: "on", version: "1.0.0" });

      const missing = await fxMod(f, ["show", "absent", "--json"]);
      expect(missing.code).toBe(1);
      expect(JSON.parse(missing.stdout)).toMatchObject({ kind: "mod_show", code: "ModNotFound" });
    } finally { f.close(); }
  }, 60000);

  test("ls is an alias of list, mods is an alias of mod, and rm removes a mod", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const viaAlias = await runFx(["mods", "ls", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(viaAlias.code, viaAlias.stderr).toBe(0);
      expect(JSON.parse(viaAlias.stdout)).toMatchObject({ kind: "mod_list", count: 1 });

      const removed = await fxMod(f, ["rm", "glm"]);
      expect(removed.code, removed.stderr).toBe(0);
      expect(removed.stdout).toContain("Removed glm.");
      expect(isModLink(f, "glm")).toBe(false);
      expect((await listJson(f)).count).toBe(0);
    } finally { f.close(); }
  }, 60000);
});

describe("fx mod off, on and update", () => {
  test("off hides a mod's provider from ask and on brings it back", async () => {
    const f = fixture(body => completion(body.model, "mod reply"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest(f.settings.providers.local.base_url, null));
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      expect((await askGlm(f, "first")).code).toBe(0);

      const off = await fxMod(f, ["off", "glm"]);
      expect(off.code).toBe(0);
      expect(off.stdout).toContain("Disabled glm.");
      expect((await listJson(f)).mods[0]).toMatchObject({ status: "off", on: false });

      const requestsBefore = f.requests.length;
      expect((await askGlm(f, "while off")).code).not.toBe(0);
      expect(f.requests.length).toBe(requestsBefore);

      const on = await fxMod(f, ["on", "glm"]);
      expect(on.code).toBe(0);
      expect(on.stdout).toContain("Enabled glm.");
      expect((await askGlm(f, "after on")).code).toBe(0);
    } finally { f.close(); }
  }, 60000);

  test("update leaves a pinned mod alone", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const repo = makeRepo(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      runGit(repo, ["-c", "tag.gpgsign=false", "tag", "v1"]);
      expect((await fxMod(f, ["add", "--yes", `file://${repo}@v1`])).code).toBe(0);

      const updated = await fxMod(f, ["update", "glm"]);
      expect(updated.code, updated.stderr).toBe(0);
      expect(updated.stdout).toContain("glm is pinned at v1.");
    } finally { f.close(); }
  }, 60000);

  test("update reports a mod already at the newest commit, then copies a new commit", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const repo = makeRepo(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      expect((await fxMod(f, ["add", "--yes", `file://${repo}`])).code).toBe(0);

      const same = await fxMod(f, ["update", "glm"]);
      expect(same.code, same.stderr).toBe(0);
      expect(same.stdout).toContain("glm is already up to date.");

      writeFile(repo, "mod.json", JSON.stringify(glmManifest("http://127.0.0.1:1/v1", null, "2.0.0")));
      commitRepo(repo, "second");
      const changed = await fxMod(f, ["update", "glm"]);
      expect(changed.code, changed.stderr).toBe(0);
      expect(changed.stdout).toMatch(/Updated glm: [0-9a-f]+ -> [0-9a-f]+\./);
      expect((await listJson(f)).mods[0]).toMatchObject({ name: "glm", version: "2.0.0", commit: head(repo) });
    } finally { f.close(); }
  }, 60000);

  test("update copies a folder mod again when its folder changed", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      writeFile(folder, "mod.json", JSON.stringify(glmManifest("http://127.0.0.1:1/v1", null, "2.0.0")));
      const updated = await fxMod(f, ["update", "glm"]);
      expect(updated.code, updated.stderr).toBe(0);
      expect(updated.stdout).toContain("Updated glm from folder.");
      expect((await listJson(f)).mods[0]).toMatchObject({ version: "2.0.0" });
    } finally { f.close(); }
  }, 60000);
});

describe("mod providers", () => {
  test("a mod's provider runs its sign-in program inside the mod and sends the token", async () => {
    const f = fixture(body => completion(body.model, "mod reply"));
    try {
      const countFile = join(f.home, "count");
      const cwdProof = join(f.home, "cwd-proof");
      const folder = makeModFolder(
        f,
        "glm",
        glmManifest(f.settings.providers.local.base_url, ["bin/sign-in", "token"]),
        { "bin/sign-in": `#!/bin/sh\n${signInBody(countFile, `[ -f mod.json ] && echo inside > "${cwdProof}"`)}\n` },
        ["bin/sign-in"],
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const result = await askGlm(f, "hello");
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("mod reply");
      expect(readFileSync(countFile, "utf8").trim()).toBe("1");
      expect(readFileSync(cwdProof, "utf8").trim()).toBe("inside");
      expect(f.requests.at(-1)!.authorization).toBe("Bearer tok-1");
      expect(f.requests.at(-1)!.path).toBe("/v1/chat/completions");
    } finally { f.close(); }
  }, 60000);

  test("a 401 on the first token replays once with a second sign-in run", async () => {
    const f = fixture(body => {
      const req = f.requests.at(-1)!;
      if (req.authorization !== "Bearer tok-2") {
        return Response.json({ error: { message: "unauthorized" } }, { status: 401 });
      }
      return completion(body.model, "replayed ok");
    });
    try {
      const countFile = join(f.home, "count");
      const folder = makeModFolder(
        f,
        "glm",
        glmManifest(f.settings.providers.local.base_url, ["bin/sign-in", "token"]),
        { "bin/sign-in": `#!/bin/sh\n${signInBody(countFile)}\n` },
        ["bin/sign-in"],
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const result = await askGlm(f, "hello");
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("replayed ok");
      expect(readFileSync(countFile, "utf8").trim()).toBe("2");
      expect(f.requests.map(req => req.authorization)).toEqual(["Bearer tok-1", "Bearer tok-2"]);
    } finally { f.close(); }
  }, 60000);

  test("an absolute sign-in program outside the mod is allowed, as in settings", async () => {
    const f = fixture(body => completion(body.model, "absolute reply"));
    try {
      const helper = join(f.home, "tools", "sign-in");
      const countFile = join(f.home, "count");
      writeFile(join(f.home, "tools"), "sign-in", `#!/bin/sh\n${signInBody(countFile)}\n`, true);
      const folder = makeModFolder(f, "glm", glmManifest(f.settings.providers.local.base_url, [helper, "token"]));
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const result = await askGlm(f, "hello");
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("absolute reply");
      expect(f.requests.at(-1)!.authorization).toBe("Bearer tok-1");
    } finally { f.close(); }
  }, 60000);

  test("a settings provider wins over a mod provider with the same name", async () => {
    const f = fixture(body => completion(body.model, "settings reply"));
    try {
      const countFile = join(f.home, "count");
      const folder = makeModFolder(
        f,
        "glm",
        glmManifest(f.settings.providers.local.base_url.replace("/v1", "/mod/v1"), ["bin/sign-in", "token"]),
        { "bin/sign-in": `#!/bin/sh\n${signInBody(countFile)}\n` },
        ["bin/sign-in"],
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      f.settings.providers.glm = { protocol: "openai-chat-completions", base_url: f.settings.providers.local.base_url, auth: { type: "none" }, model_metadata: MODEL_METADATA };
      f.save();

      const result = await askGlm(f, "hello");
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("settings reply");
      expect(f.requests.some(req => req.path.startsWith("/mod/"))).toBe(false);
      expect(existsSync(countFile)).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test("two mods with one provider name load neither, and the diagnostic names both", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const a = makeModFolder(f, "alpha", { ...glmManifest("http://127.0.0.1:1/v1", null), name: "alpha" });
      const b = makeModFolder(f, "beta", { ...glmManifest("http://127.0.0.1:1/v1", null), name: "beta" });
      expect((await fxMod(f, ["add", "--yes", a])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", b])).code).toBe(0);

      expect((await askGlm(f, "hello")).code).not.toBe(0);
      const doctor = await runFx(["doctor"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(doctor.stdout + doctor.stderr).toContain("provider glm is defined by both mod alpha and mod beta; neither loaded.");
    } finally { f.close(); }
  }, 60000);

  test("a broken mod is noted, and the other mod's provider still works", async () => {
    const f = fixture(body => completion(body.model, "other reply"));
    try {
      const good = makeModFolder(f, "alpha", glmManifest(f.settings.providers.local.base_url, null));
      const broken = makeModFolder(f, "beta", { ...glmManifest("http://127.0.0.1:1/v1", null), name: "beta", providers: { other: { protocol: "openai-chat-completions", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" } } } });
      expect((await fxMod(f, ["add", "--yes", good])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", broken])).code).toBe(0);
      writeFile(join(modsDir(f), "beta"), "mod.json", "{");

      const listed = await listJson(f);
      const beta = listed.mods.find(mod => mod.name === "beta");
      expect(beta).toMatchObject({ status: "broken" });
      expect(beta!.error).toBeTruthy();

      const result = await askGlm(f, "hello");
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).output).toBe("other reply");
      expect(result.stderr).toContain("mod beta: mod.json is not valid JSON.");
    } finally { f.close(); }
  }, 60000);
});

describe("mod threats", () => {
  test("a program path with .. is refused at add, and its program never runs", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const marker = join(f.home, "escaped");
      writeFile(f.home, "outside.sh", `#!/bin/sh\ntouch "${marker}"\nprintf '{"token":"t"}\\n'\n`, true);
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", ["../outside.sh", "token"]));
      const added = await fxMod(f, ["add", "--yes", folder]);
      expect(added.code).toBe(1);
      expect(added.stderr).toContain("must stay inside the mod");
      expect(isModLink(f, "glm")).toBe(false);
      expect(existsSync(marker)).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test("a symbolic link inside a mod is refused and nothing is installed", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", glmManifest("http://127.0.0.1:1/v1", null));
      symlinkSync(join(f.home, "secret.txt"), join(folder, "link"));
      writeFileSync(join(f.home, "secret.txt"), "outside");
      const added = await fxMod(f, ["add", "--yes", folder]);
      expect(added.code).toBe(1);
      expect(added.stderr).toContain("mod folder contains a symbolic link, which fx refuses.");
      expect(isModLink(f, "glm")).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test("the install screen names each variable a provider sends, and the header that carries it", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const manifest = glmManifest("http://127.0.0.1:1/v1", null);
      const glm = (manifest.providers as Record<string, Record<string, unknown>>).glm;
      glm.auth = { type: "bearer", env: "GLM_API_KEY" };
      glm.headers = { "X-Team": { env: "GLM_TEAM" } };
      const folder = makeModFolder(f, "glm", manifest);
      const refused = await fxMod(f, ["add", folder]);
      expect(refused.code).toBe(1);
      expect(refused.stderr).toContain("sends $GLM_API_KEY in header Authorization\n");
      expect(refused.stderr).toContain("sends $GLM_TEAM in header X-Team\n");
      expect(isModLink(f, "glm")).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test("a provider named gateway is refused at add", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const manifest = { name: "glm", version: "1.0.0", description: "Coding plan", providers: { gateway: { protocol: "openai-chat-completions", base_url: "http://127.0.0.1:1/v1", auth: { type: "none" } } } };
      const folder = makeModFolder(f, "glm", manifest);
      const added = await fxMod(f, ["add", "--yes", folder]);
      expect(added.code).toBe(1);
      expect(isModLink(f, "glm")).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test("escape sequences in a name or a description are refused at add", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const badDescription = makeModFolder(f, "desc", glmManifest("http://127.0.0.1:1/v1", null, "1.0.0", "Coding \u001b[31mplan"));
      const described = await fxMod(f, ["add", "--yes", badDescription]);
      expect(described.code).toBe(1);
      expect(described.stderr).toContain("The mod description must be plain text");
      expect(described.stderr).not.toContain("\u001b");

      const badName = makeModFolder(f, "name", { ...glmManifest("http://127.0.0.1:1/v1", null), name: "gl\u001b[2Jm" });
      const named = await fxMod(f, ["add", "--yes", badName]);
      expect(named.code).toBe(1);
      expect(named.stderr).toContain("The mod name uses lowercase letters");
      expect(named.stderr).not.toContain("\u001b");
      expect(existsSync(modsDir(f))).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test("a mod.json over 64 KiB is refused as too large", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(f, "glm", { name: "glm", version: "1.0.0", padding: "x".repeat(64 * 1024) });
      const added = await fxMod(f, ["add", "--yes", folder]);
      expect(added.code).toBe(1);
      expect(added.stderr).toContain("mod.json is larger than 64 KiB.");
    } finally { f.close(); }
  }, 60000);

  test("a project .fx.json cannot add a mod or a mod provider", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      writeFileSync(join(f.workspace, ".fx.json"), JSON.stringify({ providers: { glm: { protocol: "openai-chat-completions", base_url: f.settings.providers.local.base_url, auth: { type: "none" } } } }));
      const listed = await listJson(f);
      expect(listed.count).toBe(0);
      expect(isModLink(f, "glm")).toBe(false);
      expect((await askGlm(f, "hello")).code).not.toBe(0);
      expect(f.requests.length).toBe(0);
    } finally { f.close(); }
  }, 60000);

  test("no token or header value stays on disk or in output after a run", async () => {
    const f = fixture(body => {
      const req = f.requests.at(-1)!;
      if (req.authorization !== "Bearer tok-2") {
        return Response.json({ error: { message: "unauthorized tok-1" } }, { status: 401 });
      }
      return completion(body.model, "saved reply");
    });
    try {
      const countFile = join(f.home, "count");
      const folder = makeModFolder(
        f,
        "glm",
        glmManifest(f.settings.providers.local.base_url, ["bin/sign-in", "token"]),
        { "bin/sign-in": `#!/bin/sh\n${signInBody(countFile, "")}\n` },
        ["bin/sign-in"],
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      const result = await askGlm(f, "hello");
      expect(result.code, result.stdout + result.stderr).toBe(0);

      const secrets = ["tok-1", "tok-2"];
      const combined = result.stdout + result.stderr;
      for (const secret of secrets) {
        for (const filePath of [...collectFiles(f.home), ...collectFiles(f.workspace)]) {
          if (filePath === join(f.home, "count")) continue;
          const text = readFileSync(filePath, "utf8");
          if (text.includes(secret)) throw new Error(`Found secret ${secret} in ${filePath}`);
        }
      }
      expect(combined).not.toContain("tok-1");
      expect(combined).not.toContain("tok-2");
    } finally { f.close(); }
  }, 60000);
});

describe("mods as skill roots", () => {
  test.skipIf(!tmuxAvailable())("a mod's skill is listed with its mod in /skills, and leaves the list after fx mod rm", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    let session: TmuxSession | null = null;
    const openSkills = async (): Promise<TmuxSession> => {
      const opened = await TmuxSession.create({ cwd: f.workspace, env: f.env, width: 120, height: 40 });
      await opened.waitForComposer(TIMEOUT_MS);
      await opened.sendText("/skills list");
      return opened;
    };
    try {
      const folder = makeModFolder(f, "alpha", { name: "alpha", version: "1.0.0", description: "Skill pack" }, {
        "skills/alpha-review/SKILL.md": "---\nname: alpha-review\ndescription: Review helper\n---\nBody\n",
      });
      const added = await fxMod(f, ["add", folder, "--yes"]);
      expect(added.code, added.stderr).toBe(0);

      session = await openSkills();
      await session.waitForText("alpha-review", TIMEOUT_MS);
      expect(await session.capturePane()).toContain("mod alpha");
      await session.kill();
      session = null;

      const removed = await fxMod(f, ["rm", "alpha"]);
      expect(removed.code, removed.stderr).toBe(0);

      session = await openSkills();
      await session.waitForText("Workspace", TIMEOUT_MS);
      expect(await session.capturePane()).not.toContain("alpha-review");
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);
});

describe("mod profiles and themes", () => {
  test("a mod profile sends its prompt to the gateway and ignores permission_mode", async () => {
    const targetFile = "should-not-exist.txt";
    let parentTurn = 0;
    let childTurn = 0;
    const f = fixture(body => {
      const isChild = JSON.stringify(body.messages).includes("MOD_PROFILE_SYSTEM_MARKER");
      if (isChild) {
        childTurn += 1;
        if (childTurn === 1) {
          return toolCompletion(body.model, "write_file", { path: targetFile, content: "nope" }, "call-write");
        }
        return completion(body.model, "kid blocked");
      }
      parentTurn += 1;
      if (parentTurn === 1) {
        return toolCompletion(body.model, "subagent", {
          action: "message",
          agent: "kid",
          profile: "mod-helper",
          message: "create file",
        });
      }
      if (parentTurn === 2) {
        return toolCompletion(body.model, "subagent", { action: "wait" }, "call-wait");
      }
      return completion(body.model, "parent done");
    });
    try {
      const folder = makeModFolder(
        f,
        "alpha",
        { name: "alpha", version: "1.0.0", description: "Profile mod" },
        {
          "agents/mod-helper/profile.json": JSON.stringify({
            description: "Mod helper",
            permission_mode: "yolo",
            prompt: "append",
          }),
          "agents/mod-helper/prompt.md": "MOD_PROFILE_SYSTEM_MARKER",
        },
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const result = await runFx(["ask", "--json", "--provider", "local", "--model", "local-model", "run helper"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(childTurn, result.stdout + result.stderr).toBeGreaterThanOrEqual(1);
      expect(f.requests.some(req => JSON.stringify(req.body).includes("MOD_PROFILE_SYSTEM_MARKER"))).toBe(true);
      // `permission_mode: "yolo"` in the mod profile is ignored, so write_file
      // never runs in ask mode.
      expect(existsSync(join(f.workspace, targetFile))).toBe(false);
    } finally { f.close(); }
  }, 60000);

  test.skipIf(!tmuxAvailable())("FX_THEME loads a theme from an enabled mod in fx ask presentation", async () => {
    const f = fixture(body => completion(body.model, "themed `reply`"));
    let session: TmuxSession | null = null;
    try {
      const folder = makeModFolder(
        f,
        "alpha",
        { name: "alpha", version: "1.0.0", description: "Theme mod" },
        {
          "themes/mod-accent.json": JSON.stringify({
            type: "dark",
            colors: { inline_code: "#FF0000", dim: "#FF0000", hint: "#FF0000" },
          }),
        },
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      session = await TmuxSession.create({
        isolated: true,
        cmd: terminalCommand(["ask", "--provider", "local", "--model", "local-model", "--no-save", "hi"]),
        cwd: f.workspace,
        env: {
          ...f.env,
          NO_COLOR: undefined,
          FX_THEME: "mod-accent",
          COLORFGBG: "15;0",
          COLORTERM: undefined,
          TERM_PROGRAM: "Apple_Terminal",
        },
        width: 100,
        height: 30,
        remainOnExit: true,
      });
      await session.waitForText("__FX_EXIT_0__", TIMEOUT_MS);
      const escapes = await session.capturePaneEscapes();
      expect(escapes).toContain("38;2;255;0;0");
    } finally {
      if (session) {
        await session.kill();
        session = null;
      }
      f.close();
    }
  }, 60000);
});

/** A mod's profile `agents/<name>/`: its description and a prompt marker. */
function profileFiles(name: string, marker: string): Record<string, string> {
  return {
    [`agents/${name}/profile.json`]: JSON.stringify({ description: `${name} profile` }),
    [`agents/${name}/prompt.md`]: marker,
  };
}

function skillMd(name: string, description: string): string {
  return `---\nname: ${name}\ndescription: ${description}\n---\nBody\n`;
}

function themeFile(color: string): string {
  return JSON.stringify({ type: "dark", colors: { inline_code: color, dim: color, hint: color } });
}

/** The store folders of a mod's installed versions, by name. */
function storeVersions(f: Fixture, name: string): string[] {
  return readdirSync(join(modsDir(f), ".store")).filter(entry => entry.startsWith(`${name}-`));
}

/** The one installed version folder of a mod, as the store holds it. */
function storeVersion(f: Fixture, name: string): string {
  const [version] = storeVersions(f, name);
  if (!version) throw new Error(`no installed version of ${name}`);
  return join(modsDir(f), ".store", version);
}

/** The bodies fx sent to the gateway from request `from` on, as JSON text. */
function sentSince(f: Fixture, from: number): string {
  return JSON.stringify(f.requests.slice(from).map(request => request.body));
}

/**
 * A parent that spawns `profile` as a subagent and waits for it. A request
 * carrying a `_MARKER` string is the child's; it answers "child reply".
 */
function spawnFixture(profile: string) {
  return fixture(body => {
    if (JSON.stringify(body.messages).includes("_MARKER")) return completion(body.model, "child reply");
    const toolResults = body.messages.filter((message: any) => message.role === "tool").length;
    if (toolResults === 0) {
      return toolCompletion(body.model, "subagent", { action: "message", agent: "kid", profile, message: "do the task" }, "call-spawn");
    }
    if (toolResults === 1) return toolCompletion(body.model, "subagent", { action: "wait" }, "call-wait");
    return completion(body.model, "parent done");
  });
}

function spawnAsk(f: Fixture) {
  return runFx(["ask", "--json", "--provider", "local", "--model", "local-model", "run helper"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
}

function doctorJson(f: Fixture) {
  return runFx(["doctor", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
}

/** The theme escapes of a one-line `fx ask` run in a terminal that accepts colors. */
async function themedEscapes(f: Fixture, theme: string): Promise<string> {
  let session: TmuxSession | null = null;
  try {
    session = await TmuxSession.create({
      isolated: true,
      cmd: terminalCommand(["ask", "--provider", "local", "--model", "local-model", "--no-save", "hi"]),
      cwd: f.workspace,
      env: {
        ...f.env,
        NO_COLOR: undefined,
        FX_THEME: theme,
        COLORFGBG: "15;0",
        COLORTERM: undefined,
        TERM_PROGRAM: "Apple_Terminal",
      },
      width: 100,
      height: 30,
      remainOnExit: true,
    });
    await session.waitForText("__FX_EXIT_0__", TIMEOUT_MS);
    return await session.capturePaneEscapes();
  } finally {
    if (session) await session.kill();
  }
}

/** Closes the `/skills` menu, and waits until the footer no longer offers "esc close". */
async function closeMenu(session: TmuxSession): Promise<void> {
  await session.sendKeys("Escape");
  expect(await waitForPane(session, p => !p.includes("esc close"))).not.toContain("esc close");
  await session.waitForComposer(TIMEOUT_MS);
}

async function openTui(f: Fixture): Promise<TmuxSession> {
  return TmuxSession.create({ cwd: f.workspace, env: f.env, width: 120, height: 40 });
}

/** Polls the pane until `check` holds or the deadline passes; returns the last pane. */
async function waitForPane(session: TmuxSession, check: (pane: string) => boolean, timeoutMs = TIMEOUT_MS): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const pane = await session.capturePane();
    if (check(pane) || Date.now() >= deadline) return pane;
    await Bun.sleep(100);
  }
}

describe("mod clashes and order", () => {
  test("two mods with one profile name load neither: the spawn names both, doctor warns, and disabling one loads the other", async () => {
    const f = spawnFixture("helper");
    try {
      const alpha = makeModFolder(f, "alpha", { name: "alpha", version: "1.0.0", description: "Alpha" }, profileFiles("helper", "ALPHA_HELPER_MARKER"));
      const beta = makeModFolder(f, "beta", { name: "beta", version: "1.0.0", description: "Beta" }, profileFiles("helper", "BETA_HELPER_MARKER"));
      expect((await fxMod(f, ["add", "--yes", alpha])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", beta])).code).toBe(0);

      const clashed = await spawnAsk(f);
      expect(clashed.code, clashed.stderr).toBe(0);
      expect(sentSince(f, 0)).toContain("is defined by multiple mods (alpha, beta)");
      expect(sentSince(f, 0)).not.toContain("ALPHA_HELPER_MARKER");
      expect(sentSince(f, 0)).not.toContain("BETA_HELPER_MARKER");
      const doctor = await doctorJson(f);
      expect(doctor.stdout).toContain("profile 'helper' is defined by multiple mods (alpha, beta), so neither loads");

      expect((await fxMod(f, ["off", "beta"])).code).toBe(0);
      const before = f.requests.length;
      const loaded = await spawnAsk(f);
      expect(loaded.code, loaded.stderr).toBe(0);
      expect(sentSince(f, before)).toContain("ALPHA_HELPER_MARKER");
      expect(sentSince(f, before)).not.toContain("BETA_HELPER_MARKER");
      expect((await doctorJson(f)).stdout).not.toContain("is defined by multiple mods");
    } finally {
      f.close();
    }
  }, 90000);

  test("the user's profile beats a mod's, and a mod's beats the project's, with no clash warning", async () => {
    const f = spawnFixture("helper");
    try {
      writeFile(join(f.home, ".fx", "agents"), "helper/profile.json", JSON.stringify({ description: "home helper" }));
      writeFile(join(f.home, ".fx", "agents"), "helper/prompt.md", "HOME_HELPER_MARKER");
      writeFile(join(f.workspace, ".fx", "agents"), "helper/profile.json", JSON.stringify({ description: "project helper" }));
      writeFile(join(f.workspace, ".fx", "agents"), "helper/prompt.md", "PROJECT_HELPER_MARKER");
      const alpha = makeModFolder(f, "alpha", { name: "alpha", version: "1.0.0", description: "Alpha" }, profileFiles("helper", "ALPHA_HELPER_MARKER"));
      expect((await fxMod(f, ["add", "--yes", alpha])).code).toBe(0);

      const home = await spawnAsk(f);
      expect(home.code, home.stderr).toBe(0);
      expect(sentSince(f, 0)).toContain("HOME_HELPER_MARKER");
      expect(sentSince(f, 0)).not.toContain("ALPHA_HELPER_MARKER");
      expect(sentSince(f, 0)).not.toContain("PROJECT_HELPER_MARKER");
      expect((await doctorJson(f)).stdout).not.toContain("is defined by multiple mods");

      rmSync(join(f.home, ".fx", "agents", "helper"), { recursive: true });
      const before = f.requests.length;
      const fromMod = await spawnAsk(f);
      expect(fromMod.code, fromMod.stderr).toBe(0);
      expect(sentSince(f, before)).toContain("ALPHA_HELPER_MARKER");
      expect(sentSince(f, before)).not.toContain("PROJECT_HELPER_MARKER");
    } finally {
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("two mods with one theme name load neither: FX_THEME falls back, and doctor warns", async () => {
    const f = fixture(body => completion(body.model, "themed `reply`"));
    try {
      const alpha = makeModFolder(f, "alpha", { name: "alpha", version: "1.0.0", description: "Alpha" }, { "themes/clash.json": themeFile("#FF0000") });
      const beta = makeModFolder(f, "beta", { name: "beta", version: "1.0.0", description: "Beta" }, { "themes/clash.json": themeFile("#00FF00") });
      expect((await fxMod(f, ["add", "--yes", alpha])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", beta])).code).toBe(0);

      const escapes = await themedEscapes(f, "clash");
      expect(escapes).toContain("themed");
      expect(escapes).not.toContain("38;2;255;0;0");
      expect(escapes).not.toContain("38;2;0;255;0");
      const doctor = await doctorJson(f);
      expect(doctor.stdout).toContain("theme 'clash' is defined by multiple mods (alpha, beta), so neither loads");
    } finally {
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("a theme in ~/.fx/themes shadows a clashing mod theme, with no warning", async () => {
    const f = fixture(body => completion(body.model, "themed `reply`"));
    try {
      writeFile(join(f.home, ".fx", "themes"), "clash.json", themeFile("#0000FF"));
      const alpha = makeModFolder(f, "alpha", { name: "alpha", version: "1.0.0", description: "Alpha" }, { "themes/clash.json": themeFile("#FF0000") });
      const beta = makeModFolder(f, "beta", { name: "beta", version: "1.0.0", description: "Beta" }, { "themes/clash.json": themeFile("#00FF00") });
      expect((await fxMod(f, ["add", "--yes", alpha])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", beta])).code).toBe(0);

      const escapes = await themedEscapes(f, "clash");
      expect(escapes).toContain("38;2;0;0;255");
      expect(escapes).not.toContain("38;2;255;0;0");
      expect(escapes).not.toContain("38;2;0;255;0");
      expect((await doctorJson(f)).stdout).not.toContain("theme 'clash' is defined by multiple mods");
    } finally {
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("two mods with one skill name keep both copies, each labelled with its mod in /skills", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    let session: TmuxSession | null = null;
    try {
      const alpha = makeModFolder(f, "alpha", { name: "alpha", version: "1.0.0", description: "Alpha" }, { "skills/shared-review/SKILL.md": skillMd("shared-review", "Alpha review") });
      const beta = makeModFolder(f, "beta", { name: "beta", version: "1.0.0", description: "Beta" }, { "skills/shared-review/SKILL.md": skillMd("shared-review", "Beta review") });
      expect((await fxMod(f, ["add", "--yes", alpha])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", beta])).code).toBe(0);

      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/skills list");
      const pane = await waitForPane(session, p => p.includes("mod alpha") && p.includes("mod beta"));
      expect(pane).toContain("mod alpha");
      expect(pane).toContain("mod beta");
      expect(pane.split("shared-review").length - 1).toBeGreaterThanOrEqual(2);
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);
});

describe("mods change a running fx", () => {
  test.skipIf(!tmuxAvailable())("a skill from a mod added while the TUI runs shows in /skills after the next turn, and leaves after fx mod off", async () => {
    let replies = 0;
    const f = fixture(body => completion(body.model, `live reply ${++replies}`));
    let session: TmuxSession | null = null;
    try {
      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      const folder = makeModFolder(f, "live", { name: "live", version: "1.0.0", description: "Live" }, { "skills/live-check/SKILL.md": skillMd("live-check", "Live check") });
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      // The turn's submit asks for a skill refresh; the list follows the new catalog.
      await session.sendText("first");
      await session.waitForText("live reply 1", TIMEOUT_MS);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/skills list");
      expect(await waitForPane(session, p => p.includes("live-check"))).toContain("mod live");
      await closeMenu(session);

      expect((await fxMod(f, ["off", "live"])).code).toBe(0);
      await session.sendText("second");
      await session.waitForText("live reply 2", TIMEOUT_MS);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/skills list");
      // "Workspace" is a filter label of the menu, so the menu has drawn before the list is checked.
      const pane = await waitForPane(session, p => p.includes("Workspace"));
      expect(pane).not.toContain("live-check");
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("a mod update keeps the version a running TUI reads, and frees the old one once the TUI shows the new", async () => {
    // Who frees v1: the catalog generation that holds v1's pin is freed when the TUI
    // adopts v2 and its last lease ends (reaped on a loop pass). The generation's
    // release starts the background cleanup, which deletes v1's folder once no
    // pin names it. v2's pin is held by the new catalog, so v2 stays.
    let replies = 0;
    const f = fixture(body => completion(body.model, `pin reply ${++replies}`));
    let session: TmuxSession | null = null;
    try {
      const folder = makeModFolder(f, "pin-check", { name: "pin-check", version: "1.0.0", description: "Pinned" }, { "skills/pin-v1/SKILL.md": skillMd("pin-v1", "Pinned v1") });
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("first");
      await session.waitForText("pin reply 1", TIMEOUT_MS);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/skills list");
      expect(await waitForPane(session, p => p.includes("pin-v1"))).toContain("pin-v1");
      await closeMenu(session);

      writeFileSync(join(folder, "mod.json"), JSON.stringify({ name: "pin-check", version: "2.0.0", description: "Pinned" }));
      rmSync(join(folder, "skills", "pin-v1"), { recursive: true });
      writeFile(join(folder, "skills"), "pin-v2/SKILL.md", skillMd("pin-v2", "Pinned v2"));
      expect((await fxMod(f, ["update", "pin-check"])).code).toBe(0);
      // The running TUI still pins v1, so the store keeps both version folders.
      expect(storeVersions(f, "pin-check")).toHaveLength(2);

      await session.sendText("second");
      await session.waitForText("pin reply 2", TIMEOUT_MS);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/skills list");
      const shown = await waitForPane(session, p => p.includes("pin-v2"));
      expect(shown).toContain("pin-v2");
      expect(shown).not.toContain("pin-v1");
      await closeMenu(session);

      expect(await waitForCondition(() => storeVersions(f, "pin-check").length === 1, TIMEOUT_MS)).toBe(true);
      const [kept] = storeVersions(f, "pin-check");
      expect(existsSync(join(modsDir(f), ".store", kept!, "skills", "pin-v2", "SKILL.md"))).toBe(true);
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);
});

describe("mod threats in the installed store", () => {
  // The first defense is the store copy: `store.add` refuses a symbolic link in a
  // mod (`Invalid.symlink`; "a symbolic link inside a mod is refused" above). These
  // tests plant the link in the installed version folder afterwards, as a tampered
  // store would, and check the loader's own defense.

  test.skipIf(!tmuxAvailable())("a skill folder that links outside the mod does not load", async () => {
    // Defense: the mod root is strict like the managed root, so `collectSkillEntries`
    // skips a linked entry (`allow_linked` is false) in `skill_runtime.zig`.
    const f = fixture(() => completion("glm-model", "reply"));
    let session: TmuxSession | null = null;
    try {
      const folder = makeModFolder(f, "linked", { name: "linked", version: "1.0.0", description: "Linked" }, { "skills/plain-skill/SKILL.md": skillMd("plain-skill", "Plain") });
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      writeFile(join(f.home, "outside"), "evil-skill/SKILL.md", skillMd("evil-skill", "Evil"));
      symlinkSync(join(f.home, "outside", "evil-skill"), join(storeVersion(f, "linked"), "skills", "evil-skill"));

      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/skills list");
      const pane = await waitForPane(session, p => p.includes("mod linked"));
      expect(pane).toContain("plain-skill");
      expect(pane).not.toContain("evil-skill");
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);

  test("a mod profile whose prompt.md links outside the mod never sends the outside text", async () => {
    // Defense: `readProfile` reads with `within` set to the mod folder, so a link out
    // fails with `OutsideRepository` ("it links outside the mod...") in profiles.zig.
    const f = spawnFixture("linked-helper");
    try {
      const folder = makeModFolder(f, "linked-profile", { name: "linked-profile", version: "1.0.0", description: "Linked" }, profileFiles("linked-helper", "LINKED_HELPER_MARKER"));
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      writeFile(join(f.home, "outside"), "prompt.md", "OUTSIDE_PROMPT_MARKER");
      const prompt = join(storeVersion(f, "linked-profile"), "agents", "linked-helper", "prompt.md");
      rmSync(prompt);
      symlinkSync(join(f.home, "outside", "prompt.md"), prompt);

      const result = await spawnAsk(f);
      expect(result.code, result.stderr).toBe(0);
      expect(sentSince(f, 0)).not.toContain("OUTSIDE_PROMPT_MARKER");
      expect(sentSince(f, 0)).not.toContain("LINKED_HELPER_MARKER");
      expect(sentSince(f, 0)).toContain("links outside the mod");
      expect(sentSince(f, 0)).not.toContain("links outside the repository");
    } finally {
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("a mod theme file that links outside the mod does not load", async () => {
    // Defense: the theme loader lists a mod's `themes/` and skips any entry that is
    // not a regular file (`item.kind != .file` in `theme.zig`), so a link is never read.
    const f = fixture(body => completion(body.model, "themed `reply`"));
    try {
      const folder = makeModFolder(f, "theme-link", { name: "theme-link", version: "1.0.0", description: "Themes" }, {
        "themes/good.json": themeFile("#00FF00"),
        "themes/evil.json": themeFile("#FF0000"),
      });
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      writeFile(join(f.home, "outside"), "evil-theme.json", themeFile("#FF0000"));
      const evil = join(storeVersion(f, "theme-link"), "themes", "evil.json");
      rmSync(evil);
      symlinkSync(join(f.home, "outside", "evil-theme.json"), evil);

      // The control: a regular file in the same mod still loads.
      expect(await themedEscapes(f, "good")).toContain("38;2;0;255;0");
      const escapes = await themedEscapes(f, "evil");
      expect(escapes).not.toContain("38;2;255;0;0");
    } finally {
      f.close();
    }
  }, 90000);

  test("a mod's agents/main does not change the main agent's prompt, or a subagent asked for main", async () => {
    // Defense: `main` resolves to the built-in profile before any mod root
    // (`profiles.zig`, `main_name` in the load paths).
    const f = fixture(body => {
      if (JSON.stringify(body.messages).includes("_MARKER")) return completion(body.model, "child reply");
      if (!JSON.stringify(body.messages).includes("run helper")) return completion(body.model, "main reply");
      const toolResults = body.messages.filter((message: any) => message.role === "tool").length;
      if (toolResults === 0) {
        return toolCompletion(body.model, "subagent", { action: "message", agent: "kid", profile: "main", message: "do the task" }, "call-spawn");
      }
      if (toolResults === 1) return toolCompletion(body.model, "subagent", { action: "wait" }, "call-wait");
      return completion(body.model, "parent done");
    });
    try {
      const folder = makeModFolder(f, "main-mod", { name: "main-mod", version: "1.0.0", description: "Main" }, profileFiles("main", "MOD_MAIN_MARKER"));
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const mainAsk = await runFx(["ask", "--json", "--provider", "local", "--model", "local-model", "hello"], { cwd: f.workspace, env: f.env, timeoutMs: 30000 });
      expect(mainAsk.code, mainAsk.stderr).toBe(0);
      expect(JSON.parse(mainAsk.stdout).output).toContain("main reply");
      expect(sentSince(f, 0)).not.toContain("MOD_MAIN_MARKER");

      const spawned = await spawnAsk(f);
      expect(spawned.code, spawned.stderr).toBe(0);
      expect(sentSince(f, 0)).not.toContain("MOD_MAIN_MARKER");
    } finally {
      f.close();
    }
  }, 90000);
});

describe("mod preview, update confirmation, and live TUI refresh", () => {
  test("update refuses a sign-in command change without a terminal, keeps old version, updates with --yes, and skips prompt on version-only change", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(
        f,
        "glm",
        glmManifest("http://127.0.0.1:1/v1", ["bin/auth-v1"], "1.0.0"),
        { "bin/auth-v1": "#!/bin/sh\necho tok-1\n", "bin/auth-v2": "#!/bin/sh\necho tok-2\n" },
        ["bin/auth-v1", "bin/auth-v2"],
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      // Version-only update needs no question when there is no command.
      // With a command, any file change (including mod.json's version) asks;
      // an unchanged folder with a command installs without a question.
      const unchanged = await fxMod(f, ["update", "glm"]);
      expect(unchanged.code, unchanged.stderr).toBe(0);
      expect(unchanged.stdout).toContain("Updated glm from folder.");

      // Replacing only bin/sign-in bytes (same argv) without TTY or --yes is refused and keeps 1.0.0.
      writeFile(folder, "bin/auth-v1", "#!/bin/sh\necho tok-1-tampered\n", true);
      const tampered = await fxMod(f, ["update", "glm"]);
      expect(tampered.code).toBe(1);
      expect(tampered.stderr).toContain("This update changes the files of a mod that runs a sign-in command.");
      expect(tampered.stderr).toContain("--yes");
      expect((await listJson(f)).mods[0]).toMatchObject({ version: "1.0.0" });

      // Changing sign-in command without TTY or --yes is refused and keeps 1.0.0.
      writeFile(folder, "mod.json", JSON.stringify(glmManifest("http://127.0.0.1:1/v1", ["bin/auth-v2"], "2.0.0")));
      const refused = await fxMod(f, ["update", "glm"]);
      expect(refused.code).toBe(1);
      expect(refused.stderr).toContain("This update adds or changes a sign-in command.");
      expect(refused.stderr).toContain("This update changes the files of a mod that runs a sign-in command.");
      expect(refused.stderr).toContain("--yes");
      expect((await listJson(f)).mods[0]).toMatchObject({ version: "1.0.0" });

      // `--yes` updates to 2.0.0.
      const forced = await fxMod(f, ["update", "glm", "--yes"]);
      expect(forced.code, forced.stderr).toBe(0);
      expect(forced.stdout).toContain("Updated glm from folder.");
      expect((await listJson(f)).mods[0]).toMatchObject({ version: "2.0.0" });

      // Version-only update of a commandless mod needs no question.
      const plain = makeModFolder(f, "plain", { name: "plain", version: "1.0.0", description: "Plain" });
      expect((await fxMod(f, ["add", "--yes", plain])).code).toBe(0);
      writeFile(plain, "mod.json", JSON.stringify({ name: "plain", version: "1.1.0", description: "Plain" }));
      const plainUpdate = await fxMod(f, ["update", "plain"]);
      expect(plainUpdate.code, plainUpdate.stderr).toBe(0);
      expect(plainUpdate.stdout).toContain("Updated plain from folder.");
      expect((await listJson(f)).mods.find(m => m.name === "plain")).toMatchObject({ version: "1.1.0" });
    } finally {
      f.close();
    }
  }, 60000);

  test("the install screen and fx mod show --json list skills, profiles (with ignored permission_mode note), and themes", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    try {
      const folder = makeModFolder(
        f,
        "pack",
        { name: "pack", version: "1.0.0", description: "Asset pack" },
        {
          "skills/review/SKILL.md": skillMd("review", "Review skill"),
          "agents/auditor/profile.json": JSON.stringify({ description: "Auditor", permission_mode: "yolo" }),
          "agents/helper/profile.json": JSON.stringify({ description: "Helper" }),
          "themes/nord.json": themeFile("#112233"),
        },
      );

      // Install screen (shown even when refused without a terminal).
      const preview = await fxMod(f, ["add", folder]);
      expect(preview.code).toBe(1);
      expect(preview.stderr).toContain("skills       1");
      expect(preview.stderr).toContain("    review");
      expect(preview.stderr).toContain("profiles     2");
      expect(preview.stderr).toContain("    auditor  (fx ignores its permission_mode)");
      expect(preview.stderr).toContain("    helper\n");
      expect(preview.stderr).toContain("themes       1");
      expect(preview.stderr).toContain("    nord");

      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);

      const shown = await fxMod(f, ["show", "pack", "--json"]);
      expect(shown.code, shown.stderr).toBe(0);
      expect(JSON.parse(shown.stdout)).toMatchObject({
        kind: "mod_show",
        name: "pack",
        skills: ["review"],
        profiles: [
          { name: "auditor", permission_mode_ignored: true },
          { name: "helper", permission_mode_ignored: false },
        ],
        themes: ["nord"],
      });
    } finally {
      f.close();
    }
  }, 60000);

  test.skipIf(!tmuxAvailable())("/mods update with a command change shows the screen and --yes hint in tmux", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    let session: TmuxSession | null = null;
    try {
      const folder = makeModFolder(
        f,
        "glm",
        glmManifest("http://127.0.0.1:1/v1", ["bin/auth-v1"], "1.0.0"),
        { "bin/auth-v1": "#!/bin/sh\necho tok-1\n", "bin/auth-v2": "#!/bin/sh\necho tok-2\n" },
        ["bin/auth-v1", "bin/auth-v2"],
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      writeFile(folder, "mod.json", JSON.stringify(glmManifest("http://127.0.0.1:1/v1", ["bin/auth-v2"], "2.0.0")));

      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("/mods update glm");
      await session.waitForText("Run /mods update glm --yes to update.", TIMEOUT_MS);
      const pane = await session.capturePane();
      expect(pane).toContain("Mod: glm (2.0.0)");
      expect(pane).toContain("sign-in command");
      expect((await listJson(f)).mods[0]).toMatchObject({ version: "1.0.0" });
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("/mods add --yes of a mod with a skill makes /skills list show it without a new message", async () => {
    const f = fixture(() => completion("glm-model", "unused"));
    let session: TmuxSession | null = null;
    try {
      const folder = makeModFolder(
        f,
        "instant",
        { name: "instant", version: "1.0.0", description: "Instant skill mod" },
        { "skills/instant-skill/SKILL.md": skillMd("instant-skill", "Instant skill") },
      );

      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText(`/mods add ${folder} --yes`);
      await session.waitForText("Installed instant (1.0.0).", TIMEOUT_MS);

      await session.sendText("/skills list");
      const pane = await waitForPane(session, p => p.includes("instant-skill"));
      expect(pane).toContain("mod instant");
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);
});

describe("mod MCP servers", () => {
  const MODERN_STDIO_FIXTURE = join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs");

  function modServerFile(resultText?: string): string {
    const body = readFileSync(MODERN_STDIO_FIXTURE, "utf8");
    return resultText === undefined
      ? body
      : body.replace('process.env.FX_MCP_RESULT_TEXT ?? "MODERN_MCP_TOOL_RESULT"', JSON.stringify(resultText));
  }

  test("fx mcp list shows mod <name>, fx ask calls its tool without project approval, and order/clash rules hold", async () => {
    const f = fixture(body => {
      const messages = Array.isArray(body.messages) ? body.messages : [];
      const toolCount = messages.filter((m: any) => m.role === "tool").length;
      if (toolCount === 0) {
        return toolCompletion(body.model, "toolbox", { open: "mcp_modsrv_echo" }, "open_mod_echo");
      }
      if (toolCount === 1) {
        return toolCompletion(body.model, "toolbox", { run: "mcp_modsrv_echo", arguments: { text: "ping" } }, "call_mod_echo");
      }
      const lastTool = messages.findLast((m: any) => m.role === "tool")?.content ?? "";
      return completion(body.model, `TOOL_OUT:${lastTool}`);
    });
    try {
      const alpha = makeModFolder(
        f,
        "alpha",
        {
          name: "alpha",
          version: "1.0.0",
          mcp: {
            modsrv: { command: [process.execPath, "bin/server.mjs"], env: { FX_MCP_RESULT_TEXT: "ALPHA_MOD_RESULT" } },
            prof_wins: { command: [process.execPath, "bin/server.mjs"], env: { FX_MCP_RESULT_TEXT: "MOD_SHOULD_LOSE" } },
            clash_srv: { command: [process.execPath, "bin/server.mjs"] },
          },
        },
        { "bin/server.mjs": modServerFile() },
      );
      const beta = makeModFolder(
        f,
        "beta",
        {
          name: "beta",
          version: "1.0.0",
          mcp: {
            clash_srv: { command: [process.execPath, "bin/server.mjs"] },
          },
        },
        { "bin/server.mjs": modServerFile() },
      );
      writeFileSync(
        join(f.home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            prof_wins: { command: process.execPath, args: [MODERN_STDIO_FIXTURE], env: { FX_MCP_RESULT_TEXT: "PROFILE_WINS" } },
          },
        }),
      );
      writeFileSync(
        join(f.workspace, ".mcp.json"),
        JSON.stringify({
          mcpServers: {
            modsrv: { command: process.execPath, args: [MODERN_STDIO_FIXTURE], env: { FX_MCP_RESULT_TEXT: "PROJECT_SHOULD_LOSE" } },
            proj_only: { command: process.execPath, args: [MODERN_STDIO_FIXTURE] },
          },
        }),
      );

      expect((await fxMod(f, ["add", "--yes", alpha])).code).toBe(0);
      expect((await fxMod(f, ["add", "--yes", beta])).code).toBe(0);

      // `fx mcp list` shows mod <name>, profile wins, mod shadows project, clash loads neither with note.
      const listed = await runFx(["mcp", "list"], { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT_MS });
      expect(listed.code, listed.stderr).toBe(0);
      expect(listed.stderr).toContain("MCP server 'clash_srv' is defined by multiple mods (alpha, beta), so neither loads.");
      expect(listed.stdout).toContain("modsrv");
      expect(listed.stdout).toContain("mod alpha");
      expect(listed.stdout).toContain("prof_wins");
      expect(listed.stdout).toContain("proj_only");
      expect(listed.stdout).not.toContain("clash_srv");

      const listJsonOut = await runFx(["mcp", "list", "--json"], { cwd: f.workspace, env: f.env, timeoutMs: TIMEOUT_MS });
      expect(listJsonOut.code, listJsonOut.stderr).toBe(0);
      const servers = JSON.parse(listJsonOut.stdout).servers as Array<Record<string, any>>;
      const modEntry = servers.find(s => s.name === "modsrv");
      expect(modEntry).toMatchObject({
        name: "modsrv",
        source: "mod",
        mod: "alpha",
        file: join(modsDir(f), "alpha", "mod.json"),
        transport: "stdio",
      });
      expect(servers.find(s => s.name === "prof_wins")).toMatchObject({ source: "profile" });
      expect(servers.find(s => s.name === "clash_srv")).toBeUndefined();

      // `fx doctor` warns on the cross-mod clash under `mcp`.
      const doc = await doctorJson(f);
      const docParsed = JSON.parse(doc.stdout);
      expect(docParsed.checks.some((c: any) => c.name === "mcp" && c.status === "warn" && String(c.detail).includes("clash_srv"))).toBe(true);

      // `fx ask` calls the mod server's tool without workspace approval.
      const asked = await runFx(["ask", "--json", "--full-access", "--no-save", "Use modsrv echo."], {
        cwd: f.workspace,
        env: f.env,
        timeoutMs: TIMEOUT_MS,
      });
      expect(asked.code, asked.stderr).toBe(0);
      expect(JSON.parse(asked.stdout).output).toContain("ALPHA_MOD_RESULT");
      expect(JSON.parse(asked.stdout).output).not.toContain("PROJECT_SHOULD_LOSE");
    } finally {
      f.close();
    }
  }, 90000);

  test.skipIf(!tmuxAvailable())("updating a mod from another process restarts its server on the next prompt and collects the old version", async () => {
    let phase = 0;
    const f = fixture(body => {
      const messages = Array.isArray(body.messages) ? body.messages : [];
      const toolCount = messages.filter((m: any) => m.role === "tool").length;
      if (phase === 0) {
        if (toolCount === 0) return toolCompletion(body.model, "toolbox", { open: "mcp_modsrv_echo" }, "open_1");
        if (toolCount === 1) return toolCompletion(body.model, "toolbox", { run: "mcp_modsrv_echo", arguments: { text: "go1" } }, "call_1");
        phase = 1;
        const lastTool = messages.findLast((m: any) => m.role === "tool")?.content ?? "";
        return completion(body.model, `GOT1:${lastTool}`);
      }
      if (toolCount === 2) return toolCompletion(body.model, "toolbox", { run: "mcp_modsrv_echo", arguments: { text: "go2" } }, "call_2");
      const lastTool = messages.findLast((m: any) => m.role === "tool")?.content ?? "";
      return completion(body.model, `GOT2:${lastTool}`);
    });
    let session: TmuxSession | null = null;
    try {
      f.settings.permission_mode = "full-access";
      f.save();

      const folder = makeModFolder(
        f,
        "alpha",
        {
          name: "alpha",
          version: "1.0.0",
          mcp: { modsrv: { command: [process.execPath, "bin/server.mjs"] } },
        },
        { "bin/server.mjs": modServerFile("V1_MOD_SERVER") },
      );
      expect((await fxMod(f, ["add", "--yes", folder])).code).toBe(0);
      const v1Dir = realpathSync(join(modsDir(f), "alpha"));

      session = await openTui(f);
      await session.waitForComposer(TIMEOUT_MS);
      await session.sendText("first turn");
      await session.waitForText("V1_MOD_SERVER", TIMEOUT_MS);

      // Update mod alpha to v2 from outside the TUI.
      writeFile(folder, "bin/server.mjs", modServerFile("V2_MOD_SERVER"));
      writeFile(folder, "mod.json", JSON.stringify({
        name: "alpha",
        version: "2.0.0",
        mcp: { modsrv: { command: [process.execPath, "bin/server.mjs"] } },
      }));
      expect((await fxMod(f, ["update", "alpha", "--yes"])).code).toBe(0);
      const v2Dir = realpathSync(join(modsDir(f), "alpha"));
      expect(v2Dir).not.toBe(v1Dir);

      // Next prompt reloads the host, calls the v2 server, and collects v1 after v1's server exits.
      await session.sendText("second turn");
      await session.waitForText("V2_MOD_SERVER", TIMEOUT_MS);

      await waitForCondition(() => !existsSync(v1Dir), 10_000, 100);
      expect(existsSync(v2Dir)).toBe(true);
    } finally {
      if (session) await session.kill();
      f.close();
    }
  }, 90000);
});
