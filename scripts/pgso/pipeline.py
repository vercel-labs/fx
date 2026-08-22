from __future__ import annotations

import dataclasses
import os
import pathlib
import re
import stat
import uuid
from collections.abc import Sequence

from scripts.pgso.model import (
    ArtifactEvidence,
    PgsoError,
    sha256_file,
    size_gate,
)
from scripts.pgso.runner import hermetic_environment, run_checked
from scripts.pgso.toolchain import SUPPORTED_TARGET, Toolchain


GENERATION_FLAGS = (
    "--disable-vp",
    "--runtime-counter-relocation",
    "-pgo-kind=pgo-instr-gen-pipeline",
    "-passes=default<O2>",
)

USE_FLAGS = (
    "--disable-vp",
    "-pgo-kind=pgo-instr-use-pipeline",
    "-pgo-cold-func-opt=minsize",
    "-profile-summary-cutoff-cold=600000",
    "-passes=default<O2>,mergefunc,iroutliner",
)

BENCHMARK_USE_FLAGS = (
    "--disable-vp",
    "-pgo-kind=pgo-instr-use-pipeline",
    "-pgo-cold-func-opt=minsize",
    "-profile-summary-cutoff-cold=990000",
    "-passes=default<O2>,mergefunc,iroutliner",
)

FX_MACHINE_OUTLINER_FLAGS = (
    "-machine-outliner-reruns=1",
)

CANDIDATE_SIGNING_PAGE_SIZE = 16 * 1024

PROFILE_SECTION_ALIGNMENTS = (
    "-Wl,-sectalign,__DATA,__llvm_prf_cnts,0x4000",
    "-Wl,-sectalign,__DATA,__llvm_prf_data,0x4000",
    "-Wl,-sectalign,__DATA,__llvm_prf_bits,0x4000",
)

PROFILE_SECTIONS = (
    "__llvm_prf_cnts",
    "__llvm_prf_data",
    "__llvm_prf_bits",
)

ARTIFACT_LAYOUTS = {
    "fx": (None, "fx", "fx.bc"),
    "file_index": ("bench-file-index", "file-index-bench", "file-index.bc"),
    "ui_activity": (
        "bench-ui-activity",
        "ui-activity-progress-bench",
        "ui-activity.bc",
    ),
    "approval_review": (
        "bench-approval-review",
        "approval-review-bench",
        "approval-review.bc",
    ),
}


@dataclasses.dataclass(frozen=True)
class ArtifactSpec:
    repo_root: pathlib.Path
    target: str = SUPPORTED_TARGET
    optimize: str = "ReleaseSafe"
    update_channel: str = "stable"
    selector: str = "fx"

    def __post_init__(self) -> None:
        if self.target != SUPPORTED_TARGET:
            raise PgsoError(f"unsupported artifact target: {self.target}")
        if self.optimize != "ReleaseSafe":
            raise PgsoError("PGSO input must use Zig ReleaseSafe")
        if self.update_channel not in ("stable", "dev"):
            raise PgsoError(
                f"unsupported update channel: {self.update_channel}"
            )
        if self.selector not in ARTIFACT_LAYOUTS:
            raise PgsoError(f"unsupported pipeline artifact: {self.selector}")


