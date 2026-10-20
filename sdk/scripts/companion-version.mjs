// libfx ships each native addon as a version of libfx itself, beside the
// release it belongs to (PKG-2): libfx 0.0.15 comes with 0.0.15-0.linux-x64,
// 0.0.15-0.darwin-arm64 and so on; the dev build 0.0.15-dev.7.gabc with
// 0.0.15-0.linux-x64.dev.7.gabc. The prerelease starts with the number 0,
// which sorts below every other prerelease of that version and below the
// release itself, so no version range an app writes for libfx resolves to
// one of them.

/** The four platforms with a native addon. */
export const companions = ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64"];

/** The version the addon for `platform` ships as beside libfx `version`. */
export function companionVersion(version, platform) {
  if (!companions.includes(platform)) throw new Error(`no libfx addon for ${platform}`);
  const at = version.indexOf("-");
  if (at < 0) return `${version}-0.${platform}`;
  return `${version.slice(0, at)}-0.${platform}.${version.slice(at + 1)}`;
}

/** The dist-tag an addon version is published under; npm needs one for a prerelease. */
export const companionTag = (devChannel) => (devChannel ? "addon-dev" : "addon");
