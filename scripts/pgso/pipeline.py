from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import re
import shutil
import stat
import sys
import uuid
from collections.abc import Mapping, Sequence
from typing import Any

from scripts.pgso.model import (
    ArtifactEvidence,
    PgsoError,
    sha256_file,
    size_gate,
)
from scripts.pgso.runner import hermetic_environment, run_checked
from scripts.pgso.toolchain import DEFAULT_TARGET, Toolchain


# Zig 0.17 emits array bitcasts as per-element loops that the optimizer later
# folds into single loads. Instrumentation runs before loop unrolling, so it
# would count every element. Unroll constant-trip loops first, in both the
# generation and use pipelines, so their CFG hashes keep matching. Unrolling
# without the surrounding instcombine and simplifycfg left the ui-activity
# benchmark about 11% slower than a plain O2 build.
PROFILE_PREPARATION_PASSES = (
    "function(sroa,instcombine<no-verify-fixpoint>,loop-unroll-full,"
    "instcombine<no-verify-fixpoint>,simplifycfg)"
)

GENERATION_FLAGS = (
    "--disable-vp",
    "--runtime-counter-relocation",
    "--pgo-temporal-instrumentation",
    "-pgo-kind=pgo-instr-gen-pipeline",
    f"-passes={PROFILE_PREPARATION_PASSES},default<O2>",
)

# Apply the profile to the whole program before outlining, so the outliner
# sees the accepted whole-program optimization and profile metadata.
USE_FLAGS = (
    "--disable-vp",
    "-pgo-kind=pgo-instr-use-pipeline",
    "-pgo-cold-func-opt=minsize",
    "-profile-summary-cutoff-cold=600000",
    f"-passes={PROFILE_PREPARATION_PASSES},default<O2>,mergefunc",
)

# Each outliner input first goes through `ir_size.py expand-constant-exprs`
# and `ir_size.py swap-compares`, and each output through `ir_size.py
# check-outlined`: the outliner can fold a constant nested in a constant
# expression into a parameter that carries a different constant, and it can
# pass a greater-than comparison's operands in the wrong order (see
# ir_size.py).
IR_OUTLINER_FLAGS = (
    "-passes=iroutliner",
)

# The platform adds the symbols that stay external (`public_api_flags`).
OUTLINE_CLEANUP_FLAGS = (
    "-passes=internalize,constmerge,globaldce,mergefunc,verify",
)

# Zig writes raw bitcode. LLVM's own writer, which the IR size passes use,
# wraps Darwin bitcode in the 0x0B17C0DE wrapper header.
BITCODE_MAGICS = (b"BC\xc0\xde", b"\xde\xc0\x17\x0b")

# Drop the constants that `ir_size.py sparse-constants` left without uses and
# the ones `ir_size.py overlay-constants` replaced with aliases.
SPARSE_CLEANUP_FLAGS = (
    "-passes=globaldce,verify",
)

BENCHMARK_USE_FLAGS = (
    "--disable-vp",
    "-pgo-kind=pgo-instr-use-pipeline",
    "-pgo-cold-func-opt=minsize",
    "-profile-summary-cutoff-cold=990000",
    f"-passes={PROFILE_PREPARATION_PASSES},default<O2>,mergefunc",
)

