from __future__ import annotations

import dataclasses
import json
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

# Apply the profile before partitioning so every part inherits the accepted
# whole-program optimization and profile metadata.
USE_FLAGS = (
    "--disable-vp",
    "-pgo-kind=pgo-instr-use-pipeline",
    "-pgo-cold-func-opt=minsize",
    "-profile-summary-cutoff-cold=600000",
    f"-passes={PROFILE_PREPARATION_PASSES},default<O2>,mergefunc",
)

OUTLINE_PARTITIONS = 2

IR_OUTLINER_FLAGS = (
    "-passes=iroutliner",
)

OUTLINE_CLEANUP_FLAGS = (
    "-passes=internalize,constmerge,globaldce,mergefunc,verify",
    "-internalize-public-api-list=main,_mh_execute_header",
)

BENCHMARK_USE_FLAGS = (
    "--disable-vp",
    "-pgo-kind=pgo-instr-use-pipeline",
    "-pgo-cold-func-opt=minsize",
    "-profile-summary-cutoff-cold=990000",
    f"-passes={PROFILE_PREPARATION_PASSES},default<O2>,mergefunc,iroutliner",
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
    profile_use_base_bitcode: pathlib.Path
    outline_split_prefix: pathlib.Path
    linked_outlined_bitcode: pathlib.Path
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
            outline_split_prefix=candidate / f"{binary_name}.split.",
            linked_outlined_bitcode=candidate / f"{binary_name}.outlined.bc",
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
    def outline_split_bitcodes(self) -> tuple[pathlib.Path, ...]:
        return tuple(
            pathlib.Path(f"{self.outline_split_prefix}{index}")
            for index in range(OUTLINE_PARTITIONS)
        )

    @property
    def outlined_bitcodes(self) -> tuple[pathlib.Path, ...]:
        return tuple(
            self.candidate / f"{self.binary_name}.outlined.{index}.bc"
            for index in range(OUTLINE_PARTITIONS)
        )


@dataclasses.dataclass(frozen=True)
class CandidateMetadata:
    signature_valid: bool
    architecture: str
    min_macos: str
    load_commands: str
    dependencies: str


@dataclasses.dataclass(frozen=True)
class MacosLinkContract:
    platform: int
    min_macos: str
    sdk_version: str
    stack_size: int
    dylibs: tuple[tuple[str, str, str, str], ...]


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
        )
    )
    return tuple(argv)


def zig_build_env(paths: PipelinePaths) -> dict[str, str]:
    # `zig build` takes its global cache only from the environment.
    environment = os.environ.copy()
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(paths.global_cache)
    return environment


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
    output = (
        paths.profile_use_base_bitcode
        if paths.selector == "fx"
        else paths.profile_use_bitcode
    )
    return (
        str(toolchain.opt),
        *flags,
        f"-profile-file={profile}",
        str(paths.bitcode),
        "-o",
        str(output),
    )


