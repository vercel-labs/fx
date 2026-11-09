// Preload with `node --import <this file>`: appends the URL of each module
// the process loads, through import or require, to $LIBFX_LOAD_LOG as it
// loads, so a test can read the list while the process runs.
import { appendFileSync } from "node:fs";
import { registerHooks } from "node:module";

const log = process.env.LIBFX_LOAD_LOG;
if (log) {
  const seen = new Set();
  registerHooks({
    load(url, context, nextLoad) {
      if (!seen.has(url)) {
        seen.add(url);
        appendFileSync(log, `${url}\n`);
      }
      return nextLoad(url, context);
    },
  });
}
