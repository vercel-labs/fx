// Stress: the agent list far past the 10 rows it shows. Starts the built fx
// with `--instances` instances, opens the list, and sends `--moves` seeded
// Up and Down presses in bursts, never Up on the first row, which would close
// the list. After each burst exactly one row is drawn highlighted, it is the
// instance the presses lead to (clamped at the last row, scrolled into the
// window), the trace log's last `agents_menu_previewed` names that row, and
// its last `agent_switched` shows that agent: every move shows the agent it
// lands on. Enter then keeps it without another switch, and from the list
// opened on it, Up back to the first row and one more Up close the list on
// fx 1.
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
const events = (name: string) => (existsSync(trace) ? readFileSync(trace, "utf8").split("\n").filter((line) => line.includes(`event=${name} `)) : []);
const switches = () => events("agent_switched");

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
  const movesStarted = performance.now();
  while (sent < moves) {
    const down = random() < 0.55;
    const count = Math.min(moves - sent, 1 + Math.floor(random() * 5));
    for (let i = 0; i < count; i += 1) {
      // Up on the first row closes the list, so the burst goes down there.
      const key = down || expected === 0 ? "Down" : "Up";
      await session.sendKeys(key);
      expected = Math.max(0, Math.min(instances - 1, expected + (key === "Down" ? 1 : -1)));
    }
    sent += count;
    bursts += 1;
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
    // The row the highlight is on is the agent shown.
    const previewed = /position=(\d+) agent=(\S+)/.exec(events("agents_menu_previewed").at(-1) ?? "");
    const shown = /agent=(\S+)/.exec(switches().at(-1) ?? "")?.[1];
    if (expected > 0 || previewed) {
      if (!previewed || Number(previewed[1]) !== expected + 1 || previewed[2] !== shown) {
        throw new Error(`after ${sent} moves the highlight is on ${want}, but the last preview is ${previewed?.[0] ?? "none"} and the agent shown is ${shown ?? "none"}`);
      }
    }
  }
  const moveMs = performance.now() - movesStarted;
  const switched = switches().length;
  console.log(`${sent} moves in ${bursts} bursts in ${Math.round(moveMs)} ms (${(moveMs / sent).toFixed(1)} ms a move): the highlight was on the expected row and its agent was shown every time, in a window of ${widest} rows, with ${switched} switches`);
  await session.sendKeys("Enter");
  const target = `fx ${expected + 1}/${instances}`;
  await session.waitForPane((pane: string) => !pane.includes(LIST_HINT) && pane.includes(target), 15_000);
  if (switches().length !== switched) throw new Error(`Enter switched ${switches().length - switched} times, but the preview already showed ${target}`);
  console.log(`Enter kept ${target} with no switch, in ${Math.round(performance.now() - started)} ms`);
  // Back up to the first row, and one more Up closes the list on fx 1.
  await session.sendKeys("C-x");
  await session.waitForText(LIST_HINT, 15_000);
  for (let row = expected; row > 0; row -= 1) await session.sendKeys("Up");
  await session.waitForPane((pane: string) => pane.includes(LIST_HINT) && listRows(pane).length > 0, 15_000);
  const top = Date.now() + 15_000;
  while (listRows(await session.capturePaneEscapes()).find((row) => row.selected)?.name !== "fx 1") {
    if (Date.now() > top) throw new Error(`Up ${expected} times never reached fx 1`);
    await Bun.sleep(15);
  }
  await session.sendKeys("Up");
  await session.waitForPane((pane: string) => !pane.includes(LIST_HINT) && pane.includes(`fx 1/${instances}`), 15_000);
  console.log(`Up from the first row closed the list on fx 1/${instances}`);
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  process.exitCode = 1;
} finally {
  await session?.kill();
  gateway.stop();
  evals.cleanupIsolatedTestHome(home);
  rmSync(workspace, { recursive: true, force: true });
}
