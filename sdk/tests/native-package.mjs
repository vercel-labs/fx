// The libfx platform packages, as the package tests install them.
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { resolve } from "node:path";

// Each supported platform's package. node.js imports the same names, and
// test-node-package.mjs checks that the packager publishes them.
export const nativePackages = {
  "linux-x64": "@libfx/libfx-linux-x64-gnu",
  "linux-arm64": "@libfx/libfx-linux-arm64-gnu",
  "darwin-x64": "@libfx/libfx-darwin-x64",
  "darwin-arm64": "@libfx/libfx-darwin-arm64",
};

// The package node.js loads on this machine.
export const localNativePackage = nativePackages[`${process.platform}-${process.arch}`];

// The value of `--native-dir <dir>` in argv, resolved, or null.
export function nativeDirArgument(argv = process.argv) {
  const index = argv.indexOf("--native-dir");
  if (index < 0) return null;
  if (!argv[index + 1]) throw new Error("--native-dir needs a directory of platform package tarballs");
  return resolve(argv[index + 1]);
}

// The manifest inside a package tarball.
export function tarballManifest(path) {
  const listing = spawnSync("tar", ["-xzOf", path, "package/package.json"], { encoding: "utf8" });
  if (listing.status !== 0) throw new Error(`cannot read the manifest in ${path}: ${listing.stderr}`);
  return JSON.parse(listing.stdout);
}

// Every platform package tarball in `dir`, by package name.
export function nativeTarballs(dir) {
  return Object.fromEntries(readdirSync(dir).filter((name) => name.endsWith(".tgz")).sort()
    .map((name) => [tarballManifest(resolve(dir, name)).name, resolve(dir, name)]));
}

// The tarball in `dir` for this machine. npm rejects an explicit install
// whose os or cpu does not match, so tests install only this one.
export function localNativeTarball(dir) {
  const tarball = nativeTarballs(dir)[localNativePackage];
  if (!tarball) throw new Error(`${dir} has no ${localNativePackage} tarball`);
  return tarball;
}
