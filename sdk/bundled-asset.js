// webpack rewrites `new URL("./asset", import.meta.url)` in a bundled
// module to a relative URL object under its public path. This maps one back
// to the file webpack emitted, which Node can read or load.
export function bundledAssetUrl(asset) {
  if (asset.protocol !== "" || typeof asset.href !== "string" ||
      typeof __webpack_base_uri__ === "undefined" || typeof __webpack_public_path__ !== "string" ||
      !asset.href.startsWith(__webpack_public_path__)) {
    throw new TypeError("Bundled asset URL has no filesystem mapping");
  }
  // Webpack's relative URL is a public asset address, not a Node URL instance.
  return new URL(asset.href.slice(__webpack_public_path__.length), __webpack_base_uri__);
}
