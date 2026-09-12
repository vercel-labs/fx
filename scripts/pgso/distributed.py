"""Distributed PGSO qualification primitives."""

from __future__ import annotations

import dataclasses
import argparse
import json
import os
import pathlib
import re
import shutil
import sys
import uuid
from collections.abc import Mapping, Sequence

from scripts.pgso.corpus import (
    Corpus,
    CorpusRunError,
    Scenario,
    load_corpus,
    run_behavior_corpus,
    run_corpus,
)
from scripts.pgso.model import (
    BuildIdentity,
    PgsoError,
    sha256_file,
    verify_identity,
)
from scripts.pgso.pipeline import (
    GENERATION_FLAGS,
    ArtifactSpec,
    PipelinePaths,
    apply_profile,
    emit_bitcode,
    link_candidate,
    merge_profile_batch,
    verify_candidate,
)
from scripts.pgso.qualify import (
    BENCHMARK_PLANS,
    STARTUP_COMMANDS,
    STARTUP_MINIMUM_SAMPLES,
    BenchmarkPair,
    build_profile_linked_benchmarks,
    measure_heavy_workloads,
    measure_startup,
    measurement_payload,
    profile_linked_benchmark_evidence,
    relink_profile_linked_benchmarks,
    require_measurements_passed,
)
from scripts.pgso.runner import cancellation_guard, run_checked
from scripts.pgso.toolchain import SUPPORTED_TARGET, Toolchain


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO_ROOT / "scripts" / "pgso" / "corpus.json"
REQUIRED_BUN_VERSION = "1.3.14"
REQUIRED_HYPERFINE_VERSION = "1.20.0"


@dataclasses.dataclass(frozen=True)
class ShardPlan:
    shard_id: str
    scenario_names: tuple[str, ...]
    weight: float


def plan_shards(
    scenarios: Sequence[Scenario],
    *,
    maximum_shards: int,
    prefix: str,
) -> tuple[ShardPlan, ...]:
    if maximum_shards <= 0:
        raise PgsoError("maximum shard count must be positive")
    if re.fullmatch(r"[a-z][a-z0-9-]*", prefix) is None:
        raise PgsoError(f"invalid shard prefix: {prefix!r}")
    if not scenarios:
        raise PgsoError("cannot shard an empty scenario collection")
    names = [scenario.name for scenario in scenarios]
    if len(names) != len(set(names)):
        raise PgsoError("cannot shard duplicate scenario names")

    shard_count = min(maximum_shards, len(scenarios))
    assignments: list[list[Scenario]] = [[] for _ in range(shard_count)]
    weights = [0.0] * shard_count
    ordered = sorted(
        scenarios,
        key=lambda scenario: (-scenario.timeout_seconds, scenario.name),
    )
    for scenario in ordered:
        shard_index = min(range(shard_count), key=lambda index: (weights[index], index))
        assignments[shard_index].append(scenario)
        weights[shard_index] += scenario.timeout_seconds

    width = max(2, len(str(shard_count)))
    return tuple(
        ShardPlan(
            shard_id=f"{prefix}-{index + 1:0{width}d}",
            scenario_names=tuple(scenario.name for scenario in assignment),
            weight=weights[index],
        )
        for index, assignment in enumerate(assignments)
    )


def matrix_payload(shards: Sequence[ShardPlan]) -> dict[str, object]:
    if not shards or any(not shard.scenario_names for shard in shards):
        raise PgsoError("shard matrix cannot contain empty jobs")
    return {
        "include": [
            {
                "id": shard.shard_id,
                "scenarios": ",".join(shard.scenario_names),
            }
            for shard in shards
        ]
    }


def select_corpus(
    corpus: Corpus,
    phase: str,
    scenario_names: Sequence[str],
) -> Corpus:
    if phase == "training":
        available = corpus.scenarios
    elif phase == "behavior":
        available = corpus.candidate_scenarios
    else:
        raise PgsoError(f"unsupported corpus phase: {phase}")
    if not scenario_names:
        raise PgsoError(f"{phase} shard has no assigned scenarios")
    if len(scenario_names) != len(set(scenario_names)):
        raise PgsoError(f"duplicate assigned scenario in {phase} shard")
    by_name = {scenario.name: scenario for scenario in available}
    unknown = sorted(set(scenario_names) - set(by_name))
    if unknown:
        raise PgsoError(
            f"unknown {phase} scenario: " + ", ".join(unknown)
        )
    requested = set(scenario_names)
    selected = tuple(
        scenario for scenario in available if scenario.name in requested
    )
    return Corpus(
        repo_root=corpus.repo_root,
        manifest_path=corpus.manifest_path,
        manifest_sha256=corpus.manifest_sha256,
        scenarios=selected,
        intentional_exclusions=corpus.intentional_exclusions,
        verification_scenarios=(),
    )


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict) or not all(
        isinstance(key, str) for key in value
    ):
        raise PgsoError(f"{label} must be an object")
    return value


def identity_from_mapping(value: object) -> BuildIdentity:
    mapping = _mapping(value, "build identity")
    flags = mapping.get("generation_flags")
    if not isinstance(flags, (list, tuple)) or not all(
        isinstance(flag, str) for flag in flags
    ):
        raise PgsoError("build identity generation_flags must be strings")
    fields = (
        "source_sha",
        "target",
        "host_arch",
        "zig_version",
        "llvm_version",
        "bitcode_sha256",
        "corpus_sha256",
        "update_channel",
    )
    values: dict[str, str] = {}
    for field in fields:
        item = mapping.get(field)
        if not isinstance(item, str) or not item:
            raise PgsoError(f"build identity {field} must be a nonempty string")
        values[field] = item
    return BuildIdentity(
        **values,
        generation_flags=tuple(flags),
    )


