from __future__ import annotations

import argparse
import dataclasses
import json
import os
import pathlib
import shutil
import sys
from collections.abc import Mapping, Sequence

from scripts.pgso.corpus import load_corpus, run_behavior_corpus, run_corpus
from scripts.pgso.model import BuildIdentity, PgsoError, profile_evidence, sha256_file
from scripts.pgso.pipeline import (
    GENERATION_FLAGS,
    ArtifactSpec,
    PipelinePaths,
    apply_profile,
    build_control,
    build_instrumented,
    emit_bitcode,
    link_candidate,
    merge_profile_batch,
    read_macos_minos,
    verify_candidate,
)
from scripts.pgso.qualify import (
    EvidenceRecorder,
    REQUIRED_EVIDENCE,
    build_profile_linked_benchmarks,
    measure_heavy_workloads,
    measure_startup,
    measurement_payload,
    profile_linked_benchmark_evidence,
    relink_profile_linked_benchmarks,
    require_measurements_passed,
)
from scripts.pgso.runner import cancellation_guard, run_checked
from scripts.pgso.toolchain import SUPPORTED_TARGET
from scripts.pgso.toolchain import Toolchain


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO_ROOT / "scripts" / "pgso" / "corpus.json"
MUTATING_COMMANDS = ("build", "train", "all")
REQUIRED_BUN_VERSION = "1.3.14"
REQUIRED_HYPERFINE_VERSION = "1.20.0"


def ensure_fresh_output(path: pathlib.Path) -> pathlib.Path:
    path = path.resolve()
    if path.exists():
        if not path.is_dir():
            raise PgsoError(f"PGSO output is not a directory: {path}")
        if any(path.iterdir()):
            raise PgsoError(f"PGSO output directory is not empty: {path}")
    return path


def load_read_only_manifest(path: pathlib.Path) -> Mapping[str, object]:
    manifest_path = path.resolve() / "manifest.json"
    if not manifest_path.is_file():
        raise PgsoError(f"PGSO manifest does not exist: {manifest_path}")
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PgsoError(f"could not read PGSO manifest: {error}") from error
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise PgsoError("unsupported PGSO manifest")
    if (
        payload.get("status") != "passed"
        or payload.get("stage") != "complete"
        or payload.get("eligible") is not True
    ):
        raise PgsoError("PGSO manifest is not eligible")
    evidence = payload.get("evidence")
    if not isinstance(evidence, dict) or any(
        key not in evidence for key in REQUIRED_EVIDENCE
    ):
        raise PgsoError("PGSO manifest is missing required evidence")
    return payload


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--llvm-bin", required=True)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--target", default=SUPPORTED_TARGET)
    parser.add_argument(
        "--update-channel",
        choices=("stable", "dev"),
        default="stable",
    )
    parser.add_argument("--corpus", type=pathlib.Path, default=DEFAULT_CORPUS)
    parser.add_argument("--samples", type=int, default=50)
    parser.add_argument("--timeout-seconds", type=float, default=1800)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--bun", default="bun")
    parser.add_argument("--hyperfine", default="hyperfine")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python3 -m scripts.pgso",
        description="Build and qualify macOS arm64 fx PGSO candidates",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    descriptions = {
        "build": "Build the control and instrumented compiler artifacts",
        "train": "Build a candidate from the versioned production corpus",
        "all": "Run the complete non-publishing Stage 1 candidate gate",
    }
    for command in MUTATING_COMMANDS:
        command_parser = subparsers.add_parser(
            command,
            help=descriptions[command],
            description=descriptions[command],
        )
        _add_common_arguments(command_parser)
    report_parser = subparsers.add_parser(
        "report",
        help="Print an existing eligible manifest without modifying it",
    )
    report_parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    return parser


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = _parser()
    arguments = parser.parse_args(argv)
    if arguments.command == "report":
        return arguments
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if arguments.command == "all" and arguments.samples < 50:
        parser.error("--samples must be at least 50 for qualification")
    return arguments


def _git_output(
    arguments: Sequence[str],
    *,
    paths: PipelinePaths,
    repo_root: pathlib.Path,
    log_name: str,
) -> str:
    result = run_checked(
        ("git", *arguments),
        cwd=repo_root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / log_name,
        require_empty_stderr=True,
    )
    return result.stdout.strip()


