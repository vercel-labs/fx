import { readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";

export type ShardPlan = {
  shards: string[][];
  totals: number[];
};

type WeightEntry = {
  file: string;
  weight: number;
};

function compareFilenames(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function parseManifest(value: unknown): WeightEntry[] {
  if (!Array.isArray(value)) throw new Error("shard weight manifest must be an array");

  const seen = new Set<string>();
  return value.map((entry, index) => {
    if (!entry || typeof entry !== "object") {
      throw new Error(`invalid manifest entry at index ${index}`);
    }
    const { file, weight } = entry as Partial<WeightEntry>;
    if (typeof file !== "string" || !/^[^/\r\n]+\.test\.ts$/.test(file)) {
      throw new Error(`invalid manifest filename at index ${index}`);
    }
    if (seen.has(file)) throw new Error(`duplicate manifest entry: ${file}`);
    seen.add(file);
    if (typeof weight !== "number" ||
        !Number.isSafeInteger(weight) ||
        weight <= 0) {
      throw new Error(`weight must be a positive integer: ${file}`);
    }
    return { file, weight };
  });
}

export function buildShardPlan(
  discoveredFiles: string[],
  manifestValue: unknown,
  shardCount: number,
): ShardPlan {
  if (!Number.isSafeInteger(shardCount) || shardCount <= 0) {
    throw new Error("shard count must be a positive integer");
  }

  const discovered = [...discoveredFiles].sort(compareFilenames);
  if (new Set(discovered).size !== discovered.length) {
    throw new Error("discovered test filenames must be unique");
  }
  for (const file of discovered) {
    if (!/^[^/\r\n]+\.test\.ts$/.test(file)) {
      throw new Error(`invalid discovered test filename: ${file}`);
    }
  }

  const manifest = parseManifest(manifestValue);
  const discoveredSet = new Set(discovered);
  const weights = new Map(manifest.map((entry) => [entry.file, entry.weight]));
  const missing = discovered.filter((file) => !weights.has(file));
  if (missing.length > 0) throw new Error(`missing manifest entry: ${missing[0]}`);
  const stale = manifest
    .map((entry) => entry.file)
    .filter((file) => !discoveredSet.has(file))
    .sort(compareFilenames);
  if (stale.length > 0) throw new Error(`stale manifest entry: ${stale[0]}`);

  const ordered = [...manifest].sort((left, right) =>
    right.weight - left.weight || compareFilenames(left.file, right.file)
  );
  const shards = Array.from({ length: shardCount }, () => [] as string[]);
  const totals = Array.from({ length: shardCount }, () => 0);
  for (const entry of ordered) {
    let target = 0;
    for (let index = 1; index < shardCount; index += 1) {
      if (totals[index]! < totals[target]!) target = index;
    }
    shards[target]!.push(entry.file);
    totals[target]! += entry.weight;
  }

  const emptyIndex = shards.findIndex((shard) => shard.length === 0);
  if (emptyIndex >= 0) throw new Error(`shard ${emptyIndex} is empty`);
  const assigned = shards.flat().sort(compareFilenames);
  if (assigned.length !== discovered.length ||
      assigned.some((file, index) => file !== discovered[index])) {
    throw new Error("shard assignment is not the discovered set exactly once");
  }
  return { shards, totals };
}

// Narrows a shard plan to a listed subset of the discovered files, such as the
// macOS platform list, while keeping each file's checked-in weight.
export function restrictToFiles(
  discoveredFiles: string[],
  manifestValue: unknown,
  listValue: unknown,
): { files: string[]; manifest: WeightEntry[] } {
  if (!Array.isArray(listValue) || listValue.length === 0) {
    throw new Error("file list must be a non-empty array");
  }
  const discovered = new Set(discoveredFiles);
  const listed = new Set<string>();
  for (const file of listValue) {
    if (typeof file !== "string" || !discovered.has(file)) {
      throw new Error(`listed file is not a discovered test: ${String(file)}`);
    }
    if (listed.has(file)) throw new Error(`duplicate listed file: ${file}`);
    listed.add(file);
  }
  const manifest = parseManifest(manifestValue).filter((entry) => listed.has(entry.file));
  return { files: [...listed], manifest };
}

export function selectShard(plan: ShardPlan, shardIndex: number): string[] {
  if (!Number.isSafeInteger(shardIndex) ||
      shardIndex < 0 || shardIndex >= plan.shards.length) {
    throw new Error(`invalid shard index: ${shardIndex}`);
  }
  return plan.shards[shardIndex]!;
}

function integerArgument(args: string[], name: string): number {
  const index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) throw new Error(`missing ${name}`);
  const value = Number(args[index + 1]);
  if (!Number.isSafeInteger(value)) throw new Error(`invalid ${name}: ${args[index + 1]}`);
  return value;
}

function optionalArgument(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index < 0) return undefined;
  if (index + 1 >= args.length) throw new Error(`missing ${name} value`);
  return args[index + 1];
}

function run(args: string[]): void {
  const shardCount = integerArgument(args, "--shard-count");
  const shardIndex = integerArgument(args, "--shard-index");
  let manifest: unknown = JSON.parse(
    readFileSync(join(import.meta.dir, "ci-shard-weights.json"), "utf8"),
  );
  let discovered = readdirSync(import.meta.dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(".test.ts"))
    .map((entry) => entry.name);
  const listPath = optionalArgument(args, "--only");
  if (listPath !== undefined) {
    const list = JSON.parse(readFileSync(resolve(import.meta.dir, listPath), "utf8"));
    const restricted = restrictToFiles(discovered, manifest, list);
    discovered = restricted.files;
    manifest = restricted.manifest;
  }
  const plan = buildShardPlan(discovered, manifest, shardCount);
  const selected = selectShard(plan, shardIndex);

  for (let index = 0; index < plan.shards.length; index += 1) {
    console.error(
      `E2E shard ${index}/${shardCount}: weight=${plan.totals[index]} files=${plan.shards[index]!.join(",")}`,
    );
  }
  process.stdout.write(`${selected.join("\n")}\n`);
}

if (import.meta.main) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  }
}