@dataclasses.dataclass(frozen=True)
class PipelinePaths:
    selector: str
    binary_name: str
    root: pathlib.Path
    control_prefix: pathlib.Path
    control_binary: pathlib.Path
    ir_prefix: pathlib.Path
    bitcode: pathlib.Path
    instrumented: pathlib.Path
    instrumented_bitcode: pathlib.Path
    instrumented_object: pathlib.Path
    instrumented_binary: pathlib.Path
    compiler_runtime: pathlib.Path
    profiles: pathlib.Path
    raw_profiles: pathlib.Path
    raw_profile_pattern: pathlib.Path
    merged_profile: pathlib.Path
    candidate: pathlib.Path
    profile_use_bitcode: pathlib.Path
    profile_use_ir: pathlib.Path
    profile_use_object: pathlib.Path
    candidate_binary: pathlib.Path
    candidate_profiles: pathlib.Path
    runtime_home: pathlib.Path
    cache: pathlib.Path
    control_cache: pathlib.Path
    ir_cache: pathlib.Path
    global_cache: pathlib.Path
    logs: pathlib.Path

    @classmethod
    def create(
        cls,
        root: pathlib.Path,
        *,
        selector: str = "fx",
    ) -> "PipelinePaths":
        return cls._initialize(root, selector=selector, require_empty=True)

    @classmethod
    def open(
        cls,
        root: pathlib.Path,
        *,
        selector: str = "fx",
    ) -> "PipelinePaths":
        root = root.resolve()
        if not root.is_dir():
            raise PgsoError(f"pipeline output directory does not exist: {root}")
        return cls._initialize(root, selector=selector, require_empty=False)

    @classmethod
    def _initialize(
        cls,
        root: pathlib.Path,
        *,
        selector: str,
        require_empty: bool,
    ) -> "PipelinePaths":
        if selector not in ARTIFACT_LAYOUTS:
            raise PgsoError(f"unsupported pipeline artifact: {selector}")
        _, binary_name, bitcode_name = ARTIFACT_LAYOUTS[selector]
        root = root.resolve()
        if require_empty and root.exists() and any(root.iterdir()):
            raise PgsoError(f"pipeline output directory is not empty: {root}")
        root.mkdir(parents=True, exist_ok=True)

        control_prefix = root / "control"
        ir_prefix = root / "ir"
        instrumented = root / "instrumented"
        compiler_runtime = instrumented / "compiler-runtime"
        profiles = root / "profiles"
        raw_profiles = profiles / "raw"
        candidate = root / "candidate"
        candidate_profiles = candidate / "profile-probe"
        runtime_home = root / "home"
        cache = root / "cache"
        control_cache = cache / "control"
        ir_cache = cache / "ir"
        global_cache = cache / "global"
        logs = root / "logs"
        for directory in (
            control_prefix,
            ir_prefix,
            ir_prefix / "pgso",
            instrumented,
            compiler_runtime,
            raw_profiles,
            candidate,
            candidate_profiles,
            runtime_home,
            control_cache,
            ir_cache,
            global_cache,
            logs,
        ):
            directory.mkdir(parents=True, exist_ok=True)

        return cls(
            selector=selector,
            binary_name=binary_name,
            root=root,
            control_prefix=control_prefix,
            control_binary=control_prefix / "bin" / binary_name,
            ir_prefix=ir_prefix,
            bitcode=ir_prefix / "pgso" / bitcode_name,
            instrumented=instrumented,
            instrumented_bitcode=instrumented / bitcode_name,
            instrumented_object=instrumented / f"{binary_name}.o",
            instrumented_binary=instrumented / binary_name,
            compiler_runtime=compiler_runtime,
            profiles=profiles,
            raw_profiles=raw_profiles,
            raw_profile_pattern=raw_profiles / "train-%m-%p-%c.profraw",
            merged_profile=profiles / "merged.profdata",
            candidate=candidate,
            profile_use_bitcode=candidate / bitcode_name,
            profile_use_ir=candidate / f"{binary_name}.ll",
            profile_use_object=candidate / f"{binary_name}.o",
            candidate_binary=candidate / binary_name,
            candidate_profiles=candidate_profiles,
            runtime_home=runtime_home,
            cache=cache,
            control_cache=control_cache,
            ir_cache=ir_cache,
            global_cache=global_cache,
            logs=logs,
        )


@dataclasses.dataclass(frozen=True)
class CandidateMetadata:
    signature_valid: bool
    architecture: str
    min_macos: str
    load_commands: str
    dependencies: str


@dataclasses.dataclass(frozen=True)
class CandidateEvidence:
    artifact: ArtifactEvidence
    sha256: str
    metadata: CandidateMetadata
    version_output: str


def _require_nonempty_file(path: pathlib.Path, label: str) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise PgsoError(f"{label} is missing or empty: {path}")


def _runtime_environment(paths: PipelinePaths) -> dict[str, str]:
    environment = hermetic_environment(paths.runtime_home)
    environment.update(
        {
            "FX_AUTO_UPGRADE": "0",
            "FX_SKIP_ONBOARDING": "1",
            "FX_SOUND": "0",
            "HOME": str(paths.runtime_home),
            "NO_COLOR": "1",
        }
    )
    return environment


