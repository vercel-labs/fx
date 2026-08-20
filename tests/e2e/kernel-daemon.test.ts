import { afterEach, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runFx } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  heldFakeGatewayFinalText,
  startFakeGateway,
} from "./tmux-helpers";

const TIMEOUT = 60_000;

type Fixture = ReturnType<typeof createFixture>;
type FakeGateway = ReturnType<typeof startFakeGateway>;

let fixture: Fixture | null = null;
let gateway: FakeGateway | null = null;

function createFixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-kernel-daemon-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const pythonPath = join(root, "python-modules");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace);
  mkdirSync(join(pythonPath, "IPython", "core"), { recursive: true });
  writeFileSync(join(pythonPath, "IPython", "__init__.py"), "");
  writeFileSync(join(pythonPath, "IPython", "core", "__init__.py"), "");
  writeFileSync(
    join(pythonPath, "IPython", "core", "interactiveshell.py"),
    [
      "import ast",
      "",
      "class Execution:",
      "    def __init__(self):",
      "        self.error_before_exec = None",
      "        self.error_in_exec = None",
      "        self.result = None",
      "",
      "class InteractiveShell:",
      "    _shared = None",
      "",
      "    def __init__(self):",
      "        self.namespace = {}",
      "",
      "    @classmethod",
      "    def instance(cls):",
      "        if cls._shared is None:",
      "            cls._shared = cls()",
      "        return cls._shared",
      "",
      "    def run_cell(self, code, store_history=True, silent=False):",
      "        execution = Execution()",
      "        source = '\\n'.join(line for line in code.splitlines() if not line.lstrip().startswith('%'))",
      "        try:",
      "            tree = ast.parse(source, mode='exec')",
      "        except BaseException as error:",
      "            execution.error_before_exec = error",
      "            return execution",
      "        try:",
      "            if tree.body and isinstance(tree.body[-1], ast.Expr):",
      "                prefix = ast.Module(body=tree.body[:-1], type_ignores=[])",
      "                exec(compile(prefix, '<fx-test>', 'exec'), self.namespace)",
      "                expression = ast.Expression(tree.body[-1].value)",
      "                execution.result = eval(compile(expression, '<fx-test>', 'eval'), self.namespace)",
      "            else:",
      "                exec(compile(tree, '<fx-test>', 'exec'), self.namespace)",
      "        except BaseException as error:",
      "            execution.error_in_exec = error",
      "        return execution",
      "",
    ].join("\n"),
  );
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "auto",
      permission: { ipython: "allow" },
      auto_upgrade: false,
    }) + "\n",
    { mode: 0o600 },
  );
  return { root, home, workspace: realpathSync(workspace), pythonPath };
}

function environment(current: Fixture, fake: FakeGateway) {
  return {
    HOME: current.home,
    AI_GATEWAY_API_KEY: "fake-kernel-daemon-key",
    VERCEL_OIDC_TOKEN: undefined,
    FX_AUTO_UPGRADE: "0",
    FX_SOUND: "0",
    FX_SKIP_ONBOARDING: "1",
    FX_GATEWAY_BASE_URL: fake.baseUrl,
    FX_GATEWAY_CHAT_URL: fake.chatUrl,
    FX_MODEL: FAKE_GATEWAY_MODEL,
    FX_IPYTHON_PYTHON: "python3",
    PYTHONPATH: current.pythonPath,
  };
}

async function waitForJob(
  current: Fixture,
  fake: FakeGateway,
  jobId: string,
) {
  let latest: any = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await runFx(["daemon", "show", jobId, "--json"], {
      cwd: current.workspace,
      env: environment(current, fake),
      timeoutMs: 5_000,
    });
    expect(result.code).toBe(0);
    latest = JSON.parse(result.stdout.trim());
    const state = latest.jobs?.[0]?.state;
    if (["exited", "failed", "stopped"].includes(state)) return latest.jobs[0];
    await Bun.sleep(50);
  }
  throw new Error(`background agent did not settle: ${JSON.stringify(latest)}`);
}

