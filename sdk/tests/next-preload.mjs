// Preloaded into each Next server that test-next-package.mjs starts. Next's
// dev server rewrites NODE_OPTIONS and runs two --import flags together as
// one path, so this one file loads both hooks.
import "./no-npm-registry.mjs";
import "./record-loads.mjs";
