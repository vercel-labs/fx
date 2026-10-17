import { afterEach, describe, test } from "bun:test";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  assertSingleFooter,
  findFooterBlocks,
  visibleText,
  type FooterBlock,
} from "./tui-render-assertions";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 90_000;
const originalInput = "alpha\nleftMIDright\ngamma";
const leftKeysToMiddle = 11;

const routes = [
  {
    label: "Cmd+Backspace",
    hex: ["1b", "5b", "31", "32", "37", "3b", "39", "75"],
    expectedVisible: "alpha\nright\ngamma",
  },
  {
    label: "Cmd+Fn+Delete",
    hex: ["1b", "5b", "33", "3b", "39", "7e"],
    expectedVisible: "alpha\nleftMID\ngamma",
  },
  {
    label: "Raw Ctrl+U",
    hex: ["15"],
    expectedVisible: "alpha\nright\ngamma",
  },
  {
    label: "Raw Ctrl+K",
    hex: ["0b"],
    expectedVisible: "alpha\nleftMID\ngamma",
  },
  {
    label: "Kitty Ctrl+U",
    hex: ["1b", "5b", "31", "31", "37", "3b", "35", "75"],
    expectedVisible: "alpha\nright\ngamma",
  },
  {
    label: "Kitty Ctrl+K",
    hex: ["1b", "5b", "31", "30", "37", "3b", "35", "75"],
    expectedVisible: "alpha\nleftMID\ngamma",
  },
] as const;

let session: TmuxSession | null = null;
const workDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const dir of workDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function waitForLatestFooterState(
  label: string,
  activeSession: TmuxSession,
  stderrPath: string,
  expectedVisible: string,
  forbiddenVisible: string | null,
  timeoutMs = 5_000,
): Promise<string[]> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const grid = await activeSession.capturePaneGrid();
    const footers = findFooterBlocks(grid);
    if (footers.length === 1) {
      const footer = footers[0]!;
      const text = visibleText(
        grid.slice(footer.topDivider, footer.bottomDivider + 1).join("\n"),
      ).replaceAll("┃", "");
      if (
        text.includes(visibleText(expectedVisible)) &&
        (forbiddenVisible === null ||
          !text.includes(visibleText(forbiddenVisible)))
      ) {
        return grid;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const final = (await activeSession.capturePaneGrid()).join("\n");
  const stderr = readFileSync(stderrPath, "utf8");
  throw new Error(
    `[${label}] timed out waiting for footer state ${expectedVisible}.\nFinal grid:\n${final}\nstderr:\n${stderr}`,
  );
}

function assertFooterLogicalRows(
  grid: string[],
  footer: FooterBlock,
  expectedLines: readonly string[],
  failures: string[],
  label: string,
): void {
  const rows = grid
    .slice(footer.input, footer.bottomDivider)
    .map((row) => visibleText(row).replace(/^┃/, ""));
  let previous = -1;
  for (const line of expectedLines) {
    const expected = visibleText(line);
    const index = rows.findIndex(
      (row, rowIndex) => rowIndex > previous && row.includes(expected),
    );
    if (index === -1) {
      failures.push(`${label}: missing distinct ordered footer row for ${line}`);
      return;
    }
    previous = index;
  }
}

describe.skipIf(SKIP)("tui: logical-line deletion", () => {
  test(
    "all decoded and raw routes preserve surrounding logical lines",
    async () => {
      for (const route of routes) {
        const workDir = mkdtempSync(join(tmpdir(), "fx-line-delete-"));
        workDirs.push(workDir);
        const stderrPath = join(workDir, "stderr.log");
        writeFileSync(stderrPath, "");

        session = await TmuxSession.create({
          cmd: `env -u AI_GATEWAY_API_KEY -u VERCEL_OIDC_TOKEN FX_DISABLE_KEYCHAIN=1 FX_TEST_SKIP_ONBOARDING=1 ${FX_BIN} 2>${stderrPath}`,
          cwd: workDir,
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);

        await session.sendLiteralText("alpha");
        await session.sendHexBytes(["0a"]);
        await session.sendLiteralText("leftMIDright");
        await session.sendHexBytes(["0a"]);
        await session.sendLiteralText("gamma");
        await waitForLatestFooterState(
          route.label,
          session,
          stderrPath,
          originalInput,
          null,
        );

        await session.sendKeys(
          Array(leftKeysToMiddle).fill("Left").join(" "),
        );
        await session.sendHexBytes(route.hex);
        const finalGrid = await waitForLatestFooterState(
          route.label,
          session,
          stderrPath,
          route.expectedVisible,
          "leftMIDright",
        );

        const failures: string[] = [];
        const footer = assertSingleFooter(finalGrid, failures, route.label);
        if (footer === null) {
          failures.push(`${route.label}: latest footer is unavailable`);
        } else {
          assertFooterLogicalRows(
            finalGrid,
            footer,
            route.expectedVisible.split("\n"),
            failures,
            route.label,
          );
        }
        if (!session.isAlive()) {
          failures.push(`${route.label}: fx process is not alive`);
        }
        const stderr = readFileSync(stderrPath, "utf8");
        if (stderr.length !== 0) {
          failures.push(`${route.label}: stderr is not empty`);
        }
        if (failures.length !== 0) {
          throw new Error(
            `${failures.join("\n")}\nFinal grid:\n${finalGrid.join("\n")}\nstderr:\n${stderr}`,
          );
        }

        await session.kill();
        session = null;
      }
    },
    TIMEOUT,
  );
});
