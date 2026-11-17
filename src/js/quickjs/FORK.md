# quickjs-ng in fx

This folder is fx's copy of [quickjs-ng](https://github.com/quickjs-ng/quickjs), the JavaScript engine that `src/js/engine.zig` runs. fx builds it from this folder, so nothing is downloaded at build time, and fixes from upstream arrive only when someone updates the folder, as Update to a new release describes.

## Upstream release

| Field | Value |
| --- | --- |
| Release | `v0.18.0` |
| Commit | `d7215b0ad3fc2c562e8317fd9bca058fd4863804` |
| Archive | `https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.18.0.tar.gz` |
| Archive SHA-256 | `28bcd89aa3683fd2a946537e5ce3f11cc46b5cbf3383c7561aaef3df5ff9f1dd` |
| License | MIT, in `LICENSE` and `THIRD_PARTY_NOTICES.md` |

## What fx took

fx took the engine and nothing around it: `quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, the headers they include, and `LICENSE`. It left out `quickjs-libc`, which gives programs the `std` and `os` modules with files, processes, and timers, along with the `qjs` and `qjsc` programs, the tests, and the build files. `build.zig` compiles the four C files with upstream's flags and keeps the C undefined-behavior checks on in every optimization mode.

## Changes from upstream

Each engine file here is the release archive's copy with the patches in `patches/` applied in name order, and each patch is one change. `scripts/quickjs-fork.sh check` downloads the release, applies the patches, and compares the result with this folder byte for byte; CI runs it on every change. Describe each patch here: the file, what changed, and why.

- `patches/0001-poll-interrupts-in-long-loops.patch`, `quickjs.c`: the loops in `js_array_join`, `js_array_reverse`, `js_array_slice`, `js_array_concat`, `js_array_sort`, `JS_CopySubArray`, `JS_FlattenIntoArray`, `js_string_raw`, the array case of `js_json_to_str`, and the replacer-array loop of `JS_JSONStringify` call `js_poll_interrupts` on each pass, as `js_array_includes` already does. Each walks an object up to its `length`, which a program can set as high as 2^53 - 1, without allocating or calling back into JavaScript, so nothing else stops it. Without the check, `join`, `reverse`, `shift`, `unshift`, `splice`, `copyWithin`, `slice`, `concat`, `flat`, `sort`, `String.raw`, and `JSON.stringify` ran past fx's deadline for as long as the length allowed.
- `patches/0002-normalize-realloc-callbacks.patch`, `quickjs.c`: `String.prototype.localeCompare` and `String.prototype.normalize` passed `js_realloc` and `js_realloc_rt` to `unicode_normalize` cast to `DynBufReallocFunc`. Calling a function through a pointer of another type fails the function-type check that `build.zig` turns on, so a program that called either method trapped. The fork adds `fx_dbuf_realloc_ctx` and `fx_dbuf_realloc_rt`, which have the exact `DynBufReallocFunc` type, and passes those instead.
- `patches/0003-cutils-include-stddef.patch`, `cutils.h`: includes `<stddef.h>`. A static musl build's headers don't define `offsetof` along the way, as glibc's and macOS's do, so the header's own fallback, `((size_t) &((type *)0)->field)`, stood in for it. The undefined-behavior checks read that as a member access through a null pointer, so every `container_of` and `list_entry` trapped, and the engine stopped at its first allocation.

## Change the engine

Edit the files here, then run `scripts/quickjs-fork.sh save NAME` from the repository root. It writes the difference between this folder and the release plus the existing patches as the next patch, `patches/NNNN-NAME.patch`. Describe the patch above. `check` fails while a change has no patch.

## Update to a new release

Run `scripts/quickjs-fork.sh update v0.19.0` with the release's tag, or with a commit for a fix that has no release yet. It applies the patches to that release with a three-way merge, records each patch again against it, writes the result here, and records the release, commit, archive, and SHA-256 in the table above. A patch whose change the release already has comes out empty and is removed. When a patch no longer applies, it stops, names the patch, and keeps the merge so the conflict can be resolved. When upstream fixed the same problem its own way, delete the patch and its entry above and run the update again.

After an update, run `zig build test-js` and the code-mode tests.
