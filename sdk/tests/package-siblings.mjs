// sdk/scripts/package-libfx.mjs writes libfx and the addon versions of libfx
// that ship beside it into one directory: `<dist>/libfx` and
// `<dist>/libfx-<platform>`. `npm pack` names their tarballs
// `libfx-<version>.tgz` and `libfx-<version>-0.<platform>.tgz`
// (sdk/scripts/companion-version.mjs). Given libfx's directory or tarball,
// these return the one beside it, or null.
import { existsSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { companionVersion } from "../scripts/companion-version.mjs";

export const nativePlatform = `${process.platform}-${process.arch}`;

/** The name libfx installs this machine's addon version under, such as `libfx-linux-x64`. */
export const nativeAlias = `libfx-${nativePlatform}`;

/** The addon version for `name`, such as `linux-x64`. */
export function packageBeside(libfx, name) {
  if (!libfx.endsWith(".tgz")) {
    const dir = join(dirname(libfx), `libfx-${name}`);
    return existsSync(join(dir, "package.json")) ? dir : null;
  }
  const version = /^libfx-(.+)\.tgz$/.exec(basename(libfx))?.[1];
  const tarball = version && join(dirname(libfx), `libfx-${companionVersion(version, name)}.tgz`);
  return tarball && existsSync(tarball) ? tarball : null;
}

/** This machine's addon version, the one with its native addon. */
export const nativePackageBeside = (libfx) => packageBeside(libfx, nativePlatform);