async function waitForRunningJob(
  current: Fixture,
  fake: FakeGateway,
  jobId: string,
) {
  let latest: any = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await runFx(["daemon", "show", jobId, "--json"], {
      cwd: current.workspace,
      env: environment(current, fake),
      timeoutMs: 5_000,
    });
    expect(result.code).toBe(0);
    latest = JSON.parse(result.stdout.trim()).jobs?.[0];
    if (latest?.state === "running") return latest;
    await Bun.sleep(50);
  }
  throw new Error(`background agent did not start: ${JSON.stringify(latest)}`);
}

async function waitForDaemonStopped(current: Fixture, fake: FakeGateway) {
  let latest: any = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await runFx(["daemon", "status", "--json"], {
      cwd: current.workspace,
      env: environment(current, fake),
      timeoutMs: 5_000,
    });
    expect(result.code).toBe(0);
    expect(result.stderr).toBe("");
    latest = JSON.parse(result.stdout.trim());
    if (latest.running === false) {
      expect(latest.pid).toBeNull();
      return;
    }
    await Bun.sleep(50);
  }
  throw new Error(`daemon did not stop: ${JSON.stringify(latest)}`);
}

async function daemonIsQuiescent(current: Fixture, fake: FakeGateway) {
  try {
    const result = await runFx(["daemon", "status", "--json"], {
      cwd: current.workspace,
      env: environment(current, fake),
      timeoutMs: 5_000,
    });
    if (result.code !== 0) return false;
    const snapshot = JSON.parse(result.stdout.trim()) as {
      running: boolean;
      jobs: Array<{ state: string }>;
    };
    return snapshot.running === false && snapshot.jobs.every(
      (job) => job.state !== "running" && job.state !== "queued",
    );
  } catch {
    return false;
  }
}

async function bestEffortDaemonCleanup(current: Fixture, fake: FakeGateway) {
  try {
    await runFx(["daemon", "shutdown", "--json"], {
      cwd: current.workspace,
      env: environment(current, fake),
      timeoutMs: 10_000,
    });
  } catch {
    // The supervisor continues cleanup if this client reaches its deadline.
  }
  const deadline = Date.now() + 25_000;
  while (Date.now() < deadline) {
    if (await daemonIsQuiescent(current, fake)) return true;
    await Bun.sleep(100);
  }
  return false;
}

afterEach(async () => {
  let safeToRemove = fixture === null || gateway === null;
  let cleanupFailure: unknown = null;
  const fixtureRoot = fixture?.root;
  try {
    if (fixture && gateway) {
      try {
        const stopped = await runFx(["daemon", "shutdown", "--json"], {
          cwd: fixture.workspace,
          env: environment(fixture, gateway),
          timeoutMs: 20_000,
        });
        expect(stopped.code).toBe(0);
        expect(stopped.stderr).toBe("");
        await waitForDaemonStopped(fixture, gateway);
        safeToRemove = await daemonIsQuiescent(fixture, gateway);
      } catch (error) {
        cleanupFailure = error;
      }
      if (!safeToRemove) {
        safeToRemove = await bestEffortDaemonCleanup(fixture, gateway);
      }
    }
  } finally {
    gateway?.stop();
    gateway = null;
    if (fixture && safeToRemove) {
      rmSync(fixture.root, { recursive: true, force: true });
    }
    fixture = null;
  }
  if (!safeToRemove) {
    throw new Error(
      `daemon cleanup could not verify that every fixture process stopped; preserved ${fixtureRoot}`,
    );
  }
  if (cleanupFailure) throw cleanupFailure;
});

