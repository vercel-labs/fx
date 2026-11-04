# quickjs-ng in fx

This folder is fx's copy of [quickjs-ng](https://github.com/quickjs-ng/quickjs), the JavaScript engine that `src/js/engine.zig` runs. fx builds it from this folder, so nothing is downloaded at build time, and fixes from upstream arrive only when someone ports them here.

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

None. Every file here except this one matches the release archive byte for byte.

Record each change here when it lands: the file, what changed, and why. A fix from upstream can then be ported by comparing this folder with the next release.

## Compare the copy with upstream

Run from the repository root:

```sh
tmp="$(mktemp -d)"
curl -sSL -o "$tmp/quickjs.tar.gz" https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.18.0.tar.gz
shasum -a 256 "$tmp/quickjs.tar.gz"
tar -xzf "$tmp/quickjs.tar.gz" -C "$tmp"
for file in src/js/quickjs/*; do
  [ "$(basename "$file")" = FORK.md ] || cmp "$file" "$tmp/quickjs-0.18.0/$(basename "$file")"
done
```

`cmp` prints nothing when every file matches.
