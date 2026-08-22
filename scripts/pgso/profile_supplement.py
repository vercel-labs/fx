"""Build hash-safe PGO supplements from dedicated workload profiles."""

from __future__ import annotations

import dataclasses
import os
import pathlib
import re
import uuid
from collections.abc import Sequence

from scripts.pgso.model import PgsoError
from scripts.pgso.runner import run_checked
from scripts.pgso.toolchain import Toolchain


PROFILE_SUMMARY_CUTOFF_COLD = 600_000
SUPPLEMENT_COLD_THRESHOLD_MULTIPLIER = 2


@dataclasses.dataclass(frozen=True)
class ProfileRecord:
    name: str
    function_hash: int
    counters: tuple[int, ...]
    lines: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class ProfileSupplement:
    text: str
    function_names: tuple[str, ...]
    total_counter_value: int


@dataclasses.dataclass(frozen=True)
class MappedProfile:
    text: str
    compatible_function_names: tuple[str, ...]
    total_counter_value: int


def _ir_function_attributes(ir_text: str) -> dict[str, str]:
    attributes: dict[str, str] = {}
    definitions: list[tuple[str, str]] = []
    for line in ir_text.splitlines():
        attribute = re.match(r"^attributes #(\d+) = \{(.*)\}$", line)
        if attribute is not None:
            attributes[attribute.group(1)] = attribute.group(2)
            continue
        if not line.startswith("define "):
            continue
        name_match = re.search(r'@(?:"([^"]+)"|([^ (]+))\(', line)
        attribute_match = re.search(r" #(\d+)(?: [^{]*)? \{$", line)
        if name_match is None or attribute_match is None:
            raise PgsoError("could not parse function definition in profile-use IR")
        name = name_match.group(1) or name_match.group(2)
        definitions.append((name, attribute_match.group(1)))

    functions: dict[str, str] = {}
    for name, attribute_id in definitions:
        value = attributes.get(attribute_id)
        if value is None:
            raise PgsoError(
                f"profile-use IR is missing function attributes #{attribute_id}"
            )
        functions[name] = value
    return functions


def speed_shaped_functions(
    ir_text: str,
    allowed_prefixes: Sequence[str],
) -> tuple[str, ...]:
    if not allowed_prefixes or any(not prefix for prefix in allowed_prefixes):
        raise PgsoError("profile supplement requires nonempty function prefixes")
    selected = [
        name
        for name, attributes in _ir_function_attributes(ir_text).items()
        if any(name.startswith(prefix) for prefix in allowed_prefixes)
        and "minsize" not in attributes.split()
    ]
    if not selected:
        raise PgsoError("workload profile produced no speed-shaped functions")
    return tuple(selected)


def verify_supplement_functions(
    ir_text: str,
    profile_names: Sequence[str],
    *,
    production_module: str,
) -> dict[str, str]:
    if not profile_names:
        raise PgsoError("profile supplement contains no functions to verify")
    module_prefix = f"{production_module};"
    functions = _ir_function_attributes(ir_text)
    evidence: dict[str, str] = {}
    for profile_name in profile_names:
        if not profile_name.startswith(module_prefix):
            raise PgsoError(
                f"supplement function has the wrong module: {profile_name}"
            )
        function_name = profile_name[len(module_prefix) :]
        attributes = functions.get(function_name)
        if attributes is None:
            evidence[function_name] = "optimized_away"
        elif "minsize" in attributes.split():
            raise PgsoError(
                f"supplement function remained size-shaped: {function_name}"
            )
        else:
            evidence[function_name] = "speed"
    return evidence


