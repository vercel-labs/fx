import { describe, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildShardPlan, restrictToFiles, selectShard } from "./ci-shards";

const files = ["a.test.ts", "b.test.ts", "c.test.ts", "d.test.ts"];

describe("CI shard planner", () => {
  test("assigns descending weights to the lightest shard deterministically", () => {
    const manifest = [
      { file: "d.test.ts", weight: 3 },
      { file: "b.test.ts", weight: 7 },
      { file: "a.test.ts", weight: 9 },
      { file: "c.test.ts", weight: 5 },
    ];

    const first = buildShardPlan(files, manifest, 2);
    const second = buildShardPlan([...files].reverse(), [...manifest].reverse(), 2);

    expect(first).toEqual({
      shards: [
        ["a.test.ts", "d.test.ts"],
        ["b.test.ts", "c.test.ts"],
      ],
      totals: [12, 12],
    });
    expect(second).toEqual(first);
  });

  test("uses filename and shard index to break equal-weight ties", () => {
    expect(buildShardPlan(files, [
      { file: "d.test.ts", weight: 1 },
      { file: "c.test.ts", weight: 1 },
      { file: "b.test.ts", weight: 5 },
      { file: "a.test.ts", weight: 5 },
    ], 2)).toEqual({
      shards: [
        ["a.test.ts", "c.test.ts"],
        ["b.test.ts", "d.test.ts"],
      ],
      totals: [6, 6],
    });
  });

  test("rejects missing and stale manifest entries", () => {
    expect(() => buildShardPlan(files, [
      { file: "a.test.ts", weight: 1 },
      { file: "b.test.ts", weight: 1 },
      { file: "c.test.ts", weight: 1 },
    ], 2)).toThrow("missing manifest entry: d.test.ts");

    expect(() => buildShardPlan(files, [
      ...files.map((file) => ({ file, weight: 1 })),
      { file: "removed.test.ts", weight: 1 },
    ], 2)).toThrow("stale manifest entry: removed.test.ts");
  });

  test("rejects duplicate filenames and invalid weights", () => {
    expect(() => buildShardPlan(files, [
      ...files.map((file) => ({ file, weight: 1 })),
      { file: "a.test.ts", weight: 2 },
    ], 2)).toThrow("duplicate manifest entry: a.test.ts");

    for (const weight of [0, -1, 1.5, Number.NaN]) {
      expect(() => buildShardPlan(files, files.map((file) => ({
        file,
        weight: file === "a.test.ts" ? weight : 1,
      })), 2)).toThrow("weight must be a positive integer: a.test.ts");
    }
  });

  test("rejects invalid shard counts, empty shards, and invalid indices", () => {
    const manifest = files.map((file) => ({ file, weight: 1 }));
    expect(() => buildShardPlan(files, manifest, 0)).toThrow(
      "shard count must be a positive integer",
    );
    expect(() => buildShardPlan(files, manifest, 5)).toThrow(
      "shard 4 is empty",
    );

    const plan = buildShardPlan(files, manifest, 2);
    expect(() => selectShard(plan, -1)).toThrow("invalid shard index: -1");
    expect(() => selectShard(plan, 2)).toThrow("invalid shard index: 2");
  });

  test("assigns the discovered set exactly once", () => {
    const plan = buildShardPlan(files, [
      { file: "a.test.ts", weight: 13 },
      { file: "b.test.ts", weight: 8 },
      { file: "c.test.ts", weight: 5 },
      { file: "d.test.ts", weight: 3 },
    ], 3);
    const assigned = plan.shards.flat().sort();

    expect(assigned).toEqual(files);
    expect(new Set(assigned).size).toBe(files.length);
    expect(selectShard(plan, 0)).toEqual(plan.shards[0]);
  });

  test("an exact relative path does not select a colliding Bun test basename", () => {
    const root = mkdtempSync(join(tmpdir(), "fx-ci-shard-exact-path-"));
    const marker = join(root, "loaded.txt");
    const exact = "gateway-stream-lifecycle.test.ts";
    const collision = "tui-gateway-stream-lifecycle.test.ts";
    try {
      for (const [filename, label] of [[exact, "exact"], [collision, "collision"]]) {
        writeFileSync(
          join(root, filename),
          `import { appendFileSync } from "node:fs";\n` +
            `appendFileSync(${JSON.stringify(marker)}, ${JSON.stringify(`${label}\n`)});\n` +
            `import { test } from "bun:test";\n` +
            `test("fixture", () => {});\n`,
        );
      }

      const result = Bun.spawnSync({
        cmd: [
          process.execPath,
          "test",
          `./${exact}`,
        ],
        cwd: root,
        stdout: "pipe",
        stderr: "pipe",
      });
      expect(result.exitCode).toBe(0);
      expect(readFileSync(marker, "utf8")).toBe("exact\n");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

describe("macOS platform E2E list", () => {
  const listed: unknown = JSON.parse(
    readFileSync(join(import.meta.dir, "macos-platform-tests.json"), "utf8"),
  );
  const rootTests = readdirSync(import.meta.dir).filter((name) => name.endsWith(".test.ts"));

  test("names existing root E2E files once, in sorted order", () => {
    expect(Array.isArray(listed)).toBe(true);
    const names = listed as string[];
    expect(names.length).toBeGreaterThan(0);
    for (const name of names) expect(rootTests).toContain(name);
    expect(names).toEqual([...new Set(names)].sort());
  });

  test("includes every E2E file that branches on the platform", () => {
    const platformBranch = /\bplatform(\(\))?\s*[!=]==\s*["'](darwin|linux)["']/;
    const missing = rootTests.filter((name) =>
      platformBranch.test(readFileSync(join(import.meta.dir, name), "utf8")) &&
      !(listed as string[]).includes(name)
    );
    expect(missing).toEqual([]);
  });

  test("plans the listed files with their checked-in weights", () => {
    const manifest = [
      { file: "a.test.ts", weight: 9 },
      { file: "b.test.ts", weight: 7 },
      { file: "c.test.ts", weight: 5 },
      { file: "d.test.ts", weight: 3 },
    ];

    const restricted = restrictToFiles(files, manifest, ["d.test.ts", "b.test.ts", "c.test.ts"]);
    const plan = buildShardPlan(restricted.files, restricted.manifest, 2);

    expect(plan).toEqual({
      shards: [["b.test.ts"], ["c.test.ts", "d.test.ts"]],
      totals: [7, 8],
    });
  });

  test("rejects empty, unknown, and duplicate listed files", () => {
    const manifest = files.map((file) => ({ file, weight: 1 }));

    expect(() => restrictToFiles(files, manifest, [])).toThrow("non-empty array");
    expect(() => restrictToFiles(files, manifest, ["z.test.ts"])).toThrow("not a discovered test");
    expect(() => restrictToFiles(files, manifest, ["a.test.ts", "a.test.ts"])).toThrow("duplicate");
  });
});
