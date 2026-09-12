from __future__ import annotations

import os
import json
import pathlib
import shlex
import tempfile
import unittest
from unittest import mock

from scripts.pgso.model import PgsoError
from scripts.pgso.toolchain import Toolchain


class PgsoToolchainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-toolchain-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        self.llvm_bin = self.root / "llvm" / "bin"
        self.system_bin = self.root / "system-bin"
        self.resource_dir = self.root / "llvm" / "lib" / "clang" / "21"
        self.sdk = self.root / "MacOSX.sdk"
        self.profile_runtime = (
            self.resource_dir / "lib" / "darwin" / "libclang_rt.profile_osx.a"
        )
        self.llvm_bin.mkdir(parents=True)
        self.system_bin.mkdir()
        self.profile_runtime.parent.mkdir(parents=True)
        self.profile_runtime.write_bytes(b"profile runtime")
        self.sdk.mkdir()

        self.zig = self.root / "zig"
        self.zig_lib = self.root / "zig lib"
        self.zig_sdk = self.zig_lib / "libc" / "darwin"
        self.zig_sdk.mkdir(parents=True)
        (self.zig_sdk / "libSystem.tbd").write_bytes(b"system stub")
        (self.zig_sdk / "SDKSettings.json").write_text('{"MinimalDisplayName":"26.4"}')
        zig_env = f'.{{\n    .lib_dir = {json.dumps(str(self.zig_lib))},\n}}\n'
        self.write_executable(self.zig, f"""case "$1" in
  version) printf '0.16.0\\n' ;;
  env) printf '%s' {shlex.quote(zig_env)} ;;
  *) exit 2 ;;
esac""")
        for name in ("opt", "llc", "llvm-profdata", "llvm-ar", "llvm-nm"):
            self.write_llvm_tool(name)
        self.write_clang()
        for name in ("strip", "codesign", "otool"):
            self.write_executable(self.system_bin / name, "exit 0")
        self.write_executable(self.system_bin / "ld", "printf '%s\\n' '{\"version\":\"1167.5\",\"architectures\":[\"arm64\"]}'")
        self.write_executable(
            self.system_bin / "xcrun",
            f"""if [ "$1" = --find ]; then printf '%s\\n' {shlex.quote(str(self.system_bin / 'ld'))}; exit 0; fi
case "$3" in
  --show-sdk-path) printf '%s\\n' {shlex.quote(str(self.sdk))} ;;
  --show-sdk-version) printf '26.4\\n' ;;
  *) exit 2 ;;
esac""",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_executable(self, path: pathlib.Path, body: str) -> None:
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def write_llvm_tool(self, name: str, version: str = "21.1.8") -> None:
        self.write_executable(
            self.llvm_bin / name,
            f"printf 'LLVM version {version}\\n'",
        )

    def write_clang(self, version: str = "21.1.8") -> None:
        body = f"""case "$1" in
  --print-resource-dir) printf '%s\\n' {shlex.quote(str(self.resource_dir))} ;;
  --version) printf 'clang version {version}\\n' ;;
  *) exit 2 ;;
esac"""
        self.write_executable(self.llvm_bin / "clang", body)

    def discover(self) -> Toolchain:
        with mock.patch.dict(
            os.environ,
            {"PATH": str(self.system_bin)},
            clear=False,
        ), mock.patch("platform.system", return_value="Darwin"), mock.patch(
            "platform.machine", return_value="arm64"
        ):
            return Toolchain.discover(
                str(self.zig),
                str(self.llvm_bin),
                "aarch64-macos",
            )

    def test_discover_resolves_the_exact_native_toolchain(self) -> None:
        toolchain = self.discover()

        self.assertEqual(self.zig.resolve(), toolchain.zig)
        self.assertEqual((self.llvm_bin / "opt").resolve(), toolchain.opt)
        self.assertEqual((self.llvm_bin / "llc").resolve(), toolchain.llc)
        self.assertEqual(
            (self.llvm_bin / "llvm-profdata").resolve(),
            toolchain.llvm_profdata,
        )
        self.assertEqual((self.llvm_bin / "llvm-ar").resolve(), toolchain.llvm_ar)
        self.assertEqual((self.llvm_bin / "llvm-nm").resolve(), toolchain.llvm_nm)
        self.assertEqual((self.llvm_bin / "clang").resolve(), toolchain.clang)
        self.assertEqual((self.system_bin / "strip").resolve(), toolchain.strip)
        self.assertEqual(
            (self.system_bin / "codesign").resolve(),
            toolchain.codesign,
        )
        self.assertEqual((self.system_bin / "otool").resolve(), toolchain.otool)
        self.assertEqual(self.sdk.resolve(), toolchain.sdk)
        self.assertEqual("26.4", toolchain.sdk_version)
        self.assertEqual((self.system_bin / "ld").resolve(), toolchain.apple_ld)
        self.assertEqual("1167.5", toolchain.apple_ld_version)
        self.assertEqual(self.zig_sdk.resolve(), toolchain.zig_darwin_sdk)
        self.assertEqual("26.4", toolchain.zig_sdk_version)
        self.assertEqual(self.profile_runtime.resolve(), toolchain.profile_runtime)
        self.assertEqual("0.16.0", toolchain.zig_version)
        self.assertEqual("21.1.8", toolchain.llvm_version)
        self.assertEqual("aarch64-macos", toolchain.target)
        self.assertEqual("arm64", toolchain.host_arch)

    def test_discover_rejects_the_wrong_target(self) -> None:
        with self.assertRaisesRegex(PgsoError, "unsupported target: x86_64-macos"):
            Toolchain.discover(str(self.zig), str(self.llvm_bin), "x86_64-macos")

    def test_discover_rejects_a_non_darwin_host(self) -> None:
        with mock.patch("platform.system", return_value="Linux"):
            with self.assertRaisesRegex(PgsoError, "requires a Darwin host"):
                Toolchain.discover(
                    str(self.zig),
                    str(self.llvm_bin),
                    "aarch64-macos",
                )

    def test_discover_rejects_a_non_arm64_host(self) -> None:
        with mock.patch("platform.system", return_value="Darwin"), mock.patch(
            "platform.machine", return_value="x86_64"
        ):
            with self.assertRaisesRegex(PgsoError, "requires an arm64 host"):
                Toolchain.discover(
                    str(self.zig),
                    str(self.llvm_bin),
                    "aarch64-macos",
                )

    def test_discover_rejects_the_wrong_zig_version(self) -> None:
        self.write_executable(self.zig, "printf '0.16.1\\n'")

        with self.assertRaisesRegex(PgsoError, "requires Zig 0.16.0"):
            self.discover()

    def test_discover_rejects_a_mixed_llvm_version(self) -> None:
        self.write_llvm_tool("llc", version="21.1.9")

        with self.assertRaisesRegex(PgsoError, "requires LLVM 21.1.8"):
            self.discover()

    def test_discover_rejects_a_missing_executable(self) -> None:
        (self.llvm_bin / "opt").unlink()

        with self.assertRaisesRegex(PgsoError, "missing executable: opt"):
            self.discover()

    def test_discover_rejects_an_llvm_tool_outside_the_root(self) -> None:
        outside = self.root / "outside-opt"
        self.write_executable(outside, "printf 'LLVM version 21.1.8\\n'")
        (self.llvm_bin / "opt").unlink()
        (self.llvm_bin / "opt").symlink_to(outside)

        with self.assertRaisesRegex(PgsoError, "LLVM tool escapes configured root"):
            self.discover()

    def test_discover_rejects_a_missing_profile_runtime(self) -> None:
        self.profile_runtime.unlink()

        with self.assertRaisesRegex(PgsoError, "missing LLVM profile runtime"):
            self.discover()

    def test_discover_rejects_a_missing_macos_sdk(self) -> None:
        self.sdk.rmdir()

        with self.assertRaisesRegex(PgsoError, "macOS SDK does not exist"):
            self.discover()

    def test_discover_rejects_a_missing_or_incompatible_native_linker(self) -> None:
        linker = self.system_bin / "ld"
        linker.unlink()
        with self.assertRaisesRegex(PgsoError, "missing executable: Apple linker"):
            self.discover()
        self.write_executable(linker, "printf '%s\\n' '{\"version\":\"1167.5\",\"architectures\":[\"x86_64\"]}'")
        with self.assertRaisesRegex(PgsoError, "does not support arm64"):
            self.discover()
        self.write_executable(linker, "printf 'malformed\\n'")
        with self.assertRaisesRegex(PgsoError, "invalid Apple linker version details"):
            self.discover()

    def test_discover_requires_the_pinned_zig_system_stub(self) -> None:
        (self.zig_sdk / "libSystem.tbd").unlink()
        with self.assertRaisesRegex(PgsoError, "missing Zig libSystem stub"):
            self.discover()

    def test_discover_rejects_unusable_zig_library_metadata(self) -> None:
        for env_text in (".{}", '.{\n.lib_dir = "relative",\n}', '.{\n.lib_dir = "a",\n.lib_dir = "b",\n}'):
            self.write_executable(self.zig, f"""if [ "$1" = version ]; then printf '0.16.0\\n'; else printf '%s' {shlex.quote(env_text)}; fi""")
            with self.subTest(env_text=env_text), self.assertRaises(PgsoError):
                self.discover()

    def test_discover_rejects_invalid_zig_sdk_settings(self) -> None:
        for text in ("invalid", "[]", '{"MinimalDisplayName":"unknown"}'):
            (self.zig_sdk / "SDKSettings.json").write_text(text)
            with self.subTest(text=text), self.assertRaises(PgsoError):
                self.discover()

    def test_discover_rejects_an_invalid_sdk_version(self) -> None:
        self.write_executable(
            self.system_bin / "xcrun",
            f"""if [ "$1" = --find ]; then printf '%s\\n' {shlex.quote(str(self.system_bin / 'ld'))}; exit 0; fi
case "$3" in
  --show-sdk-path) printf '%s\\n' {shlex.quote(str(self.sdk))} ;;
  --show-sdk-version) printf 'unknown-sdk\\n' ;;
  *) exit 2 ;;
esac""",
        )
        with self.assertRaisesRegex(PgsoError, "invalid macOS SDK version"):
            self.discover()


if __name__ == "__main__":
    unittest.main()