FX_MACHINE_OUTLINER_FLAGS = (
    "-machine-outliner-reruns=1",
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
    target: str = DEFAULT_TARGET
    optimize: str = "ReleaseSafe"
    update_channel: str = "stable"
    selector: str = "fx"

    def __post_init__(self) -> None:
        # Platform modules import this one, so load the registry here.
        from scripts.pgso import platforms

        try:
            platforms.for_target(self.target)
        except PgsoError:
            raise PgsoError(f"unsupported artifact target: {self.target}") from None
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
    profile_use_base_bitcode: pathlib.Path
    outlined_bitcode: pathlib.Path
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
            profile_use_base_bitcode=candidate / f"{binary_name}.profile-use.bc",
            outlined_bitcode=candidate / f"{binary_name}.outlined.bc",
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

    @property
    def startup_profiles(self) -> pathlib.Path:
        """One kept profile per startup scenario, written during training."""
        return self.profiles / "startup"

    @property
    def startup_order(self) -> pathlib.Path:
        """The startup functions in first-use order, for the candidate link."""
        return self.logs / "startup-order.txt"


@dataclasses.dataclass(frozen=True)
class CandidateEvidence:
    artifact: ArtifactEvidence
    sha256: str
    # The platform's candidate metadata (`inspect_candidate`).
    metadata: Any
    version_output: str


# LLVM IR names, for ordering the outlined helpers after their callers.
_LLVM_FUNCTION_NAME = re.compile(
    r'@("(?:[^"\\]|\\[0-9a-fA-F]{2})*"|[A-Za-z$._][A-Za-z$._0-9]*)\('
)


_OUTLINED_IR_CALL = re.compile(
    r"@(outlined_ir_func_[0-9]+(?:\.[0-9]+)?)\("
)


def _decode_llvm_identifier(value: str) -> str:
    if not value.startswith('"'):
        return value
    raw = value[1:-1]
    decoded = bytearray()
    index = 0
    while index < len(raw):
        if raw[index] == "\\":
            decoded.append(int(raw[index + 1:index + 3], 16))
            index += 3
        else:
            decoded.extend(raw[index].encode())
            index += 1
    try:
        return decoded.decode()
    except UnicodeDecodeError as error:
        raise PgsoError("invalid UTF-8 in LLVM function name") from error


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
        )
    )
    return tuple(argv)


def zig_build_env(paths: PipelinePaths) -> dict[str, str]:
    # `zig build` takes its global cache only from the environment.
    environment = os.environ.copy()
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(paths.global_cache)
    return environment


def ir_size_argv(
    toolchain: Toolchain,
    command: str,
    source: pathlib.Path,
    output: pathlib.Path,
    options: Sequence[str] = (),
) -> tuple[str, ...]:
    return (
        sys.executable,
        str(toolchain.ir_size),
        "--libllvm",
        str(toolchain.libllvm),
        *options,
        command,
        str(source),
        str(output),
    )


def check_outlined_argv(
    toolchain: Toolchain,
    source: pathlib.Path,
) -> tuple[str, ...]:
    return (
        sys.executable,
        str(toolchain.ir_size),
        "--libllvm",
        str(toolchain.libllvm),
        "check-outlined",
        str(source),
    )


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
    output: pathlib.Path | None = None,
) -> tuple[str, ...]:
    profile = profile_path or paths.merged_profile
    flags = USE_FLAGS if paths.selector == "fx" else BENCHMARK_USE_FLAGS
    return (
        str(toolchain.opt),
        *flags,
        f"-profile-file={profile}",
        str(paths.bitcode),
        "-o",
        str(output or paths.profile_use_base_bitcode),
    )


def outline_ir_argv(
    toolchain: Toolchain,
    source: pathlib.Path,
    output: pathlib.Path,
) -> tuple[str, ...]:
    return (
        str(toolchain.opt),
        *IR_OUTLINER_FLAGS,
        str(source),
        "-o",
        str(output),
    )


def cleanup_outlined_ir_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    return (
        str(toolchain.opt),
        *OUTLINE_CLEANUP_FLAGS,
        *toolchain.platform.public_api_flags(toolchain, paths),
        str(paths.outlined_bitcode),
        "-o",
        str(paths.profile_use_bitcode),
    )


def instrumented_run_argv(
    paths: PipelinePaths,
    arguments: Sequence[str],
) -> tuple[str, ...]:
    return (str(paths.instrumented_binary), *arguments)


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
        *toolchain.platform.candidate_object_flags(paths),
        str(paths.profile_use_bitcode),
        "-o",
        str(paths.profile_use_object),
    )