def split_ir_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    return (
        str(toolchain.llvm_split),
        "-j",
        str(OUTLINE_PARTITIONS),
        "-o",
        str(paths.outline_split_prefix),
        str(paths.profile_use_base_bitcode),
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


def link_outlined_ir_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    return (
        str(toolchain.llvm_link),
        *map(str, paths.outlined_bitcodes),
        "-o",
        str(paths.linked_outlined_bitcode),
    )


def cleanup_outlined_ir_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    return (
        str(toolchain.opt),
        *OUTLINE_CLEANUP_FLAGS,
        str(paths.linked_outlined_bitcode),
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


def candidate_runtime_probe_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> tuple[str, ...]:
    command = candidate_link_argv(toolchain, paths)
    return (*command[:2], "-###", *command[2:])


_STUB_TARGET_LIST = re.compile(r"(targets:\s*)\[([^\]]*)\]")


def apple_ld_system_stub(text: str) -> str:
    # Zig 0.17's macOS 27 stub lists arm64e.x1 targets, which the Xcode 16.4
    # linker rejects as an unknown architecture. An arm64 link never uses them.
    def drop_arm64e_x1(match: re.Match[str]) -> str:
        targets = [target.strip() for target in match.group(2).split(",")]
        kept = [t for t in targets if t and not t.startswith("arm64e.x1-")]
        if not kept:
            raise PgsoError("system stub section targets only arm64e.x1")
        return f"{match.group(1)}[ {', '.join(kept)} ]"

    result = _STUB_TARGET_LIST.sub(drop_arm64e_x1, text)
    if "arm64e.x1" in result:
        raise PgsoError("system stub names arm64e.x1 outside a target list")
    return result


def temporal_candidate_link_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
    compiler_runtime: pathlib.Path,
    contract: MacosLinkContract,
    system_stub: pathlib.Path,
) -> tuple[str, ...]:
    return (
        str(toolchain.apple_ld),
        "-arch",
        "arm64",
        "-platform_version",
        "macos",
        contract.min_macos,
        contract.sdk_version,
        "-stack_size",
        format(contract.stack_size, "x"),
        "-syslibroot",
        str(toolchain.sdk),
        "-dead_strip",
        "-e",
        "_main",
        "-no_deduplicate",
        "-no_function_starts",
        "-order_file",
        str(paths.logs / "candidate-order.txt"),
        "-map",
        str(paths.logs / "candidate-link.map"),
        str(paths.profile_use_object),
        str(compiler_runtime),
        str(system_stub),
        "-o",
        str(paths.candidate_binary),
    )


def _candidate_text_symbols(symbol_text: str) -> dict[str, int]:
    symbols: dict[str, int] = {}
    for line in symbol_text.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(
            r"(.+) ([A-Za-z?]) ([0-9a-fA-F]+) ([0-9a-fA-F]+)", line,
        )
        if match is None:
            raise PgsoError("invalid candidate object symbol output")
        name, kind, address, _ = match.groups()
        if kind not in ("t", "T"):
            continue
        value = int(address, 16)
        if name in symbols and symbols[name] != value:
            raise PgsoError(f"ambiguous candidate text symbol: {name}")
        symbols[name] = value
    return symbols


def map_temporal_symbols(
    order_text: str,
    symbol_text: str,
) -> tuple[tuple[str, ...], dict[str, object]]:
    count = re.findall(r"(?m)^# Ordered (\d+) functions$", order_text)
    names = tuple(
        line.strip() for line in order_text.splitlines()
        if line.strip() and not line.startswith("#")
    )
    if (
        len(count) != 1
        or int(count[0]) != len(names)
        or len(set(names)) != len(names)
    ):
        raise PgsoError("invalid temporal function order")
    symbols = _candidate_text_symbols(symbol_text)
    ordered: list[str] = []
    addresses: set[int] = set()
    bindings: list[dict[str, object]] = []
    unmapped: list[str] = []
    for name in names:
        candidates = tuple(
            value for value in ("_" + name, "l_" + name) if value in symbols
        )
        locations = {symbols[value] for value in candidates}
        if not locations:
            unmapped.append(name)
            continue
        if len(locations) != 1:
            raise PgsoError(f"ambiguous temporal symbol: {name}")
        selected = candidates[0]
        if any(character in selected for character in ("\r", "\n", "\0")):
            raise PgsoError("unrepresentable temporal symbol")
        address = symbols[selected]
        bindings.append({
            "profile_name": name,
            "symbols": candidates,
            "selected": selected,
            "address": address,
        })
        if address not in addresses:
            ordered.append(selected)
            addresses.add(address)
    if not ordered:
        raise PgsoError("temporal order contains no defined text symbols")
    return tuple(ordered), {
        "profile_functions": len(names),
        "bindings": bindings,
        "unmapped_symbols": unmapped,
    }


_LLVM_FUNCTION_NAME = re.compile(
    r'@("(?:[^"\\]|\\[0-9a-fA-F]{2})*"|[A-Za-z$._][A-Za-z$._0-9]*)\('
)
_OUTLINED_IR_SYMBOL = re.compile(
    r"_outlined_ir_func_[0-9]+(?:\.[0-9]+)?"
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


def order_outlined_ir_helpers(
    ordered: Sequence[str],
    symbol_text: str,
    ir_path: pathlib.Path,
) -> tuple[tuple[str, ...], dict[str, int]]:
    symbols = _candidate_text_symbols(symbol_text)
    helpers = {
        name for name in symbols if _OUTLINED_IR_SYMBOL.fullmatch(name)
    }
    calls: dict[str, list[str]] = {}
    current: str | None = None
    with ir_path.open("r", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("define "):
                match = _LLVM_FUNCTION_NAME.search(line)
                if match is None:
                    raise PgsoError("invalid LLVM function definition")
                name = _decode_llvm_identifier(match.group(1))
                candidates = tuple(
                    value
                    for value in ("_" + name, "l_" + name)
                    if value in symbols
                )
                locations = {symbols[value] for value in candidates}
                if len(locations) > 1:
                    raise PgsoError(f"ambiguous candidate text symbol: {name}")
                current = candidates[0] if candidates else None
                continue
            if line.rstrip("\n") == "}":
                current = None
                continue
            if current is None:
                continue
            for name in _OUTLINED_IR_CALL.findall(line):
                helper = "_" + name
                if helper not in helpers:
                    continue
                targets = calls.setdefault(current, [])
                if helper not in targets:
                    targets.append(helper)

    ranks: dict[str, int] = {}
    for rank, symbol in enumerate(ordered):
        pending = [symbol]
        while pending:
            for helper in calls.get(pending.pop(), ()):
                previous = ranks.get(helper)
                if previous is None or rank < previous:
                    ranks[helper] = rank
                    pending.append(helper)

    result = list(ordered)
    addresses = {symbols[name] for name in ordered}
    for helper in sorted(
        helpers,
        key=lambda name: (ranks.get(name, len(ordered)), symbols[name], name),
    ):
        address = symbols[helper]
        if address not in addresses:
            result.append(helper)
            addresses.add(address)
    return tuple(result), {
        "outlined_helpers": len(helpers),
        "profile_ranked_outlined_helpers": len(ranks),
    }


def validate_temporal_link_map(
    link_map: str,
    object_path: pathlib.Path,
    ordered: Sequence[str],
) -> dict[str, object]:
    try:
        object_table, remainder = (
            link_map.split("# Object files:\n", 1)[1].split("# Sections:\n", 1)
        )
        sections, _ = remainder.split("# Symbols:\n", 1)
    except (IndexError, ValueError) as error:
        raise PgsoError("incomplete candidate linker map") from error
    text_sections = re.findall(
        r"(?m)^0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s+__TEXT\s+__text\s*$",
        sections,
    )
    if len(text_sections) != 1:
        raise PgsoError("linker map must identify one text section")
    text_start, text_size = (int(value, 16) for value in text_sections[0])
    objects = re.findall(r"(?m)^\[\s*(\d+)\] (.+)$", object_table)
    indexes = [
        int(index) for index, path in objects
        if pathlib.Path(path).resolve() == object_path.resolve()
    ]
    if len(indexes) != 1:
        raise PgsoError("linker map must identify the candidate object exactly once")
    live: dict[str, int] = {}
    sizes: dict[int, int] = {}
    removed: set[str] = set()
    needed = set(ordered)
    section = ""
    for line in link_map.splitlines():
        if line.startswith("# "):
            if line == "# Symbols:":
                section = "live"
            elif line == "# Dead Stripped Symbols:":
                section = "removed"
            continue
        match = re.fullmatch(
            r"(0x[0-9a-fA-F]+|<<dead>>)\s+0x([0-9a-fA-F]+)\s+\[\s*(\d+)\]\s+(.+)",
            line,
        )
        if match is None or int(match[3]) != indexes[0]:
            continue
        address, size, _, name = match.groups()
        if section == "removed":
            if name in needed:
                removed.add(name)
        elif section == "live" and address != "<<dead>>":
            location = int(address, 16)
            if not text_start <= location < text_start + text_size:
                continue
            if name in needed:
                if name in live and live[name] != location:
                    raise PgsoError(f"ambiguous linker map symbol: {name}")
                live[name] = location
            sizes[location] = max(sizes.get(location, 0), int(size, 16))
    missing = [name for name in ordered if name not in live and name not in removed]
    if missing:
        raise PgsoError(f"ordered symbols absent from linker map: {missing[:5]}")
    locations = [live[name] for name in ordered if name in live]
    if (
        not locations
        or locations != sorted(locations)
        or len(set(locations)) != len(locations)
    ):
        raise PgsoError("linker did not apply the temporal function order")
    ordered_bytes = sum(sizes[location] for location in locations)
    if ordered_bytes <= 0:
        raise PgsoError("temporal linker map contains no ordered code bytes")
    return {
        "ordered_sections": len(locations),
        "ordered_bytes": ordered_bytes,
        "linker_removed_symbols": [name for name in ordered if name in removed],
    }


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
        env=zig_build_env(paths),
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
        env=zig_build_env(paths),
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
    if paths.selector != "fx":
        _require_nonempty_file(paths.profile_use_bitcode, "profile-use bitcode")
        return paths.profile_use_bitcode

    _require_nonempty_file(
        paths.profile_use_base_bitcode,
        "whole-program profile-use bitcode",
    )
    original_symbols = _defined_external_symbols(
        toolchain,
        paths.profile_use_base_bitcode,
        paths.logs / "public-symbols-before.json",
    )
    run_checked(
        split_ir_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "split-profile-use.json",
        require_empty_stderr=True,
    )
    for split in paths.outline_split_bitcodes:
        _require_nonempty_file(split, "profile-use IR partition")
    for index, (split, outlined) in enumerate(
        zip(paths.outline_split_bitcodes, paths.outlined_bitcodes)
    ):
        run_checked(
            outline_ir_argv(toolchain, split, outlined),
            cwd=paths.root,
            env=os.environ.copy(),
            timeout_s=900,
            log_path=paths.logs / f"outline-profile-use-{index}.json",
            require_empty_stderr=True,
        )
        _require_nonempty_file(outlined, "outlined IR partition")
    run_checked(
        link_outlined_ir_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "link-outlined-ir.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.linked_outlined_bitcode, "linked outlined bitcode")
    run_checked(
        cleanup_outlined_ir_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "cleanup-outlined-ir.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.profile_use_bitcode, "profile-use bitcode")
    outlined_symbols = _defined_external_symbols(
        toolchain,
        paths.profile_use_bitcode,
        paths.logs / "public-symbols-after.json",
    )
    if outlined_symbols != original_symbols:
        raise PgsoError(
            "partitioned outlining changed the public symbol surface: "
            f"before={original_symbols}, after={outlined_symbols}"
        )
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


def _link_temporal_candidate(toolchain: Toolchain, paths: PipelinePaths) -> None:
    _require_nonempty_file(paths.merged_profile, "temporal production profile")
    _require_nonempty_file(paths.control_binary, "ReleaseSafe control")
    contract = read_macos_link_contract(
        toolchain,
        paths.control_binary,
        paths.logs / "link-control-macos.json",
    )
    if _version_tuple(toolchain.zig_sdk_version) != _version_tuple(contract.sdk_version):
        raise PgsoError("control SDK does not match the pinned Zig SDK")
    probe = run_checked(
        candidate_runtime_probe_argv(toolchain, paths),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "candidate-runtime-probe.json",
    )
    runtime = parse_compiler_runtime(probe.stdout + "\n" + probe.stderr)
    platform = re.findall(
        r"-platform_version macos (\d+(?:\.\d+)+) (\d+(?:\.\d+)+)",
        probe.stdout + "\n" + probe.stderr,
    )
    if len(platform) != 1 or (
        _version_tuple(platform[0][0]), _version_tuple(platform[0][1])
    ) != (_version_tuple(contract.min_macos), _version_tuple(contract.sdk_version)):
        raise PgsoError(
            "optimized Zig runtime probe does not match the control platform and SDK"
        )
    _require_nonempty_file(runtime, "candidate compiler runtime")
    runtime_hash = sha256_file(runtime)
    runtime_object = _extract_compiler_runtime(
        toolchain, runtime, paths,
        destination=paths.candidate_binary.parent / "compiler-runtime",
        log_stem="candidate-compiler-runtime",
    )
    runtime_object_hash = sha256_file(runtime_object)
    system_stub = toolchain.zig_darwin_sdk / "libSystem.tbd"
    _require_nonempty_file(system_stub, "pinned Zig system library stub")
    stub_hash = sha256_file(system_stub)
    linked_stub = paths.candidate_binary.parent / "system-stub" / "libSystem.tbd"
    linked_stub.parent.mkdir(parents=True, exist_ok=True)
    linked_stub.write_text(
        apple_ld_system_stub(system_stub.read_text(encoding="utf-8")),
        encoding="utf-8",
    )
    linked_stub_hash = sha256_file(linked_stub)
    order_path = paths.logs / "candidate-profile.order"
    run_checked(
        (str(toolchain.llvm_profdata), "order", str(paths.merged_profile), "-o", str(order_path)),
        cwd=paths.root, env=os.environ.copy(), timeout_s=120,
        log_path=paths.logs / "candidate-profile-order.json", require_empty_stderr=True,
    )
    symbols = run_checked(
        (str(toolchain.llvm_nm), "--defined-only", "--format=posix", "--radix=x", str(paths.profile_use_object)),
        cwd=paths.root, env=os.environ.copy(), timeout_s=120,
        log_path=paths.logs / "candidate-object-symbols.json", require_empty_stderr=True,
        max_capture_chars=8 * 1024 * 1024,
    )
    if symbols.stdout_truncated:
        raise PgsoError("candidate object symbols exceeded the bounded capture limit")
    ordered, mapping = map_temporal_symbols(
        order_path.read_text(encoding="utf-8"), symbols.stdout,
    )
    ordered, outlined_layout = order_outlined_ir_helpers(
        ordered,
        symbols.stdout,
        paths.profile_use_ir,
    )
    mapping.update(outlined_layout)
    mapped_order = paths.logs / "candidate-order.txt"
    mapped_order.write_text(
        "".join(f"{paths.profile_use_object.name}:{name}\n" for name in ordered),
        encoding="utf-8",
    )
    (paths.logs / "candidate-order-mapping.json").write_text(
        json.dumps(mapping, indent=2) + "\n", encoding="utf-8",
    )
    result = run_checked(
        temporal_candidate_link_argv(toolchain, paths, runtime_object, contract, linked_stub),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-candidate.json",
        require_empty_stderr=True,
    )
    if result.stdout:
        raise PgsoError("unexpected temporal linker stdout")
    link_map = paths.logs / "candidate-link.map"
    # Apple maps include opaque literal bytes outside the named text symbols.
    layout = validate_temporal_link_map(
        link_map.read_text(encoding="utf-8", errors="surrogateescape"),
        paths.profile_use_object, ordered,
    )
    linked_contract = read_macos_link_contract(
        toolchain, paths.candidate_binary, paths.logs / "linked-macos-contract.json",
    )
    validate_macos_link_contract(linked_contract, contract)
    validate_archive_unchanged(runtime, runtime_hash)
    if (
        sha256_file(runtime_object) != runtime_object_hash
        or sha256_file(system_stub) != stub_hash
        or sha256_file(linked_stub) != linked_stub_hash
    ):
        raise PgsoError("candidate runtime object or system stub changed during link")
    evidence = {
        "linker": "apple-ld",
        "linker_version": toolchain.apple_ld_version,
        "minimum_macos": contract.min_macos,
        "sdk_version": contract.sdk_version,
        "main_stack_size": contract.stack_size,
        "dependencies": contract.dylibs,
        "sysroot_sdk_version": toolchain.sdk_version,
        "sysroot": str(toolchain.sdk),
        "system_stub": str(system_stub),
        "system_stub_sha256": stub_hash,
        "linked_system_stub_sha256": linked_stub_hash,
        "runtime_archive_sha256": runtime_hash,
        "runtime_object_sha256": runtime_object_hash,
        "profile_sha256": sha256_file(paths.merged_profile),
        "order_sha256": sha256_file(mapped_order),
        "link_map_sha256": sha256_file(link_map),
        "unmapped_profile_functions": len(mapping["unmapped_symbols"]),
        **layout,
    }
    (paths.logs / "candidate-layout.json").write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


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
    if paths.selector == "fx":
        _link_temporal_candidate(toolchain, paths)
    else:
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


def _version_tuple(value: str) -> tuple[int, int, int]:
    if re.fullmatch(r"\d+(?:\.\d+){1,2}", value) is None:
        raise PgsoError(f"invalid Mach-O version: {value}")
    parts = tuple(map(int, value.split(".")))
    return parts[0], parts[1], parts[2] if len(parts) == 3 else 0


def parse_macos_link_contract(load_commands: str) -> MacosLinkContract:
    commands: dict[str, list[str]] = {}
    for block in re.split(r"(?m)^Load command \d+\n", load_commands):
        command = re.findall(r"(?m)^\s*cmd (LC_[A-Z0-9_]+)\s*$", block)
        if len(command) == 1:
            commands.setdefault(command[0], []).append(block)

    def one(kind: str) -> str:
        blocks = commands.get(kind, [])
        if len(blocks) != 1:
            raise PgsoError(f"Mach-O requires exactly one {kind}")
        return blocks[0]

    def field(block: str, key: str, pattern: str) -> str:
        values = re.findall(rf"(?m)^\s*{re.escape(key)}\s+({pattern})\s*$", block)
        if len(values) != 1:
            raise PgsoError(f"invalid Mach-O {key}")
        return values[0]

    build = one("LC_BUILD_VERSION")
    platform = int(field(build, "platform", r"\d+"))
    if platform != 1:
        raise PgsoError("candidate platform is not macOS")
    minimum = field(build, "minos", r"\d+(?:\.\d+){1,2}")
    sdk = field(build, "sdk", r"\d+(?:\.\d+){1,2}")
    stack_size = int(field(one("LC_MAIN"), "stacksize", r"\d+"))
    if stack_size > (1 << 64) - 1:
        raise PgsoError("invalid Mach-O stack size")
    dylibs: list[tuple[str, str, str, str]] = []
    for kind in (
        "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
        "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
    ):
        for block in commands.get(kind, []):
            name = field(block, "name", r".+ \(offset \d+\)").rsplit(" (offset ", 1)[0]
            current = field(block, "current version", r"\d+(?:\.\d+){1,2}")
            compatible = field(block, "compatibility version", r"\d+(?:\.\d+){1,2}")
            dylibs.append((kind, name, current, compatible))
    return MacosLinkContract(platform, minimum, sdk, stack_size, tuple(sorted(dylibs)))


def read_macos_link_contract(
    toolchain: Toolchain,
    binary: pathlib.Path,
    log_path: pathlib.Path,
) -> MacosLinkContract:
    result = run_checked(
        (str(toolchain.otool), "-l", str(binary)),
        cwd=binary.parent, env=os.environ.copy(), timeout_s=60,
        log_path=log_path, require_empty_stderr=True,
    )
    if result.stdout_truncated:
        raise PgsoError("Mach-O load commands exceeded the capture limit")
    return parse_macos_link_contract(result.stdout)


def validate_macos_link_contract(
    actual: MacosLinkContract,
    expected: MacosLinkContract,
) -> None:
    for attribute, label in (
        ("platform", "platform"), ("min_macos", "minimum macOS version"),
        ("sdk_version", "SDK compatibility"), ("stack_size", "main stack size"),
        ("dylibs", "dynamic library dependencies"),
    ):
        actual_value = getattr(actual, attribute)
        expected_value = getattr(expected, attribute)
        if actual_value != expected_value:
            raise PgsoError(
                f"candidate {label} mismatch: expected {expected_value}, got {actual_value}"
            )


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
    expected_contract: MacosLinkContract,
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
    validate_macos_link_contract(parse_macos_link_contract(metadata.load_commands), expected_contract)


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
    expected_contract = read_macos_link_contract(
        toolchain, paths.control_binary, paths.logs / "verify-control-contract.json",
    )
    validate_candidate_metadata(
        metadata, expected_minos=expected_minos, expected_contract=expected_contract,
    )
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