test(
  "daemon keeps an agent running after submit and its root IPython namespace persists",
  async () => {
    fixture = createFixture();
    gateway = startFakeGateway([
      fakeGatewayToolCall("kernel_seed", "ipython", {
        code: "value = 40\nprint('kernel seeded')",
      }),
      (body: string) => {
        expect(body).toContain("kernel seeded");
        return fakeGatewayToolCall("kernel_read", "ipython", {
          code: "%precision 3\nvalue + 2",
        });
      },
      (body: string) => {
        expect(body).toContain("42");
        return fakeGatewayFinalText("BACKGROUND_KERNEL_OK");
      },
    ]);
    const env = environment(fixture, gateway);

    const started = await runFx(["daemon", "start", "--json"], {
      cwd: fixture.workspace,
      env,
      timeoutMs: 5_000,
    });
    expect(started.code).toBe(0);
    expect(started.stderr).toBe("");

    const submitted = await runFx([
      "daemon",
      "submit",
      "--json",
      "--cwd",
      fixture.workspace,
      "--",
      "Use the IPython tool twice and report the result.",
    ], { cwd: fixture.workspace, env, timeoutMs: 5_000 });
    expect(submitted.code).toBe(0);
    expect(submitted.stderr).toBe("");
    const command = JSON.parse(submitted.stdout.trim()) as { job_id: string };
    expect(command.job_id).toMatch(/^job-/);

    const job = await waitForJob(fixture, gateway, command.job_id);
    expect(job.state).toBe("exited");
    expect(job.exit_code).toBe(0);
    expect(job.cwd).toBe(fixture.workspace);

    const output = JSON.parse(readFileSync(job.log_path, "utf8").trim()) as {
      output: string;
      tool_calls: Array<{ name: string; status: string }>;
    };
    expect(output.output).toBe("BACKGROUND_KERNEL_OK");
    expect(output.tool_calls).toEqual([
      { name: "ipython", status: "success" },
      { name: "ipython", status: "success" },
    ]);
    const workerStderr = readFileSync(
      job.log_path.replace(/\.log$/, ".stderr.log"),
      "utf8",
    );
    expect(workerStderr).not.toContain("panic");
    expect(workerStderr).not.toContain("error:");

    const listed = await runFx(["daemon", "jobs", "--json"], {
      cwd: fixture.workspace,
      env,
      timeoutMs: 5_000,
    });
    expect(listed.code).toBe(0);
    expect(listed.stderr).toBe("");
    expect(listed.stdout).not.toContain("process_token");
    expect(JSON.parse(listed.stdout.trim()).jobs[0].id).toBe(command.job_id);

    const stopped = await runFx(["daemon", "shutdown", "--json"], {
      cwd: fixture.workspace,
      env,
      timeoutMs: 5_000,
    });
    expect(stopped.code).toBe(0);
    expect(stopped.stderr).toBe("");
  },
  TIMEOUT,
);

test(
  "daemon stops a running agent and never exposes its process token",
  async () => {
    fixture = createFixture();
    const held = heldFakeGatewayFinalText();
    try {
      gateway = startFakeGateway([held.response]);
      const env = environment(fixture, gateway);

      const submitted = await runFx([
        "daemon",
        "submit",
        "--json",
        "--cwd",
        fixture.workspace,
        "--",
        "Wait for the model response.",
      ], { cwd: fixture.workspace, env, timeoutMs: 5_000 });
      expect(submitted.code).toBe(0);
      expect(submitted.stderr).toBe("");
      const jobId = JSON.parse(submitted.stdout.trim()).job_id as string;
      const running = await waitForRunningJob(fixture, gateway, jobId);
      expect(running.pid).toBeNumber();

      const listed = await runFx(["daemon", "jobs", "--json"], {
        cwd: fixture.workspace,
        env,
        timeoutMs: 5_000,
      });
      expect(listed.code).toBe(0);
      expect(listed.stderr).toBe("");
      expect(listed.stdout).not.toContain("process_token");
      expect(JSON.parse(listed.stdout.trim()).jobs.some(
        (job: { id: string; state: string }) =>
          job.id === jobId && job.state === "running",
      )).toBe(true);

      const stopped = await runFx(["daemon", "stop", jobId, "--json"], {
        cwd: fixture.workspace,
        env,
        timeoutMs: 10_000,
      });
      expect(stopped.code).toBe(0);
      expect(stopped.stderr).toBe("");
      const settled = await waitForJob(fixture, gateway, jobId);
      expect(settled.state).toBe("stopped");

      let processExists = true;
      for (let attempt = 0; attempt < 100; attempt += 1) {
        try {
          process.kill(running.pid, 0);
        } catch {
          processExists = false;
          break;
        }
        await Bun.sleep(20);
      }
      expect(processExists).toBe(false);
    } finally {
      held.dispose();
    }
  },
  TIMEOUT,
);
