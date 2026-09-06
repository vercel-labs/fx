#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { setImmediate } from "node:timers";

// A hot Wasm loop must survive resumption across host tasks during JIT tier-up.
// Bun 1.3.14 crashes here without any SDK, fetch, or instance teardown involved.
// Fixture source (Zig 0.16, wasm32-freestanding, ReleaseSmall, no entry, rdynamic):
// extern "host" fn next() i32;
// export fn run() i32 {
//     var sum: i32 = 0;
//     for (0..100000) |_| sum +%= next();
//     return sum;
// }
const module = await WebAssembly.compile(new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 2,
  13, 1, 4, 104, 111, 115, 116, 4, 110, 101, 120, 116, 0, 0, 3, 2,
  1, 0, 4, 5, 1, 112, 1, 1, 1, 5, 3, 1, 0, 16, 6, 9,
  1, 127, 1, 65, 128, 128, 192, 0, 11, 7, 16, 2, 6, 109, 101, 109,
  111, 114, 121, 2, 0, 3, 114, 117, 110, 0, 1, 10, 49, 1, 47, 1,
  2, 127, 65, 0, 33, 0, 65, 160, 141, 6, 33, 1, 2, 64, 3, 64,
  32, 1, 69, 13, 1, 32, 1, 65, 127, 106, 33, 1, 16, 128, 128, 128,
  128, 0, 32, 0, 106, 33, 0, 12, 0, 11, 11, 32, 0, 11,
]));

let calls = 0;
let suspensions = 0;
const instance = await WebAssembly.instantiate(module, {
  host: {
    next: new WebAssembly.Suspending(() => {
      calls += 1;
      if (calls % 32 !== 0) return 1;
      suspensions += 1;
      return new Promise((resolve) => setImmediate(() => resolve(1)));
    }),
  },
});
assert.equal(await WebAssembly.promising(instance.exports.run)(), 100_000);
assert.equal(calls, 100_000);
assert.equal(suspensions, 3125);
console.log("Wasm JSPI tier-up passed: 100000 calls and 3125 task resumptions");
