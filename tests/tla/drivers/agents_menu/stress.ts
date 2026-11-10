// Stress: the agent list far past the 10 rows it shows. Starts the built fx
// with `--instances` instances, opens the list, and sends `--moves` seeded
// Up and Down presses in bursts. After each burst exactly one row is drawn
// highlighted, it is the instance the presses lead to (clamped at both
// ends, scrolled into the window), and the trace log has no
// `agent_switched`: the screen never changes while the highlight moves.
// Enter then switches once, to the highlighted instance.
//
// Usage:
//   bun tests/tla/drivers/agents_menu/stress.ts [--instances 100] [--moves 1000] [--seed 1]
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { binary, targetHelpers, worktree } from "../lib/context";
import { LIST_HINT, listRows, seeded } from "./lib";

function option(name: string, fallback: string): string {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 && process.argv[at + 1] ? process.argv[at + 1]! : fallback;
}

const instances = Number(option("instances", "100"));
const moves = Number(option("moves", "1000"));
const seed = Number(option("seed", "1"));
const random = seeded(seed);

const { TmuxSession, startFakeGateway, FAKE_GATEWAY_MODEL } = await targetHelpers();
const evals = await import(join(worktree, "tests", "evals", "eval-helpers.ts"));
const gateway = startFakeGateway([]);
const home: string = evals.createIsolatedTestHome();
const workspace = realpathSync(mkdtempSync(join(tmpdir(), "fx-tla-agents-menu-stress-")));
mkdirSync(join(home, ".fx"), { recursive: true });
const trace = join(home, "fx-trace.log");
const switches = () => (existsSync(trace) ? readFileSync(trace, "utf8").split("\n").filter((line) => line.includes("event=agent_switched")) : []);

let session: any;
const started = performance.now();
try {
  session = await TmuxSession.create({
    cmd: binary,
    cwd: workspace,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: "fake-agents-menu-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_AUTO_UPGRADE: "0",
      FX_SOUND: "0",
      FX_TRACE_LOG: trace,
      FX_TEST_INSTANCES: String(instances),
    },
    width: 120,
    height: 40,
  });
  await session.waitForComposer(60_000);
  await session.waitForPane((pane: string) => pane.includes(`fx 1/${instances}`), 60_000);
  console.log(`fx with ${instances} instances up in ${Math.round(performance.now() - started)} ms`);
  await session.sendKeys("C-x");
  await session.waitForText(LIST_HINT, 15_000);
  let expected = 0;
  let sent = 0;
  let bursts = 0;
  let widest = 0;
  while (sent < moves) {
    const down = random() < 0.55;
    const count = Math.min(moves - sent, 1 + Math.floor(random() * 5));
    for (let i = 0; i < count; i += 1) await session.sendKeys(down ? "Down" : "Up");
    sent += count;
    bursts += 1;
    expected = Math.max(0, Math.min(instances - 1, expected + (down ? count : -count)));
    const want = `fx ${expected + 1}`;
    const deadline = Date.now() + 10_000;
    for (;;) {
      const rows = listRows(await session.capturePaneEscapes());
      const selected = rows.filter((row) => row.selected);
      if (selected.length === 1 && selected[0]!.name === want) {
        widest = Math.max(widest, rows.length);
        break;
      }
      if (Date.now() > deadline) {
        throw new Error(`after ${sent} moves the list highlights ${JSON.stringify(selected.map((row) => row.name))}, not ${want}:\n${await session.capturePane()}`);
      }
      await Bun.sleep(15);
    }
    const seen = switches();
    if (seen.length > 0) throw new Error(`the screen switched while the highlight moved, after ${sent} moves: ${seen[0]}`);
  }
  console.log(`${sent} moves in ${bursts} bursts: the highlight was on the expected row every time, in a window of ${widest} rows, and nothing switched`);
  await session.sendKeys("Enter");
  const target = `fx ${expected + 1}/${instances}`;
  await session.waitForPane((pane: string) => !pane.includes(LIST_HINT) && pane.includes(target), 15_000);
  const seen = switches();
  if (seen.length !== 1) throw new Error(`Enter switched ${seen.length} times`);
  console.log(`Enter switched once, to ${target}, in ${Math.round(performance.now() - started)} ms`);
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  process.exitCode = 1;
} finally {
  await session?.kill();
  gateway.stop();
  evals.cleanupIsolatedTestHome(home);
  rmSync(workspace, { recursive: true, force: true });
}
