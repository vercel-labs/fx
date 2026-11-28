import { describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { completion, createConfiguredProviderFixture as fixture, toolCompletion } from "./fixtures/chat-completions";
import { collectFiles, runGit } from "./fixtures/shared-helpers";
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
