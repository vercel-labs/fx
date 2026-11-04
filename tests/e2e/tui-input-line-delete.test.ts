import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupIsolatedTestHome,
  createIsolatedTestHome,
  FX_BIN,
} from "../evals/eval-helpers";
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
let testHome: string | null = null;
const workDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  if (testHome) {
    cleanupIsolatedTestHome(testHome);
    testHome = null;
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

        testHome = createIsolatedTestHome();
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: workDir,
          env: { HOME: testHome },
          stderrPath,
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
        cleanupIsolatedTestHome(testHome);
        testHome = null;
      }
    },
    TIMEOUT,
  );

  test(
    "repeated line-start deletion joins the previous logical line",
    async () => {
      const lineStartRoutes = routes.filter(
        (route) => route.expectedVisible === "alpha\nright\ngamma",
      );
      for (const route of lineStartRoutes) {
        const workDir = mkdtempSync(join(tmpdir(), "fx-line-delete-"));
        workDirs.push(workDir);
        const stderrPath = join(workDir, "stderr.log");
        writeFileSync(stderrPath, "");

        testHome = createIsolatedTestHome();
        session = await TmuxSession.create({
          cmd: FX_BIN,
          cwd: workDir,
          env: { HOME: testHome },
          stderrPath,
          width: 120,
          height: 40,
        });
        await session.waitForComposer(10_000);

        await session.sendLiteralText("alpha");
        await session.sendHexBytes(["0a"]);
        await session.sendLiteralText("beta");
        await session.sendHexBytes(["0a"]);
        await session.sendLiteralText("gamma");
        await waitForLatestFooterState(
          route.label,
          session,
          stderrPath,
          "alpha\nbeta\ngamma",
          null,
        );

        await session.sendHexBytes(route.hex);
        await waitForLatestFooterState(
          route.label,
          session,
          stderrPath,
          "alpha\nbeta",
          "gamma",
        );

        // At the start of the now empty line, the next press removes the
        // line break, so typed text lands at the end of the line above.
        await session.sendHexBytes(route.hex);
        await session.sendLiteralText("X");
        const finalGrid = await waitForLatestFooterState(
          route.label,
          session,
          stderrPath,
          "alpha\nbetaX",
          "gamma",
        );

        const failures: string[] = [];
        const footer = assertSingleFooter(finalGrid, failures, route.label);
        if (footer === null) {
          failures.push(`${route.label}: latest footer is unavailable`);
        } else {
          assertFooterLogicalRows(
            finalGrid,
            footer,
            ["alpha", "betaX"],
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
        cleanupIsolatedTestHome(testHome);
        testHome = null;
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP)("tui: backward word deletion", () => {
  const wordRoutes = [
    { label: "Kitty Ctrl+Backspace", sequence: "\x1b[127;5u", expected: "left  right" },
    { label: "Kitty Ctrl+Backspace repeat", sequence: "\x1b[127;5:2u", expected: "left  right" },
    { label: "modifyOtherKeys Ctrl+Backspace", sequence: "\x1b[27;5;127~", expected: "left  right" },
    { label: "Option+Backspace", sequence: "\x1b[127;3u", expected: "left  right" },
    { label: "Backspace", sequence: "\x7f", expected: "left caf right" },
    { label: "Ctrl+H", sequence: "\x08", expected: "left caf right" },
  ];

  for (const route of wordRoutes) {
    test(route.label, async () => {
      testHome = createIsolatedTestHome();
      const stderrPath = join(testHome, "stderr.log");
      writeFileSync(stderrPath, "");
      session = await TmuxSession.create({
        cmd: FX_BIN,
        cwd: testHome,
        env: { HOME: testHome },
        stderrPath,
        width: 120,
        height: 40,
      });
      await session.waitForComposer(10_000);
      await session.sendLiteralText("alpha");
      await session.sendHexBytes(["0a"]);
      await session.sendLiteralText("left café right");
      await session.sendHexBytes(["0a"]);
      await session.sendLiteralText("gamma");
      await waitForLatestFooterState(
        route.label, session, stderrPath, "alpha\nleft café right\ngamma", null,
      );
      await session.sendKeys(Array(12).fill("Left").join(" "));
      await session.sendHexBytes(Array.from(Buffer.from(route.sequence), (byte) =>
        byte.toString(16).padStart(2, "0")
      ));
      const finalGrid = await waitForLatestFooterState(
        route.label, session, stderrPath, `alpha\n${route.expected}\ngamma`, "left café right",
      );
      const failures: string[] = [];
      const footer = assertSingleFooter(finalGrid, failures, route.label);
      if (footer) {
        assertFooterLogicalRows(finalGrid, footer, ["alpha", route.expected, "gamma"], failures, route.label);
      }
      expect(failures).toEqual([]);
      expect(session.isAlive()).toBe(true);
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    }, TIMEOUT);
  }
});
