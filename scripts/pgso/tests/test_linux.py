from __future__ import annotations

import json
import os
import pathlib
import tempfile
import types
import unittest
from unittest import mock

from scripts.pgso import linux, macos, platforms
from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import PipelinePaths
from scripts.pgso.runner import CommandResult

# `llvm-readelf --file-header --program-headers --wide` of a static musl fx
# control, trimmed to the lines the layout reads.
CONTROL_HEADERS = """ELF Header:
  Class:                             ELF64
  OS/ABI:                            UNIX - System V
  Type:                              EXEC (Executable file)
  Machine:                           AArch64

Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  PHDR           0x000040 0x0000000001000040 0x0000000001000040 0x0001c0 0x0001c0 R   0x8
  LOAD           0x000000 0x0000000001000000 0x0000000001000000 0x0ee670 0x0ee670 R   0x10000
  LOAD           0x0ee670 0x00000000010fe670 0x00000000010fe670 0x94a918 0x94a918 R E 0x10000
  LOAD           0xa38f88 0x0000000001a58f88 0x0000000001a58f88 0x000038 0x000078 RW  0x10000
  LOAD           0xa38fc0 0x0000000001a68fc0 0x0000000001a68fc0 0x006aa0 0x077f3f RW  0x10000
  TLS            0xa38f88 0x0000000001a48f88 0x0000000001a48f88 0x000000 0x04001c R   0x8
  GNU_RELRO      0xa38f88 0x0000000001a58f88 0x0000000001a58f88 0x000038 0x000078 R   0x1
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x1000000 RW  0x0
"""
CONTROL_SECTIONS = "  [ 1] .rodata PROGBITS\n  [ 2] .text PROGBITS\n"


class LinuxPlatformTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="fx-pgso-linux-")
        self.root = pathlib.Path(self.temporary_directory.name)
        self.paths = PipelinePaths.create(self.root / "run")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def toolchain(self) -> types.SimpleNamespace:
        return types.SimpleNamespace(
            zig=self.root / "zig",
            llvm_profdata=self.root / "llvm-profdata",
            profile_runtime=self.root / "libclang_rt.profile.a",
            tools=linux.Tools(ld_lld=self.root / "llvm" / "ld.lld", readelf=self.root / "llvm" / "llvm-readelf"),
            platform=linux.ARM64,
            target=linux.ARM64.TARGET,
        )

    def write_control_link(self, *, inputs: tuple[pathlib.Path, ...]) -> list[str]:
        for item in inputs:
            item.write_bytes(item.name.encode())
        argv = [
            "ld.lld", "--entry", "_start", "-z", "stack-size=16777216", "--gc-sections", "-s", "-static",
            str(inputs[0]), "/cache/fx_zcu.o", *map(str, inputs[1:]), "-o", "/cache/fx",
        ]
        result = CommandResult(
            argv=("zig", "build"),
            returncode=0,
            stdout="",
            stderr="ld.lld -r /cache/partial.o -o /cache/partial\n" + " ".join(argv) + "\n",
            elapsed_seconds=1.0,
        )
        with mock.patch.object(linux, "sha256_file", side_effect=lambda path: sha256_file(path) if path.exists() else "missing"):
            linux.record_control_build(self.toolchain(), result, self.paths)
        return argv

    def test_the_registry_selects_each_linux_architecture(self) -> None:
        self.assertIs(linux.ARM64, platforms.for_target("aarch64-linux"))
        self.assertIs(linux.X86_64, platforms.for_target("x86_64-linux"))
        self.assertEqual("Linux x86_64", linux.X86_64.DISPLAY_NAME)

    def test_only_x86_64_has_a_larger_size_ceiling(self) -> None:
        self.assertEqual(7.000, macos.SIZE_CEILING_MIB)
        self.assertEqual(7.000, linux.ARM64.SIZE_CEILING_MIB)
        self.assertEqual(8.000, linux.X86_64.SIZE_CEILING_MIB)

    def test_every_platform_provides_what_the_pipeline_reads(self) -> None:
        names = (
            "TARGET", "DISPLAY_NAME", "HOST_ARCH", "LIBLLVM_NAME", "SIZE_CEILING_MIB", "CONTROL_BUILD_FLAGS",
            "STARTUP_SCENARIOS", "ZIG_CC_LINK_FLAGS", "check_host", "discover_tools",
            "os_versions", "record_control_build", "external_control_strip_argv",
            "read_control_identity", "control_identity_from_evidence", "link_instrumented",
            "public_api_flags", "candidate_object_flags", "link_candidate_binary",
            "inspect_candidate", "candidate_evidence",
        )
        for platform in (macos, linux.ARM64, linux.X86_64):
            for name in names:
                with self.subTest(platform=platform.TARGET, name=name):
                    self.assertTrue(hasattr(platform, name))

    def test_zig_cc_links_for_the_toolchain_target(self) -> None:
        toolchain = self.toolchain()
        toolchain.target = linux.X86_64.TARGET
        argv = linux._zig_cc_argv(toolchain, (self.root / "a.o",), self.root / "out")
        self.assertEqual("x86_64-linux", argv[argv.index("-target") + 1])

    def test_elf_layout_reads_the_static_control_contract(self) -> None:
        layout = linux.parse_elf_layout(CONTROL_HEADERS, "", CONTROL_SECTIONS)

        self.assertEqual("ELF64", layout["class"])
        self.assertEqual("EXEC (Executable file)", layout["type"])
        self.assertEqual("AArch64", layout["machine"])
        self.assertEqual(
            ["PHDR", "LOAD", "LOAD", "LOAD", "LOAD", "TLS", "GNU_RELRO", "GNU_STACK"],
            layout["segment_types"],
        )
        self.assertEqual("0x0000000001000000", layout["first_load_vaddr"])
        self.assertEqual({"memsz": "0x1000000", "flags": "RW"}, layout["gnu_stack"])
        self.assertFalse(layout["has_interp"])
        self.assertFalse(layout["has_dynamic"])
        self.assertTrue(layout["has_tls"])
        self.assertFalse(layout["has_notes"])
        self.assertEqual([], layout["profile_sections"])

    def test_candidate_must_match_the_control_layout_without_profile_sections(self) -> None:
        control = {"elf_layout": linux.parse_elf_layout(CONTROL_HEADERS, "", CONTROL_SECTIONS)}
        same = dict(control["elf_layout"])
        with mock.patch.object(linux, "read_elf_layout", return_value=same):
            metadata = linux.inspect_candidate(self.toolchain(), self.paths, control)
        self.assertEqual({"elf_layout": same}, linux.candidate_evidence(metadata))

        for change, message in (
            ({"has_notes": True}, "differs from the control"),
            ({"gnu_stack": {"memsz": "0x20000", "flags": "RW"}}, "differs from the control"),
            ({"profile_sections": ["__llvm_prf_cnts"]}, "retains an LLVM profile section"),
        ):
            with self.subTest(change=change), mock.patch.object(
                linux, "read_elf_layout", return_value={**same, **change}
            ), self.assertRaisesRegex(PgsoError, message):
                linux.inspect_candidate(self.toolchain(), self.paths, control)

    def test_control_identity_round_trips_through_evidence(self) -> None:
        layout = linux.parse_elf_layout(CONTROL_HEADERS, "", CONTROL_SECTIONS)
        self.assertEqual({"elf_layout": layout}, linux.control_identity_from_evidence({"elf_layout": layout, "sha256": "x"}))
        with self.assertRaisesRegex(PgsoError, "ELF layout is invalid"):
            linux.control_identity_from_evidence({"minimum_macos": "15.0"})

    def test_control_build_records_its_final_link_and_input_hashes(self) -> None:
        crt1, libc = self.root / "crt1.o", self.root / "libc.a"
        argv = self.write_control_link(inputs=(crt1, libc))

        record = json.loads((self.paths.logs / "control-link.json").read_text())
        self.assertEqual(argv, record["argv"])
        self.assertEqual("/cache/fx_zcu.o", record["zig_object"])
        self.assertEqual({str(crt1): sha256_file(crt1), str(libc): sha256_file(libc)}, record["inputs"])

        for stderr, message in (
            ("ld.lld -r /cache/partial.o -o /cache/partial\n", "one final ld.lld link, found 0"),
            ("ld.lld /cache/fx_zcu.o -o a\nld.lld /cache/fx_zcu.o -o b\n", "found 2"),
            ("ld.lld /cache/x.o -o /cache/fx\n", "one Zig object"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(PgsoError, message):
                linux.record_control_build(
                    self.toolchain(),
                    CommandResult(("zig",), 0, "", stderr, 1.0),
                    self.paths,
                )

    def test_relink_swaps_only_the_zig_object_and_output(self) -> None:
        crt1, libc = self.root / "crt1.o", self.root / "libc.a"
        self.write_control_link(inputs=(crt1, libc))
        runtime = self.root / "libclang_rt.profile.a"

        argv = linux.relink_argv(
            self.toolchain(),
            self.paths,
            self.root / "instrumented.o",
            self.root / "instrumented",
            flags=("-u", "__llvm_profile_runtime"),
            inputs=(runtime,),
        )

        self.assertEqual(
            [
                str(self.root / "llvm" / "ld.lld"), "--entry", "_start", "-z", "stack-size=16777216",
                "--gc-sections", "-s", "-static", str(crt1), str(self.root / "instrumented.o"), str(runtime),
                str(libc), "-u", "__llvm_profile_runtime", "-o", str(self.root / "instrumented"),
            ],
            argv,
        )
        libc.write_bytes(b"rebuilt")
        with self.assertRaisesRegex(PgsoError, "control link input changed"):
            linux.relink_argv(self.toolchain(), self.paths, self.root / "o", self.root / "b")

    def test_function_symbols_keep_names_with_spaces_and_skip_undefined(self) -> None:
        text = (
            "Symbol table '.symtab' contains 5 entries:\n"
            "   Num:    Value          Size Type    Bind   Vis       Ndx Name\n"
            "     1: 0000000000000000    16 FUNC    GLOBAL DEFAULT     4 main\n"
            "     2: 0000000000000010    32 FUNC    LOCAL  DEFAULT     5 array_list.Aligned(u8, null).append\n"
            "     3: 0000000000000000     0 FUNC    GLOBAL DEFAULT   UND write\n"
            "     4: 0000000000000040     8 OBJECT  LOCAL  DEFAULT     6 table\n"
        )
        self.assertEqual(
            {"main": ("4", 0, 16), "array_list.Aligned(u8, null).append": ("5", 16, 32)},
            linux.parse_function_symbols(text),
        )
        clash = text + "     5: 0000000000000020    16 FUNC    GLOBAL DEFAULT     7 main\n"
        with self.assertRaisesRegex(PgsoError, "ambiguous candidate text symbol: main"):
            linux.parse_function_symbols(clash)

    def test_profile_order_keeps_one_name_per_function_body(self) -> None:
        functions = {"main": ("4", 0, 16), "alias": ("4", 0, 16), "helper": ("5", 0, 8)}

        ordered, mapping, seen = linux.order_symbols("# order\nmain\nalias\nmissing\nhelper\n", functions)

        self.assertEqual(["main", "helper"], ordered)
        self.assertEqual({"profile_functions": 4, "unmapped_profile_functions": 1}, mapping)
        self.assertEqual({("4", 0), ("5", 0)}, seen)

    def test_startup_functions_lead_the_link_order(self) -> None:
        functions = {"help": ("4", 0, 16), "main": ("4", 16, 8), "loop": ("5", 0, 8)}
        self.paths.startup_order.write_text("help\nmain\n", encoding="utf-8")
        profile_order = self.root / "profile.order"
        profile_order.write_text("# Ordered 2 functions\nloop\nmain\n", encoding="utf-8")

        ordered, _, _ = linux.order_symbols(linux.link_order_text(self.paths, profile_order), functions)

        self.assertEqual(["help", "main", "loop"], ordered)

    def test_the_link_order_requires_the_startup_order(self) -> None:
        profile_order = self.root / "profile.order"
        profile_order.write_text("loop\n", encoding="utf-8")

        with self.assertRaisesRegex(PgsoError, "startup function order"):
            linux.link_order_text(self.paths, profile_order)

    def test_outlined_helpers_follow_their_earliest_caller(self) -> None:
        ir = self.root / "profile-use.ll"
        ir.write_text(
            "define void @main() {\n  call void @outlined_ir_func_2()\n  ret void\n}\n"
            "define void @late() {\n  call void @outlined_ir_func_1()\n  call void @outlined_ir_func_2()\n  ret void\n}\n",
            encoding="utf-8",
        )
        functions = {
            "main": ("4", 0, 8), "late": ("5", 0, 8),
            "outlined_ir_func_1": ("6", 0, 4), "outlined_ir_func_2": ("7", 0, 4), "outlined_ir_func_9": ("8", 0, 4),
        }
        seen = {("4", 0), ("5", 0)}

        ordered, counts = linux.append_outlined_helpers(["main", "late"], functions, ir, seen)

        self.assertEqual(["main", "late", "outlined_ir_func_2", "outlined_ir_func_1", "outlined_ir_func_9"], ordered)
        self.assertEqual({"outlined_helpers": 3, "ranked_helpers": 2}, counts)

    def test_the_link_must_apply_the_order_or_explain_each_missing_symbol(self) -> None:
        obj = self.root / "fx.o"
        removed = linux.removed_sections(
            f"removing unused section {obj}:(.text.dead)\nremoving unused section /other.a:(.text.main)\n",
            obj,
        )
        self.assertEqual({".text.dead"}, removed)
        with self.assertRaisesRegex(PgsoError, "unexpected linker output"):
            linux.removed_sections("ld.lld: warning: something\n", obj)

        link_map = (
            "             VMA              LMA     Size Align Out     In      Symbol\n"
            "         10fe670          10fe670       10     4                 main\n"
            "         10fe680          10fe680       20     4                 fx.foo bar\n"
        )
        found = linux.map_addresses(link_map, ["main", "fx.foo bar", "dead"])
        self.assertEqual({"main": 0x10FE670, "fx.foo bar": 0x10FE680}, found)

        self.assertEqual(["dead"], linux.check_applied_order(["main", "dead", "fx.foo bar"], found, removed))
        with self.assertRaisesRegex(PgsoError, "not removed"):
            linux.check_applied_order(["main", "gone"], found, removed)
        with self.assertRaisesRegex(PgsoError, "did not apply the profile function order"):
            linux.check_applied_order(["fx.foo bar", "main"], found, removed)

    def test_public_api_keeps_every_symbol_the_seed_defines(self) -> None:
        with mock.patch.object(
            linux,
            "_defined_external_symbols",
            return_value=(("main", "T"), ("memcpy", "W"), ("strlen", "W")),
        ):
            flags = linux.public_api_flags(self.toolchain(), self.paths)

        api = self.paths.logs / "public-api.txt"
        self.assertEqual((f"-internalize-public-api-file={api}",), flags)
        self.assertEqual("main\nmemcpy\nstrlen\n", api.read_text())

    def test_only_fx_objects_get_function_sections(self) -> None:
        self.assertEqual(("-function-sections",), linux.candidate_object_flags(self.paths))
        benchmark = PipelinePaths.create(self.root / "bench", selector="ui_activity")
        self.assertEqual((), linux.candidate_object_flags(benchmark))

    def test_discover_tools_reads_lld_readelf_and_the_profile_runtime_from_one_root(self) -> None:
        root = self.root / "llvm" / "bin"
        root.mkdir(parents=True)
        resource = self.root / "llvm" / "lib" / "clang" / "22"
        runtime = resource / "lib" / linux.ARM64.PROFILE_RUNTIME_TRIPLE / "libclang_rt.profile.a"
        runtime.parent.mkdir(parents=True)
        runtime.write_bytes(b"archive")
        # As in the LLVM release, ld.lld is a link to lld.
        (root / "lld").write_text("#!/bin/sh\n")
        (root / "lld").chmod(0o755)
        (root / "ld.lld").symlink_to("lld")
        (root / "llvm-readelf").write_text("#!/bin/sh\n")
        (root / "llvm-readelf").chmod(0o755)
        clang = root / "clang"
        clang.write_text(f"#!/bin/sh\necho {resource}\n")
        clang.chmod(0o755)

        tools, found = linux.ARM64.discover_tools(self.root / "zig", clang)

        resolved_root = root.resolve()
        self.assertEqual(
            linux.Tools(ld_lld=resolved_root / "ld.lld", readelf=resolved_root / "llvm-readelf"),
            tools,
        )
        self.assertEqual("ld.lld", tools.ld_lld.name)
        self.assertEqual(runtime.resolve(), found)
        # Each architecture reads only its own runtime.
        with self.assertRaisesRegex(PgsoError, "x86_64-unknown-linux-gnu"):
            linux.X86_64.discover_tools(self.root / "zig", clang)
        x86_runtime = resource / "lib" / linux.X86_64.PROFILE_RUNTIME_TRIPLE / "libclang_rt.profile.a"
        x86_runtime.parent.mkdir(parents=True)
        x86_runtime.write_bytes(b"archive")
        self.assertEqual(x86_runtime.resolve(), linux.X86_64.discover_tools(self.root / "zig", clang)[1])
        (root / "llvm-readelf").unlink()
        with self.assertRaisesRegex(PgsoError, "missing executable: llvm-readelf"):
            linux.ARM64.discover_tools(self.root / "zig", clang)

    def test_host_must_be_native_linux_of_the_same_architecture(self) -> None:
        for platform, other in ((linux.ARM64, "x86_64"), (linux.X86_64, "aarch64")):
            with self.subTest(target=platform.TARGET):
                with mock.patch("platform.system", return_value="Linux"), mock.patch(
                    "platform.machine", return_value=platform.HOST_ARCH
                ):
                    self.assertEqual(platform.HOST_ARCH, platform.check_host())
                with mock.patch("platform.system", return_value="Darwin"), self.assertRaisesRegex(
                    PgsoError, "requires a Linux host"
                ):
                    platform.check_host()
                with mock.patch("platform.system", return_value="Linux"), mock.patch(
                    "platform.machine", return_value=other
                ), self.assertRaisesRegex(PgsoError, f"requires an {platform.HOST_ARCH} host, not {other}"):
                    platform.check_host()


if __name__ == "__main__":
    unittest.main()