def zig_build_argv(
    toolchain: Toolchain,
    spec: ArtifactSpec,
    paths: PipelinePaths,
    *,
    emit_ir: bool,
) -> tuple[str, ...]:
    prefix = paths.ir_prefix if emit_ir else paths.control_prefix
    cache = paths.ir_cache if emit_ir else paths.control_cache
    argv = [str(toolchain.zig), "build"]
    if emit_ir:
        argv.append("pgso-ir")
        argv.append(f"-Dpgso-artifact={spec.selector}")
    else:
        build_step = ARTIFACT_LAYOUTS[spec.selector][0]
        if build_step is not None:
            argv.append(build_step)
    argv.extend(
        (
            f"-Dtarget={spec.target}",
            f"-Doptimize={spec.optimize}",
            f"-Dupdate-channel={spec.update_channel}",
            "--prefix",
            str(prefix),
            "--cache-dir",
            str(cache),
            "--global-cache-dir",
            str(paths.global_cache),
        )
    )
    return tuple(argv)


def instrumentation_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    return (
        str(toolchain.opt),
        *GENERATION_FLAGS,
        f"-profile-file={paths.raw_profile_pattern}",
        str(paths.bitcode),
        "-o",
        str(paths.instrumented_bitcode),
    )


def profile_use_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
    profile_path: pathlib.Path | None = None,
) -> tuple[str, ...]:
    profile = profile_path or paths.merged_profile
    flags = USE_FLAGS if paths.selector == "fx" else BENCHMARK_USE_FLAGS
    return (
        str(toolchain.opt),
        *flags,
        f"-profile-file={profile}",
        str(paths.bitcode),
        "-o",
        str(paths.profile_use_bitcode),
    )


def instrumented_run_argv(
    paths: PipelinePaths,
    arguments: Sequence[str],
) -> tuple[str, ...]:
    return (str(paths.instrumented_binary), *arguments)


def instrumented_link_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
    compiler_runtime_object: pathlib.Path,
    min_macos: str,
) -> tuple[str, ...]:
    return (
        str(toolchain.clang),
        "-target",
        f"arm64-apple-macos{min_macos}",
        f"-mmacosx-version-min={min_macos}",
        "-isysroot",
        str(toolchain.sdk),
        "-Wl,-dead_strip",
        *PROFILE_SECTION_ALIGNMENTS,
        str(paths.instrumented_object),
        str(toolchain.profile_runtime),
        str(compiler_runtime_object),
        "-o",
        str(paths.instrumented_binary),
        "-lc",
    )


def candidate_link_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    return (
        str(toolchain.zig),
        "cc",
        "-target",
        toolchain.target,
        "-O2",
        "-Wl,-dead_strip",
        "-s",
        str(paths.profile_use_object),
        "-o",
        str(paths.candidate_binary),
        "-lc",
    )


def candidate_object_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    # A second AArch64 outliner pass can fold sequences exposed by the first.
    # Keep benchmark artifacts on their established code-generation contract.
    outliner_flags = FX_MACHINE_OUTLINER_FLAGS if paths.selector == "fx" else ()
    return (
        str(toolchain.llc),
        "-filetype=obj",
        "-O=2",
        *outliner_flags,
        str(paths.profile_use_bitcode),
        "-o",
        str(paths.profile_use_object),
    )


def build_control(
    toolchain: Toolchain,
    spec: ArtifactSpec,
    paths: PipelinePaths,
) -> pathlib.Path:
    run_checked(
        zig_build_argv(toolchain, spec, paths, emit_ir=False),
        cwd=spec.repo_root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "build-control.json",
    )
    _require_nonempty_file(paths.control_binary, "ReleaseSafe control")
    return paths.control_binary


