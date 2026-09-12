from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import tempfile
import unittest

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import (
    BENCHMARK_USE_FLAGS,
    FX_MACHINE_OUTLINER_FLAGS,
    GENERATION_FLAGS,
    PROFILE_SECTION_ALIGNMENTS,
    USE_FLAGS,
    ArtifactSpec,
    CandidateMetadata,
    MacosLinkContract,
    PipelinePaths,
    apply_profile,
    candidate_object_argv,
    candidate_link_argv,
    candidate_runtime_probe_argv,
    temporal_candidate_link_argv,
    map_temporal_symbols,
    parse_macos_link_contract,
    validate_temporal_link_map,
    instrumentation_argv,
    instrumented_run_argv,
    instrumented_link_argv,
    link_candidate,
    merge_profile_batch,
    parse_compiler_runtime,
    profile_use_argv,
    reject_profile_outputs,
    validate_archive_unchanged,
    validate_bitcode_hash,
    validate_candidate_metadata,
    validate_candidate_size,
    validate_profile_section_alignment,
    verify_release_safe_ir,
    zig_build_argv,
)
from scripts.pgso.toolchain import Toolchain


class PgsoPipelineTests(unittest.TestCase):
    def test_temporal_order_binds_real_text_symbols_and_accounts_for_unmapped_names(self) -> None:
        ordered, evidence = map_temporal_symbols(
            "# Ordered 4 functions\n# fx\nalpha\nbeta\nalias\nmissing\n",
            "_alpha T 0 0\nl_beta t 8 0\nl_alias t 8 0\n_missing d 20 0\n",
        )
        self.assertEqual(("_alpha", "l_beta"), ordered)
        self.assertEqual(4, evidence["profile_functions"])
        self.assertEqual(3, len(evidence["bindings"]))
        self.assertEqual(["missing"], evidence["unmapped_symbols"])

    def test_temporal_order_preserves_symbol_names_with_spaces(self) -> None:
        ordered, _ = map_temporal_symbols("# Ordered 1 functions\nname with spaces\n", "l_name with spaces t 0 0\n")
        self.assertEqual(("l_name with spaces",), ordered)

    def test_temporal_order_rejects_ambiguous_empty_or_malformed_input(self) -> None:
        for order, symbols in (
            ("# Ordered 1 functions\nalpha\n", "_alpha T 0 0\nl_alpha t 8 0\n"),
            ("# Ordered 1 functions\nalpha\n", "_alpha T 0 0\n_alpha T 8 0\n"),
            ("# Ordered 1 functions\nmissing\n", "_alpha T 0 0\n"),
            ("# Ordered 2 functions\nalpha\n", "_alpha T 0 0\n"),
            ("# Ordered 2 functions\nalpha\nalpha\n", "_alpha T 0 0\n"),
            ("# Ordered 0 functions\n", "_alpha T 0 0\n"),
            ("# Ordered 1 functions\nalpha\n", "[truncated output]\n"),
        ):
            with self.subTest(order=order, symbols=symbols), self.assertRaises(PgsoError):
                map_temporal_symbols(order, symbols)

    def test_link_map_proves_applied_order_in_the_original_object(self) -> None:
        link_map = (
            f"# Object files:\n[ 1] {self.paths.profile_use_object}\n[ 2] /runtime.o\n"
            "# Sections:\n0x1000 0x18 __TEXT __text\n0x2000 0x10 __TEXT __const\n"
            "# Symbols:\n0x1000 0x8 [ 1] _alpha\n0x1000 0x0 [ 1] l_alias\n"
            "0x1008 0x10 [ 1] l_beta\n0x10 0x100 [ 2] l_beta\n"
            "0x2000 0x8 [ 1] 8-byte-literal\n0x2008 0x8 [ 1] 8-byte-literal\n"
            "# Dead Stripped Symbols:\n<<dead>> 0x8 [ 1] l_removed\n"
        )
        self.assertEqual(
            {"ordered_sections": 2, "ordered_bytes": 24, "linker_removed_symbols": ["l_removed"]},
            validate_temporal_link_map(link_map, self.paths.profile_use_object, ("l_alias", "l_beta", "l_removed")),
        )
        for names in (("l_beta", "_alpha"), ("unknown",), ("l_alias", "_alpha")):
            with self.subTest(names=names), self.assertRaises(PgsoError):
                validate_temporal_link_map(link_map, self.paths.profile_use_object, names)
        with self.assertRaises(PgsoError):
            validate_temporal_link_map(link_map, self.root / "other.o", ("_alpha",))

    def test_temporal_link_preserves_the_control_platform_and_original_object(self) -> None:
        runtime = self.root / "libcompiler_rt_zcu.o"
        contract = MacosLinkContract(1, "13.3", "26.4", 16 * 1024 * 1024, ())
        toolchain = dataclasses.replace(self.toolchain, sdk_version="15.5")
        command = temporal_candidate_link_argv(toolchain, self.paths, runtime, contract)
        self.assertEqual(str(self.toolchain.apple_ld), command[0])
        platform = command.index("-platform_version")
        self.assertEqual(("macos", "13.3", "26.4"), command[platform + 1:platform + 4])
        self.assertIn(str(self.paths.profile_use_object), command)
        self.assertIn(str(runtime), command)
        self.assertNotIn(str(self.paths.instrumented_object), command)
        self.assertNotIn(str(self.toolchain.profile_runtime), command)
        self.assertEqual("1000000", command[command.index("-stack_size") + 1])
        self.assertIn(str(toolchain.zig_darwin_sdk / "libSystem.tbd"), command)
        self.assertIn(str(self.paths.logs / "candidate-order.txt"), command)
        for flag in ("-order_file", "-no_deduplicate", "-no_function_starts", "-map"):
            self.assertIn(flag, command)
        original = candidate_link_argv(self.toolchain, self.paths)
        probe = candidate_runtime_probe_argv(self.toolchain, self.paths)
        self.assertEqual(original, tuple(arg for arg in probe if arg != "-###"))
        self.assertEqual(1, probe.count("-###"))
        self.assertIn("-O2", probe)
        self.assertIn("-s", probe)

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="fx-pgso-pipeline-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        self.paths = PipelinePaths.create(self.root / "run")
        self.toolchain = self.make_toolchain()
        self.spec = ArtifactSpec(repo_root=self.root / "repo")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_open_reconstructs_an_existing_artifact_layout(self) -> None:
        marker = self.paths.bitcode
        marker.write_bytes(b"bitcode")

        reopened = PipelinePaths.open(self.paths.root)

        self.assertEqual(self.paths, reopened)
        self.assertEqual(b"bitcode", reopened.bitcode.read_bytes())

    def make_toolchain(self, **changes: pathlib.Path) -> Toolchain:
        tool_root = self.root / "tools"
        tool_root.mkdir(exist_ok=True)
        defaults = {
            "zig": tool_root / "zig",
            "llvm_bin": tool_root,
            "opt": tool_root / "opt",
            "llc": tool_root / "llc",
            "llvm_profdata": tool_root / "llvm-profdata",
            "llvm_ar": tool_root / "llvm-ar",
            "llvm_nm": tool_root / "llvm-nm",
            "clang": tool_root / "clang",
            "apple_ld": tool_root / "ld",
            "apple_ld_version": "1167.5",
            "strip": tool_root / "strip",
            "codesign": tool_root / "codesign",
            "otool": tool_root / "otool",
            "xcrun": tool_root / "xcrun",
            "sdk": self.root / "MacOSX.sdk",
            "sdk_version": "26.4",
            "zig_darwin_sdk": self.root / "ZigDarwin.sdk",
            "zig_sdk_version": "26.4",
            "profile_runtime": self.root / "libclang_rt.profile_osx.a",
            "zig_version": "0.16.0",
            "llvm_version": "21.1.8",
            "target": "aarch64-macos",
            "host_arch": "arm64",
        }
        defaults.update(changes)
        return Toolchain(**defaults)

    def write_executable(self, name: str, body: str) -> pathlib.Path:
        path = self.root / name
        path.write_text(f"#!/usr/bin/python3\n{body}\n")
        path.chmod(0o755)
        return path

    def test_profile_pipelines_use_the_exact_accepted_flags(self) -> None:
        self.assertEqual(
            (
                "--disable-vp",
                "--runtime-counter-relocation",
                "--pgo-temporal-instrumentation",
                "-pgo-kind=pgo-instr-gen-pipeline",
                "-passes=default<O2>",
            ),
            GENERATION_FLAGS,
        )
        self.assertEqual(
            (
                "--disable-vp",
                "-pgo-kind=pgo-instr-use-pipeline",
                "-pgo-cold-func-opt=minsize",
                "-profile-summary-cutoff-cold=600000",
                "-passes=default<O2>,mergefunc,iroutliner",
            ),
            USE_FLAGS,
        )
        self.assertEqual(
            (
                "--disable-vp",
                "-pgo-kind=pgo-instr-use-pipeline",
                "-pgo-cold-func-opt=minsize",
                "-profile-summary-cutoff-cold=990000",
                "-passes=default<O2>,mergefunc,iroutliner",
            ),
            BENCHMARK_USE_FLAGS,
        )
        self.assertEqual(
            (
                "-machine-outliner-reruns=1",
            ),
            FX_MACHINE_OUTLINER_FLAGS,
        )
        self.assertEqual(
            (
                str(self.toolchain.opt),
                *GENERATION_FLAGS,
                f"-profile-file={self.paths.raw_profile_pattern}",
                str(self.paths.bitcode),
                "-o",
                str(self.paths.instrumented_bitcode),
            ),
            instrumentation_argv(self.toolchain, self.paths),
        )
        self.assertEqual(
            (
                str(self.toolchain.opt),
                *USE_FLAGS,
                f"-profile-file={self.paths.merged_profile}",
                str(self.paths.bitcode),
                "-o",
                str(self.paths.profile_use_bitcode),
            ),
            profile_use_argv(self.toolchain, self.paths),
        )
        benchmark_paths = PipelinePaths.create(
            self.root / "benchmark-run",
            selector="ui_activity",
        )
        self.assertEqual(
            (
                str(self.toolchain.opt),
                *BENCHMARK_USE_FLAGS,
                f"-profile-file={benchmark_paths.merged_profile}",
                str(benchmark_paths.bitcode),
                "-o",
                str(benchmark_paths.profile_use_bitcode),
            ),
            profile_use_argv(self.toolchain, benchmark_paths),
        )
        mapped_profile = self.paths.profiles / "production.profdata"
        self.assertEqual(
            f"-profile-file={mapped_profile}",
            profile_use_argv(
                self.toolchain,
                self.paths,
                mapped_profile,
            )[len(USE_FLAGS) + 1],
        )
        self.assertEqual(
            (str(self.paths.instrumented_binary), "help"),
            instrumented_run_argv(self.paths, ("help",)),
        )
        self.assertEqual(
            (str(self.paths.instrumented_binary),),
            instrumented_run_argv(self.paths, ()),
        )

    def test_zig_build_arguments_pin_release_safe_target_and_caches(self) -> None:
        control = zig_build_argv(
            self.toolchain,
            self.spec,
            self.paths,
            emit_ir=False,
        )
        ir = zig_build_argv(
            self.toolchain,
            self.spec,
            self.paths,
            emit_ir=True,
        )

        self.assertEqual((str(self.toolchain.zig), "build"), control[:2])
        self.assertNotIn("pgso-ir", control)
        self.assertIn("-Dtarget=aarch64-macos", control)
        self.assertIn("-Doptimize=ReleaseSafe", control)
        self.assertIn("-Dupdate-channel=stable", control)
        self.assertIn("pgso-ir", ir)
        self.assertIn("-Dpgso-artifact=fx", ir)
        self.assertNotEqual(
            control[control.index("--cache-dir") + 1],
            ir[ir.index("--cache-dir") + 1],
        )

    def test_benchmark_artifacts_use_their_existing_build_owners_and_names(self) -> None:
        cases = (
            ("file_index", "bench-file-index", "file-index-bench", "file-index.bc"),
            (
                "ui_activity",
                "bench-ui-activity",
                "ui-activity-progress-bench",
                "ui-activity.bc",
            ),
            (
                "approval_review",
                "bench-approval-review",
                "approval-review-bench",
                "approval-review.bc",
            ),
        )
        for selector, build_step, binary_name, bitcode_name in cases:
            with self.subTest(selector=selector):
                spec = ArtifactSpec(repo_root=self.root / "repo", selector=selector)
                paths = PipelinePaths.create(
                    self.root / f"run-{selector}",
                    selector=selector,
                )
                control = zig_build_argv(
                    self.toolchain,
                    spec,
                    paths,
                    emit_ir=False,
                )
                ir = zig_build_argv(
                    self.toolchain,
                    spec,
                    paths,
                    emit_ir=True,
                )

                self.assertIn(build_step, control)
                self.assertIn(f"-Dpgso-artifact={selector}", ir)
                self.assertEqual(binary_name, paths.control_binary.name)
                self.assertEqual(bitcode_name, paths.bitcode.name)
                self.assertEqual(binary_name, paths.candidate_binary.name)

    def test_link_arguments_preserve_alignment_and_candidate_contract(self) -> None:
        compiler_runtime_object = self.root / "libcompiler_rt_zcu.o"
        instrumented = instrumented_link_argv(
            self.toolchain,
            self.paths,
            compiler_runtime_object,
            "13.0",
        )
        candidate = candidate_link_argv(self.toolchain, self.paths)
        candidate_object = candidate_object_argv(self.toolchain, self.paths)
        benchmark_paths = PipelinePaths.create(
            self.root / "benchmark-run",
            selector="file_index",
        )
        benchmark_object = candidate_object_argv(self.toolchain, benchmark_paths)

        for alignment in PROFILE_SECTION_ALIGNMENTS:
            self.assertIn(alignment, instrumented)
        self.assertIn("-mmacosx-version-min=13.0", instrumented)
        self.assertIn(str(self.toolchain.sdk), instrumented)
        self.assertIn(str(self.toolchain.profile_runtime), instrumented)
        self.assertEqual(
            (
                str(self.toolchain.zig),
                "cc",
                "-target",
                "aarch64-macos",
                "-O2",
                "-Wl,-dead_strip",
                "-s",
                str(self.paths.profile_use_object),
                "-o",
                str(self.paths.candidate_binary),
                "-lc",
            ),
            candidate,
        )
        for flag in FX_MACHINE_OUTLINER_FLAGS:
            self.assertIn(flag, candidate_object)
            self.assertNotIn(flag, benchmark_object)

    def test_candidate_object_and_signing_contract(self) -> None:
        actions = self.root / "candidate-actions.txt"
        runtime = self.root / "libcompiler_rt.a"
        runtime.write_bytes(b"compiler runtime")
        self.toolchain.zig_darwin_sdk.mkdir()
        (self.toolchain.zig_darwin_sdk / "libSystem.tbd").write_bytes(b"system stub")
        (self.paths.compiler_runtime / "instrumented.o").write_bytes(b"instrumented runtime")
        self.paths.merged_profile.write_bytes(b"temporal profile")
        self.paths.control_binary.parent.mkdir(parents=True)
        self.paths.control_binary.write_bytes(b"control")
        artifact_tool = self.write_executable(
            "artifact-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('artifact ' + ' '.join(sys.argv[1:]) + '\\n')
output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(b'artifact')""",
        )
        strip = self.write_executable(
            "strip-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('strip ' + ' '.join(sys.argv[1:]) + '\\n')""",
        )
        codesign = self.write_executable(
            "codesign-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('codesign ' + ' '.join(sys.argv[1:]) + '\\n')""",
        )
        zig = self.write_executable(
            "zig-probe",
            f"""import pathlib,sys
assert '-###' in sys.argv and '-O2' in sys.argv and '-s' in sys.argv
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('probe ' + ' '.join(sys.argv[1:]) + '\\n')
print('zig ld -platform_version macos 13.0.0 26.4 {runtime}')""",
        )
        otool = self.write_executable("otool", f"print({self.good_candidate_metadata().load_commands!r})")
        ar = self.write_executable(
            "ar-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('ar ' + ' '.join(sys.argv[1:]) + '\\n')
if sys.argv[1] == 't': print('libcompiler_rt_zcu.o')
elif sys.argv[1] == 'x': pathlib.Path('libcompiler_rt_zcu.o').write_bytes(b'optimized runtime object')
else: sys.exit(2)""",
        )
        profiler = self.write_executable(
            "profile-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('order ' + ' '.join(sys.argv[1:]) + '\\n')
pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_text('# Ordered 1 functions\\n# fx\\nalpha\\n')""",
        )
        nm = self.write_executable(
            "nm-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('symbols ' + ' '.join(sys.argv[1:]) + '\\n')
print('_alpha T 0 0')""",
        )
        link_map = f"# Object files:\n[ 1] {self.paths.profile_use_object}\n# Sections:\n0x1000 0x8 __TEXT __text\n# Symbols:\n0x1000 0x8 [ 1] _alpha\n"
        linker = self.write_executable(
            "ld-tool",
            f"""import pathlib,sys
with pathlib.Path({str(actions)!r}).open('a') as stream:
    stream.write('link ' + ' '.join(sys.argv[1:]) + '\\n')
pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(b'artifact')
pathlib.Path(sys.argv[sys.argv.index('-map') + 1]).write_bytes({link_map!r}.encode() + b'\\x89 literal data\\n')""",
        )
        toolchain = dataclasses.replace(
            self.toolchain,
            zig=zig,
            otool=otool,
            apple_ld=linker,
            llvm_ar=ar,
            llvm_profdata=profiler,
            llvm_nm=nm,
            sdk_version="15.5",
            opt=artifact_tool,
            llc=artifact_tool,
            strip=strip,
            codesign=codesign,
        )
        self.paths.profile_use_bitcode.write_bytes(b'profile-use bitcode')

        link_candidate(
            toolchain,
            self.paths,
            require_release_safe_evidence=False,
        )

        self.assertEqual(
            [
                "artifact -S "
                f"{self.paths.profile_use_bitcode} -o "
                f"{self.paths.profile_use_ir}",
                "artifact -filetype=obj -O=2 "
                "-machine-outliner-reruns=1 "
                f"{self.paths.profile_use_bitcode} -o "
                f"{self.paths.profile_use_object}",
                "probe cc -### -target aarch64-macos -O2 -Wl,-dead_strip -s "
                f"{self.paths.profile_use_object} -o "
                f"{self.paths.candidate_binary} -lc",
                f"ar t {runtime}",
                f"ar x {runtime}",
                f"order order {self.paths.merged_profile} -o {self.paths.logs / 'candidate-profile.order'}",
                f"symbols --defined-only --format=posix --radix=x {self.paths.profile_use_object}",
                "link " + " ".join(temporal_candidate_link_argv(
                    toolchain, self.paths,
                    self.paths.candidate_binary.parent / "compiler-runtime" / "libcompiler_rt_zcu.o",
                    self.good_link_contract(),
                )[1:]),
                f"strip -S -x {self.paths.candidate_binary}",
                "codesign --force --sign - --options linker-signed "
                f"--pagesize 16384 {self.paths.candidate_binary}",
            ],
            actions.read_text().splitlines(),
        )
        self.assertEqual(b"compiler runtime", runtime.read_bytes())
        self.assertEqual(b"instrumented runtime", (self.paths.compiler_runtime / "instrumented.o").read_bytes())
        layout = json.loads((self.paths.logs / "candidate-layout.json").read_text())
        self.assertEqual("26.4", layout["sdk_version"])
        self.assertEqual("15.5", layout["sysroot_sdk_version"])
        self.assertEqual(16777216, layout["main_stack_size"])
        self.assertEqual(8, layout["ordered_bytes"])
        self.assertIn(
            sha256_file(runtime),
            (self.paths.logs / "candidate-layout.json").read_text(),
        )

    def test_benchmark_candidate_keeps_the_zig_linker(self) -> None:
        paths = PipelinePaths.create(self.root / "benchmark-link", selector="ui_activity")
        artifact = self.write_executable(
            "benchmark-tool",
            """import pathlib,sys
pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(b'artifact')""",
        )
        noop = self.write_executable("noop", "pass")
        toolchain = dataclasses.replace(
            self.toolchain, zig=artifact, opt=artifact, llc=artifact,
            strip=noop, codesign=noop,
        )
        paths.profile_use_bitcode.write_bytes(b'bitcode')
        self.assertEqual(paths.candidate_binary, link_candidate(
            toolchain, paths, require_release_safe_evidence=False,
        ))
        self.assertFalse((paths.logs / "candidate-runtime-probe.json").exists())
        self.assertFalse((paths.logs / "candidate-layout.json").exists())

    def test_bitcode_hash_must_match_the_original(self) -> None:
        bitcode = self.root / "fx.bc"
        bitcode.write_bytes(b"release-safe bitcode")

        validate_bitcode_hash(bitcode, sha256_file(bitcode))
        with self.assertRaisesRegex(PgsoError, "bitcode identity mismatch"):
            validate_bitcode_hash(bitcode, "0" * 64)

    def test_merge_rejects_an_empty_raw_profile_batch(self) -> None:
        with self.assertRaisesRegex(PgsoError, "raw profile batch is empty"):
            merge_profile_batch(
                self.toolchain,
                (),
                self.paths.merged_profile,
                self.paths.logs / "merge.json",
            )

    def test_merge_is_atomic_and_rejects_profdata_warnings(self) -> None:
        profdata = self.write_executable(
            "warning-profdata",
            """import pathlib,sys
output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
output.write_bytes(b'new profile')
sys.stderr.write('profile warning')""",
        )
        toolchain = dataclasses.replace(self.toolchain, llvm_profdata=profdata)
        raw = self.paths.raw_profiles / "one.profraw"
        raw.write_bytes(b"raw")
        self.paths.merged_profile.write_bytes(b"previous profile")

        with self.assertRaisesRegex(PgsoError, "wrote unexpected stderr"):
            merge_profile_batch(
                toolchain,
                (raw,),
                self.paths.merged_profile,
                self.paths.logs / "merge-warning.json",
            )

        self.assertEqual(b"previous profile", self.paths.merged_profile.read_bytes())
        self.assertTrue(raw.exists())

    def test_merge_replaces_the_accumulator_then_deletes_merged_raw_files(self) -> None:
        profdata = self.write_executable(
            "clean-profdata",
            """import pathlib,sys
output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
output.write_bytes(b'merged profile')""",
        )
        toolchain = dataclasses.replace(self.toolchain, llvm_profdata=profdata)
        raw_profiles = (
            self.paths.raw_profiles / "one.profraw",
            self.paths.raw_profiles / "two.profraw",
        )
        for raw in raw_profiles:
            raw.write_bytes(b"raw")

        count = merge_profile_batch(
            toolchain,
            raw_profiles,
            self.paths.merged_profile,
            self.paths.logs / "merge-clean.json",
        )

        self.assertEqual(2, count)
        self.assertEqual(b"merged profile", self.paths.merged_profile.read_bytes())
        self.assertFalse(any(raw.exists() for raw in raw_profiles))

    def test_profile_use_rejects_hash_drift_before_running_opt(self) -> None:
        self.paths.bitcode.write_bytes(b"changed bitcode")
        self.paths.merged_profile.write_bytes(b"profile")

        with self.assertRaisesRegex(PgsoError, "bitcode identity mismatch"):
            apply_profile(
                self.toolchain,
                self.paths,
                "0" * 64,
            )

    def test_profile_use_rejects_optimizer_warnings(self) -> None:
        opt = self.write_executable(
            "warning-opt",
            """import pathlib,sys
output = pathlib.Path(sys.argv[sys.argv.index('-o') + 1])
output.write_bytes(b'profile-use bitcode')
sys.stderr.write('optimizer warning')""",
        )
        toolchain = dataclasses.replace(self.toolchain, opt=opt)
        self.paths.bitcode.write_bytes(b"same bitcode")
        self.paths.merged_profile.write_bytes(b"profile")

        with self.assertRaisesRegex(PgsoError, "wrote unexpected stderr"):
            apply_profile(
                toolchain,
                self.paths,
                sha256_file(self.paths.bitcode),
            )

    def test_compiler_runtime_probe_requires_one_absolute_archive(self) -> None:
        archive = self.root / "libcompiler_rt.a"

        self.assertEqual(
            archive,
            parse_compiler_runtime(f"zig ld {archive}"),
        )
        for output in (
            "zig ld without a runtime",
            f"zig ld {archive} /other/libcompiler_rt.a",
            "zig ld relative/libcompiler_rt.a",
        ):
            with self.subTest(output=output):
                with self.assertRaisesRegex(PgsoError, "exactly one absolute"):
                    parse_compiler_runtime(output)

    def test_compiler_runtime_probe_allows_cold_cache_archive_commands(self) -> None:
        archive = self.root / "libcompiler_rt.a"

        self.assertEqual(
            archive,
            parse_compiler_runtime(
                "zig ar /tmp/libubsan_rt_zcu.o\n"
                f"zig ld /tmp/input.o {archive}"
            ),
        )

    def test_compiler_runtime_probe_rejects_mixed_warning_output(self) -> None:
        archive = self.root / "libcompiler_rt.a"

        with self.assertRaisesRegex(
            PgsoError,
            "unexpected compiler runtime probe output",
        ):
            parse_compiler_runtime(
                f"warning: mixed toolchain output\nzig ld {archive}"
            )

    def test_compiler_runtime_archive_must_not_change_during_extraction(self) -> None:
        archive = self.root / "libcompiler_rt.a"
        archive.write_bytes(b"original")
        original_hash = sha256_file(archive)

        validate_archive_unchanged(archive, original_hash)
        archive.write_bytes(b"mutated")
        with self.assertRaisesRegex(PgsoError, "compiler runtime archive changed"):
            validate_archive_unchanged(archive, original_hash)

    def test_release_safe_ir_requires_overflow_and_all_panic_evidence(self) -> None:
        markers = (
            "@llvm.uadd.with.overflow.i64",
            "integer overflow",
            "index out of bounds: index ",
            "attempt to unwrap error: ",
            "attempt to use null value",
            "reached unreachable code",
        )
        ir = self.root / "candidate.ll"
        ir.write_text("\n".join(markers))
        verify_release_safe_ir(ir)

        for missing in markers:
            with self.subTest(missing=missing):
                ir.write_text("\n".join(marker for marker in markers if marker != missing))
                with self.assertRaisesRegex(PgsoError, "ReleaseSafe evidence missing"):
                    verify_release_safe_ir(ir)

    def test_instrumented_profile_sections_require_16_kib_alignment(self) -> None:
        good = "\n".join(
            f"sectname {name}\nsegname __DATA\nalign 2^14 (16384)"
            for name in ("__llvm_prf_cnts", "__llvm_prf_data", "__llvm_prf_bits")
        )
        validate_profile_section_alignment(good)

        with self.assertRaisesRegex(PgsoError, "profile section alignment"):
            validate_profile_section_alignment(good.replace("2^14", "2^3", 1))

    def good_candidate_metadata(self) -> CandidateMetadata:
        return CandidateMetadata(
            signature_valid=True,
            architecture="arm64",
            min_macos="13.0",
            load_commands=(
                "Load command 0\ncmd LC_BUILD_VERSION\nplatform 1\nminos 13.0\nsdk 26.4\n"
                "Load command 1\ncmd LC_MAIN\nentryoff 1736\nstacksize 16777216\n"
                "Load command 2\ncmd LC_LOAD_DYLIB\nname /usr/lib/libSystem.B.dylib (offset 24)\n"
                "current version 1356.0.0\ncompatibility version 1.0.0\n"
            ),
            dependencies="fx:\n/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)",
        )

    def good_link_contract(self) -> MacosLinkContract:
        return parse_macos_link_contract(self.good_candidate_metadata().load_commands)

    def test_candidate_metadata_accepts_the_complete_control_contract(self) -> None:
        validate_candidate_metadata(self.good_candidate_metadata(), expected_minos="13.0", expected_contract=self.good_link_contract())

    def test_link_contract_rejects_missing_or_duplicate_commands(self) -> None:
        commands = self.good_candidate_metadata().load_commands
        for invalid in (
            commands.replace("sdk 26.4\n", ""),
            commands.replace("platform 1", "platform 2"),
            commands.replace("stacksize 16777216", "stacksize -1"),
            commands.replace("stacksize 16777216", f"stacksize {1 << 64}"),
            commands + "Load command 3\ncmd LC_MAIN\nentryoff 1736\nstacksize 16777216\n",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(PgsoError):
                parse_macos_link_contract(invalid)

    def test_candidate_metadata_rejects_library_version_drift(self) -> None:
        metadata = self.good_candidate_metadata()
        with self.assertRaisesRegex(PgsoError, "library dependencies"):
            validate_candidate_metadata(
                dataclasses.replace(metadata, load_commands=metadata.load_commands.replace("1356.0.0", "1351.0.0")),
                expected_minos="13.0", expected_contract=self.good_link_contract(),
            )

    def test_candidate_metadata_rejects_sdk_compatibility_drift(self) -> None:
        metadata = self.good_candidate_metadata()
        with self.assertRaisesRegex(PgsoError, "SDK"):
            validate_candidate_metadata(
                dataclasses.replace(metadata, load_commands=metadata.load_commands.replace("sdk 26.4", "sdk 15.5")),
                expected_minos="13.0",
                expected_contract=self.good_link_contract(),
            )

    def test_candidate_metadata_rejects_lost_main_stack_request(self) -> None:
        metadata = self.good_candidate_metadata()
        with self.assertRaisesRegex(PgsoError, "stack"):
            validate_candidate_metadata(
                dataclasses.replace(metadata, load_commands=metadata.load_commands.replace("stacksize 16777216", "stacksize 0")),
                expected_minos="13.0",
                expected_contract=self.good_link_contract(),
            )

    def test_candidate_metadata_rejects_missing_signature(self) -> None:
        with self.assertRaisesRegex(PgsoError, "code signature"):
            validate_candidate_metadata(
                dataclasses.replace(
                    self.good_candidate_metadata(),
                    signature_valid=False,
                ),
                expected_minos="13.0",
                expected_contract=self.good_link_contract(),
            )

    def test_candidate_metadata_rejects_wrong_architecture_or_minos(self) -> None:
        cases = (
            ("architecture", "x86_64", "architecture"),
            ("min_macos", "14.0", "minimum macOS version"),
        )
        for field, value, message in cases:
            with self.subTest(field=field):
                with self.assertRaisesRegex(PgsoError, message):
                    validate_candidate_metadata(
                        dataclasses.replace(
                            self.good_candidate_metadata(),
                            **{field: value},
                        ),
                        expected_minos="13.0",
                        expected_contract=self.good_link_contract(),
                    )

    def test_candidate_metadata_rejects_profile_runtime_or_sections(self) -> None:
        cases = (
            (
                "dependencies",
                "/tmp/libclang_rt.profile_osx.dylib",
                "profile runtime dependency",
            ),
            (
                "load_commands",
                "sectname __llvm_prf_cnts",
                "profile section",
            ),
        )
        for field, value, message in cases:
            with self.subTest(field=field):
                with self.assertRaisesRegex(PgsoError, message):
                    validate_candidate_metadata(
                        dataclasses.replace(
                            self.good_candidate_metadata(),
                            **{field: value},
                        ),
                        expected_minos="13.0",
                        expected_contract=self.good_link_contract(),
                    )

    def test_candidate_size_rejects_more_than_7_800_mib(self) -> None:
        candidate = self.root / "candidate"
        candidate.write_bytes(b"")
        with candidate.open("r+b") as stream:
            stream.truncate(8_178_893)

        with self.assertRaisesRegex(PgsoError, "exceeds 7.800 MiB"):
            validate_candidate_size(candidate)

    def test_candidate_must_not_create_an_adversarial_profile_file(self) -> None:
        before: set[pathlib.Path] = set()
        generated = self.root / "candidate-123.profraw"

        reject_profile_outputs(before, before)
        with self.assertRaisesRegex(PgsoError, "candidate created profile output"):
            reject_profile_outputs(before, {generated})


if __name__ == "__main__":
    unittest.main()
