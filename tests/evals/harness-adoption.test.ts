// Whether the model uses `import proto_fx as harness` when it helps, and
// whether it wrongly assumes plain `python` keeps state between commands.
//
// It runs proto-fx against any OpenAI-compatible endpoint:
//   PROTO_FX_EVAL_BASE_URL=http://127.0.0.1:8394 bun test harness-adoption.test.ts
// Optional: PROTO_FX_EVAL_RUNS (repeats per task, default 1) and
// PROTO_FX_EVAL_REPORT (a file that receives one JSON line per run).
// Without PROTO_FX_EVAL_BASE_URL the tests are skipped.
import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const BIN = resolve(import.meta.dirname, "../../zig-out/bin/proto-fx");
const BASE_URL = process.env.PROTO_FX_EVAL_BASE_URL ?? "";
const RUNS = Math.max(1, Number(process.env.PROTO_FX_EVAL_RUNS ?? "1"));
const REPORT = process.env.PROTO_FX_EVAL_REPORT ?? "";
const TIMEOUT_MS = 600_000;

const homes: string[] = [];

afterAll(() => {
  for (const home of homes) {
    // The supervisor daemon is not used by `ask`, but stop it if one started.
    spawnSync(BIN, ["daemon", "stop"], { env: { ...process.env, HOME: home }, stdio: "ignore", timeout: 20_000 });
    rmSync(home, { recursive: true, force: true });
  }
});

/** A short HOME, since Unix socket paths have a length limit. */
function freshHome(): string {
  const home = mkdtempSync("/tmp/pfxev");
  homes.push(home);
  const setup = spawnSync(BIN, ["setup", "--base-url", BASE_URL], { env: { ...process.env, HOME: home }, encoding: "utf-8", timeout: 60_000 });
  if (setup.status !== 0) throw new Error(`setup failed: ${setup.stderr}`);
  return home;
}

interface Ask {
  output: string;
  session_id: string;
  commands: string[];
  tools: string[];
}

function ask(home: string, cwd: string, prompt: string, resume?: string): Ask {
  const args = ["ask", "--full-access", "--json"];
  if (resume) args.push("--resume-id", resume);
  args.push("--", prompt);
  const run = spawnSync(BIN, args, { cwd, env: { ...process.env, HOME: home, NO_COLOR: "1", FX_SOUND: "0" }, encoding: "utf-8", timeout: TIMEOUT_MS, maxBuffer: 64 << 20 });
  let json: any;
  try {
    json = JSON.parse(run.stdout.trim());
  } catch {
    throw new Error(`no JSON from proto-fx ask (status ${run.status})\nstdout: ${run.stdout.slice(-2000)}\nstderr: ${run.stderr.slice(-2000)}`);
  }
  const calls: any[] = json.tool_calls ?? [];
  return {
    output: json.final_output || json.output || "",
    session_id: json.session_id,
    commands: calls.map((c) => c.command_result?.command ?? "").filter((c) => c.length > 0),
    tools: calls.map((c) => c.name),
  };
}

/** Every text file under `dir`, for code the model saved and then ran. */
function sources(dir: string): string {
  let text = "";
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    const info = statSync(path);
    if (info.isDirectory()) text += sources(path);
    else if (info.size < 1 << 20 && /\.(py|sh)$/.test(name)) text += readFileSync(path, "utf-8") + "\n";
  }
  return text;
}

/** NameErrors in tool results: Python that expected an earlier command's state. */
function nameErrors(home: string): number {
  const sessions = join(home, ".proto-fx", "sessions");
  if (!existsSync(sessions)) return 0;
  let count = 0;
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (/\.(json|jsonl)$/.test(name)) count += (readFileSync(path, "utf-8").match(/NameError: name '/g) ?? []).length;
    }
  };
  walk(sessions);
  return count;
}

