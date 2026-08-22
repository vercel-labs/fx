from __future__ import annotations

import dataclasses
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
    PipelinePaths,
    apply_profile,
    candidate_object_argv,
    candidate_link_argv,
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
            "clang": tool_root / "clang",
            "strip": tool_root / "strip",
            "codesign": tool_root / "codesign",
            "otool": tool_root / "otool",
            "xcrun": tool_root / "xcrun",
            "sdk": self.root / "MacOSX.sdk",
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
        toolchain = dataclasses.replace(
            self.toolchain,
            zig=artifact_tool,
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
                "artifact cc -target aarch64-macos -O2 -Wl,-dead_strip -s "
                f"{self.paths.profile_use_object} -o "
                f"{self.paths.candidate_binary} -lc",
                f"strip -S -x {self.paths.candidate_binary}",
                "codesign --force --sign - --options linker-signed "
                f"--pagesize 16384 {self.paths.candidate_binary}",
            ],
            actions.read_text().splitlines(),
        )

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
            load_commands="LC_BUILD_VERSION\nminos 13.0",
            dependencies="/usr/lib/libSystem.B.dylib",
        )

    def test_candidate_metadata_rejects_missing_signature(self) -> None:
        with self.assertRaisesRegex(PgsoError, "code signature"):
            validate_candidate_metadata(
                dataclasses.replace(
                    self.good_candidate_metadata(),
                    signature_valid=False,
                ),
                expected_minos="13.0",
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
