#!/usr/bin/env node
import assert from "node:assert/strict";
import { createCatalogReader } from "../model-catalog.js";

const url = "https://ai-gateway.vercel.sh/coding-agent/v1/models";
const request = (key, signal, team) => ({
  method: "GET", headers: { authorization: "Bearer " + key, ...(team ? { "x-vercel-ai-gateway-team": team } : {}) },
  ...(signal ? { signal } : {}),
});
const response = suffix => Response.json({ object: "list", data: [
  { id: "models/first-" + suffix, type: "language", max_tokens: 1024 },
  { id: "models/last-" + suffix, type: "language", max_tokens: 2048 },
  { id: "models/embedding", type: "embedding" },
] });
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

{
  let calls = 0;
  const fetch = async () => { calls++; return response("shared"); };
  const first = createCatalogReader(fetch, { shared: true });
  const second = createCatalogReader(fetch, { shared: true });
  assert.deepEqual(await first.models(url, request("same")), ["models/first-shared", "models/last-shared"]);
  assert.deepEqual(await second.models(url, request("same")), ["models/first-shared", "models/last-shared"]);
  assert.equal(calls, 1);
  assert.equal(second.metadata(url, request("same"), "models/last-shared").data[0].max_tokens, 2048);
  const observed = first.metadata(url, request("same"), "models/last-shared");
  observed.data[0].max_tokens = 999;
  observed.data.length = 0;
  assert.equal(second.metadata(url, request("same"), "models/last-shared").data[0].max_tokens, 2048, "observer mutation escaped into shared metadata");
  assert.deepEqual(second.metadata(url, request("same"), "models/missing").data, []);
  const list = await first.models(url, request("same"));
  list.length = 0;
  assert.equal((await second.models(url, request("same"))).length, 2);
  await second.models(url, request("other"));
  await second.models(url, request("same", undefined, "other-team"));
  assert.equal(calls, 3);
  first.release(); second.release();
}
{
  let calls = 0;
  const fetch = async () => { calls++; return response("private"); };
  const first = createCatalogReader(fetch);
  const second = createCatalogReader(fetch);
  await first.models(url, request("same")); await second.models(url, request("same"));
  assert.equal(calls, 2);
  first.release();
  assert.equal(first.metadata(url, request("same"), "models/last-private"), null);
  second.release();
}
{
  let calls = 0, aborted = false;
  const gate = deferred();
  const fetch = async (_, init) => {
    calls++;
    init.signal.addEventListener("abort", () => { aborted = true; });
    await gate.promise;
    return response("alive");
  };
  const first = createCatalogReader(fetch, { shared: true });
  const second = createCatalogReader(fetch, { shared: true });
  const controller = new AbortController();
  const cancelled = first.models(url, request("same", controller.signal));
  const surviving = second.models(url, request("same"));
  controller.abort();
  await assert.rejects(cancelled, error => error.name === "AbortError");
  assert.equal(aborted, false);
  gate.resolve();
  assert.deepEqual(await surviving, ["models/first-alive", "models/last-alive"]);
  assert.equal(calls, 1);
}
{
  for (let microtasks = 0; microtasks <= 6; microtasks++) {
    const gate = deferred();
    const started = deferred();
    let cancelled = false;
    const body = new ReadableStream({ cancel() { cancelled = true; } });
    const reader = createCatalogReader(() => { started.resolve(); return gate.promise; });
    const controller = new AbortController();
    const pending = reader.models(url, request("cancel-handoff", controller.signal));
    await started.promise;
    gate.resolve(new Response(body));
    for (let index = 0; index < microtasks; index++) await Promise.resolve();
    controller.abort();
    await assert.rejects(pending, error => error.name === "AbortError");
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(cancelled, true, `response handoff leaked after ${microtasks} microtasks`);
    reader.release();
  }
}
{
  let clock = 0, calls = 0;
  const tasks = [];
  const gate = deferred();
  const reader = createCatalogReader(async () => {
    calls++;
    if (calls === 2) await gate.promise;
    return response(String(calls));
  }, { now: () => clock, onBackgroundTask: task => tasks.push(task) });
  await reader.models(url, request("one"));
  clock = 10 * 60 * 1000;
  assert.equal(reader.metadata(url, request("one"), "models/last-1").data[0].max_tokens, 2048);
  assert.equal(calls, 1, "peeking must not start refresh before first text");
  reader.refresh();
  assert.deepEqual(await reader.models(url, request("one")), ["models/first-1", "models/last-1"]);
  gate.resolve();
  await Promise.all(tasks);
  assert.equal(calls, 2);
  assert.equal(reader.metadata(url, request("one"), "models/last-1").data.length, 0);
  assert.equal(reader.metadata(url, request("one"), "models/last-2").data[0].max_tokens, 2048);
  clock = 71 * 60 * 1000;
  assert.equal(reader.metadata(url, request("one"), "models/last-2"), null);
  await reader.models(url, request("one"));
  assert.equal(calls, 3);
  reader.release();
}
{
  let clock = 0;
  const tasks = [];
  const reader = createCatalogReader(async () => response("unchanged"), {
    now: () => clock, onBackgroundTask: task => tasks.push(task),
  });
  await reader.models(url, request("one"));
  const revision = reader.metadata(url, request("one"), "models/last-unchanged").revision;
  clock = 6 * 60 * 1000;
  reader.metadata(url, request("one"), "models/last-unchanged");
  reader.refresh(); await Promise.all(tasks);
  assert.notEqual(reader.metadata(url, request("one"), "models/last-unchanged").revision, revision, "identical refresh must renew the core lease");
  clock = 61 * 60 * 1000;
  assert.ok(reader.metadata(url, request("one"), "models/last-unchanged").validForMs > 0);
  reader.release();
}
{
  let clock = 0, calls = 0, status = 503;
  const tasks = [];
  const reader = createCatalogReader(async () => ++calls === 1 ? response("good") : new Response(null, { status }), {
    now: () => clock, onBackgroundTask: task => tasks.push(task),
  });
  await reader.models(url, request("one"));
  clock = 6 * 60 * 1000;
  reader.metadata(url, request("one"), "models/last-good");
  reader.refresh(); await Promise.all(tasks);
  assert.equal(reader.metadata(url, request("one"), "models/last-good").data[0].max_tokens, 2048);
  reader.refresh(); assert.equal(calls, 2, "backoff must suppress repeated failures");
  clock += 1001; status = 401;
  reader.metadata(url, request("one"), "models/last-good");
  reader.refresh(); await Promise.all(tasks);
  assert.equal(reader.metadata(url, request("one"), "models/last-good"), null);
  await assert.rejects(reader.models(url, request("one")), /HTTP 401/);
  reader.release();
}
{
  let calls = 0;
  const reader = createCatalogReader(() => {
    calls++;
    if (calls === 1) throw new Error("transient fixture failure");
    return response("retry");
  });
  await assert.rejects(reader.models(url, request("one")), /transient fixture failure/);
  assert.deepEqual(await reader.models(url, request("one")), ["models/first-retry", "models/last-retry"]);
  assert.equal(calls, 2, "a synchronous failure must not leave a settled pending request");
  reader.release();
}
{
  const invalid = createCatalogReader(async () => new Response("not JSON"));
  await assert.rejects(invalid.models(url, request("one")), /malformed/);
  const invalidShape = createCatalogReader(async () => Response.json({ data: {} }));
  await assert.rejects(invalidShape.models(url, request("one")), /malformed/);
  const oversized = createCatalogReader(async () => new Response("", { headers: { "content-length": "4194305" } }));
  await assert.rejects(oversized.models(url, request("one")), RangeError);
}
console.log("model catalog cache contracts passed");