function adoption(code: string) {
  return {
    harness: /import proto_fx|from proto_fx/.test(code),
    fs_replace: /harness\.fs\.replace|fs\.replace\(/.test(code),
    fs_write: /harness\.fs\.write/.test(code),
    store: /harness\.store/.test(code),
    kernel: /harness\.kernel\(/.test(code),
    agent: /harness\.(agent|parallel|pipeline)\(/.test(code),
  };
}

function report(task: string, run: number, fields: Record<string, unknown>) {
  const line = JSON.stringify({ task, run, ...fields });
  console.log(line);
  if (REPORT) appendFileSync(REPORT, line + "\n");
}

describe.skipIf(!BASE_URL || !existsSync(BIN))("eval: proto_fx harness adoption", () => {
  for (let run = 1; run <= RUNS; run++) {
    test(`stateful data task, run ${run}`, () => {
      const home = freshHome();
      const work = mkdtempSync("/tmp/pfxew");
      homes.push(work);
      // 1000 deterministic rows; values 0..99.
      const rows = ["id,value,group"];
      for (let i = 0; i < 1000; i++) rows.push(`${i},${(i * 37) % 100},${["a", "b", "c"][i % 3]}`);
      writeFileSync(join(work, "data.csv"), rows.join("\n") + "\n");
      const values = rows.slice(1).map((r) => Number(r.split(",")[1]));
      const over50 = values.filter((v) => v > 50).length;
      const groupBMax = Math.max(...rows.slice(1).filter((r) => r.endsWith(",b")).map((r) => Number(r.split(",")[1])));

      const first = ask(home, work, "Load data.csv with Python and tell me the mean of the value column. Keep the parsed data loaded in Python, because I will ask follow-up questions about it and do not want it parsed again.");
      const second = ask(home, work, "Using the data you already have loaded, how many rows have value greater than 50?", first.session_id);
      const third = ask(home, work, "And, from that same loaded data, what is the largest value in group b?", first.session_id);
      const code = [...first.commands, ...second.commands, ...third.commands].join("\n") + "\n" + sources(work);
      const used = adoption(code);
      const errors = nameErrors(home);
      report("stateful-data", run, {
        ...used,
        name_errors: errors,
        python_commands: [...first.commands, ...second.commands, ...third.commands].filter((c) => /python|uv run/.test(c)).length,
        correct_over50: second.output.includes(String(over50)),
        correct_group_b_max: third.output.includes(String(groupBMax)),
      });
      expect(second.output.includes(String(over50))).toBe(true);
    }, TIMEOUT_MS * 3);

    test(`multi-file edit task, run ${run}`, () => {
      const home = freshHome();
      const work = mkdtempSync("/tmp/pfxew");
      homes.push(work);
      mkdirSync(join(work, "pkg"));
      writeFileSync(join(work, "pkg", "core.py"), "def fetch_rows(source):\n    return list(source)\n\n\ndef count(source):\n    return len(fetch_rows(source))\n");
      for (const name of ["api", "cli", "jobs", "report"]) {
        writeFileSync(join(work, "pkg", `${name}.py`), `from .core import fetch_rows\n\n\ndef ${name}_main(src):\n    rows = fetch_rows(src)\n    again = fetch_rows(src)\n    return rows, again\n`);
      }
      const result = ask(home, work, "Rename the function fetch_rows to load_rows everywhere in the pkg folder: its definition, every import, and every call. Use Python for the edits if that is easier.");
      const code = result.commands.join("\n") + "\n" + sources(work);
      const used = adoption(code);
      const remaining = sources(join(work, "pkg")).match(/fetch_rows/g)?.length ?? 0;
      const renamed = sources(join(work, "pkg")).match(/load_rows/g)?.length ?? 0;
      report("multi-file-edit", run, {
        ...used,
        edit_file_calls: result.tools.filter((t) => t === "edit_file").length,
        write_file_calls: result.tools.filter((t) => t === "write_file").length,
        shell_calls: result.tools.filter((t) => t === "shell").length,
        remaining_old_name: remaining,
        new_name_count: renamed,
      });
      expect(remaining).toBe(0);
      expect(renamed).toBe(14);
    }, TIMEOUT_MS);
  }
});