def _parse_record(block: str) -> ProfileRecord:
    lines = tuple(block.splitlines())
    if len(lines) < 6 or lines[1] != "# Func Hash:":
        raise PgsoError("malformed text instrumentation profile record")
    if lines[3] != "# Num Counters:" or lines[5] != "# Counter Values:":
        raise PgsoError("malformed text instrumentation profile counters")
    try:
        function_hash = int(lines[2])
        counter_count = int(lines[4])
        counters = tuple(int(value) for value in lines[6 : 6 + counter_count])
    except ValueError as error:
        raise PgsoError("invalid integer in text instrumentation profile") from error
    if counter_count <= 0 or len(counters) != counter_count:
        raise PgsoError("text instrumentation profile counter count mismatch")
    return ProfileRecord(
        name=lines[0],
        function_hash=function_hash,
        counters=counters,
        lines=lines,
    )


def _parse_profile(text: str) -> tuple[ProfileRecord, ...]:
    header = "# IR level Instrumentation Flag\n:ir\n"
    if not text.startswith(header):
        raise PgsoError("expected an IR-level text instrumentation profile")
    blocks = tuple(
        block for block in text[len(header) :].strip().split("\n\n") if block
    )
    records = tuple(_parse_record(block) for block in blocks)
    if not records:
        raise PgsoError("text instrumentation profile contains no functions")
    names = tuple(record.name for record in records)
    if len(names) != len(set(names)):
        raise PgsoError("text instrumentation profile contains duplicate functions")
    return records


def _cold_counter_threshold(records: Sequence[ProfileRecord]) -> int:
    counters = sorted(
        (value for record in records for value in record.counters),
        reverse=True,
    )
    total = sum(counters)
    if total <= 0:
        raise PgsoError("production instrumentation profile has no counter data")
    target = (
        total * PROFILE_SUMMARY_CUTOFF_COLD + 999_999
    ) // 1_000_000
    accumulated = 0
    for value in counters:
        accumulated += value
        if accumulated >= target:
            return value
    raise PgsoError("could not derive the production profile cold cutoff")