def emit_bitcode(
    toolchain: Toolchain,
    spec: ArtifactSpec,
    paths: PipelinePaths,
    *,
    expected_sha256: str | None = None,
) -> str:
    run_checked(
        zig_build_argv(toolchain, spec, paths, emit_ir=True),
        cwd=spec.repo_root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "emit-bitcode.json",
    )
    _require_nonempty_file(paths.bitcode, "ReleaseSafe LLVM bitcode")
    with paths.bitcode.open("rb") as stream:
        if stream.read(4) != b"BC\xc0\xde":
            raise PgsoError(f"invalid LLVM bitcode header: {paths.bitcode}")
    digest = sha256_file(paths.bitcode)
    if expected_sha256 is not None:
        validate_bitcode_hash(paths.bitcode, expected_sha256)
    return digest


def validate_bitcode_hash(path: pathlib.Path, expected_sha256: str) -> None:
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256:
        raise PgsoError(
            "bitcode identity mismatch: "
            f"expected {expected_sha256}, got {actual_sha256}"
        )


def parse_compiler_runtime(output: str) -> pathlib.Path:
    lines = tuple(line.strip() for line in output.splitlines() if line.strip())
    link_lines = tuple(line for line in lines if line.startswith("zig ld "))
    unknown_lines = tuple(
        line
        for line in lines
        if not line.startswith(("zig ar ", "zig ld "))
    )
    if len(link_lines) != 1 or unknown_lines:
        raise PgsoError(
            "unexpected compiler runtime probe output; expected one zig ld line"
        )
    matches = re.findall(
        r"(?<![^\s\"'])(/[^\s\"']*libcompiler_rt\.a)(?![^\s\"'])",
        link_lines[0],
    )
    unique = tuple(dict.fromkeys(matches))
    if len(unique) != 1:
        raise PgsoError(
            "compiler runtime probe must contain exactly one absolute "
            f"libcompiler_rt.a path; found {len(unique)}"
        )
    return pathlib.Path(unique[0])


def validate_archive_unchanged(
    archive: pathlib.Path,
    expected_sha256: str,
) -> None:
    actual_sha256 = sha256_file(archive)
    if actual_sha256 != expected_sha256:
        raise PgsoError(
            "compiler runtime archive changed during extraction: "
            f"expected {expected_sha256}, got {actual_sha256}"
        )


