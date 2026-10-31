"""The macOS arm64 PGSO platform: Apple's tools, Mach-O links, and checks.

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
from collections.abc import Mapping, Sequence

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import (
    _LLVM_FUNCTION_NAME,
    _OUTLINED_IR_CALL,
    PipelinePaths,
    _decode_llvm_identifier,
    _discover_compiler_runtime,
    _extract_compiler_runtime,
    _require_nonempty_file,
    parse_compiler_runtime,
    validate_archive_unchanged,
)
from scripts.pgso.runner import CommandResult, run_checked
from scripts.pgso.toolchain import Toolchain, _capture, _resolve_executable

TARGET = "aarch64-macos"
DISPLAY_NAME = "macOS arm64"
HOST_ARCH = "arm64"
LIBLLVM_NAME = "libLLVM.dylib"
# The candidate may be at most this size, and needs 0.250 MiB of headroom
# below it, which leaves about 140 KB of growth above a 5.61 MiB build.
SIZE_CEILING_MIB = 6.000
# The ordinary control build already records everything the links reuse.
CONTROL_BUILD_FLAGS: tuple[str, ...] = ()
# Apple ld's dead-code stripping for `zig cc` links.
ZIG_CC_LINK_FLAGS = ("-Wl,-dead_strip",)
STARTUP_SCENARIOS: tuple[str, ...] = ()


def external_control_strip_argv(
    toolchain: Toolchain, binary: pathlib.Path
) -> tuple[str, ...]:
    return (str(toolchain.tools.strip), "-S", "-x", str(binary))


@dataclasses.dataclass(frozen=True)
class Tools:
    apple_ld: pathlib.Path
    apple_ld_version: str
    strip: pathlib.Path
    codesign: pathlib.Path
    otool: pathlib.Path
    xcrun: pathlib.Path
    sdk: pathlib.Path
    sdk_version: str
    zig_darwin_sdk: pathlib.Path
    zig_sdk_version: str


def check_host() -> str:
    """The host architecture, after checking the host can build and run the target."""
    if platform.system() != "Darwin":
        raise PgsoError("PGSO requires a Darwin host")
    host_arch = platform.machine()
    if host_arch != HOST_ARCH:
        raise PgsoError("PGSO requires an arm64 host")
    return host_arch


def _zig_darwin_sdk(zig: pathlib.Path) -> tuple[pathlib.Path, str]:
    output = _capture((str(zig), "env"), "Zig environment")
    matches = re.findall(r'^\s*\.lib_dir = ("(?:[^"\\]|\\.)*"),\s*$', output, re.MULTILINE)
    if len(matches) != 1:
        raise PgsoError("Zig environment must contain one lib_dir")
    try:
        lib_dir = pathlib.Path(json.loads(matches[0]))
    except (ValueError, TypeError) as error:
        raise PgsoError("invalid Zig library directory") from error
    if not lib_dir.is_absolute():
        raise PgsoError("Zig library directory must be absolute")
    sdk = (lib_dir / "libc" / "darwin").resolve()
    stub = sdk / "libSystem.tbd"
    if not stub.is_file() or stub.stat().st_size == 0:
        raise PgsoError(f"missing Zig libSystem stub: {stub}")
    try:
        settings = json.loads((sdk / "SDKSettings.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PgsoError("could not read Zig Darwin SDK settings") from error
    version = settings.get("MinimalDisplayName") if isinstance(settings, dict) else None
    if not isinstance(version, str) or re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version) is None:
        raise PgsoError("invalid Zig Darwin SDK version")
    return sdk, version


def discover_tools(zig_path: pathlib.Path, clang: pathlib.Path) -> tuple[Tools, pathlib.Path]:
    """Apple's linker, signing, and inspection tools, and the LLVM profile runtime."""
    strip = _resolve_executable("strip", "strip")
    codesign = _resolve_executable("codesign", "codesign")
    otool = _resolve_executable("otool", "otool")
    xcrun = _resolve_executable("xcrun", "xcrun")
    apple_ld = _resolve_executable(
        _capture((str(xcrun), "--find", "ld"), "Apple linker path"),
        "Apple linker",
    )
    try:
        details = json.loads(_capture((str(apple_ld), "-version_details"), "Apple linker version"))
    except ValueError as error:
        raise PgsoError("invalid Apple linker version details") from error
    apple_ld_version = details.get("version") if isinstance(details, dict) else None
    if not isinstance(apple_ld_version, str) or re.fullmatch(r"\d+(?:\.\d+)*", apple_ld_version) is None:
        raise PgsoError("invalid Apple linker version")
    architectures = details.get("architectures")
    if not isinstance(architectures, list) or "arm64" not in architectures:
        raise PgsoError("Apple linker does not support arm64")
    zig_darwin_sdk, zig_sdk_version = _zig_darwin_sdk(zig_path)

    sdk_output = _capture(
        (str(xcrun), "--sdk", "macosx", "--show-sdk-path"),
        "macOS SDK path",
    )
    sdk = pathlib.Path(sdk_output).expanduser().resolve()
    if not sdk.is_dir():
        raise PgsoError(f"macOS SDK does not exist: {sdk}")
    sdk_version = _capture(
        (str(xcrun), "--sdk", "macosx", "--show-sdk-version"),
        "macOS SDK version",
    )
    if re.fullmatch(r"\d+\.\d+(?:\.\d+)?", sdk_version) is None:
        raise PgsoError(f"invalid macOS SDK version: {sdk_version}")

    resource_output = _capture(
        (str(clang), "--print-resource-dir"),
        "clang resource directory",
    )
    resource_dir = pathlib.Path(resource_output).expanduser().resolve()
    profile_runtime = (
        resource_dir / "lib" / "darwin" / "libclang_rt.profile_osx.a"
    )
    if not profile_runtime.is_file() or profile_runtime.stat().st_size == 0:
        raise PgsoError(
            f"missing LLVM profile runtime: {profile_runtime}"
        )

    return (
        Tools(
            apple_ld=apple_ld,
            apple_ld_version=apple_ld_version,
            strip=strip,
            codesign=codesign,
            otool=otool,
            xcrun=xcrun,
            sdk=sdk,
            sdk_version=sdk_version,
            zig_darwin_sdk=zig_darwin_sdk,
            zig_sdk_version=zig_sdk_version,
        ),
        profile_runtime,
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
        str(toolchain.tools.sdk),
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
        *ZIG_CC_LINK_FLAGS,
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
        str(toolchain.tools.apple_ld),
        "-arch",
        "arm64",
        "-platform_version",
        "macos",
        contract.min_macos,
        contract.sdk_version,
        "-stack_size",
        format(contract.stack_size, "x"),
        "-syslibroot",
        str(toolchain.tools.sdk),
        "-dead_strip",
        "-e",
        "_main",
        "-no_deduplicate",
        "-no_function_starts",
        # fx builds without unwind tables; newer ld otherwise emits ~160 KB.
        "-no_compact_unwind",
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


_OUTLINED_IR_SYMBOL = re.compile(
    r"_outlined_ir_func_[0-9]+(?:\.[0-9]+)?"
)


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


def _link_temporal_candidate(toolchain: Toolchain, paths: PipelinePaths) -> None:
    _require_nonempty_file(paths.merged_profile, "temporal production profile")
    _require_nonempty_file(paths.control_binary, "ReleaseSafe control")
    contract = read_macos_link_contract(
        toolchain,
        paths.control_binary,
        paths.logs / "link-control-macos.json",
    )
    if _version_tuple(toolchain.tools.zig_sdk_version) != _version_tuple(contract.sdk_version):
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
    system_stub = toolchain.tools.zig_darwin_sdk / "libSystem.tbd"
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
        "linker_version": toolchain.tools.apple_ld_version,
        "minimum_macos": contract.min_macos,
        "sdk_version": contract.sdk_version,
        "main_stack_size": contract.stack_size,
        "dependencies": contract.dylibs,
        "sysroot_sdk_version": toolchain.tools.sdk_version,
        "sysroot": str(toolchain.tools.sdk),
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
        (str(toolchain.tools.otool), "-l", str(binary)),
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
        (str(toolchain.tools.otool), "-l", str(binary)),
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


# The platform functions the shared pipeline calls (scripts/pgso/platforms.py).


def read_control_identity(
    toolchain: Toolchain,
    binary: pathlib.Path,
    log_path: pathlib.Path,
) -> dict[str, str]:
    """The control's properties the candidate must match, as evidence fields."""
    return {"minimum_macos": read_macos_minos(toolchain, binary, log_path)}


def control_identity_from_evidence(control: Mapping[str, object]) -> dict[str, str]:
    minimum_macos = control.get("minimum_macos")
    if not isinstance(minimum_macos, str):
        raise PgsoError("seed control minimum macOS is invalid")
    return {"minimum_macos": minimum_macos}


def link_instrumented(
    toolchain: Toolchain,
    paths: PipelinePaths,
    control: Mapping[str, str],
) -> None:
    archive = _discover_compiler_runtime(toolchain, paths)
    compiler_runtime_object = _extract_compiler_runtime(toolchain, archive, paths)
    run_checked(
        instrumented_link_argv(
            toolchain,
            paths,
            compiler_runtime_object,
            control["minimum_macos"],
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "link-instrumented.json",
        require_empty_stderr=True,
    )
    _require_nonempty_file(paths.instrumented_binary, "instrumented executable")

    load_commands = run_checked(
        (str(toolchain.tools.otool), "-l", str(paths.instrumented_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "instrumented-load-commands.json",
        require_empty_stderr=True,
    )
    validate_profile_section_alignment(load_commands.stdout)
    run_checked(
        (
            str(toolchain.tools.codesign),
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


def record_control_build(toolchain: Toolchain, result: CommandResult, paths: PipelinePaths) -> None:
    """Nothing to record: the macOS links rebuild their own commands."""


def candidate_object_flags(paths: PipelinePaths) -> tuple[str, ...]:
    return ()


def os_versions(paths: PipelinePaths) -> dict[str, str]:
    result = run_checked(
        ("sw_vers", "-productVersion"),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=30,
        log_path=paths.logs / "macos-version.json",
        require_empty_stderr=True,
    )
    return {"macos_version": result.stdout.strip()}


def public_api_flags(toolchain: Toolchain, paths: PipelinePaths) -> tuple[str, ...]:
    """The symbols the outlined-IR cleanup keeps external."""
    return ("-internalize-public-api-list=main,_mh_execute_header",)


def link_candidate_binary(toolchain: Toolchain, paths: PipelinePaths) -> None:
    """Link, strip, and sign the candidate from `paths.profile_use_object`."""
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
            str(toolchain.tools.strip),
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
            str(toolchain.tools.codesign),
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


def inspect_candidate(
    toolchain: Toolchain,
    paths: PipelinePaths,
    control: Mapping[str, str],
) -> CandidateMetadata:
    """The candidate's signature and Mach-O layout, checked against the control's."""
    run_checked(
        (
            str(toolchain.tools.codesign),
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
        (str(toolchain.tools.otool), "-hv", str(paths.candidate_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "candidate-header.json",
        require_empty_stderr=True,
    )
    load_commands = run_checked(
        (str(toolchain.tools.otool), "-l", str(paths.candidate_binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=paths.logs / "candidate-load-commands.json",
        require_empty_stderr=True,
    )
    dependencies = run_checked(
        (str(toolchain.tools.otool), "-L", str(paths.candidate_binary)),
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
        metadata,
        expected_minos=control["minimum_macos"],
        expected_contract=expected_contract,
    )
    return metadata


def candidate_evidence(metadata: CandidateMetadata) -> dict[str, object]:
    return {
        "architecture": metadata.architecture,
        "minimum_macos": metadata.min_macos,
        "signature_valid": metadata.signature_valid,
    }
