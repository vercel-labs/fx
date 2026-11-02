// libfx for require(). Node.js 20.19, 22.12, and later load an ES module with
// require(), so this runs node.js itself: CommonJS and ES module callers share
// one copy of libfx, and bundlers follow the same imports for both.
try {
  module.exports = require("./node.js");
} catch (error) {
  if (error?.code !== "ERR_REQUIRE_ESM") throw error;
  throw new Error(`require("libfx") needs Node.js 20.19, 22.12, or newer, which load ES modules with require(); this is Node.js ${process.versions.node}. Upgrade Node.js, or load libfx with import.`, { cause: error });
}