def _discover_compiler_runtime(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> pathlib.Path:
    result = run_checked(
        (
            str(toolchain.zig),
            "cc",
            "-target",
            toolchain.target,
            "-###",
            str(paths.instrumented_object),
            str(toolchain.profile_runtime),
            "-o",
            str(paths.instrumented / "runtime-probe"),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "compiler-runtime-probe.json",
    )
    archive = parse_compiler_runtime(result.stdout + "\n" + result.stderr)
    _require_nonempty_file(archive, "Zig compiler runtime archive")
    return archive


def _extract_compiler_runtime(
    toolchain: Toolchain,
    archive: pathlib.Path,
    paths: PipelinePaths,
) -> pathlib.Path:
    if any(paths.compiler_runtime.iterdir()):
        raise PgsoError(
            f"compiler runtime extraction directory is not empty: "
            f"{paths.compiler_runtime}"
        )
    archive_sha256 = sha256_file(archive)
    listed = run_checked(
        (str(toolchain.llvm_ar), "t", str(archive)),
        cwd=paths.compiler_runtime,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "compiler-runtime-list.json",
        require_empty_stderr=True,
    )
    members = tuple(line.strip() for line in listed.stdout.splitlines() if line.strip())
    if len(members) != 1:
        raise PgsoError(
            f"Zig compiler runtime must contain one object; found {len(members)}"
        )
    member = members[0]
    if pathlib.Path(member).name != member or member in (".", ".."):
        raise PgsoError(f"unsafe compiler runtime archive member: {member}")

    run_checked(
        (str(toolchain.llvm_ar), "x", str(archive)),
        cwd=paths.compiler_runtime,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "compiler-runtime-extract.json",
        require_empty_stderr=True,
    )
    extracted = paths.compiler_runtime / member
    _require_nonempty_file(extracted, "extracted Zig compiler runtime object")
    extracted.chmod(0o644)
    if stat.S_IMODE(extracted.stat().st_mode) != 0o644:
        raise PgsoError(f"could not set compiler runtime object mode: {extracted}")
    validate_archive_unchanged(archive, archive_sha256)
    return extracted


def validate_profile_section_alignment(load_commands: str) -> None:
    for section in PROFILE_SECTIONS:
        pattern = re.compile(
            rf"sectname\s+{re.escape(section)}"
            rf"(?:(?!sectname).)*?align\s+2\^14\s+\(16384\)",
            re.DOTALL,
        )
        if pattern.search(load_commands) is None:
            raise PgsoError(
                f"profile section alignment is not 16 KiB: {section}"
            )


def collect_instrumented_profile(
    toolchain: Toolchain,
    paths: PipelinePaths,
    *,
    training_argv: Sequence[str],
    training_name: str,
    timeout_s: float = 60,
) -> tuple[pathlib.Path, ...]:
    if re.fullmatch(r"[a-z0-9][a-z0-9-]*", training_name) is None:
        raise PgsoError(f"invalid instrumented training name: {training_name}")
    _require_nonempty_file(paths.instrumented_binary, "instrumented executable")
    before = set(paths.raw_profiles.glob("*.profraw"))
    environment = _runtime_environment(paths)
    environment["LLVM_PROFILE_FILE"] = str(paths.raw_profile_pattern)
    run_checked(
        instrumented_run_argv(paths, training_argv),
        cwd=paths.root,
        env=environment,
        timeout_s=timeout_s,
        log_path=paths.logs / f"instrumented-{training_name}.json",
        require_empty_stderr=True,
    )
    generated = tuple(sorted(set(paths.raw_profiles.glob("*.profraw")) - before))
    if len(generated) != 1:
        raise PgsoError(
            f"instrumented {training_name} must create one raw profile; "
            f"found {len(generated)}"
        )
    _require_nonempty_file(generated[0], "instrumented smoke raw profile")
    return generated


def build_instrumented(
    toolchain: Toolchain,
    paths: PipelinePaths,
    min_macos: str,
    *,
    training_argv: Sequence[str] = ("help",),
    training_name: str = "help",
) -> tuple[pathlib.Path, ...]:
    _require_nonempty_file(paths.bitcode, "ReleaseSafe LLVM bitcode")
    run_checked(
        instrumentation_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "instrument-bitcode.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.instrumented_bitcode, "instrumented bitcode")
    run_checked(
        (
            str(toolchain.llc),
            "-filetype=obj",
            "-O=2",
            str(paths.instrumented_bitcode),
            "-o",
            str(paths.instrumented_object),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "instrumented-object.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.instrumented_object, "instrumented object")

    archive = _discover_compiler_runtime(toolchain, paths)
    compiler_runtime_object = _extract_compiler_runtime(
        toolchain,
        archive,
        paths,
    )
    run_checked(
        instrumented_link_argv(
            toolchain,
            paths,
            compiler_runtime_object,
            min_macos,
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-instrumented.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.instrumented_binary, "instrumented executable")

    load_commands = run_checked(
        (str(toolchain.otool), "-l", str(paths.instrumented_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "instrumented-load-commands.json",
        require_empty_stderr=True,
    )
    validate_profile_section_alignment(load_commands.stdout)
    run_checked(
        (
            str(toolchain.codesign),
            "--verify",
            "--strict",
            str(paths.instrumented_binary),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "instrumented-signature.json",
        require_empty_stderr=True,
    )

    return collect_instrumented_profile(
        toolchain,
        paths,
        training_argv=training_argv,
        training_name=training_name,
    )


def merge_profile_batch(
    toolchain: Toolchain,
    raw_profiles: Sequence[pathlib.Path],
    merged_profile: pathlib.Path,
    log_path: pathlib.Path,
) -> int:
    if not raw_profiles:
        raise PgsoError("raw profile batch is empty")
    if len(set(raw_profiles)) != len(raw_profiles):
        raise PgsoError("raw profile batch contains duplicate paths")
    for raw_profile in raw_profiles:
        _require_nonempty_file(raw_profile, "raw profile")
    if merged_profile.exists():
        _require_nonempty_file(merged_profile, "merged profile accumulator")

    merged_profile.parent.mkdir(parents=True, exist_ok=True)
    temporary = merged_profile.with_name(
        f".{merged_profile.name}.{uuid.uuid4().hex}.tmp"
    )
    inputs: list[str] = []
    if merged_profile.exists():
        inputs.append(str(merged_profile))
    inputs.extend(str(path) for path in raw_profiles)
    run_checked(
        (
            str(toolchain.llvm_profdata),
            "merge",
            "-o",
            str(temporary),
            *inputs,
        ),
        cwd=merged_profile.parent,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=log_path,
        require_empty_stderr=True,
    )
    _require_nonempty_file(temporary, "temporary merged profile")
    os.replace(temporary, merged_profile)
    for raw_profile in raw_profiles:
        raw_profile.unlink()
    return len(raw_profiles)


def apply_profile(
    toolchain: Toolchain,
    paths: PipelinePaths,
    expected_bitcode_sha256: str,
    *,
    profile_path: pathlib.Path | None = None,
) -> pathlib.Path:
    validate_bitcode_hash(paths.bitcode, expected_bitcode_sha256)
    profile = profile_path or paths.merged_profile
    _require_nonempty_file(profile, "merged profile")
    run_checked(
        profile_use_argv(toolchain, paths, profile),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "profile-use.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_bitcode, "profile-use bitcode")
    return paths.profile_use_bitcode


def verify_release_safe_ir(ir_path: pathlib.Path) -> None:
    required = {
        "checked arithmetic": re.compile(
            r"llvm\.[su](?:add|sub|mul)\.with\.overflow"
        ),
        "integer overflow panic": re.compile(r"integer overflow"),
        "bounds panic": re.compile(r"index out of bounds: index "),
        "error-unwrapping panic": re.compile(r"attempt to unwrap error: "),
        "null-unwrapping panic": re.compile(r"attempt to use null value"),
        "unreachable panic": re.compile(r"reached unreachable code"),
    }
    found: set[str] = set()
    with ir_path.open("r", encoding="utf-8", errors="replace") as stream:
        for line in stream:
            for label, pattern in required.items():
                if label not in found and pattern.search(line):
                    found.add(label)
            if len(found) == len(required):
                return
    missing = ", ".join(label for label in required if label not in found)
    raise PgsoError(f"ReleaseSafe evidence missing: {missing}")


def link_candidate(
    toolchain: Toolchain,
    paths: PipelinePaths,
    *,
    require_release_safe_evidence: bool = True,
) -> pathlib.Path:
    _require_nonempty_file(paths.profile_use_bitcode, "profile-use bitcode")
    run_checked(
        (
            str(toolchain.opt),
            "-S",
            str(paths.profile_use_bitcode),
            "-o",
            str(paths.profile_use_ir),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "profile-use-ir.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_ir, "profile-use textual IR")
    if require_release_safe_evidence:
        verify_release_safe_ir(paths.profile_use_ir)

    run_checked(
        candidate_object_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "candidate-object.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_object, "candidate object")
    run_checked(
        candidate_link_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-candidate.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.candidate_binary, "candidate executable")
    run_checked(
        (
            str(toolchain.strip),
            "-S",
            "-x",
            str(paths.candidate_binary),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "strip-candidate.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.candidate_binary, "stripped candidate executable")
    run_checked(
        (
            str(toolchain.codesign),
            "--force",
            "--sign",
            "-",
            "--options",
            "linker-signed",
            "--pagesize",
            str(CANDIDATE_SIGNING_PAGE_SIZE),
            str(paths.candidate_binary),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "resign-candidate.json",
        require_empty_stderr=False,
    )
    _require_nonempty_file(paths.candidate_binary, "re-signed candidate executable")
    return paths.candidate_binary


def _parse_architecture(header: str) -> str:
    if re.search(r"\bARM64\b", header, re.IGNORECASE):
        return "arm64"
    if re.search(r"\bX86_64\b", header, re.IGNORECASE):
        return "x86_64"
    raise PgsoError("could not parse candidate architecture")


def _parse_minos(load_commands: str) -> str:
    match = re.search(r"\bminos\s+(\d+(?:\.\d+)+)", load_commands)
    if match is None:
        raise PgsoError("could not parse minimum macOS version")
    return match.group(1)


def read_macos_minos(
    toolchain: Toolchain,
    binary: pathlib.Path,
    log_path: pathlib.Path,
) -> str:
    result = run_checked(
        (str(toolchain.otool), "-l", str(binary)),
        cwd=binary.parent,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=log_path,
        require_empty_stderr=True,
    )
    return _parse_minos(result.stdout)


def validate_candidate_metadata(
    metadata: CandidateMetadata,
    *,
    expected_minos: str,
) -> None:
    if not metadata.signature_valid:
        raise PgsoError("candidate code signature is missing or invalid")
    if metadata.architecture != "arm64":
        raise PgsoError(
            f"candidate architecture is {metadata.architecture}, expected arm64"
        )
    if metadata.min_macos != expected_minos:
        raise PgsoError(
            "candidate minimum macOS version mismatch: "
            f"expected {expected_minos}, got {metadata.min_macos}"
        )
    if "libclang_rt.profile" in metadata.dependencies:
        raise PgsoError("candidate has an LLVM profile runtime dependency")
    if "__llvm_prf_" in metadata.load_commands:
        raise PgsoError("candidate retains an LLVM profile section")


def validate_candidate_size(candidate: pathlib.Path) -> ArtifactEvidence:
    _require_nonempty_file(candidate, "candidate executable")
    return size_gate(candidate.stat().st_size)


def reject_profile_outputs(
    before: set[pathlib.Path],
    after: set[pathlib.Path],
) -> None:
    generated = after - before
    if generated:
        names = ", ".join(str(path) for path in sorted(generated))
        raise PgsoError(f"candidate created profile output: {names}")


def verify_candidate(
    toolchain: Toolchain,
    paths: PipelinePaths,
    *,
    expected_minos: str,
) -> CandidateEvidence:
    _require_nonempty_file(paths.candidate_binary, "candidate executable")
    run_checked(
        (
            str(toolchain.codesign),
            "--verify",
            "--strict",
            str(paths.candidate_binary),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "candidate-signature.json",
        require_empty_stderr=True,
    )
    header = run_checked(
        (str(toolchain.otool), "-hv", str(paths.candidate_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "candidate-header.json",
        require_empty_stderr=True,
    )
    load_commands = run_checked(
        (str(toolchain.otool), "-l", str(paths.candidate_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "candidate-load-commands.json",
        require_empty_stderr=True,
    )
    dependencies = run_checked(
        (str(toolchain.otool), "-L", str(paths.candidate_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "candidate-dependencies.json",
        require_empty_stderr=True,
    )
    metadata = CandidateMetadata(
        signature_valid=True,
        architecture=_parse_architecture(header.stdout),
        min_macos=_parse_minos(load_commands.stdout),
        load_commands=load_commands.stdout,
        dependencies=dependencies.stdout,
    )
    validate_candidate_metadata(metadata, expected_minos=expected_minos)
    artifact = validate_candidate_size(paths.candidate_binary)

    before = set(paths.candidate_profiles.glob("*.profraw"))
    environment = _runtime_environment(paths)
    environment["LLVM_PROFILE_FILE"] = str(
        paths.candidate_profiles / "candidate-%p.profraw"
    )
    help_result = run_checked(
        (str(paths.candidate_binary), "help"),
        cwd=paths.root,
        env=environment,
        timeout_s=60,
        log_path=paths.logs / "candidate-help.json",
        require_empty_stderr=True,
    )
    if "Usage:" not in help_result.stdout:
        raise PgsoError("candidate help output is incomplete")
    version_result = run_checked(
        (str(paths.candidate_binary), "--version"),
        cwd=paths.root,
        env=environment,
        timeout_s=60,
        log_path=paths.logs / "candidate-version.json",
        require_empty_stderr=True,
    )
    if not version_result.stdout.strip():
        raise PgsoError("candidate version output is empty")
    after = set(paths.candidate_profiles.glob("*.profraw"))
    reject_profile_outputs(before, after)

    return CandidateEvidence(
        artifact=artifact,
        sha256=sha256_file(paths.candidate_binary),
        metadata=metadata,
        version_output=version_result.stdout.strip(),
    )