def _normalized_record_lines(
    record: ProfileRecord,
    destination_name: str,
    maximum_counter: int,
) -> tuple[tuple[str, ...], int]:
    source_maximum = max(record.counters)
    if source_maximum == maximum_counter:
        counters = record.counters
    else:
        counters = tuple(
            0
            if value == 0
            else max(1, value * maximum_counter // source_maximum)
            for value in record.counters
        )
    counter_count = len(record.counters)
    lines = (
        destination_name,
        *record.lines[1:6],
        *(str(value) for value in counters),
        *record.lines[6 + counter_count :],
    )
    return lines, sum(counters)


def extract_compatible_profile(
    production_text: str,
    benchmark_text: str,
    *,
    source_module: str,
    destination_module: str,
    allowed_prefixes: Sequence[str],
    speed_functions: Sequence[str],
) -> ProfileSupplement:
    if not source_module or ";" in source_module:
        raise PgsoError("invalid benchmark profile module name")
    if not destination_module or ";" in destination_module:
        raise PgsoError("invalid production profile module name")
    if not allowed_prefixes or any(not prefix for prefix in allowed_prefixes):
        raise PgsoError("profile supplement requires nonempty function prefixes")
    if not speed_functions:
        raise PgsoError("profile supplement requires speed-shaped functions")
    speed_function_set = set(speed_functions)

    production_records = _parse_profile(production_text)
    production = {record.name: record for record in production_records}
    maximum_counter = (
        _cold_counter_threshold(production_records)
        * SUPPLEMENT_COLD_THRESHOLD_MULTIPLIER
    )
    source_prefix = f"{source_module};"
    destination_prefix = f"{destination_module};"
    selected: list[tuple[ProfileRecord, str]] = []
    total_counter_value = 0
    for record in _parse_profile(benchmark_text):
        if not record.name.startswith(source_prefix):
            continue
        function_name = record.name[len(source_prefix) :]
        if not any(function_name.startswith(prefix) for prefix in allowed_prefixes):
            continue
        if function_name not in speed_function_set:
            continue
        destination_name = destination_prefix + function_name
        destination = production.get(destination_name)
        if destination is None:
            continue
        if (
            destination.function_hash != record.function_hash
            or len(destination.counters) != len(record.counters)
        ):
            continue
        normalized_lines, counter_value = _normalized_record_lines(
            record,
            destination_name,
            maximum_counter,
        )
        if counter_value == 0:
            continue
        selected.append(
            (
                dataclasses.replace(record, lines=normalized_lines),
                destination_name,
            )
        )
        total_counter_value += counter_value

    if not selected:
        raise PgsoError("workload profile has no compatible nonzero functions")

    blocks: list[str] = []
    names: list[str] = []
    for record, destination_name in selected:
        names.append(destination_name)
        blocks.append("\n".join((destination_name, *record.lines[1:])))
    return ProfileSupplement(
        text=(
            "# IR level Instrumentation Flag\n:ir\n"
            + "\n\n".join(blocks)
            + "\n"
        ),
        function_names=tuple(names),
        total_counter_value=total_counter_value,
    )


def map_production_profile(
    production_text: str,
    benchmark_text: str,
    *,
    source_module: str,
    destination_module: str,
) -> MappedProfile:
    if not source_module or ";" in source_module:
        raise PgsoError("invalid production profile module name")
    if not destination_module or ";" in destination_module:
        raise PgsoError("invalid benchmark profile module name")
    production_records = _parse_profile(production_text)
    benchmark_records = _parse_profile(benchmark_text)
    benchmark = {record.name: record for record in benchmark_records}
    source_prefix = f"{source_module};"
    destination_prefix = f"{destination_module};"
    compatible: list[str] = []
    blocks: list[str] = []
    for index, record in enumerate(production_records):
        function_name = (
            record.name[len(source_prefix) :]
            if record.name.startswith(source_prefix)
            else ""
        )
        destination_name = destination_prefix + function_name
        destination = benchmark.get(destination_name)
        if (
            function_name
            and destination is not None
            and destination.function_hash == record.function_hash
            and len(destination.counters) == len(record.counters)
        ):
            compatible.append(function_name)
        else:
            destination_name = (
                f"{destination_prefix}__fx_profile_summary."
                f"{index}.{record.function_hash}"
            )
        blocks.append("\n".join((destination_name, *record.lines[1:])))
    return MappedProfile(
        text=(
            "# IR level Instrumentation Flag\n:ir\n"
            + "\n\n".join(blocks)
            + "\n"
        ),
        compatible_function_names=tuple(compatible),
        total_counter_value=sum(
            sum(record.counters) for record in production_records
        ),
    )


def _dump_profile_text(
    toolchain: Toolchain,
    profile: pathlib.Path,
    destination: pathlib.Path,
    *,
    label: str,
    log_dir: pathlib.Path,
) -> None:
    run_checked(
        (
            str(toolchain.llvm_profdata),
            "merge",
            "-text",
            str(profile),
            "-o",
            str(destination),
        ),
        cwd=destination.parent,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=log_dir / f"{label}-profile-text.json",
        require_empty_stderr=True,
    )
    if not destination.is_file() or destination.stat().st_size == 0:
        raise PgsoError(f"{label} text profile is missing: {destination}")


def create_profile_supplement(
    toolchain: Toolchain,
    *,
    production_profile: pathlib.Path,
    benchmark_profile: pathlib.Path,
    benchmark_ir: pathlib.Path,
    output_text: pathlib.Path,
    source_module: str,
    destination_module: str,
    allowed_prefixes: Sequence[str],
    log_dir: pathlib.Path,
) -> ProfileSupplement:
    for path, label in (
        (production_profile, "production profile"),
        (benchmark_profile, "benchmark profile"),
        (benchmark_ir, "benchmark profile-use IR"),
    ):
        if not path.is_file() or path.stat().st_size == 0:
            raise PgsoError(f"{label} is missing or empty: {path}")
    output_text.parent.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    production_text = output_text.with_suffix(".production.txt")
    benchmark_text = output_text.with_suffix(".benchmark.txt")
    for profile, destination, label in (
        (production_profile, production_text, "production"),
        (benchmark_profile, benchmark_text, "benchmark"),
    ):
        _dump_profile_text(
            toolchain,
            profile,
            destination,
            label=label,
            log_dir=log_dir,
        )

    try:
        speed_functions = speed_shaped_functions(
            benchmark_ir.read_text(encoding="utf-8", errors="replace"),
            allowed_prefixes,
        )
        supplement = extract_compatible_profile(
            production_text.read_text(encoding="utf-8"),
            benchmark_text.read_text(encoding="utf-8"),
            source_module=source_module,
            destination_module=destination_module,
            allowed_prefixes=allowed_prefixes,
            speed_functions=speed_functions,
        )
        output_text.write_text(supplement.text, encoding="utf-8")
        return supplement
    finally:
        production_text.unlink(missing_ok=True)
        benchmark_text.unlink(missing_ok=True)


def create_mapped_benchmark_profile(
    toolchain: Toolchain,
    *,
    production_profile: pathlib.Path,
    benchmark_profile: pathlib.Path,
    output_text: pathlib.Path,
    output_profile: pathlib.Path,
    source_module: str,
    destination_module: str,
    log_dir: pathlib.Path,
) -> MappedProfile:
    for path, label in (
        (production_profile, "production profile"),
        (benchmark_profile, "benchmark profile"),
    ):
        if not path.is_file() or path.stat().st_size == 0:
            raise PgsoError(f"{label} is missing or empty: {path}")
    output_text.parent.mkdir(parents=True, exist_ok=True)
    output_profile.parent.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    production_text = output_text.with_suffix(".production.txt")
    benchmark_text = output_text.with_suffix(".benchmark.txt")
    for profile, destination, label in (
        (production_profile, production_text, "production"),
        (benchmark_profile, benchmark_text, "benchmark"),
    ):
        _dump_profile_text(
            toolchain,
            profile,
            destination,
            label=label,
            log_dir=log_dir,
        )
    temporary = output_profile.with_name(
        f".{output_profile.name}.{uuid.uuid4().hex}.tmp"
    )
    try:
        mapped = map_production_profile(
            production_text.read_text(encoding="utf-8"),
            benchmark_text.read_text(encoding="utf-8"),
            source_module=source_module,
            destination_module=destination_module,
        )
        output_text.write_text(mapped.text, encoding="utf-8")
        run_checked(
            (
                str(toolchain.llvm_profdata),
                "merge",
                str(output_text),
                "-o",
                str(temporary),
            ),
            cwd=output_profile.parent,
            env=os.environ.copy(),
            timeout_s=300,
            log_path=log_dir / "map-profile.json",
            require_empty_stderr=True,
        )
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise PgsoError(
                f"mapped benchmark profile is missing: {temporary}"
            )
        os.replace(temporary, output_profile)
        return mapped
    finally:
        temporary.unlink(missing_ok=True)
        production_text.unlink(missing_ok=True)
        benchmark_text.unlink(missing_ok=True)


def merge_profile_supplement(
    toolchain: Toolchain,
    *,
    production_profile: pathlib.Path,
    supplement_text: pathlib.Path,
    log_path: pathlib.Path,
) -> None:
    temporary = production_profile.with_name(
        f".{production_profile.name}.{uuid.uuid4().hex}.tmp"
    )
    run_checked(
        (
            str(toolchain.llvm_profdata),
            "merge",
            str(production_profile),
            str(supplement_text),
            "-o",
            str(temporary),
        ),
        cwd=production_profile.parent,
        env=os.environ.copy(),
        timeout_s=300,
        log_path=log_path,
        require_empty_stderr=True,
    )
    if not temporary.is_file() or temporary.stat().st_size == 0:
        raise PgsoError(f"merged production profile is missing: {temporary}")
    os.replace(temporary, production_profile)