def validate_seed_identity(identity: BuildIdentity) -> None:
    if identity.target != SUPPORTED_TARGET or identity.host_arch != "arm64":
        raise PgsoError("seed identity is not native macOS arm64")
    if identity.update_channel != "stable":
        raise PgsoError("seed identity must use the stable update channel")
    if identity.generation_flags != GENERATION_FLAGS:
        raise PgsoError("seed identity has unexpected profile generation flags")


def aggregate_scenario_shards(
    documents: Sequence[Mapping[str, object]],
    *,
    phase: str,
    expected_names: Sequence[str],
    expected_identity: BuildIdentity,
    expected_artifact_sha256: str,
) -> dict[str, object]:
    if not documents:
        raise PgsoError(f"no {phase} shard evidence found")
    expected = tuple(expected_names)
    expected_set = set(expected)
    if len(expected) != len(expected_set):
        raise PgsoError(f"expected {phase} scenarios contain duplicates")

    shard_ids: set[str] = set()
    combined: dict[str, Mapping[str, object]] = {}
    merged_raw_profiles = 0
    for raw_document in documents:
        document = _mapping(raw_document, f"{phase} shard evidence")
        if document.get("schema_version") != 1:
            raise PgsoError(f"unsupported {phase} shard schema")
        if document.get("phase") != phase:
            raise PgsoError(f"unexpected shard phase: {document.get('phase')!r}")
        if document.get("status") != "passed":
            raise PgsoError(f"{phase} shard did not pass")
        shard_id = document.get("shard_id")
        if not isinstance(shard_id, str) or not shard_id:
            raise PgsoError(f"{phase} shard ID must be a nonempty string")
        if shard_id in shard_ids:
            raise PgsoError(f"duplicate {phase} shard ID: {shard_id}")
        shard_ids.add(shard_id)

        verify_identity(expected_identity, identity_from_mapping(document.get("identity")))
        if document.get("artifact_sha256") != expected_artifact_sha256:
            raise PgsoError(f"{phase} artifact hash mismatch: {shard_id}")

        assigned = document.get("assigned_scenarios")
        if not isinstance(assigned, list) or not assigned or not all(
            isinstance(name, str) and name for name in assigned
        ):
            raise PgsoError(f"{phase} shard assignment is invalid: {shard_id}")
        if len(assigned) != len(set(assigned)):
            raise PgsoError(f"duplicate {phase} scenario within shard: {shard_id}")

        result = _mapping(document.get("result"), f"{phase} shard result")
        raw_results = result.get("results")
        if not isinstance(raw_results, list):
            raise PgsoError(f"{phase} shard results must be a list: {shard_id}")
        result_by_name: dict[str, Mapping[str, object]] = {}
        for value in raw_results:
            item = _mapping(value, f"{phase} scenario result")
            name = item.get("name")
            if not isinstance(name, str) or not name:
                raise PgsoError(f"{phase} scenario result has an invalid name")
            if name in result_by_name:
                raise PgsoError(f"duplicate {phase} scenario result: {name}")
            if item.get("status") != "passed":
                raise PgsoError(f"{phase} scenario did not pass: {name}")
            result_by_name[name] = item
        if set(assigned) != set(result_by_name):
            raise PgsoError(f"{phase} shard result does not match assignment: {shard_id}")
        if (
            result.get("passed") != len(assigned)
            or result.get("failed") != 0
            or result.get("skipped") != 0
        ):
            raise PgsoError(f"{phase} shard summary is inconsistent: {shard_id}")
        for name, item in result_by_name.items():
            if name in combined:
                raise PgsoError(f"duplicate {phase} scenario: {name}")
            combined[name] = item
        profile_count = result.get("merged_raw_profiles")
        if isinstance(profile_count, bool) or not isinstance(profile_count, int):
            raise PgsoError(f"{phase} shard profile count is invalid: {shard_id}")
        merged_raw_profiles += profile_count

    missing = sorted(expected_set - set(combined))
    if missing:
        raise PgsoError(f"missing {phase} scenario: " + ", ".join(missing))
    unexpected = sorted(set(combined) - expected_set)
    if unexpected:
        raise PgsoError(f"unexpected {phase} scenario: " + ", ".join(unexpected))
    ordered_results = [dict(combined[name]) for name in expected]
    return {
        "passed": len(ordered_results),
        "skipped": 0,
        "failed": 0,
        "merged_raw_profiles": merged_raw_profiles,
        "results": ordered_results,
    }


