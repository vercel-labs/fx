"""The Linux arm64 PGSO platform: ld.lld links of the static musl fx, and ELF checks.

Zig links the static musl control with its own ld.lld. A `zig cc` link of the
same object picks different inputs and flags, so the control build records
Zig's exact link command (`zig build --verbose-link`), and the instrumented
and candidate links reuse it with only the Zig object swapped. That keeps the
candidate's ELF layout identical to the control's, which `inspect_candidate`
checks.

The shared pipeline reaches this module through `Toolchain.platform`; see
scripts/pgso/platforms.py for the functions every platform provides.
"""
from __future__ import annotations

import dataclasses
import json
import os
import pathlib
import platform
import re
import shlex
from collections.abc import Mapping, Sequence

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import (
    _LLVM_FUNCTION_NAME,
    _OUTLINED_IR_CALL,
    PipelinePaths,
    _decode_llvm_identifier,
    _defined_external_symbols,
    _require_nonempty_file,
)
from scripts.pgso.runner import CommandResult, run_checked
from scripts.pgso.toolchain import Toolchain, _capture

TARGET = "aarch64-linux"
DISPLAY_NAME = "Linux arm64"
HOST_ARCH = "aarch64"
LIBLLVM_NAME = "libLLVM.so"
# The candidate may be at most this size, and needs 0.250 MiB of headroom
# below it, which leaves about 150 KB of growth above a 5.86 MiB build.
SIZE_CEILING_MIB = 6.250
# Record Zig's own link of the control, which the other links reuse.
CONTROL_BUILD_FLAGS = ("--verbose-link",)
# Profile use compiles the cold functions for size, which on Linux slows these
# short commands past the startup gate, so their cold functions are exempt.
STARTUP_SCENARIOS = (
    "direct-help",
    "direct-version",
    "direct-status",
    "direct-doctor",
    "direct-sessions",
)
ZIG_CC_LINK_FLAGS = ("-Wl,--gc-sections",)


def external_control_strip_argv(
    _toolchain: Toolchain, _binary: pathlib.Path
) -> tuple[str, ...]:
    # The link's `-s` already removes every symbol.
    return ()
PROFILE_RUNTIME_TRIPLE = "aarch64-unknown-linux-gnu"
PROFILE_SECTIONS = ("__llvm_prf_cnts", "__llvm_prf_data")
# The whole fx object's symbol table and the linker's removed-section list
# exceed the default capture limit.
LARGE_OUTPUT_CHARS = 256 * 1024 * 1024

_GC_REMOVED = re.compile(r"removing unused section (.+):\((.+)\)")
_OUTLINED_IR_HELPER = re.compile(r"outlined_ir_func_[0-9]+(?:\.[0-9]+)?")
_SEGMENT_TYPES = (
    "PHDR",
    "LOAD",
    "TLS",
    "GNU_RELRO",
    "GNU_STACK",
    "INTERP",
    "DYNAMIC",
    "GNU_EH_FRAME",
    "NOTE",
)


@dataclasses.dataclass(frozen=True)
class Tools:
    ld_lld: pathlib.Path
    readelf: pathlib.Path


@dataclasses.dataclass(frozen=True)
class CandidateMetadata:
    layout: dict[str, object]


def check_host() -> str:
    """The host architecture, after checking the host can build and run the target."""
    if platform.system() != "Linux":
        raise PgsoError("Linux PGSO requires a Linux host")
    host_arch = platform.machine()
    if host_arch != HOST_ARCH:
        raise PgsoError("Linux PGSO requires an aarch64 host")
    return host_arch


def discover_tools(zig_path: pathlib.Path, clang: pathlib.Path) -> tuple[Tools, pathlib.Path]:
    """LLVM's linker and ELF reader from the configured root, and the profile runtime."""
    llvm_root = clang.resolve().parent
    found: dict[str, pathlib.Path] = {}
    for name in ("ld.lld", "llvm-readelf"):
        candidate = llvm_root / name
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise PgsoError(f"missing executable: {name}")
        resolved = candidate.resolve()
        if resolved.parent != llvm_root:
            raise PgsoError(f"LLVM tool escapes configured root: {name}: {resolved}")
        # Keep the name: `ld.lld` links to `lld`, which picks its linker
        # flavor from the name it was run as.
        found[name] = candidate
    resource_dir = pathlib.Path(
        _capture((str(clang), "--print-resource-dir"), "clang resource directory")
    ).expanduser().resolve()
    # LLVM's release build of the runtime targets glibc; it has no libc
    # dependency the static musl link cannot satisfy.
    profile_runtime = resource_dir / "lib" / PROFILE_RUNTIME_TRIPLE / "libclang_rt.profile.a"
    if not profile_runtime.is_file() or profile_runtime.stat().st_size == 0:
        raise PgsoError(f"missing LLVM profile runtime: {profile_runtime}")
    return Tools(ld_lld=found["ld.lld"], readelf=found["llvm-readelf"]), profile_runtime