def build_control(
    toolchain: Toolchain,
    spec: ArtifactSpec,
    paths: PipelinePaths,
) -> pathlib.Path:
    result = run_checked(
        (
            *zig_build_argv(toolchain, spec, paths, emit_ir=False),
            *toolchain.platform.CONTROL_BUILD_FLAGS,
        ),
        cwd=spec.repo_root,
        env=zig_build_env(paths),
        timeout_s=900,
        log_path=paths.logs / "build-control.json",
    )
    _require_nonempty_file(paths.control_binary, "ReleaseSafe control")
    toolchain.platform.record_control_build(toolchain, result, paths)
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
        env=zig_build_env(paths),
        timeout_s=900,
        log_path=paths.logs / "emit-bitcode.json",
    )
    _require_nonempty_file(paths.bitcode, "ReleaseSafe LLVM bitcode")
    _require_bitcode_header(paths.bitcode)
    # Every job derives instrumentation and profile use from this file, so
    # the helper attributes are part of the recorded bitcode identity.
    staged = paths.bitcode.with_name(paths.bitcode.name + ".staged")
    run_checked(
        ir_size_argv(toolchain, "outline-helpers", paths.bitcode, staged),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "outline-helpers.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(staged, "outlined-helper bitcode")
    _require_bitcode_header(staged)
    os.replace(staged, paths.bitcode)
    digest = sha256_file(paths.bitcode)
    if expected_sha256 is not None:
        validate_bitcode_hash(paths.bitcode, expected_sha256)
    return digest


def _require_bitcode_header(path: pathlib.Path) -> None:
    with path.open("rb") as stream:
        if stream.read(4) not in BITCODE_MAGICS:
            raise PgsoError(f"invalid LLVM bitcode header: {path}")


def rewrite_sparse_constants(toolchain: Toolchain, paths: PipelinePaths) -> None:
    """Replace copies of mostly undefined constants with their defined stores,
    pack the constants that are still referenced into one blob, move
    mostly empty writable globals to zero-fill, and read error names
    through one function over a compact table."""
    rewritten = paths.profile_use_bitcode.with_name(
        paths.profile_use_bitcode.name + ".sparse"
    )
    overlaid = paths.profile_use_bitcode.with_name(
        paths.profile_use_bitcode.name + ".overlaid"
    )
    zero_filled = paths.profile_use_bitcode.with_name(
        paths.profile_use_bitcode.name + ".zero-filled"
    )
    compacted = paths.profile_use_bitcode.with_name(
        paths.profile_use_bitcode.name + ".compacted"
    )
    run_checked(
        ir_size_argv(
            toolchain,
            "sparse-constants",
            paths.profile_use_bitcode,
            rewritten,
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "sparse-constants.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(rewritten, "sparse-constant bitcode")
    run_checked(
        ir_size_argv(toolchain, "overlay-constants", rewritten, overlaid),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "overlay-constants.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(overlaid, "overlaid-constant bitcode")
    rewritten.unlink()
    run_checked(
        ir_size_argv(toolchain, "zero-fill-globals", overlaid, zero_filled),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "zero-fill-globals.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(zero_filled, "zero-filled bitcode")
    overlaid.unlink()
    run_checked(
        ir_size_argv(toolchain, "compact-error-names", zero_filled, compacted),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "compact-error-names.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(compacted, "compacted-error-name bitcode")
    zero_filled.unlink()
    run_checked(
        (
            str(toolchain.opt),
            *SPARSE_CLEANUP_FLAGS,
            str(compacted),
            "-o",
            str(paths.profile_use_bitcode),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "sparse-cleanup.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_bitcode, "profile-use bitcode")
    compacted.unlink()


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
    *,
    destination: pathlib.Path | None = None,
    log_stem: str = "compiler-runtime",
) -> pathlib.Path:
    directory = paths.compiler_runtime if destination is None else destination
    directory.mkdir(parents=True, exist_ok=True)
    if any(directory.iterdir()):
        raise PgsoError(
            f"compiler runtime extraction directory is not empty: "
            f"{directory}"
        )
    archive_sha256 = sha256_file(archive)
    listed = run_checked(
        (str(toolchain.llvm_ar), "t", str(archive)),
        cwd=directory,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / f"{log_stem}-list.json",
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
        cwd=directory,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / f"{log_stem}-extract.json",
        require_empty_stderr=True,
    )
    extracted = directory / member
    _require_nonempty_file(extracted, "extracted Zig compiler runtime object")
    extracted.chmod(0o644)
    if stat.S_IMODE(extracted.stat().st_mode) != 0o644:
        raise PgsoError(f"could not set compiler runtime object mode: {extracted}")
    validate_archive_unchanged(archive, archive_sha256)
    return extracted


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
    control: Mapping[str, str],
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

    toolchain.platform.link_instrumented(toolchain, paths, control)

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
    inputs: list[pathlib.Path] = []
    if merged_profile.exists():
        _require_nonempty_file(merged_profile, "merged profile accumulator")
        inputs.append(merged_profile)
    inputs.extend(raw_profiles)
    _merge_profiles(toolchain, inputs, merged_profile, log_path)
    for raw_profile in raw_profiles:
        raw_profile.unlink()
    return len(raw_profiles)


def _merge_profiles(
    toolchain: Toolchain,
    inputs: Sequence[pathlib.Path],
    output: pathlib.Path,
    log_path: pathlib.Path,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{uuid.uuid4().hex}.tmp")
    run_checked(
        (
            str(toolchain.llvm_profdata),
            "merge",
            "-o",
            str(temporary),
            *(str(path) for path in inputs),
        ),
        cwd=output.parent,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=log_path,
        require_empty_stderr=True,
    )
    _require_nonempty_file(temporary, "temporary merged profile")
    os.replace(temporary, output)


def keep_startup_profile(
    toolchain: Toolchain,
    raw_profiles: Sequence[pathlib.Path],
    output: pathlib.Path,
    log_path: pathlib.Path,
) -> None:
    """Merge one startup scenario's raw profiles into `output`.

    The raw profiles stay in place for the shared training merge, which
    deletes them.
    """
    if not raw_profiles:
        raise PgsoError("startup scenario produced no raw profile")
    if output.exists():
        raise PgsoError(f"startup profile already exists: {output}")
    for raw_profile in raw_profiles:
        _require_nonempty_file(raw_profile, "raw profile")
    _merge_profiles(toolchain, raw_profiles, output, log_path)


def _bare_profile_name(name: str) -> str:
    # Profile records name a function as `<module>;<name>`.
    return name.split(";", 1)[1] if ";" in name else name


def executed_functions(show_text: str) -> set[str]:
    """The functions with a nonzero block count in `llvm-profdata show
    --all-functions --counts` output."""
    executed: set[str] = set()
    current: str | None = None
    for line in show_text.splitlines():
        header = re.match(r"^  (\S.*):$", line)
        if header:
            current = header.group(1)
            continue
        counts = re.match(r"^    Block counts: \[(.*)\]$", line)
        if counts and current is not None:
            if any(int(value) for value in counts.group(1).split(",") if value.strip()):
                executed.add(_bare_profile_name(current))
            current = None
    return executed


def remove_profile_records(text: str, names: set[str]) -> tuple[str, set[str]]:
    """Drop the records of `names` from a text profile.

    Returns the remaining text and the names whose records were removed.
    Header lines, comments, and the temporal trace block stay.
    """
    lines = text.splitlines(keepends=True)
    kept: list[str] = []
    removed: set[str] = set()
    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith((":", "#")) or not line.strip():
            kept.append(line)
            index += 1
            continue
        # A record runs from its name to the next blank line.
        end = index
        while end < len(lines) and lines[end].strip():
            end += 1
        bare = _bare_profile_name(line.strip())
        is_record = end - index >= 4 and lines[index + 1].startswith("# Func Hash")
        if is_record and bare in names:
            removed.add(bare)
        else:
            kept.extend(lines[index:end])
        index = end
    return "".join(kept), removed


def exempt_cold_startup_functions(
    toolchain: Toolchain,
    paths: PipelinePaths,
    expected_bitcode_sha256: str,
    scenarios: Sequence[str],
    benchmark_profiles: Sequence[pathlib.Path] = (),
) -> dict[str, object]:
    """Keep profile use from compiling the cold startup functions for size.

    Profile use marks the functions it judges cold `minsize`, and that slows
    short commands such as `fx help`. This applies the production profile
    once, then removes from `paths.merged_profile` the records of the startup
    functions that came out `minsize`, so the real profile use and the
    benchmark relinks treat them as unprofiled. Hot startup functions, those
    the build inlined away, and those any of `benchmark_profiles` executes
    keep their records: the heavy benchmarks build from the production
    profile, so removing a record they rely on slows them. It also writes the
    startup functions in first-use order to `paths.startup_order`, which the
    link places first and `apply_profile` keeps out of outlining.
    """
    validate_bitcode_hash(paths.bitcode, expected_bitcode_sha256)
    startup_profiles = [paths.startup_profiles / f"{name}.profdata" for name in scenarios]
    for profile in startup_profiles:
        _require_nonempty_file(profile, "startup profile")
    startup_profile = paths.profiles / "startup.profdata"
    _merge_profiles(toolchain, startup_profiles, startup_profile, paths.logs / "merge-startup.json")

    def profdata(*argv: str, log_name: str) -> None:
        run_checked(
            (str(toolchain.llvm_profdata), *argv),
            cwd=paths.root,
            env=os.environ.copy(),
            timeout_s=300,
            log_path=paths.logs / log_name,
            require_empty_stderr=True,
        )

    shown = paths.logs / "startup-functions.txt"
    profdata("show", "--all-functions", "--counts", str(startup_profile), "-o", str(shown),
             log_name="startup-functions.json")
    startup = executed_functions(shown.read_text(encoding="utf-8"))
    if not startup:
        raise PgsoError("startup profiles executed no functions")

    probe = paths.candidate / f"{paths.binary_name}.startup-probe.bc"
    run_checked(
        profile_use_argv(toolchain, paths, paths.merged_profile, output=probe),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "startup-probe-profile-use.json",
        require_empty_stderr=True,
    )
    _require_bitcode_header(probe)
    attributes_path = paths.logs / "startup-probe-attributes.json"
    run_checked(
        ir_size_argv(toolchain, "minsize-functions", probe, attributes_path),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "startup-probe-minsize.json",
        require_empty_stderr=True,
    )
    attributes = json.loads(attributes_path.read_text(encoding="utf-8"))
    defined = set(attributes["defined"])
    cold = set(attributes["minsize"])
    benchmark_functions: set[str] = set()
    for index, benchmark_profile in enumerate(benchmark_profiles):
        _require_nonempty_file(benchmark_profile, "benchmark training profile")
        listing = paths.logs / f"startup-benchmark-functions-{index}.txt"
        profdata("show", "--all-functions", "--counts", str(benchmark_profile), "-o", str(listing),
                 log_name=f"startup-benchmark-functions-{index}.json")
        benchmark_functions |= executed_functions(listing.read_text(encoding="utf-8"))
    exempt = (startup & cold) - benchmark_functions

    text_profile = paths.logs / "production.proftext"
    profdata("merge", "--text", str(paths.merged_profile), "-o", str(text_profile),
             log_name="production-to-text.json")
    filtered, removed = remove_profile_records(text_profile.read_text(encoding="utf-8"), exempt)
    if removed != exempt:
        raise PgsoError(
            f"cold startup functions without a profile record: {sorted(exempt - removed)[:8]}"
        )
    filtered_text = paths.logs / "production-startup-exempt.proftext"
    filtered_text.write_text(filtered, encoding="utf-8")
    original = paths.profiles / "merged-before-startup-exemption.profdata"
    shutil.copy2(paths.merged_profile, original)
    _merge_profiles(toolchain, (filtered_text,), paths.merged_profile, paths.logs / "production-startup-exempt.json")

    startup_order = paths.logs / "startup-profile.order"
    profdata("order", str(startup_profile), "-o", str(startup_order), log_name="startup-profile-order.json")
    first_use = [
        line.strip()
        for line in startup_order.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    order = first_use + sorted(startup - set(first_use))
    paths.startup_order.write_text("".join(f"{name}\n" for name in order), encoding="utf-8")
    return {
        "scenarios": list(scenarios),
        "startup_profile_sha256": sha256_file(startup_profile),
        "startup_functions": len(startup),
        "exempt_functions": len(exempt),
        "kept_for_benchmarks": len(startup & cold & benchmark_functions),
        "kept_hot_functions": len((startup & defined) - cold),
        "not_defined_functions": len(startup - defined),
        "records_removed": len(removed),
        "profile_before_sha256": sha256_file(original),
        "profile_sha256": sha256_file(paths.merged_profile),
        "startup_order_functions": len(order),
        "startup_order_sha256": sha256_file(paths.startup_order),
    }


def _defined_external_symbols(
    toolchain: Toolchain,
    bitcode: pathlib.Path,
    log_path: pathlib.Path,
) -> tuple[tuple[str, str], ...]:
    result = run_checked(
        (
            str(toolchain.llvm_nm),
            "--defined-only",
            "--extern-only",
            "--format=posix",
            "--radix=x",
            str(bitcode),
        ),
        cwd=bitcode.parent,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=log_path,
        require_empty_stderr=True,
    )
    if result.stdout_truncated:
        raise PgsoError("public symbol output exceeded the bounded capture limit")
    symbols: list[tuple[str, str]] = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(
            r"(.+) ([A-Za-z?]) ([0-9a-fA-F-]+) ([0-9a-fA-F-]+)",
            line,
        )
        if match is None:
            raise PgsoError("invalid public symbol output")
        symbols.append((match.group(1), match.group(2)))
    if len(symbols) != len({name for name, _ in symbols}):
        raise PgsoError("duplicate public symbols in profile-use bitcode")
    return tuple(sorted(symbols))


def apply_profile(
    toolchain: Toolchain,
    paths: PipelinePaths,
    expected_bitcode_sha256: str,
    *,
    profile_path: pathlib.Path | None = None,
    no_outline_functions: pathlib.Path | None = None,
) -> pathlib.Path:
    """Apply the profile, then outline and clean up the result.

    The functions listed in `no_outline_functions`, one per line, are marked
    `nooutline` first, so neither outliner moves their code into shared
    helpers placed elsewhere.
    """
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
    _require_nonempty_file(
        paths.profile_use_base_bitcode,
        "whole-program profile-use bitcode",
    )
    if no_outline_functions is not None:
        _require_nonempty_file(no_outline_functions, "no-outline function list")
        marked = paths.profile_use_base_bitcode.with_name(
            paths.profile_use_base_bitcode.name + ".no-outline.bc"
        )
        run_checked(
            ir_size_argv(
                toolchain,
                "no-outline",
                paths.profile_use_base_bitcode,
                marked,
                ("--functions", str(no_outline_functions)),
            ),
            cwd=paths.root,
            env=os.environ.copy(),
            timeout_s=900,
            log_path=paths.logs / "no-outline.json",
            require_empty_stderr=True,
        )
        _require_bitcode_header(marked)
        os.replace(marked, paths.profile_use_base_bitcode)
    if paths.selector != "fx":
        _outline_without_folded_constants(
            toolchain,
            paths,
            paths.profile_use_base_bitcode,
            paths.profile_use_bitcode,
            "profile-use",
        )
        rewrite_sparse_constants(toolchain, paths)
        return paths.profile_use_bitcode

    original_symbols = _defined_external_symbols(
        toolchain,
        paths.profile_use_base_bitcode,
        paths.logs / "public-symbols-before.json",
    )
    _outline_without_folded_constants(
        toolchain,
        paths,
        paths.profile_use_base_bitcode,
        paths.outlined_bitcode,
        "profile-use",
    )
    run_checked(
        cleanup_outlined_ir_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "cleanup-outlined-ir.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_bitcode, "profile-use bitcode")
    rewrite_sparse_constants(toolchain, paths)
    outlined_symbols = _defined_external_symbols(
        toolchain,
        paths.profile_use_bitcode,
        paths.logs / "public-symbols-after.json",
    )
    if outlined_symbols != original_symbols:
        raise PgsoError(
            "outlining changed the public symbol surface: "
            f"before={original_symbols}, after={outlined_symbols}"
        )
    return paths.profile_use_bitcode


def _outline_without_folded_constants(
    toolchain: Toolchain,
    paths: PipelinePaths,
    source: pathlib.Path,
    output: pathlib.Path,
    name: str,
) -> None:
    expanded = source.with_name(source.name + ".expanded.bc")
    run_checked(
        ir_size_argv(toolchain, "expand-constant-exprs", source, expanded),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / f"expand-constant-exprs-{name}.json",
        require_empty_stderr=True,
    )
    _require_bitcode_header(expanded)
    swapped = source.with_name(source.name + ".swapped.bc")
    run_checked(
        ir_size_argv(toolchain, "swap-compares", expanded, swapped),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / f"swap-compares-{name}.json",
        require_empty_stderr=True,
    )
    _require_bitcode_header(swapped)
    run_checked(
        outline_ir_argv(toolchain, swapped, output),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / f"outline-{name}.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(output, "outlined IR")
    run_checked(
        check_outlined_argv(toolchain, output),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / f"check-outlined-{name}.json",
        require_empty_stderr=True,
    )


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
    toolchain.platform.link_candidate_binary(toolchain, paths)
    return paths.candidate_binary


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
    control: Mapping[str, str],
) -> CandidateEvidence:
    _require_nonempty_file(paths.candidate_binary, "candidate executable")
    metadata = toolchain.platform.inspect_candidate(toolchain, paths, control)
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
