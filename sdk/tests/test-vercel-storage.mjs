#!/usr/bin/env node
// The remote test fixture must reject incomplete setup before a suite starts
// creating sessions. These checks use fake credentials and make no requests.
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const fixture = new URL("./vercel-storage.mjs", import.meta.url).href;
const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const required = {
  WORKFLOW_VERCEL_AUTH_TOKEN: "fake-access-token-not-a-real-credential",
  VERCEL_PROJECT_ID: "prj_test",
  VERCEL_PROJECT_NAME: "libfx-test",
  VERCEL_TEAM_ID: "team_test",
  VERCEL_DEPLOYMENT_ID: "dpl_test",
};
const clean = { ...process.env };
for (const key of Object.keys(clean)) {
  if (key.startsWith("VERCEL_") || key.startsWith("WORKFLOW_") || key.startsWith("LIBFX_TEST_")) delete clean[key];
}
const noNetwork = 'globalThis.fetch = () => { throw new Error("unexpected network request"); };';
const run = (args, env) => {
  const result = spawnSync(process.execPath, args, {
    cwd: repoRoot,
    env: { ...clean, ...env },
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.error, undefined, result.error?.message);
  assert.equal(result.signal, null);
  return result;
};

let checks = 0;
for (const key of Object.keys(required)) {
  for (const value of [undefined, "   "]) {
    const env = { ...required, [key]: value };
    if (value === undefined) delete env[key];
    const result = run(["--input-type=module", "-e", `${noNetwork} await import(${JSON.stringify(fixture)});`], env);
    assert.equal(result.status, 1, `missing ${key} must fail before the suite starts`);
    assert.ok(result.stderr.includes(key), `the error must name ${key}`);
    assert.ok(!result.stderr.includes(required.WORKFLOW_VERCEL_AUTH_TOKEN), "credentials must not appear in the error");
    checks += 1;
  }
}

// A development OIDC token cannot authenticate the local api-workflow proxy.
const oidcOnly = { ...required, VERCEL_OIDC_TOKEN: "fake-oidc-not-an-access-token" };
delete oidcOnly.WORKFLOW_VERCEL_AUTH_TOKEN;
const oidc = run(["--input-type=module", "-e", `${noNetwork} await import(${JSON.stringify(fixture)});`], oidcOnly);
assert.equal(oidc.status, 1);
assert.ok(oidc.stderr.includes("WORKFLOW_VERCEL_AUTH_TOKEN"));
assert.ok(!oidc.stderr.includes(oidcOnly.VERCEL_OIDC_TOKEN));
checks += 1;

const valid = run(["--input-type=module", "-e", `${noNetwork} const { vercelStorage } = await import(${JSON.stringify(fixture)}); if (typeof vercelStorage !== "function") throw new Error("missing fixture");`], required);
assert.equal(valid.status, 0, valid.stderr);
checks += 1;

// Exercise the real suite entry point too, not only the fixture's import.
const suite = run(["--experimental-wasm-jspi", "sdk/tests/test-durable.mjs", "vercel", "native"], oidcOnly);
assert.equal(suite.status, 1);
assert.ok(suite.stderr.includes("WORKFLOW_VERCEL_AUTH_TOKEN"));
assert.ok(!suite.stdout.includes("FAIL "), "a setup error must not be reported as product failures");
checks += 1;

console.log(`vercel storage preflight passed: ${checks} checks, no network requests`);