def _profile_summary(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> str:
    result = run_checked(
        (
            str(toolchain.llvm_profdata),
            "show",
            str(paths.merged_profile),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "profile-summary.json",
        require_empty_stderr=True,
    )
    if not result.stdout.strip():
        raise PgsoError("merged profile summary is empty")
    return result.stdout.strip()


def _configuration(arguments: argparse.Namespace) -> dict[str, object]:
    return {
        "target": arguments.target,
        "update_channel": arguments.update_channel,
        "corpus": str(arguments.corpus.resolve()),
        "llvm_bin": str(pathlib.Path(arguments.llvm_bin).resolve()),
        "samples": arguments.samples,
        "timeout_seconds": arguments.timeout_seconds,
        "zig": arguments.zig,
        "bun": arguments.bun,
        "hyperfine": arguments.hyperfine,
    }


def _resolve_runtime_executable(command: str, label: str) -> pathlib.Path:
    candidate = shutil.which(command)
    if candidate is None:
        raise PgsoError(f"missing runtime executable: {label}")
    resolved = pathlib.Path(candidate).resolve()
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise PgsoError(f"runtime executable is not usable: {label}: {resolved}")
    return resolved


def _runtime_versions(
    arguments: argparse.Namespace,
    paths: PipelinePaths,
) -> tuple[pathlib.Path, pathlib.Path, dict[str, str]]:
    bun = _resolve_runtime_executable(arguments.bun, "Bun")
    bun_result = run_checked(
        (str(bun), "--version"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=30,
        log_path=paths.logs / "bun-version.json",
        require_empty_stderr=True,
    )
    bun_version = bun_result.stdout.strip()
    if bun_version != REQUIRED_BUN_VERSION:
        raise PgsoError(
            f"PGSO requires Bun {REQUIRED_BUN_VERSION}; "
            f"bun reported {bun_version}"
        )

    hyperfine = _resolve_runtime_executable(arguments.hyperfine, "Hyperfine")
    hyperfine_result = run_checked(
        (str(hyperfine), "--version"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=30,
        log_path=paths.logs / "hyperfine-version.json",
        require_empty_stderr=True,
    )
    hyperfine_version = hyperfine_result.stdout.strip()
    expected_hyperfine = f"hyperfine {REQUIRED_HYPERFINE_VERSION}"
    if hyperfine_version != expected_hyperfine:
        raise PgsoError(
            f"PGSO requires Hyperfine {REQUIRED_HYPERFINE_VERSION}; "
            f"hyperfine reported {hyperfine_version}"
        )

    tmux = _resolve_runtime_executable("tmux", "tmux")
    tmux_result = run_checked(
        (str(tmux), "-V"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=30,
        log_path=paths.logs / "tmux-version.json",
        require_empty_stderr=True,
    )
    macos_result = run_checked(
        ("sw_vers", "-productVersion"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=30,
        log_path=paths.logs / "macos-version.json",
        require_empty_stderr=True,
    )
    return bun, hyperfine, {
        "bun_path": str(bun),
        "bun_version": bun_version,
        "hyperfine_path": str(hyperfine),
        "hyperfine_version": hyperfine_version,
        "tmux_path": str(tmux),
        "tmux_version": tmux_result.stdout.strip(),
        "macos_version": macos_result.stdout.strip(),
    }


def run_command(arguments: argparse.Namespace) -> pathlib.Path:
    output_dir = ensure_fresh_output(arguments.output_dir)
    paths = PipelinePaths.create(output_dir)
    recorder = EvidenceRecorder(
        paths.root / "manifest.json",
        command=arguments.command,
        configuration=_configuration(arguments),
    )
    stage = "validate"
    try:
        recorder.stage(stage, "running")
        toolchain = Toolchain.discover(
            arguments.zig,
            arguments.llvm_bin,
            arguments.target,
        )
        bun, hyperfine, runtime_versions = _runtime_versions(arguments, paths)
        corpus = load_corpus(arguments.corpus, repo_root=REPO_ROOT)
        source_sha = _git_output(
            ("rev-parse", "HEAD"),
            paths=paths,
            repo_root=REPO_ROOT,
            log_name="source-sha.json",
        )
        if len(source_sha) != 40:
            raise PgsoError(f"invalid source SHA: {source_sha!r}")
        tracked_changes = _git_output(
            ("status", "--porcelain", "--untracked-files=no"),
            paths=paths,
            repo_root=REPO_ROOT,
            log_name="source-status.json",
        )
        if tracked_changes:
            raise PgsoError("tracked source changes are present")
        recorder.stage(
            stage,
            "passed",
            {
                "runtime": runtime_versions,
                "validation": {
                    "source_sha": source_sha,
                    "host_arch": toolchain.host_arch,
                    "target": toolchain.target,
                    "zig_version": toolchain.zig_version,
                    "llvm_version": toolchain.llvm_version,
                }
            },
        )

        spec = ArtifactSpec(
            repo_root=REPO_ROOT,
            target=arguments.target,
            update_channel=arguments.update_channel,
        )
        stage = "control"
        recorder.stage(stage, "running")
        control = build_control(toolchain, spec, paths)
        control_minos = read_macos_minos(
            toolchain,
            control,
            paths.logs / "control-load-commands.json",
        )
        control_sha256 = sha256_file(control)
        recorder.stage(
            stage,
            "passed",
            {
                "control": {
                    "path": str(control),
                    "sha256": control_sha256,
                    "size_bytes": control.stat().st_size,
                    "minimum_macos": control_minos,
                }
            },
        )

        stage = "bitcode"
        recorder.stage(stage, "running")
        bitcode_sha256 = emit_bitcode(toolchain, spec, paths)
        identity = BuildIdentity(
            source_sha=source_sha,
            target=toolchain.target,
            host_arch=toolchain.host_arch,
            zig_version=toolchain.zig_version,
            llvm_version=toolchain.llvm_version,
            bitcode_sha256=bitcode_sha256,
            corpus_sha256=corpus.manifest_sha256,
            update_channel=arguments.update_channel,
            generation_flags=GENERATION_FLAGS,
        )
        recorder.stage(
            stage,
            "passed",
            {"identity": dataclasses.asdict(identity)},
        )

        stage = "instrumented"
        recorder.stage(stage, "running")
        smoke_profiles = build_instrumented(
            toolchain,
            paths,
            control_minos,
        )
        merged_raw_profiles = merge_profile_batch(
            toolchain,
            smoke_profiles,
            paths.merged_profile,
            paths.logs / "merge-instrumented-smoke.json",
        )
        recorder.stage(
            stage,
            "passed",
            {
                "instrumented": {
                    "path": str(paths.instrumented_binary),
                    "sha256": sha256_file(paths.instrumented_binary),
                    "smoke_profiles": merged_raw_profiles,
                    "smoke_profile": profile_evidence(
                        paths.merged_profile,
                        merged_raw_profiles=merged_raw_profiles,
                    ),
                }
            },
        )
        if arguments.command == "build":
            recorder.finish_partial("build-complete")
            return recorder.path

        stage = "corpus-training"
        recorder.stage(stage, "running")
        training_result = run_corpus(
            corpus,
            paths.instrumented_binary,
            paths.raw_profiles,
            paths.merged_profile,
            toolchain=toolchain,
            bun=bun,
        )
        merged_raw_profiles += training_result.merged_raw_profiles
        profile_summary = _profile_summary(toolchain, paths)
        recorder.stage(
            stage,
            "passed",
            {
                "training_corpus": dataclasses.asdict(training_result),
                "profile": {
                    "path": str(paths.merged_profile),
                    "sha256": sha256_file(paths.merged_profile),
                    "size_bytes": paths.merged_profile.stat().st_size,
                    "merged_raw_profiles": merged_raw_profiles,
                    "summary": profile_summary,
                },
            },
        )

        stage = "profile-use"
        recorder.stage(stage, "running")
        linked_benchmarks = build_profile_linked_benchmarks(
            toolchain,
            REPO_ROOT,
            paths,
        )
        emit_bitcode(
            toolchain,
            spec,
            paths,
            expected_sha256=bitcode_sha256,
        )
        apply_profile(toolchain, paths, bitcode_sha256)
        link_candidate(toolchain, paths)
        linked_benchmarks = relink_profile_linked_benchmarks(
            toolchain,
            paths,
            linked_benchmarks,
        )
        candidate = verify_candidate(
            toolchain,
            paths,
            expected_minos=control_minos,
        )
        if not candidate.artifact.preferred_headroom_met:
            raise PgsoError(
                "candidate meets the hard size ceiling but lacks "
                "0.250 MiB preferred adoption headroom"
            )
        artifacts = {
            "control": {
                "path": str(control),
                "sha256": control_sha256,
                "size_bytes": control.stat().st_size,
                "minimum_macos": control_minos,
            },
            "candidate": {
                "path": str(paths.candidate_binary),
                "sha256": candidate.sha256,
                "size": dataclasses.asdict(candidate.artifact),
                "architecture": candidate.metadata.architecture,
                "minimum_macos": candidate.metadata.min_macos,
                "signature_valid": candidate.metadata.signature_valid,
                "version": candidate.version_output,
            },
            "warnings": 0,
            "linker": json.loads(
                (paths.logs / "candidate-layout.json").read_text(encoding="utf-8")
            ),
        }
        supplement_evidence = profile_linked_benchmark_evidence(
            linked_benchmarks,
            paths.profile_use_ir.read_text(
                encoding="utf-8",
                errors="replace",
            ),
        )
        profile = {
            "path": str(paths.merged_profile),
            "sha256": sha256_file(paths.merged_profile),
            "size_bytes": paths.merged_profile.stat().st_size,
            "merged_raw_profiles": merged_raw_profiles,
            "summary": _profile_summary(toolchain, paths),
            "supplements": supplement_evidence,
        }
        recorder.stage(
            stage,
            "passed",
            {"artifacts": artifacts, "profile": profile},
        )
        if arguments.command == "train":
            recorder.finish_partial("train-complete")
            return recorder.path

        stage = "candidate-corpus"
        recorder.stage(stage, "running")
        behavior_result = run_behavior_corpus(
            corpus,
            paths.candidate_binary,
            paths.root / "candidate-behavior",
            bun=bun,
        )
        corpus_evidence = {
            "manifest_path": str(corpus.manifest_path),
            "manifest_sha256": corpus.manifest_sha256,
            "intentional_exclusions": corpus.intentional_exclusions,
            "training": dataclasses.asdict(training_result),
            "candidate": dataclasses.asdict(behavior_result),
        }
        recorder.stage(
            stage,
            "passed",
            {"corpus": corpus_evidence},
        )

        stage = "startup"
        recorder.stage(stage, "running")
        startup_results = measure_startup(
            repo_root=REPO_ROOT,
            control_binary=control,
            candidate_binary=paths.candidate_binary,
            hyperfine_binary=hyperfine,
            output_dir=paths.root / "measurements" / "startup",
            samples=arguments.samples,
            timeout_s=arguments.timeout_seconds,
        )
        recorder.stage(
            stage,
            "passed",
            {"startup": measurement_payload(startup_results)},
        )
        require_measurements_passed("startup", startup_results)

        stage = "heavy-workloads"
        recorder.stage(stage, "running")
        heavy_results = measure_heavy_workloads(
            toolchain=None,
            repo_root=REPO_ROOT,
            output_dir=paths.root / "measurements" / "heavy",
            samples=arguments.samples,
            timeout_s=arguments.timeout_seconds,
            prebuilt_pairs={
                selector: linked.pair
                for selector, linked in linked_benchmarks.items()
            },
        )
        recorder.stage(
            stage,
            "passed",
            {"heavy_workloads": measurement_payload(heavy_results)},
        )
        require_measurements_passed("heavy workload", heavy_results)

        recorder.complete()
        return recorder.path
    except BaseException as error:
        recorder.fail(stage, error)
        raise


def main(argv: Sequence[str] | None = None) -> int:
    try:
        with cancellation_guard():
            arguments = parse_args(argv)
            if arguments.command == "report":
                payload = load_read_only_manifest(arguments.output_dir)
                print(json.dumps(payload, indent=2, sort_keys=True))
                return 0
            manifest_path = run_command(arguments)
            print(manifest_path)
            return 0
    except PgsoError as error:
        print(f"PGSO failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
