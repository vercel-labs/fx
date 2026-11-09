// Preloaded into each Next server that test-next-package.mjs starts.
//
// Before `next dev --webpack` compiles anything, it waits for Next's version
// check, a request to the npm registry with no timeout of its own. While the
// registry was slow, dev printed that it was ready and then answered nothing
// until the test gave up. The check only feeds Next's error overlay, so the
// request fails here at once and Next uses its "staleness unknown" answer.
const fetch = globalThis.fetch;
globalThis.fetch = (input, init) => {
  const url = String(input instanceof Request ? input.url : input);
  if (url.startsWith("https://registry.npmjs.org/")) {
    return Promise.reject(new TypeError("test-next-package.mjs does not use the npm registry"));
  }
  return fetch(input, init);
};