def aggregate_measurement_shards(
    documents: Sequence[Mapping[str, object]],
    *,
    phase: str,
    expected_names: Sequence[str],
    expected_identity: BuildIdentity,
    expected_artifact_sha256: str,
    expected_profile_linkage: Mapping[str, Mapping[str, object]] | None = None,
) -> list[dict[str, object]]:
    if not documents:
        raise PgsoError(f"no {phase} measurement evidence found")
    expected = tuple(expected_names)
    if len(expected) != len(set(expected)):
        raise PgsoError(f"expected {phase} measurements contain duplicates")
    if expected_profile_linkage is not None and set(expected_profile_linkage) != set(
        expected
    ):
        raise PgsoError(f"expected {phase} profile linkage is incomplete")
    measurements: dict[str, Mapping[str, object]] = {}
    shard_ids: set[str] = set()
    for raw_document in documents:
        document = _mapping(raw_document, f"{phase} measurement evidence")
        if document.get("schema_version") != 1:
            raise PgsoError(f"unsupported {phase} measurement schema")
        if document.get("phase") != phase:
            raise PgsoError(f"unexpected measurement phase: {document.get('phase')!r}")
        if document.get("status") != "passed":
            raise PgsoError(f"{phase} measurement shard did not pass")
        shard_id = document.get("shard_id")
        if not isinstance(shard_id, str) or not shard_id:
            raise PgsoError(f"{phase} measurement shard ID is invalid")
        if shard_id in shard_ids:
            raise PgsoError(f"duplicate {phase} measurement shard ID: {shard_id}")
        shard_ids.add(shard_id)
        verify_identity(expected_identity, identity_from_mapping(document.get("identity")))
        if document.get("artifact_sha256") != expected_artifact_sha256:
            raise PgsoError(f"{phase} measurement artifact hash mismatch: {shard_id}")
        measurement = _mapping(
            document.get("measurement"),
            f"{phase} measurement",
        )
        name = measurement.get("name")
        if not isinstance(name, str) or not name:
            raise PgsoError(f"{phase} measurement name is invalid")
        if name in measurements:
            raise PgsoError(f"duplicate {phase} measurement: {name}")
        if measurement.get("passed") is not True:
            raise PgsoError(f"{phase} measurement failed: {name}")
        required_samples = STARTUP_MINIMUM_SAMPLES if phase == "startup" else 50
        if measurement.get("requested_samples") != required_samples:
            raise PgsoError(
                f"{phase} measurement requires exactly {required_samples} samples: {name}"
            )
        for sample_label in ("control_samples", "candidate_samples"):
            samples = measurement.get(sample_label)
            if not isinstance(samples, list) or len(samples) != required_samples:
                raise PgsoError(
                    f"{phase} measurement requires exactly {required_samples} samples: {name}"
                )
        if (
            measurement.get("control_failures") != 0
            or measurement.get("candidate_failures") != 0
            or measurement.get("errors") != []
        ):
            raise PgsoError(f"{phase} measurement contains execution failures: {name}")
        comparison = _mapping(
            measurement.get("comparison"),
            f"{phase} measurement comparison",
        )
        if comparison.get("passed") is not True:
            raise PgsoError(f"{phase} measurement comparison failed: {name}")
        if expected_profile_linkage is not None:
            linkage = _mapping(
                document.get("profile_linkage"),
                f"{phase} profile linkage",
            )
            if dict(linkage) != dict(expected_profile_linkage[name]):
                raise PgsoError(f"{phase} profile linkage mismatch: {name}")
        measurements[name] = measurement

    missing = sorted(set(expected) - set(measurements))
    if missing:
        raise PgsoError(f"missing {phase} measurement: " + ", ".join(missing))
    unexpected = sorted(set(measurements) - set(expected))
    if unexpected:
        raise PgsoError(f"unexpected {phase} measurement: " + ", ".join(unexpected))
    return [dict(measurements[name]) for name in expected]