def os_versions(paths: PipelinePaths) -> dict[str, str]:
    release = ""
    try:
        for line in pathlib.Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if line.startswith("PRETTY_NAME="):
                release = line.split("=", 1)[1].strip().strip('"')
    except OSError as error:
        raise PgsoError("could not read /etc/os-release") from error
    if not release:
        raise PgsoError("/etc/os-release has no PRETTY_NAME")
    return {"os_release": release, "kernel_release": platform.release()}


# The control's link.


def _final_link(text: str) -> list[str]:
    links = [
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith("ld.lld ") and " -r " not in line
    ]
    if len(links) != 1:
        raise PgsoError(f"control build must print one final ld.lld link, found {len(links)}")
    return shlex.split(links[0])


def record_control_build(toolchain: Toolchain, result: CommandResult, paths: PipelinePaths) -> None:
    """Keep Zig's link of the control, and the hashes of the inputs it reuses."""
    if result.stdout_truncated or result.stderr_truncated:
        raise PgsoError("control build output was truncated before its link command")
    argv = _final_link(result.stdout + "\n" + result.stderr)
    objects = [item for item in argv if item.endswith("_zcu.o")]
    if len(objects) != 1:
        raise PgsoError(f"control link must name one Zig object, found {objects}")
    if argv.count("-o") != 1:
        raise PgsoError("control link must name one output")
    inputs = sorted({item for item in argv[1:] if item.endswith((".o", ".a")) and item != objects[0]})
    record = {
        "argv": argv,
        "zig_object": objects[0],
        "inputs": {item: sha256_file(pathlib.Path(item)) for item in inputs},
    }
    (paths.logs / "control-link.json").write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _control_link(paths: PipelinePaths) -> tuple[list[str], str]:
    path = paths.logs / "control-link.json"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
        argv, zig_object, inputs = record["argv"], record["zig_object"], record["inputs"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise PgsoError(f"missing or invalid control link record: {path}") from error
    for item, digest in inputs.items():
        if not pathlib.Path(item).is_file() or sha256_file(pathlib.Path(item)) != digest:
            raise PgsoError(f"control link input changed: {item}")
    return argv, zig_object


def relink_argv(
    toolchain: Toolchain,
    paths: PipelinePaths,
    obj: pathlib.Path,
    output: pathlib.Path,
    *,
    flags: Sequence[str] = (),
    inputs: Sequence[pathlib.Path] = (),
) -> list[str]:
    """The control's link with `obj` and `inputs` in place of its Zig object."""
    argv, zig_object = _control_link(paths)
    argv = [str(toolchain.tools.ld_lld), *argv[1:]]
    at = argv.index(zig_object)
    argv[at:at + 1] = [str(obj), *map(str, inputs)]
    out = argv.index("-o")
    argv[out + 1] = str(output)
    argv[out:out] = list(flags)
    return argv


def _zig_cc_argv(
    toolchain: Toolchain,
    inputs: Sequence[pathlib.Path],
    output: pathlib.Path,
    *flags: str,
) -> tuple[str, ...]:
    return (
        str(toolchain.zig),
        "cc",
        "-target",
        TARGET,
        "-O2",
        *ZIG_CC_LINK_FLAGS,
        *flags,
        *map(str, inputs),
        "-o",
        str(output),
        "-lc",
    )


# The control's properties the candidate must match.


def _readelf(toolchain: Toolchain, binary: pathlib.Path, log_path: pathlib.Path, *flags: str) -> str:
    return run_checked(
        (str(toolchain.tools.readelf), *flags, str(binary)),
        cwd=binary.parent,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=log_path,
        require_empty_stderr=True,
    ).stdout


def parse_elf_layout(headers: str, notes: str, sections: str) -> dict[str, object]:
    def field(label: str) -> str | None:
        match = re.search(rf"^\s*{label}:\s+(.+)$", headers, re.MULTILINE)
        return match.group(1).strip() if match else None

    segments = []
    for line in headers.splitlines():
        fields = line.split()
        if fields and fields[0] in _SEGMENT_TYPES and len(fields) >= 8:
            segments.append(
                {
                    "type": fields[0],
                    "vaddr": fields[2],
                    "memsz": fields[5],
                    # Flags sit between the memory size and the alignment.
                    "flags": " ".join(fields[6:-1]),
                }
            )
    stack = next((s for s in segments if s["type"] == "GNU_STACK"), None)
    return {
        "class": field("Class"),
        "type": field("Type"),
        "machine": field("Machine"),
        "abi": field("OS/ABI"),
        "segment_types": [s["type"] for s in segments],
        "first_load_vaddr": next((s["vaddr"] for s in segments if s["type"] == "LOAD"), None),
        "gnu_stack": {"memsz": stack["memsz"], "flags": stack["flags"]} if stack else None,
        "has_interp": any(s["type"] == "INTERP" for s in segments),
        "has_dynamic": any(s["type"] == "DYNAMIC" for s in segments),
        "has_tls": any(s["type"] == "TLS" for s in segments),
        "has_notes": bool(notes.strip()),
        "profile_sections": sorted(set(re.findall(r"__llvm_prf_[a-z]+", sections))),
    }


def read_elf_layout(toolchain: Toolchain, binary: pathlib.Path, log_path: pathlib.Path) -> dict[str, object]:
    stem = log_path.with_suffix("")
    return parse_elf_layout(
        _readelf(toolchain, binary, stem.with_name(f"{stem.name}-headers.json"), "--file-header", "--program-headers", "--wide"),
        _readelf(toolchain, binary, stem.with_name(f"{stem.name}-notes.json"), "--notes"),
        _readelf(toolchain, binary, stem.with_name(f"{stem.name}-sections.json"), "--sections", "--wide"),
    )


def read_control_identity(
    toolchain: Toolchain,
    binary: pathlib.Path,
    log_path: pathlib.Path,
) -> dict[str, object]:
    """The control's ELF layout, as evidence fields."""
    return {"elf_layout": read_elf_layout(toolchain, binary, log_path)}


def control_identity_from_evidence(control: Mapping[str, object]) -> dict[str, object]:
    layout = control.get("elf_layout")
    if not isinstance(layout, dict):
        raise PgsoError("seed control ELF layout is invalid")
    return {"elf_layout": layout}


# The instrumented link.


def link_instrumented(
    toolchain: Toolchain,
    paths: PipelinePaths,
    control: Mapping[str, object],
) -> None:
    # clang adds this reference on Linux; without it the static link drops the
    # runtime's registration and the instrumented binary writes no profile.
    keep_runtime = ("-u", "__llvm_profile_runtime")
    if paths.selector == "fx":
        argv: Sequence[str] = relink_argv(
            toolchain,
            paths,
            paths.instrumented_object,
            paths.instrumented_binary,
            flags=keep_runtime,
            inputs=(toolchain.profile_runtime,),
        )
    else:
        argv = _zig_cc_argv(
            toolchain,
            (paths.instrumented_object, toolchain.profile_runtime),
            paths.instrumented_binary,
            "-Wl,-u,__llvm_profile_runtime",
        )
    run_checked(
        argv,
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-instrumented.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.instrumented_binary, "instrumented executable")
    sections = _readelf(
        toolchain,
        paths.instrumented_binary,
        paths.logs / "instrumented-sections.json",
        "--sections",
        "--wide",
    )
    missing = [section for section in PROFILE_SECTIONS if section not in sections]
    if missing:
        raise PgsoError(f"instrumented executable lacks profile sections: {missing}")


# Profile use and the candidate link.


def public_api_flags(toolchain: Toolchain, paths: PipelinePaths) -> tuple[str, ...]:
    """Every symbol the seed defines stays external: `main` and Zig's weak libc."""
    public = _defined_external_symbols(
        toolchain,
        paths.bitcode,
        paths.logs / "public-api-symbols.json",
    )
    api = paths.logs / "public-api.txt"
    api.write_text("".join(f"{name}\n" for name, _ in public), encoding="utf-8")
    return (f"-internalize-public-api-file={api}",)


def candidate_object_flags(paths: PipelinePaths) -> tuple[str, ...]:
    # lld orders whole sections, so each fx function needs its own.
    return ("-function-sections",) if paths.selector == "fx" else ()


def parse_function_symbols(text: str) -> dict[str, tuple[str, int, int]]:
    """{name: (section index, value, size)} for the defined functions `readelf --symbols` lists."""
    functions: dict[str, tuple[str, int, int]] = {}
    for line in text.splitlines():
        # Num: Value Size Type Bind Vis Ndx Name. Zig names can contain spaces.
        fields = line.split(maxsplit=7)
        if len(fields) < 8 or not fields[0].endswith(":") or fields[3] != "FUNC":
            continue
        if fields[6] in ("UND", "ABS"):
            continue
        key = (fields[6], int(fields[1], 16), int(fields[2]))
        if functions.get(fields[7], key) != key:
            raise PgsoError(f"ambiguous candidate text symbol: {fields[7]}")
        functions[fields[7]] = key
    return functions


def order_symbols(
    order_text: str,
    functions: Mapping[str, tuple[str, int, int]],
) -> tuple[list[str], dict[str, object], set[tuple[str, int]]]:
    """The profile order as candidate symbols, one per function body."""
    names = [line.strip() for line in order_text.splitlines() if line.strip() and not line.startswith("#")]
    ordered: list[str] = []
    seen: set[tuple[str, int]] = set()
    unmapped = 0
    for name in names:
        location = functions.get(name)
        if location is None:
            unmapped += 1
            continue
        if location[:2] not in seen:
            ordered.append(name)
            seen.add(location[:2])
    return ordered, {"profile_functions": len(names), "unmapped_profile_functions": unmapped}, seen


def append_outlined_helpers(
    ordered: Sequence[str],
    functions: Mapping[str, tuple[str, int, int]],
    profile_use_ir: pathlib.Path,
    seen: set[tuple[str, int]],
) -> tuple[list[str], dict[str, int]]:
    """Add each IR-outlined helper after the earliest ordered function that calls it."""
    helpers = {name for name in functions if _OUTLINED_IR_HELPER.fullmatch(name)}
    calls: dict[str, list[str]] = {}
    current = None
    with profile_use_ir.open("r", encoding="utf-8") as stream:
        for line in stream:
            if line.startswith("define "):
                match = _LLVM_FUNCTION_NAME.search(line)
                name = _decode_llvm_identifier(match.group(1)) if match else None
                current = name if name in functions else None
                continue
            if line.rstrip("\n") == "}":
                current = None
                continue
            if current is None:
                continue
            for helper in _OUTLINED_IR_CALL.findall(line):
                if helper in helpers:
                    targets = calls.setdefault(current, [])
                    if helper not in targets:
                        targets.append(helper)
    ranks: dict[str, int] = {}
    for rank, symbol in enumerate(ordered):
        pending = [symbol]
        while pending:
            for helper in calls.get(pending.pop(), ()):
                if helper not in ranks or rank < ranks[helper]:
                    ranks[helper] = rank
                    pending.append(helper)
    result = list(ordered)
    for helper in sorted(helpers, key=lambda name: (ranks.get(name, len(ordered)), name)):
        if functions[helper][:2] not in seen:
            result.append(helper)
            seen.add(functions[helper][:2])
    return result, {"outlined_helpers": len(helpers), "ranked_helpers": len(ranks)}


def removed_sections(linker_stdout: str, obj: pathlib.Path) -> set[str]:
    """The sections of `obj` that `--print-gc-sections` reports removed."""
    removed: set[str] = set()
    for line in linker_stdout.splitlines():
        match = _GC_REMOVED.fullmatch(line.strip())
        if match is None:
            raise PgsoError(f"unexpected linker output: {line}")
        if pathlib.Path(match[1]) == obj:
            removed.add(match[2])
    return removed


def map_addresses(link_map: str, names: Sequence[str]) -> dict[str, int]:
    """The output address of each of `names` that the lld map lists."""
    needed = set(names)
    found: dict[str, int] = {}
    for line in link_map.splitlines():
        # VMA LMA Size Align Symbol; the symbol may contain spaces.
        fields = line.split(maxsplit=4)
        if len(fields) != 5:
            continue
        try:
            address = int(fields[0], 16)
        except ValueError:
            continue
        name = fields[4].strip()
        if name in needed and name not in found:
            found[name] = address
    return found


def check_applied_order(
    ordered: Sequence[str],
    found: Mapping[str, int],
    removed: set[str],
) -> list[str]:
    """The ordered symbols the linker removed, after checking it applied the order."""
    missing = [name for name in ordered if name not in found]
    unexplained = [
        name for name in missing
        if not any(section.endswith("." + name) for section in removed)
    ]
    if unexplained:
        raise PgsoError(f"ordered symbols absent from the link map and not removed: {unexplained[:5]}")
    locations = [found[name] for name in ordered if name in found]
    if not locations or locations != sorted(locations) or len(set(locations)) != len(locations):
        raise PgsoError("linker did not apply the profile function order")
    return missing


def link_order_text(paths: PipelinePaths, profile_order: pathlib.Path) -> str:
    """The startup functions in first-use order, then the profile order.

    The startup exemption removed the cold startup functions' records, so the
    profile order leaves them out.
    """
    _require_nonempty_file(paths.startup_order, "startup function order")
    return paths.startup_order.read_text(encoding="utf-8") + profile_order.read_text(encoding="utf-8")


def _link_ordered_candidate(toolchain: Toolchain, paths: PipelinePaths) -> None:
    order_path = paths.logs / "candidate-profile.order"
    run_checked(
        (str(toolchain.llvm_profdata), "order", str(paths.merged_profile), "-o", str(order_path)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "candidate-profile-order.json",
        require_empty_stderr=True,
    )
    symbols = run_checked(
        (str(toolchain.tools.readelf), "--symbols", "--wide", str(paths.profile_use_object)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=paths.logs / "candidate-object-symbols.json",
        require_empty_stderr=True,
        max_capture_chars=LARGE_OUTPUT_CHARS,
    )
    if symbols.stdout_truncated:
        raise PgsoError("candidate object symbols exceeded the capture limit")
    functions = parse_function_symbols(symbols.stdout)
    ordered, mapping, seen = order_symbols(link_order_text(paths, order_path), functions)
    ordered, helpers = append_outlined_helpers(ordered, functions, paths.profile_use_ir, seen)
    order_file = paths.logs / "candidate-order.txt"
    order_file.write_text("".join(f"{name}\n" for name in ordered), encoding="utf-8")

    link_map = paths.logs / "candidate-link.map"
    argv = relink_argv(
        toolchain,
        paths,
        paths.profile_use_object,
        paths.candidate_binary,
        flags=(
            f"--symbol-ordering-file={order_file}",
            "--icf=none",
            f"-Map={link_map}",
            # lld warns about every ordered symbol it removed; the map check
            # below accounts for each one instead.
            "--no-warn-symbol-ordering",
            "--print-gc-sections",
        ),
    )
    result = run_checked(
        argv,
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-candidate.json",
        require_empty_stderr=True,
        max_capture_chars=LARGE_OUTPUT_CHARS,
    )
    if result.stdout_truncated:
        raise PgsoError("candidate linker output exceeded the capture limit")
    removed = removed_sections(result.stdout, paths.profile_use_object)
    found = map_addresses(link_map.read_text(encoding="utf-8", errors="replace"), ordered)
    linker_removed = check_applied_order(ordered, found, removed)
    layout = {
        "linker": "ld.lld",
        **mapping,
        **helpers,
        "ordered_symbols": len(ordered),
        "ordered_in_map": len(ordered) - len(linker_removed),
        "linker_removed_symbols": linker_removed,
        "removed_sections": len(removed),
        "order_sha256": sha256_file(order_file),
        "link_map_sha256": sha256_file(link_map),
    }
    (paths.logs / "candidate-layout.json").write_text(
        json.dumps(layout, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def link_candidate_binary(toolchain: Toolchain, paths: PipelinePaths) -> None:
    """Link the candidate from `paths.profile_use_object`; both links strip with `-s`."""
    if paths.selector == "fx":
        _link_ordered_candidate(toolchain, paths)
    else:
        run_checked(
            _zig_cc_argv(toolchain, (paths.profile_use_object,), paths.candidate_binary, "-s"),
            cwd=paths.root,
            env=os.environ.copy(),
            timeout_s=900,
            log_path=paths.logs / "link-candidate.json",
            require_empty_stderr=True,
        )
    _require_nonempty_file(paths.candidate_binary, "candidate executable")


def inspect_candidate(
    toolchain: Toolchain,
    paths: PipelinePaths,
    control: Mapping[str, object],
) -> CandidateMetadata:
    """The candidate's ELF layout, checked against the control's."""
    layout = read_elf_layout(toolchain, paths.candidate_binary, paths.logs / "candidate-elf.json")
    expected = control["elf_layout"]
    if not isinstance(expected, dict):
        raise PgsoError("control ELF layout is invalid")
    if layout["profile_sections"]:
        raise PgsoError("candidate retains an LLVM profile section")
    differences = {
        key: (expected.get(key), layout.get(key))
        for key in sorted(set(expected) | set(layout))
        if expected.get(key) != layout.get(key)
    }
    if differences:
        raise PgsoError(f"candidate ELF layout differs from the control: {differences}")
    return CandidateMetadata(layout=layout)


def candidate_evidence(metadata: CandidateMetadata) -> dict[str, object]:
    return {"elf_layout": metadata.layout}
