# quickjs-ng in fx

This folder is fx's copy of [quickjs-ng](https://github.com/quickjs-ng/quickjs), the JavaScript engine that `src/js/engine.zig` runs. fx builds it from this folder, so nothing is downloaded at build time, and fixes from upstream arrive only when someone updates the folder, as Update to a new release describes.

## Upstream release

| Field | Value |
| --- | --- |
| Release | `v0.18.0` |
| Commit | `d7215b0ad3fc2c562e8317fd9bca058fd4863804` |
| License | MIT, in `LICENSE` and `THIRD_PARTY_NOTICES.md` |

## Release files

The release's copy of each engine file and its SHA-256. `check` compares this folder with them after taking the patches off, and `update` rewrites the table for the release it moves to. The hashes are of the files, not of the archive they come in: GitHub keeps a commit's files the same in every archive, but not the archive's compressed bytes.

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `96f73f9d2a16c21a36b418f06073be26e7d6d5e7c1bc99756b21a4f2c74ef171` |
| `builtin-array-fromasync.h` | `d313ac1e47eaa08f39b2cb0929a512d88e492906c400f650e141d00b79faa905` |
| `builtin-iterator-zip-keyed.h` | `5b015a8063088987f0fb19357c9da5ec44a7197493fdbb23740fde8f470049a4` |
| `builtin-iterator-zip.h` | `54834b615ddc59541515a7aa6d2c66fbfbf3213608f52e463d2469d63d395465` |
| `cutils.h` | `dffec8bea17f08108da5a91c1178804754698bbbb6202dc100268e78e8c5b770` |
| `dtoa.c` | `a8d2cf2d04db406e0c16acdd95ab0e709d309902865722f41dac07a1ba5676af` |
| `dtoa.h` | `1c4a4540c0038632c8a4c225472fbc21bd476fb35c4da4a857a11965b58231b9` |
| `libregexp-opcode.h` | `2a98d646089f3a72f25480116297c5fdb5b28fd9f815447273951f4ade4a115e` |
| `libregexp.c` | `af13e996abb1767fe0cdfda123c45b811d53688d403a2ac47142e97bf79f1fae` |
| `libregexp.h` | `53ff95a038f7001b752c455d195d998e2955f0ae4ed62a002c13eca798db3ceb` |
| `libunicode-table.h` | `5840a921ac11664b505ee37b1219f518fff2a04972fe848b4bdf1e85c5a0bd83` |
| `libunicode.c` | `c4724e77ec5f122373d2635b6d481cfb5d96024a38453a54a0830007c4b5f3c9` |
| `libunicode.h` | `ad13f66aaea3fab1616e84b9c048f2a315e1bdbab628b966617a7a3e55bcba2b` |
| `list.h` | `cb6e24e8ee54bccdd66234fe54cd702d1160b9841db2b9b9adeb5003afe301d5` |
| `quickjs-atom.h` | `8045b870825a43ecdb50692aac7ad21b43139b288df466ca5f7b780bde4ac13f` |
| `quickjs-c-atomics.h` | `29883c742a5c512278fce54d19b1b9af949006e1d7dfc9ffa2e0946b184d8c5c` |
| `quickjs-opcode.h` | `0054b0c45fd091afa308c3fb93b5862e0b071235918d3d73e413d23fce388bbc` |
| `quickjs.c` | `51b1d3919ffe812d0e01793f85d347bcea48c924c11262c5c5f00df1e4759d74` |
| `quickjs.h` | `6d3879c856551653a1c64fabe52d6d07dc84e97bac3df45848df626702fc30de` |

## What fx took

fx took the engine and nothing around it: `quickjs.c`, `libregexp.c`, `libunicode.c`, `dtoa.c`, the headers they include, and `LICENSE`. It left out `quickjs-libc`, which gives programs the `std` and `os` modules with files, processes, and timers, along with the `qjs` and `qjsc` programs, the tests, and the build files. `build.zig` compiles the four C files with upstream's flags and keeps the C undefined-behavior checks on in every optimization mode.

## Changes from upstream