def _write_json(path: pathlib.Path, payload: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _read_json(path: pathlib.Path, label: str) -> Mapping[str, object]:
    if not path.is_file():
        raise PgsoError(f"{label} does not exist: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PgsoError(f"could not read {label}: {error}") from error
    return _mapping(payload, label)


def _fresh_directory(path: pathlib.Path) -> pathlib.Path:
    path = path.resolve()
    if path.exists():
        if not path.is_dir():
            raise PgsoError(f"output is not a directory: {path}")
        if any(path.iterdir()):
            raise PgsoError(f"output directory is not empty: {path}")
    path.mkdir(parents=True, exist_ok=True)
    return path


def _parse_names(value: str) -> tuple[str, ...]:
    names = tuple(item for item in value.split(",") if item)
    if not names or ",".join(names) != value:
        raise PgsoError("scenario assignment must be comma-separated names")
    if any(re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) is None for name in names):
        raise PgsoError("scenario assignment contains an invalid name")
    return names


def _manifest_evidence(
    manifest: Mapping[str, object],
    *,
    stage: str,
    label: str,
) -> Mapping[str, object]:
    if manifest.get("schema_version") != 1:
        raise PgsoError(f"unsupported {label} schema")
    if manifest.get("status") != "passed" or manifest.get("stage") != stage:
        raise PgsoError(f"{label} is not a passed {stage} artifact")
    return _mapping(manifest.get("evidence"), f"{label} evidence")


def _require_hash(path: pathlib.Path, expected: object, label: str) -> str:
    if not isinstance(expected, str) or len(expected) != 64:
        raise PgsoError(f"{label} has an invalid expected hash")
    if not path.is_file() or path.stat().st_size == 0:
        raise PgsoError(f"{label} is missing or empty: {path}")
    actual = sha256_file(path)
    if actual != expected:
        raise PgsoError(f"{label} hash mismatch: expected {expected}, got {actual}")
    return actual


def _checkout_sha(log_dir: pathlib.Path) -> str:
    result = run_checked(
        ("git", "rev-parse", "HEAD"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=log_dir / "source-sha.json",
        require_empty_stderr=True,
    )
    return result.stdout.strip()


def _validate_checkout(
    identity: BuildIdentity,
    corpus: Corpus,
    log_dir: pathlib.Path,
) -> None:
    if _checkout_sha(log_dir) != identity.source_sha:
        raise PgsoError("distributed job source SHA does not match seed identity")
    if corpus.manifest_sha256 != identity.corpus_sha256:
        raise PgsoError("distributed job corpus hash does not match seed identity")
    status = run_checked(
        ("git", "status", "--porcelain", "--untracked-files=no"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=60,
        log_path=log_dir / "source-status.json",
        require_empty_stderr=True,
    )
    if status.stdout:
        raise PgsoError("distributed job has tracked source changes")


def _validate_toolchain(identity: BuildIdentity, toolchain: Toolchain) -> None:
    actual = dataclasses.replace(
        identity,
        target=toolchain.target,
        host_arch=toolchain.host_arch,
        zig_version=toolchain.zig_version,
        llvm_version=toolchain.llvm_version,
    )
    verify_identity(identity, actual)


def _require_version(
    command: str,
    expected: str,
    label: str,
    log: pathlib.Path,
) -> pathlib.Path:
    resolved = shutil.which(command)
    if resolved is None:
        raise PgsoError(f"missing runtime executable: {label}")
    executable = pathlib.Path(resolved).resolve()
    result = run_checked(
        (str(executable), "--version") if label != "tmux" else (str(executable), "-V"),
        cwd=REPO_ROOT,
        env=os.environ.copy(),
        timeout_s=30,
        log_path=log,
        require_empty_stderr=True,
    )
    if expected and result.stdout.strip() != expected:
        raise PgsoError(
            f"{label} version mismatch: expected {expected}, "
            f"got {result.stdout.strip()}"
        )
    return executable


def _load_seed(
    seed_dir: pathlib.Path,
    corpus: Corpus,
    log_dir: pathlib.Path,
) -> tuple[PipelinePaths, Mapping[str, object], BuildIdentity]:
    paths = PipelinePaths.open(seed_dir)
    manifest = _read_json(paths.root / "manifest.json", "seed manifest")
    evidence = _manifest_evidence(
        manifest,
        stage="build-complete",
        label="seed manifest",
    )
    identity = identity_from_mapping(evidence.get("identity"))
    validate_seed_identity(identity)
    _validate_checkout(identity, corpus, log_dir)
    _require_hash(paths.bitcode, identity.bitcode_sha256, "seed bitcode")
    control = _mapping(evidence.get("control"), "seed control evidence")
    _require_hash(paths.control_binary, control.get("sha256"), "seed control binary")
    instrumented = _mapping(
        evidence.get("instrumented"),
        "seed instrumented evidence",
    )
    _require_hash(
        paths.instrumented_binary,
        instrumented.get("sha256"),
        "seed instrumented binary",
    )
    profile = _mapping(
        instrumented.get("smoke_profile"),
        "seed smoke profile evidence",
    )
    _require_hash(paths.merged_profile, profile.get("sha256"), "seed smoke profile")
    return paths, evidence, identity


def _load_candidate(
    candidate_dir: pathlib.Path,
    corpus: Corpus,
    log_dir: pathlib.Path,
) -> tuple[PipelinePaths, Mapping[str, object], BuildIdentity, str]:
    paths = PipelinePaths.open(candidate_dir)
    manifest = _read_json(paths.root / "manifest.json", "candidate manifest")
    evidence = _manifest_evidence(
        manifest,
        stage="candidate-complete",
        label="candidate manifest",
    )
    identity = identity_from_mapping(evidence.get("identity"))
    _validate_checkout(identity, corpus, log_dir)
    artifacts = _mapping(evidence.get("artifacts"), "candidate artifacts")
    candidate = _mapping(artifacts.get("candidate"), "candidate artifact")
    candidate_hash = _require_hash(
        paths.candidate_binary,
        candidate.get("sha256"),
        "candidate binary",
    )
    control = _mapping(artifacts.get("control"), "control artifact")
    _require_hash(paths.control_binary, control.get("sha256"), "control binary")
    profile = _mapping(evidence.get("profile"), "candidate profile evidence")
    _require_hash(paths.merged_profile, profile.get("sha256"), "production profile")
    _load_prebuilt_benchmark_pairs(paths, evidence)
    return paths, evidence, identity, candidate_hash


def _load_prebuilt_benchmark_pairs(
    candidate_paths: PipelinePaths,
    candidate_evidence: Mapping[str, object],
) -> dict[str, BenchmarkPair]:
    profile = _mapping(
        candidate_evidence.get("profile"),
        "candidate profile evidence",
    )
    supplements = _mapping(
        profile.get("supplements"),
        "candidate profile supplements",
    )
    pairs: dict[str, BenchmarkPair] = {}
    for plan in BENCHMARK_PLANS:
        evidence = _mapping(
            supplements.get(plan.selector),
            f"{plan.selector} profile supplement",
        )
        if evidence.get("profile_module") != plan.profile_module:
            raise PgsoError(
                f"benchmark profile module mismatch: {plan.selector}"
            )
        function_modes = _mapping(
            evidence.get("functions"),
            f"{plan.selector} supplement functions",
        )
        if not function_modes or any(
            mode not in ("speed", "optimized_away")
            for mode in function_modes.values()
        ):
            raise PgsoError(
                f"benchmark profile functions are invalid: {plan.selector}"
            )
        benchmark_modes = _mapping(
            evidence.get("benchmark_functions"),
            f"{plan.selector} benchmark function modes",
        )
        if set(benchmark_modes) != set(function_modes) or any(
            mode not in ("speed", "optimized_away")
            for mode in benchmark_modes.values()
        ):
            raise PgsoError(
                f"benchmark candidate functions are invalid: {plan.selector}"
            )
        pair_paths = PipelinePaths.open(
            candidate_paths.root / "heavy" / plan.selector,
            selector=plan.selector,
        )
        control_binary = (
            pair_paths.root / "external-control" / plan.profile_module
        )
        _require_hash(
            control_binary,
            evidence.get("control_sha256"),
            f"{plan.selector} benchmark control",
        )
        _require_hash(
            pair_paths.candidate_binary,
            evidence.get("candidate_sha256"),
            f"{plan.selector} benchmark candidate",
        )
        _require_hash(
            pair_paths.merged_profile,
            evidence.get("benchmark_profile_sha256"),
            f"{plan.selector} benchmark profile",
        )
        candidate_profile = pair_paths.profiles / "production.profdata"
        _require_hash(
            candidate_profile,
            evidence.get("candidate_profile_sha256"),
            f"{plan.selector} candidate profile",
        )
        mapped_profile_text = pair_paths.profiles / "production.proftext"
        _require_hash(
            mapped_profile_text,
            evidence.get("mapped_profile_sha256"),
            f"{plan.selector} mapped profile",
        )
        supplement_path = (
            candidate_paths.profiles
            / "supplements"
            / f"{plan.selector}.proftext"
        )
        _require_hash(
            supplement_path,
            evidence.get("supplement_sha256"),
            f"{plan.selector} profile supplement",
        )
        bitcode_sha256 = evidence.get("bitcode_sha256")
        merged_raw_profiles = evidence.get("merged_raw_profiles")
        if not isinstance(bitcode_sha256, str) or not isinstance(
            merged_raw_profiles,
            int,
        ):
            raise PgsoError(
                f"benchmark profile identity is invalid: {plan.selector}"
            )
        mapped_functions = evidence.get("mapped_compatible_functions")
        mapped_counter_total = evidence.get("mapped_counter_total")
        if (
            isinstance(mapped_functions, bool)
            or not isinstance(mapped_functions, int)
            or mapped_functions <= 0
            or isinstance(mapped_counter_total, bool)
            or not isinstance(mapped_counter_total, int)
            or mapped_counter_total <= 0
        ):
            raise PgsoError(
                f"mapped benchmark evidence is invalid: {plan.selector}"
            )
        pairs[plan.selector] = BenchmarkPair(
            selector=plan.selector,
            control_binary=control_binary,
            candidate_binary=pair_paths.candidate_binary,
            bitcode_sha256=bitcode_sha256,
            merged_raw_profiles=merged_raw_profiles,
            merged_profile=pair_paths.merged_profile,
            profile_use_ir=pair_paths.profile_use_ir,
            candidate_profile=candidate_profile,
        )
    return pairs


def _artifact_document_paths(
    root: pathlib.Path,
    filename: str = "manifest.json",
) -> tuple[pathlib.Path, ...]:
    if not root.is_dir():
        raise PgsoError(f"no shard manifests found under {root}")
    selected: dict[str, tuple[int, pathlib.Path]] = {}
    for entry in sorted(root.iterdir()):
        version = re.fullmatch(r"(.+)-attempt-([0-9]+)", entry.name)
        if version:
            name, attempt = version.group(1), int(version.group(2))
            if attempt < 1:
                raise PgsoError(f"invalid artifact attempt: {entry.name}")
        elif entry.is_dir() and not entry.is_symlink():
            name, attempt = entry.name, 0
        else:
            continue
        previous = selected.get(name)
        if previous is not None and previous[0] == attempt:
            raise PgsoError(f"ambiguous artifact attempt: {entry.name}")
        if previous is None or attempt > previous[0]:
            selected[name] = attempt, entry

    direct = root / filename
    paths = [direct] if direct.is_file() else []
    for attempt, directory in selected.values():
        if attempt and (directory.is_symlink() or not directory.is_dir()):
            raise PgsoError(f"unsafe artifact directory: {directory}")
        documents = tuple(directory.glob(f"**/{filename}"))
        if attempt and not documents:
            raise PgsoError(f"latest artifact has no {filename}: {directory}")
        paths.extend(documents)
    if not paths:
        raise PgsoError(f"no shard manifests found under {root}")
    return tuple(sorted(paths))


def _load_documents(
    root: pathlib.Path,
    filename: str = "manifest.json",
) -> tuple[Mapping[str, object], ...]:
    return tuple(
        _read_json(path, "shard manifest")
        for path in _artifact_document_paths(root, filename)
    )


def run_plan(phase: str, corpus_path: pathlib.Path, maximum_shards: int) -> dict[str, object]:
    if phase == "startup":
        return {"include": [{"name": name} for name, _argv in STARTUP_COMMANDS]}
    if phase == "heavy":
        return {
            "include": [
                {"name": workload.name}
                for plan in BENCHMARK_PLANS
                for workload in plan.workloads
            ]
        }
    corpus = load_corpus(corpus_path, repo_root=REPO_ROOT)
    if phase == "training":
        scenarios = corpus.scenarios
    elif phase == "behavior":
        scenarios = corpus.candidate_scenarios
    else:
        raise PgsoError(f"unsupported shard plan phase: {phase}")
    return matrix_payload(
        plan_shards(scenarios, maximum_shards=maximum_shards, prefix=phase)
    )


def run_training_shard(arguments: argparse.Namespace) -> pathlib.Path:
    output = _fresh_directory(arguments.output_dir)
    log_dir = output / "logs"
    corpus = load_corpus(arguments.corpus, repo_root=REPO_ROOT)
    seed_paths, seed_evidence, identity = _load_seed(arguments.seed_dir, corpus, log_dir)
    toolchain = Toolchain.discover(arguments.zig, arguments.llvm_bin, identity.target)
    _validate_toolchain(identity, toolchain)
    bun = _require_version(
        arguments.bun,
        REQUIRED_BUN_VERSION,
        "Bun",
        log_dir / "bun-version.json",
    )
    _require_version("tmux", "", "tmux", log_dir / "tmux-version.json")
    names = _parse_names(arguments.scenarios)
    selected = select_corpus(corpus, "training", names)
    instrumented = _mapping(
        seed_evidence.get("instrumented"),
        "seed instrumented evidence",
    )
    instrumented_hash = str(instrumented.get("sha256"))
    manifest_path = output / "manifest.json"
    try:
        result = run_corpus(
            selected,
            seed_paths.instrumented_binary,
            output / "profiles" / "raw",
            output / "profile.profdata",
            toolchain=toolchain,
            bun=bun,
        )
        payload: dict[str, object] = {
            "schema_version": 1,
            "status": "passed",
            "phase": "training",
            "shard_id": arguments.shard_id,
            "identity": dataclasses.asdict(identity),
            "artifact_sha256": instrumented_hash,
            "assigned_scenarios": list(names),
            "result": dataclasses.asdict(result),
            "profile_sha256": sha256_file(output / "profile.profdata"),
        }
    except CorpusRunError as error:
        payload = {
            "schema_version": 1,
            "status": "failed",
            "phase": "training",
            "shard_id": arguments.shard_id,
            "identity": dataclasses.asdict(identity),
            "artifact_sha256": instrumented_hash,
            "assigned_scenarios": list(names),
            "result": dataclasses.asdict(error.result),
            "error": str(error),
        }
        _write_json(manifest_path, payload)
        raise
    _write_json(manifest_path, payload)
    return manifest_path


def run_candidate(arguments: argparse.Namespace) -> pathlib.Path:
    output = _fresh_directory(arguments.output_dir)
    paths = PipelinePaths.create(output)
    corpus = load_corpus(arguments.corpus, repo_root=REPO_ROOT)
    seed_paths, seed_evidence, identity = _load_seed(
        arguments.seed_dir,
        corpus,
        paths.logs,
    )
    toolchain = Toolchain.discover(arguments.zig, arguments.llvm_bin, identity.target)
    _validate_toolchain(identity, toolchain)
    manifest_paths = _artifact_document_paths(arguments.shards_dir)
    documents = tuple(_read_json(path, "shard manifest") for path in manifest_paths)
    instrumented = _mapping(
        seed_evidence.get("instrumented"),
        "seed instrumented evidence",
    )
    instrumented_hash = str(instrumented.get("sha256"))
    training = aggregate_scenario_shards(
        documents,
        phase="training",
        expected_names=tuple(item.name for item in corpus.scenarios),
        expected_identity=identity,
        expected_artifact_sha256=instrumented_hash,
    )

    paths.control_binary.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(seed_paths.control_binary, paths.control_binary)
    shutil.copy2(seed_paths.merged_profile, paths.merged_profile)
    shard_profiles: list[pathlib.Path] = []
    for manifest_path, document in zip(manifest_paths, documents, strict=True):
        profile = manifest_path.parent / "profile.profdata"
        _require_hash(profile, document.get("profile_sha256"), "training shard profile")
        shard_profiles.append(profile)
    merged_count = merge_profile_batch(
        toolchain,
        shard_profiles,
        paths.merged_profile,
        paths.logs / "merge-distributed-profiles.json",
    )
    if merged_count != len(documents):
        raise PgsoError("distributed profile merge count mismatch")

    linked_benchmarks = build_profile_linked_benchmarks(
        toolchain,
        REPO_ROOT,
        paths,
    )

    spec = ArtifactSpec(
        repo_root=REPO_ROOT,
        target=identity.target,
        update_channel=identity.update_channel,
    )
    emit_bitcode(toolchain, spec, paths, expected_sha256=identity.bitcode_sha256)
    apply_profile(toolchain, paths, identity.bitcode_sha256)
    link_candidate(toolchain, paths)
    linked_benchmarks = relink_profile_linked_benchmarks(
        toolchain,
        paths,
        linked_benchmarks,
    )
    control = _mapping(seed_evidence.get("control"), "seed control evidence")
    minimum_macos = control.get("minimum_macos")
    if not isinstance(minimum_macos, str):
        raise PgsoError("seed control minimum macOS is invalid")
    candidate = verify_candidate(toolchain, paths, expected_minos=minimum_macos)
    if not candidate.artifact.preferred_headroom_met:
        raise PgsoError(
            "candidate meets the hard size ceiling but lacks 0.250 MiB preferred adoption headroom"
        )
    artifacts = {
        "control": {
            "sha256": sha256_file(paths.control_binary),
            "size_bytes": paths.control_binary.stat().st_size,
            "minimum_macos": minimum_macos,
        },
        "candidate": {
            "sha256": candidate.sha256,
            "size": dataclasses.asdict(candidate.artifact),
            "architecture": candidate.metadata.architecture,
            "minimum_macos": candidate.metadata.min_macos,
            "signature_valid": candidate.metadata.signature_valid,
            "version": candidate.version_output,
        },
        "warnings": 0,
        "linker": _read_json(paths.logs / "candidate-layout.json", "candidate layout"),
    }
    smoke_profile = _mapping(
        instrumented.get("smoke_profile"),
        "seed smoke profile evidence",
    )
    production_ir = paths.profile_use_ir.read_text(
        encoding="utf-8",
        errors="replace",
    )
    supplement_evidence = profile_linked_benchmark_evidence(
        linked_benchmarks,
        production_ir,
    )
    profile = {
        "sha256": sha256_file(paths.merged_profile),
        "size_bytes": paths.merged_profile.stat().st_size,
        "merged_raw_profiles": int(training["merged_raw_profiles"])
        + int(smoke_profile.get("merged_raw_profiles", 0)),
        "supplements": supplement_evidence,
    }
    payload = {
        "schema_version": 1,
        "status": "passed",
        "stage": "candidate-complete",
        "eligible": False,
        "evidence": {
            "identity": dataclasses.asdict(identity),
            "runtime": seed_evidence.get("runtime"),
            "artifacts": artifacts,
            "training": training,
            "profile": profile,
        },
    }
    _write_json(paths.root / "manifest.json", payload)
    return paths.root / "manifest.json"


def run_behavior_shard(arguments: argparse.Namespace) -> pathlib.Path:
    output = _fresh_directory(arguments.output_dir)
    log_dir = output / "driver-logs"
    corpus = load_corpus(arguments.corpus, repo_root=REPO_ROOT)
    candidate_paths, _evidence, identity, candidate_hash = _load_candidate(
        arguments.candidate_dir,
        corpus,
        log_dir,
    )
    bun = _require_version(
        arguments.bun,
        REQUIRED_BUN_VERSION,
        "Bun",
        log_dir / "bun-version.json",
    )
    _require_version("tmux", "", "tmux", log_dir / "tmux-version.json")
    names = _parse_names(arguments.scenarios)
    selected = select_corpus(corpus, "behavior", names)
    manifest_path = output / "manifest.json"
    try:
        result = run_behavior_corpus(
            selected,
            candidate_paths.candidate_binary,
            output / "behavior",
            bun=bun,
        )
        payload: dict[str, object] = {
            "schema_version": 1,
            "status": "passed",
            "phase": "behavior",
            "shard_id": arguments.shard_id,
            "identity": dataclasses.asdict(identity),
            "artifact_sha256": candidate_hash,
            "assigned_scenarios": list(names),
            "result": dataclasses.asdict(result),
        }
    except CorpusRunError as error:
        payload = {
            "schema_version": 1,
            "status": "failed",
            "phase": "behavior",
            "shard_id": arguments.shard_id,
            "identity": dataclasses.asdict(identity),
            "artifact_sha256": candidate_hash,
            "assigned_scenarios": list(names),
            "result": dataclasses.asdict(error.result),
            "error": str(error),
        }
        _write_json(manifest_path, payload)
        raise
    _write_json(manifest_path, payload)
    return manifest_path


def run_measurement_shard(arguments: argparse.Namespace) -> pathlib.Path:
    output = _fresh_directory(arguments.output_dir)
    log_dir = output / "driver-logs"
    corpus = load_corpus(arguments.corpus, repo_root=REPO_ROOT)
    candidate_paths, _evidence, identity, candidate_hash = _load_candidate(
        arguments.candidate_dir,
        corpus,
        log_dir,
    )
    if arguments.kind == "startup":
        hyperfine = _require_version(
            arguments.hyperfine,
            f"hyperfine {REQUIRED_HYPERFINE_VERSION}",
            "Hyperfine",
            log_dir / "hyperfine-version.json",
        )
        results = measure_startup(
            repo_root=REPO_ROOT,
            control_binary=candidate_paths.control_binary,
            candidate_binary=candidate_paths.candidate_binary,
            hyperfine_binary=hyperfine,
            output_dir=output / "measurements",
            samples=arguments.samples,
            timeout_s=arguments.timeout_seconds,
            command_names=(arguments.name,),
        )
        phase = "startup"
    else:
        benchmark_pairs = _load_prebuilt_benchmark_pairs(
            candidate_paths,
            _evidence,
        )
        results = measure_heavy_workloads(
            toolchain=None,
            repo_root=REPO_ROOT,
            output_dir=output / "measurements",
            samples=arguments.samples,
            timeout_s=arguments.timeout_seconds,
            workload_names=(arguments.name,),
            prebuilt_pairs=benchmark_pairs,
        )
        phase = "heavy"
    if len(results) != 1:
        raise PgsoError(f"{phase} shard produced {len(results)} measurements")
    payload = {
        "schema_version": 1,
        "status": "passed" if results[0].passed else "failed",
        "phase": phase,
        "shard_id": results[0].name,
        "identity": dataclasses.asdict(identity),
        "artifact_sha256": candidate_hash,
        "measurement": measurement_payload(results)[0],
    }
    if phase == "heavy":
        profile = _mapping(
            _evidence.get("profile"),
            "candidate profile evidence",
        )
        supplements = _mapping(
            profile.get("supplements"),
            "candidate profile supplements",
        )
        plan = next(
            plan
            for plan in BENCHMARK_PLANS
            if any(workload.name == arguments.name for workload in plan.workloads)
        )
        supplement = _mapping(
            supplements.get(plan.selector),
            f"{plan.selector} profile supplement",
        )
        payload["profile_linkage"] = {
            "production_profile_sha256": profile.get("sha256"),
            "benchmark_profile_sha256": supplement.get(
                "benchmark_profile_sha256"
            ),
            "candidate_profile_sha256": supplement.get(
                "candidate_profile_sha256"
            ),
            "mapped_profile_sha256": supplement.get(
                "mapped_profile_sha256"
            ),
            "benchmark_control_sha256": supplement.get("control_sha256"),
            "benchmark_candidate_sha256": supplement.get("candidate_sha256"),
            "supplement_sha256": supplement.get("supplement_sha256"),
            "selector": plan.selector,
        }
    manifest_path = output / "manifest.json"
    _write_json(manifest_path, payload)
    require_measurements_passed(phase, results)
    return manifest_path


def run_aggregate(arguments: argparse.Namespace) -> pathlib.Path:
    output = _fresh_directory(arguments.output_dir)
    corpus = load_corpus(arguments.corpus, repo_root=REPO_ROOT)
    candidate_paths, candidate_evidence, identity, candidate_hash = _load_candidate(
        arguments.candidate_dir,
        corpus,
        output / "logs",
    )
    behavior = aggregate_scenario_shards(
        _load_documents(arguments.behavior_dir),
        phase="behavior",
        expected_names=tuple(item.name for item in corpus.candidate_scenarios),
        expected_identity=identity,
        expected_artifact_sha256=candidate_hash,
    )
    startup_names = tuple(f"startup-{name}" for name, _argv in STARTUP_COMMANDS)
    startup = aggregate_measurement_shards(
        _load_documents(arguments.startup_dir),
        phase="startup",
        expected_names=startup_names,
        expected_identity=identity,
        expected_artifact_sha256=candidate_hash,
    )
    heavy_names = tuple(
        workload.name
        for plan in BENCHMARK_PLANS
        for workload in plan.workloads
    )
    profile = _mapping(
        candidate_evidence.get("profile"),
        "candidate profile evidence",
    )
    supplements = _mapping(
        profile.get("supplements"),
        "candidate profile supplements",
    )
    heavy_profile_linkage: dict[str, Mapping[str, object]] = {}
    for plan in BENCHMARK_PLANS:
        supplement = _mapping(
            supplements.get(plan.selector),
            f"{plan.selector} profile supplement",
        )
        linkage = {
            "production_profile_sha256": profile.get("sha256"),
            "benchmark_profile_sha256": supplement.get(
                "benchmark_profile_sha256"
            ),
            "candidate_profile_sha256": supplement.get(
                "candidate_profile_sha256"
            ),
            "mapped_profile_sha256": supplement.get(
                "mapped_profile_sha256"
            ),
            "benchmark_control_sha256": supplement.get("control_sha256"),
            "benchmark_candidate_sha256": supplement.get("candidate_sha256"),
            "supplement_sha256": supplement.get("supplement_sha256"),
            "selector": plan.selector,
        }
        for workload in plan.workloads:
            heavy_profile_linkage[workload.name] = linkage
    heavy = aggregate_measurement_shards(
        _load_documents(arguments.heavy_dir),
        phase="heavy",
        expected_names=heavy_names,
        expected_identity=identity,
        expected_artifact_sha256=candidate_hash,
        expected_profile_linkage=heavy_profile_linkage,
    )
    training = candidate_evidence.get("training")
    if not isinstance(training, dict):
        raise PgsoError("candidate manifest is missing aggregated training evidence")
    destination = output / "candidate" / "fx"
    destination.parent.mkdir(parents=True)
    shutil.copy2(candidate_paths.candidate_binary, destination)
    if sha256_file(destination) != candidate_hash:
        raise PgsoError("aggregated candidate hash changed during copy")
    payload = {
        "schema_version": 1,
        "command": "distributed",
        "status": "passed",
        "stage": "complete",
        "eligible": True,
        "error": None,
        "evidence": {
            "identity": dataclasses.asdict(identity),
            "runtime": candidate_evidence.get("runtime"),
            "artifacts": candidate_evidence.get("artifacts"),
            "profile": profile,
            "corpus": {
                "manifest_path": str(corpus.manifest_path),
                "manifest_sha256": corpus.manifest_sha256,
                "intentional_exclusions": corpus.intentional_exclusions,
                "training": training,
                "candidate": behavior,
            },
            "startup": startup,
            "heavy_workloads": heavy,
        },
    }
    manifest_path = output / "manifest.json"
    _write_json(manifest_path, payload)
    return manifest_path


def _add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--corpus", type=pathlib.Path, default=DEFAULT_CORPUS)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run distributed macOS arm64 PGSO qualification")
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan = subparsers.add_parser("plan")
    _add_common(plan)
    plan.add_argument(
        "--phase",
        choices=("training", "behavior", "startup", "heavy"),
        required=True,
    )
    plan.add_argument("--maximum-shards", type=int, default=20)

    training = subparsers.add_parser("train-shard")
    _add_common(training)
    training.add_argument("--seed-dir", required=True, type=pathlib.Path)
    training.add_argument("--output-dir", required=True, type=pathlib.Path)
    training.add_argument("--shard-id", required=True)
    training.add_argument("--scenarios", required=True)
    training.add_argument("--llvm-bin", required=True)
    training.add_argument("--zig", default="zig")
    training.add_argument("--bun", default="bun")

    candidate = subparsers.add_parser("candidate")
    _add_common(candidate)
    candidate.add_argument("--seed-dir", required=True, type=pathlib.Path)
    candidate.add_argument("--shards-dir", required=True, type=pathlib.Path)
    candidate.add_argument("--output-dir", required=True, type=pathlib.Path)
    candidate.add_argument("--llvm-bin", required=True)
    candidate.add_argument("--zig", default="zig")

    behavior = subparsers.add_parser("behavior-shard")
    _add_common(behavior)
    behavior.add_argument("--candidate-dir", required=True, type=pathlib.Path)
    behavior.add_argument("--output-dir", required=True, type=pathlib.Path)
    behavior.add_argument("--shard-id", required=True)
    behavior.add_argument("--scenarios", required=True)
    behavior.add_argument("--bun", default="bun")

    measurement = subparsers.add_parser("measure")
    _add_common(measurement)
    measurement.add_argument("--candidate-dir", required=True, type=pathlib.Path)
    measurement.add_argument("--output-dir", required=True, type=pathlib.Path)
    measurement.add_argument("--kind", choices=("startup", "heavy"), required=True)
    measurement.add_argument("--name", required=True)
    measurement.add_argument("--hyperfine", default="hyperfine")
    measurement.add_argument("--samples", type=int, default=50)
    measurement.add_argument("--timeout-seconds", type=float, default=1800)

    aggregate = subparsers.add_parser("aggregate")
    _add_common(aggregate)
    aggregate.add_argument("--candidate-dir", required=True, type=pathlib.Path)
    aggregate.add_argument("--behavior-dir", required=True, type=pathlib.Path)
    aggregate.add_argument("--startup-dir", required=True, type=pathlib.Path)
    aggregate.add_argument("--heavy-dir", required=True, type=pathlib.Path)
    aggregate.add_argument("--output-dir", required=True, type=pathlib.Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        with cancellation_guard():
            if arguments.command == "plan":
                payload = run_plan(
                    arguments.phase,
                    arguments.corpus,
                    arguments.maximum_shards,
                )
                print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
                return 0
            if arguments.command == "train-shard":
                manifest = run_training_shard(arguments)
            elif arguments.command == "candidate":
                manifest = run_candidate(arguments)
            elif arguments.command == "behavior-shard":
                manifest = run_behavior_shard(arguments)
            elif arguments.command == "measure":
                if arguments.samples < 50:
                    raise PgsoError("measurement requires at least 50 samples")
                manifest = run_measurement_shard(arguments)
            else:
                manifest = run_aggregate(arguments)
            print(manifest)
            return 0
    except PgsoError as error:
        output = getattr(arguments, "output_dir", None)
        if isinstance(output, pathlib.Path):
            output.mkdir(parents=True, exist_ok=True)
            failure = output / "failure.json"
            _write_json(
                failure,
                {
                    "schema_version": 1,
                    "status": "failed",
                    "eligible": False,
                    "command": arguments.command,
                    "error": str(error),
                },
            )
        print(f"Distributed PGSO failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