Each engine file here is the release's copy with the patches in `patches/` applied in name order, and each patch is one change. `scripts/quickjs-fork.sh check` takes the patches off a copy of this folder, newest first, and compares each file with its SHA-256 under Release files. It downloads nothing, and CI runs it on every change. Describe each patch here: the file, what changed, and why.

- `patches/0001-poll-interrupts-in-long-loops.patch`, `quickjs.c`: the loops in `js_array_join`, `js_array_reverse`, `js_array_slice`, `js_array_concat`, `js_array_sort`, `JS_CopySubArray`, `JS_FlattenIntoArray`, `js_string_raw`, the array case of `js_json_to_str`, and the replacer-array loop of `JS_JSONStringify` call `js_poll_interrupts` on each pass, as `js_array_includes` already does. Each walks an object up to its `length`, which a program can set as high as 2^53 - 1, without allocating or calling back into JavaScript, so nothing else stops it. Without the check, `join`, `reverse`, `shift`, `unshift`, `splice`, `copyWithin`, `slice`, `concat`, `flat`, `sort`, `String.raw`, and `JSON.stringify` ran past fx's deadline for as long as the length allowed.
- `patches/0002-normalize-realloc-callbacks.patch`, `quickjs.c`: `String.prototype.localeCompare` and `String.prototype.normalize` passed `js_realloc` and `js_realloc_rt` to `unicode_normalize` cast to `DynBufReallocFunc`. Calling a function through a pointer of another type fails the function-type check that `build.zig` turns on, so a program that called either method trapped. The fork adds `fx_dbuf_realloc_ctx` and `fx_dbuf_realloc_rt`, which have the exact `DynBufReallocFunc` type, and passes those instead.
- `patches/0003-cutils-include-stddef.patch`, `cutils.h`: includes `<stddef.h>`. A static musl build's headers don't define `offsetof` along the way, as glibc's and macOS's do, so the header's own fallback, `((size_t) &((type *)0)->field)`, stood in for it. The undefined-behavior checks read that as a member access through a null pointer, so every `container_of` and `list_entry` trapped, and the engine stopped at its first allocation.
- `patches/0004-no-debug-dumps.patch`, `quickjs.c`: builds without `ENABLE_DUMPS`. Upstream turns the dump code on whenever `NDEBUG` is undefined, and fx builds the C without `NDEBUG`, which also keeps the engine's `assert` checks. fx never sets dump flags, so that code was linked but never ran: about 36 KB of the engine.
- `patches/0005-no-modules.patch`, `quickjs.c`: dynamic `import()` rejects its promise before loading anything, and evaluating a module, compiling source as a module, reading module bytecode, and building a module namespace each return an error first. The namespace is built through the engine's table of lazy property initializers, so its entry needs the error too, or the namespace and export-resolution code stays linked. fx runs every program as a script, and `engine.zig`'s module loader already refused every `import()`, but the module code stayed linked: about 20 KB. `import()` still returns a promise that rejects with "import() is not available in code mode", so a program's `.catch` sees it.

## Change the engine

Edit the files here, then run `scripts/quickjs-fork.sh save NAME` from the repository root. It downloads the release by its commit, checks its files against the table above, and writes the difference between this folder and the release plus the existing patches as the next patch, `patches/NNNN-NAME.patch`. Describe the patch above. `check` fails while a change has no patch.

## Update to a new release

Run `scripts/quickjs-fork.sh update v0.19.0` with the release's tag, or with a full commit for a fix that has no release yet. It applies the patches to that release with a three-way merge, records each patch again against it, writes the result here, and records the release, its commit, and its files' SHA-256s above. It refuses to start while this folder has a change no patch holds, so save that change first. A patch whose change the release already has comes out empty and is removed; remove its entry above.

When a patch no longer applies, the update stops, names the patch, and keeps its work folder with the merge in `repo`. Resolve the conflict in the files there, then run `scripts/quickjs-fork.sh update --continue DIR` with the folder it named. That records the resolved files as the patch's new version and goes on with the rest. When upstream fixed the same problem its own way, keep upstream's lines; the patch then comes out empty and is removed.

After an update, run `zig build test-js` and the code-mode tests. `scripts/quickjs-fork-test.sh` tests the script itself against a local stand-in for quickjs-ng, with no network.
