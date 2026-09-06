from __future__ import annotations

import dataclasses
import json
import math
import os
import pathlib
import shlex
import time
import uuid
from collections.abc import Callable, Mapping, Sequence

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import (
    ArtifactSpec,
    PipelinePaths,
    apply_profile,
    build_instrumented,
    collect_instrumented_profile,
    emit_bitcode,
    link_candidate,
    merge_profile_batch,
    read_macos_minos,
)
from scripts.pgso.profile_supplement import (
    MappedProfile,
    ProfileSupplement,
    create_mapped_benchmark_profile,
    create_profile_supplement,
    merge_profile_supplement,
    verify_supplement_functions,
)
from scripts.pgso.runner import emit_progress, hermetic_environment, run_checked
from scripts.pgso.toolchain import Toolchain


MINIMUM_SAMPLES = 50
STARTUP_MINIMUM_SAMPLES = 1_000
STARTUP_WARMUP_RUNS = 10
STARTUP_MINIMUM_ROUNDS = 10
STARTUP_MAX_RUNS_PER_ROUND = 10
MAXIMUM_REGRESSION = 0.10
REQUIRED_EVIDENCE = (
    "identity",
    "runtime",
    "artifacts",
    "profile",
    "corpus",
    "startup",
    "heavy_workloads",
)

STARTUP_COMMANDS = (
    ("help", ("help",)),
    ("version", ("--version",)),
    ("status", ("status", "--json")),
    ("doctor", ("doctor", "--json")),
    ("sessions", ("sessions", "--json")),
)


@dataclasses.dataclass(frozen=True)
class Workload:
    name: str
    argv: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class BenchmarkPlan:
    selector: str
    profile_module: str
    function_prefixes: tuple[str, ...]
    training_argvs: tuple[tuple[str, ...], ...]
    workloads: tuple[Workload, ...]


@dataclasses.dataclass(frozen=True)
class BenchmarkPair:
    selector: str
    control_binary: pathlib.Path
    candidate_binary: pathlib.Path
    bitcode_sha256: str
    merged_raw_profiles: int
    merged_profile: pathlib.Path | None = None
    profile_use_ir: pathlib.Path | None = None
    candidate_profile: pathlib.Path | None = None


@dataclasses.dataclass(frozen=True)
class ProfileLinkedBenchmark:
    pair: BenchmarkPair
    supplement_path: pathlib.Path
    supplement: ProfileSupplement
    mapped_profile_text: pathlib.Path | None = None
    mapped_profile: MappedProfile | None = None


BENCHMARK_PLANS = (
    BenchmarkPlan(
        selector="file_index",
        profile_module="file-index-bench",
        function_prefixes=("core.workspace.file_index.",),
        training_argvs=(("100000", "500"),),
        workloads=(Workload("file-index-100k", ("100000", "500")),),
    ),
    BenchmarkPlan(
        selector="ui_activity",
        profile_module="ui-activity-progress-bench",
        function_prefixes=(
            "core.output.activity_runtime.",
            "core.output.worker_status.",
            "ui.transcript.",
            "ui.render_engine.",
        ),
        training_argvs=((),),
        workloads=(Workload("ui-activity", ()),),
    ),
    BenchmarkPlan(
        selector="approval_review",
        profile_module="approval-review-bench",
        function_prefixes=(
            "core.output.diff.",
            "core.permissions.approval_prompt.",
            "ui.approval_screen.",
            "ui.footer.approval_ui.",
            "ui.render_engine.transcript_blocks.",
            "ui.render_engine.transcript_measure.",
            "core.terminal.vt_emulator.",
        ),
        training_argvs=(
            ("transcript", "3", "1"),
            ("diff", "3", "1"),
            ("combined", "3", "1"),
            ("payload", "3", "1"),
        ),
        workloads=(
            Workload("approval-transcript", ("transcript", "1", "1")),
            Workload("approval-diff", ("diff", "1", "1")),
            Workload("approval-combined", ("combined", "1", "1")),
            Workload("approval-payload", ("payload", "1", "1")),
        ),
    ),
)


def select_startup_commands(
    names: Sequence[str] | None,
) -> tuple[tuple[str, tuple[str, ...]], ...]:
    if names is None:
        return STARTUP_COMMANDS
    if not names:
        raise PgsoError("startup assignment cannot be empty")
    if len(names) != len(set(names)):
        raise PgsoError("duplicate startup command")
    available = {name: argv for name, argv in STARTUP_COMMANDS}
    unknown = sorted(set(names) - set(available))
    if unknown:
        raise PgsoError("unknown startup command: " + ", ".join(unknown))
    requested = set(names)
    return tuple(item for item in STARTUP_COMMANDS if item[0] in requested)


def select_benchmark_plans(
    workload_names: Sequence[str] | None,
) -> tuple[BenchmarkPlan, ...]:
    if workload_names is None:
        return BENCHMARK_PLANS
    if not workload_names:
        raise PgsoError("heavy workload assignment cannot be empty")
    if len(workload_names) != len(set(workload_names)):
        raise PgsoError("duplicate heavy workload")
    available = {
        workload.name
        for plan in BENCHMARK_PLANS
        for workload in plan.workloads
    }
    unknown = sorted(set(workload_names) - available)
    if unknown:
        raise PgsoError("unknown heavy workload: " + ", ".join(unknown))
    requested = set(workload_names)
    return tuple(
        dataclasses.replace(
            plan,
            workloads=tuple(
                workload
                for workload in plan.workloads
                if workload.name in requested
            ),
        )
        for plan in BENCHMARK_PLANS
        if any(workload.name in requested for workload in plan.workloads)
    )


@dataclasses.dataclass(frozen=True)
class Comparison:
    control_samples: tuple[float, ...]
    candidate_samples: tuple[float, ...]
    control_p50: float
    control_p95: float
    candidate_p50: float
    candidate_p95: float
    p50_change: float
    p95_change: float
    passed: bool


@dataclasses.dataclass(frozen=True)
class MeasurementResult:
    name: str
    argv: tuple[str, ...]
    requested_samples: int
    control_samples: tuple[float, ...]
    candidate_samples: tuple[float, ...]
    control_failures: int
    candidate_failures: int
    errors: tuple[str, ...]
    comparison: Comparison | None
    passed: bool


class EvidenceRecorder:
    def __init__(
        self,
        path: pathlib.Path,
        *,
        command: str,
        configuration: Mapping[str, object],
    ) -> None:
        self.path = path
        self.payload: dict[str, object] = {
            "schema_version": 1,
            "command": command,
            "configuration": dict(configuration),
            "status": "running",
            "stage": "initialize",
            "eligible": False,
            "error": None,
            "evidence": {},
            "stages": [],
        }
        self._active_stage: tuple[str, float] | None = None
        self._write()

    def _stage_elapsed(self, name: str) -> float:
        if self._active_stage is None or self._active_stage[0] != name:
            return 0.0
        return time.monotonic() - self._active_stage[1]

    def _write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(
            f".{self.path.name}.{uuid.uuid4().hex}.tmp"
        )
        temporary.write_text(
            json.dumps(self.payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, self.path)

    def stage(
        self,
        name: str,
        status: str,
        evidence: Mapping[str, object] | None = None,
    ) -> None:
        if status not in ("running", "passed"):
            raise PgsoError(f"invalid evidence stage status: {status}")
        if self.payload["status"] == "failed":
            raise PgsoError("cannot update a failed evidence manifest")
        self.payload["stage"] = name
        self.payload["status"] = "running"
        stages = self.payload["stages"]
        if not isinstance(stages, list):
            raise PgsoError("invalid in-memory evidence stage list")
        elapsed_seconds = self._stage_elapsed(name) if status == "passed" else None
        stage_entry: dict[str, object] = {"name": name, "status": status}
        if elapsed_seconds is not None:
            stage_entry["elapsed_seconds"] = elapsed_seconds
        stages.append(stage_entry)
        if evidence:
            recorded = self.payload["evidence"]
            if not isinstance(recorded, dict):
                raise PgsoError("invalid in-memory evidence mapping")
            recorded.update(evidence)
        self._write()
        if status == "running":
            self._active_stage = (name, time.monotonic())
            emit_progress(f"stage started: {name}")
        else:
            self._active_stage = None
            if elapsed_seconds is None:
                raise PgsoError("passed stage is missing elapsed time")
            emit_progress(f"stage passed in {elapsed_seconds:.3f}s: {name}")

    def fail(self, stage: str, error: BaseException) -> None:
        elapsed_seconds = self._stage_elapsed(stage)
        self.payload["stage"] = stage
        self.payload["status"] = "failed"
        self.payload["eligible"] = False
        self.payload["error"] = str(error)
        stages = self.payload["stages"]
        if isinstance(stages, list):
            stages.append(
                {
                    "name": stage,
                    "status": "failed",
                    "elapsed_seconds": elapsed_seconds,
                }
            )
        self._write()
        self._active_stage = None
        emit_progress(
            f"stage failed in {elapsed_seconds:.3f}s: {stage}: {error}"
        )

    def complete(self) -> None:
        evidence = self.payload["evidence"]
        if not isinstance(evidence, dict):
            raise PgsoError("invalid in-memory evidence mapping")
        missing = tuple(key for key in REQUIRED_EVIDENCE if key not in evidence)
        if missing:
            raise PgsoError(
                "required evidence is incomplete: " + ", ".join(missing)
            )
        self.payload["stage"] = "complete"
        self.payload["status"] = "passed"
        self.payload["eligible"] = True
        self.payload["error"] = None
        stages = self.payload["stages"]
        if isinstance(stages, list):
            stages.append({"name": "complete", "status": "passed"})
        self._write()

    def finish_partial(self, stage: str) -> None:
        if self.payload["status"] == "failed":
            raise PgsoError("cannot finish a failed evidence manifest")
        self.payload["stage"] = stage
        self.payload["status"] = "passed"
        self.payload["eligible"] = False
        self.payload["error"] = None
        stages = self.payload["stages"]
        if isinstance(stages, list):
            stages.append({"name": stage, "status": "passed"})
        self._write()


def percentile(samples: Sequence[float], fraction: float) -> float:
    if not samples:
        raise PgsoError("percentile requires at least one sample")
    if not 0 < fraction <= 1:
        raise PgsoError("percentile fraction must be in (0, 1]")
    if not all(math.isfinite(sample) and sample >= 0 for sample in samples):
        raise PgsoError("samples must be finite nonnegative values")
    ordered = sorted(samples)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


def _change(control: float, candidate: float) -> float:
    if control <= 0:
        raise PgsoError("control percentile must be positive")
    return candidate / control - 1.0


def compare_samples(
    control_samples: Sequence[float],
    candidate_samples: Sequence[float],
    *,
    minimum_samples: int = MINIMUM_SAMPLES,
    maximum_regression: float = MAXIMUM_REGRESSION,
) -> Comparison:
    if len(control_samples) < minimum_samples or len(candidate_samples) < minimum_samples:
        raise PgsoError(
            f"comparison requires at least {minimum_samples} samples per artifact"
        )
    if maximum_regression < 0:
        raise PgsoError("maximum regression must be nonnegative")
    control = tuple(control_samples)
    candidate = tuple(candidate_samples)
    control_p50 = percentile(control, 0.50)
    control_p95 = percentile(control, 0.95)
    candidate_p50 = percentile(candidate, 0.50)
    candidate_p95 = percentile(candidate, 0.95)
    p50_change = _change(control_p50, candidate_p50)
    p95_change = _change(control_p95, candidate_p95)
    passed = (
        candidate_p50 <= control_p50 * (1.0 + maximum_regression)
        and candidate_p95 <= control_p95 * (1.0 + maximum_regression)
    )
    return Comparison(
        control_samples=control,
        candidate_samples=candidate,
        control_p50=control_p50,
        control_p95=control_p95,
        candidate_p50=candidate_p50,
        candidate_p95=candidate_p95,
        p50_change=p50_change,
        p95_change=p95_change,
        passed=passed,
    )


def _read_hyperfine_samples(
    path: pathlib.Path,
    *,
    expected_samples: int,
) -> dict[str, tuple[float, ...]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PgsoError(f"could not read Hyperfine export: {path}: {error}") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("results"), list):
        raise PgsoError("Hyperfine export is missing its results list")

    parsed: dict[str, tuple[float, ...]] = {}
    for entry in payload["results"]:
        if not isinstance(entry, dict):
            raise PgsoError("Hyperfine result must be an object")
        label = entry.get("command")
        if label not in ("control", "candidate"):
            raise PgsoError(f"Hyperfine round contains unexpected label: {label!r}")
        if label in parsed:
            raise PgsoError(f"Hyperfine round contains duplicate label: {label}")
        raw_samples = entry.get("times")
        if not isinstance(raw_samples, list):
            raise PgsoError(f"Hyperfine {label} result is missing its samples")
        if len(raw_samples) != expected_samples:
            raise PgsoError(
                f"Hyperfine round returned {len(raw_samples)} {label} samples; "
                f"expected {expected_samples}"
            )
        samples: list[float] = []
        for index, sample in enumerate(raw_samples):
            if (
                isinstance(sample, bool)
                or not isinstance(sample, (int, float))
                or not math.isfinite(sample)
                or sample <= 0
            ):
                raise PgsoError(
                    f"Hyperfine {label} sample {index} must be finite and positive"
                )
            samples.append(float(sample))
        parsed[label] = tuple(samples)

    missing = tuple(label for label in ("control", "candidate") if label not in parsed)
    if missing:
        raise PgsoError(f"Hyperfine round is missing label: {', '.join(missing)}")
    return parsed


def measure_alternating(
    *,
    name: str,
    control_binary: pathlib.Path,
    candidate_binary: pathlib.Path,
    argv: Sequence[str],
    samples: int,
    sample_runner: Callable[[str, pathlib.Path, tuple[str, ...], int], float],
) -> MeasurementResult:
    if samples < MINIMUM_SAMPLES:
        raise PgsoError(
            f"qualification requires at least {MINIMUM_SAMPLES} samples"
        )
    control_samples: list[float] = []
    candidate_samples: list[float] = []
    control_failures = 0
    candidate_failures = 0
    errors: list[str] = []
    arguments = tuple(argv)

    for sample_index in range(samples):
        order = (
            (("control", control_binary), ("candidate", candidate_binary))
            if sample_index % 2 == 0
            else (("candidate", candidate_binary), ("control", control_binary))
        )
        for label, binary in order:
            try:
                elapsed = sample_runner(label, binary, arguments, sample_index)
                if not math.isfinite(elapsed) or elapsed <= 0:
                    raise PgsoError("sample duration must be finite and positive")
                if label == "control":
                    control_samples.append(elapsed)
                else:
                    candidate_samples.append(elapsed)
            except Exception as error:
                errors.append(f"{label}[{sample_index}]: {error}")
                if label == "control":
                    control_failures += 1
                else:
                    candidate_failures += 1

    comparison: Comparison | None = None
    if (
        control_failures == 0
        and candidate_failures == 0
        and len(control_samples) >= MINIMUM_SAMPLES
        and len(candidate_samples) >= MINIMUM_SAMPLES
    ):
        comparison = compare_samples(control_samples, candidate_samples)
    passed = comparison is not None and comparison.passed
    return MeasurementResult(
        name=name,
        argv=arguments,
        requested_samples=samples,
        control_samples=tuple(control_samples),
        candidate_samples=tuple(candidate_samples),
        control_failures=control_failures,
        candidate_failures=candidate_failures,
        errors=tuple(errors),
        comparison=comparison,
        passed=passed,
    )


def _external_control_link_argv(
    toolchain: Toolchain,
    object_path: pathlib.Path,
    binary_path: pathlib.Path,
) -> tuple[str, ...]:
    return (
        str(toolchain.zig),
        "cc",
        "-target",
        toolchain.target,
        "-O2",
        "-Wl,-dead_strip",
        "-s",
        str(object_path),
        "-o",
        str(binary_path),
        "-lc",
    )


def build_external_o2_control(
    toolchain: Toolchain,
    paths: PipelinePaths,
) -> pathlib.Path:
    output = paths.root / "external-control"
    output.mkdir(parents=True, exist_ok=False)
    bitcode = output / paths.bitcode.name
    object_path = output / f"{paths.binary_name}.o"
    binary = output / paths.binary_name
    run_checked(
        (
            str(toolchain.opt),
            "-passes=default<O2>",
            str(paths.bitcode),
            "-o",
            str(bitcode),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "external-control-opt.json",
        require_empty_stderr=True,
    )
    run_checked(
        (
            str(toolchain.llc),
            "-filetype=obj",
            "-O=2",
            str(bitcode),
            "-o",
            str(object_path),
        ),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "external-control-object.json",
        require_empty_stderr=True,
    )
    run_checked(
        _external_control_link_argv(toolchain, object_path, binary),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=900,
        log_path=paths.logs / "external-control-link.json",
        require_empty_stderr=True,
    )
    run_checked(
        (str(toolchain.strip), "-S", "-x", str(binary)),
        cwd=paths.root,
        env=os.environ.copy(),
        timeout_s=120,
        log_path=paths.logs / "external-control-strip.json",
        require_empty_stderr=True,
    )
    if not binary.is_file() or binary.stat().st_size == 0:
        raise PgsoError(f"external O2 control is missing or empty: {binary}")
    return binary


def build_benchmark_pair(
    toolchain: Toolchain,
    repo_root: pathlib.Path,
    output_root: pathlib.Path,
    plan: BenchmarkPlan,
) -> BenchmarkPair:
    paths = PipelinePaths.create(output_root, selector=plan.selector)
    spec = ArtifactSpec(repo_root=repo_root, selector=plan.selector)
    bitcode_sha256 = emit_bitcode(toolchain, spec, paths)
    external_control = build_external_o2_control(toolchain, paths)
    minimum_macos = read_macos_minos(
        toolchain,
        external_control,
        paths.logs / "control-load-commands.json",
    )

    first_training = plan.training_argvs[0]
    raw_profiles = list(
        build_instrumented(
            toolchain,
            paths,
            minimum_macos,
            training_argv=first_training,
            training_name="training-1",
        )
    )
    for index, training_argv in enumerate(plan.training_argvs[1:], start=2):
        raw_profiles.extend(
            collect_instrumented_profile(
                toolchain,
                paths,
                training_argv=training_argv,
                training_name=f"training-{index}",
                timeout_s=300,
            )
        )
    merged_count = merge_profile_batch(
        toolchain,
        raw_profiles,
        paths.merged_profile,
        paths.logs / "merge-training.json",
    )
    emit_bitcode(
        toolchain,
        spec,
        paths,
        expected_sha256=bitcode_sha256,
    )
    apply_profile(toolchain, paths, bitcode_sha256)
    candidate = link_candidate(
        toolchain,
        paths,
        require_release_safe_evidence=False,
    )
    return BenchmarkPair(
        selector=plan.selector,
        control_binary=external_control,
        candidate_binary=candidate,
        bitcode_sha256=bitcode_sha256,
        merged_raw_profiles=merged_count,
        merged_profile=paths.merged_profile,
        profile_use_ir=paths.profile_use_ir,
    )


def build_profile_linked_benchmarks(
    toolchain: Toolchain,
    repo_root: pathlib.Path,
    production_paths: PipelinePaths,
) -> dict[str, ProfileLinkedBenchmark]:
    supplement_dir = production_paths.profiles / "supplements"
    supplement_dir.mkdir()
    linked: dict[str, ProfileLinkedBenchmark] = {}
    for plan in BENCHMARK_PLANS:
        pair = build_benchmark_pair(
            toolchain,
            repo_root,
            production_paths.root / "heavy" / plan.selector,
            plan,
        )
        if pair.merged_profile is None or pair.profile_use_ir is None:
            raise PgsoError(
                f"benchmark profile evidence is incomplete: {plan.selector}"
            )
        supplement_path = supplement_dir / f"{plan.selector}.proftext"
        supplement = create_profile_supplement(
            toolchain,
            production_profile=production_paths.merged_profile,
            benchmark_profile=pair.merged_profile,
            benchmark_ir=pair.profile_use_ir,
            output_text=supplement_path,
            source_module=plan.profile_module,
            destination_module="fx",
            allowed_prefixes=plan.function_prefixes,
            log_dir=(
                production_paths.logs / "supplements" / plan.selector
            ),
        )
        linked[plan.selector] = ProfileLinkedBenchmark(
            pair=pair,
            supplement_path=supplement_path,
            supplement=supplement,
        )
    for plan in BENCHMARK_PLANS:
        merge_profile_supplement(
            toolchain,
            production_profile=production_paths.merged_profile,
            supplement_text=linked[plan.selector].supplement_path,
            log_path=(
                production_paths.logs
                / "supplements"
                / plan.selector
                / "merge.json"
            ),
        )
    return linked


def relink_profile_linked_benchmarks(
    toolchain: Toolchain,
    production_paths: PipelinePaths,
    linked_benchmarks: Mapping[str, ProfileLinkedBenchmark],
) -> dict[str, ProfileLinkedBenchmark]:
    expected = tuple(plan.selector for plan in BENCHMARK_PLANS)
    if set(linked_benchmarks) != set(expected):
        raise PgsoError("profile-linked benchmark set is incomplete")
    relinked: dict[str, ProfileLinkedBenchmark] = {}
    for plan in BENCHMARK_PLANS:
        linked = linked_benchmarks[plan.selector]
        pair = linked.pair
        if pair.merged_profile is None:
            raise PgsoError(
                f"benchmark training profile is incomplete: {plan.selector}"
            )
        pair_paths = PipelinePaths.open(
            production_paths.root / "heavy" / plan.selector,
            selector=plan.selector,
        )
        mapped_text = pair_paths.profiles / "production.proftext"
        mapped_profile_path = pair_paths.profiles / "production.profdata"
        mapped = create_mapped_benchmark_profile(
            toolchain,
            production_profile=production_paths.merged_profile,
            benchmark_profile=pair.merged_profile,
            output_text=mapped_text,
            output_profile=mapped_profile_path,
            source_module="fx",
            destination_module=plan.profile_module,
            log_dir=pair_paths.logs / "production-profile-map",
        )
        supplemented_functions = {
            name.removeprefix("fx;")
            for name in linked.supplement.function_names
        }
        if not supplemented_functions.issubset(
            set(mapped.compatible_function_names)
        ):
            raise PgsoError(
                f"mapped benchmark omitted supplemented functions: "
                f"{plan.selector}"
            )
        apply_profile(
            toolchain,
            pair_paths,
            pair.bitcode_sha256,
            profile_path=mapped_profile_path,
        )
        candidate = link_candidate(
            toolchain,
            pair_paths,
            require_release_safe_evidence=False,
        )
        relinked[plan.selector] = dataclasses.replace(
            linked,
            pair=dataclasses.replace(
                pair,
                candidate_binary=candidate,
                profile_use_ir=pair_paths.profile_use_ir,
                candidate_profile=mapped_profile_path,
            ),
            mapped_profile_text=mapped_text,
            mapped_profile=mapped,
        )
    return relinked


def profile_linked_benchmark_evidence(
    linked_benchmarks: Mapping[str, ProfileLinkedBenchmark],
    production_ir: str,
) -> dict[str, object]:
    expected = tuple(plan.selector for plan in BENCHMARK_PLANS)
    if set(linked_benchmarks) != set(expected):
        raise PgsoError("profile-linked benchmark evidence is incomplete")
    evidence: dict[str, object] = {}
    for plan in BENCHMARK_PLANS:
        linked = linked_benchmarks[plan.selector]
        pair = linked.pair
        if (
            pair.merged_profile is None
            or pair.profile_use_ir is None
            or pair.candidate_profile is None
            or linked.mapped_profile_text is None
            or linked.mapped_profile is None
        ):
            raise PgsoError(
                f"benchmark profile evidence is incomplete: {plan.selector}"
            )
        function_modes = verify_supplement_functions(
            production_ir,
            linked.supplement.function_names,
            production_module="fx",
        )
        benchmark_profile_names = tuple(
            f"{plan.profile_module};{name.removeprefix('fx;')}"
            for name in linked.supplement.function_names
        )
        benchmark_modes = verify_supplement_functions(
            pair.profile_use_ir.read_text(
                encoding="utf-8",
                errors="replace",
            ),
            benchmark_profile_names,
            production_module=plan.profile_module,
        )
        evidence[plan.selector] = {
            "profile_module": plan.profile_module,
            "bitcode_sha256": pair.bitcode_sha256,
            "merged_raw_profiles": pair.merged_raw_profiles,
            "benchmark_profile_sha256": sha256_file(pair.merged_profile),
            "candidate_profile_sha256": sha256_file(
                pair.candidate_profile
            ),
            "mapped_profile_sha256": sha256_file(
                linked.mapped_profile_text
            ),
            "mapped_compatible_functions": len(
                linked.mapped_profile.compatible_function_names
            ),
            "mapped_counter_total": linked.mapped_profile.total_counter_value,
            "control_sha256": sha256_file(pair.control_binary),
            "candidate_sha256": sha256_file(pair.candidate_binary),
            "supplement_sha256": sha256_file(linked.supplement_path),
            "normalized_counter_total": (
                linked.supplement.total_counter_value
            ),
            "functions": function_modes,
            "benchmark_functions": benchmark_modes,
        }
    return evidence


def _measurement_environment(home: pathlib.Path) -> dict[str, str]:
    environment = hermetic_environment(home)
    environment.update(
        {
            "FX_AUTO_UPGRADE": "0",
            "FX_DISABLE_KEYCHAIN": "1",
            "FX_SKIP_ONBOARDING": "1",
            "FX_SOUND": "0",
            "HOME": str(home),
            "NO_COLOR": "1",
        }
    )
    return environment


def measure_startup(
    *,
    repo_root: pathlib.Path,
    control_binary: pathlib.Path,
    candidate_binary: pathlib.Path,
    hyperfine_binary: pathlib.Path,
    output_dir: pathlib.Path,
    samples: int,
    timeout_s: float,
    command_names: Sequence[str] | None = None,
) -> tuple[MeasurementResult, ...]:
    home = output_dir / "home"
    logs = output_dir / "logs"
    home.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    results: list[MeasurementResult] = []
    startup_samples = max(samples, STARTUP_MINIMUM_SAMPLES)
    startup_rounds = max(
        STARTUP_MINIMUM_ROUNDS,
        math.ceil(startup_samples / STARTUP_MAX_RUNS_PER_ROUND),
    )
    samples_per_round, extra_samples = divmod(startup_samples, startup_rounds)
    round_samples = tuple(
        samples_per_round + (round_index < extra_samples)
        for round_index in range(startup_rounds)
    )

    for command_name, command_argv in select_startup_commands(command_names):
        for label, binary in (
            ("control", control_binary),
            ("candidate", candidate_binary),
        ):
            result = run_checked(
                (str(binary), *command_argv),
                cwd=repo_root,
                env=_measurement_environment(home),
                timeout_s=timeout_s,
                log_path=logs / f"{command_name}-preflight-{label}.json",
                require_empty_stderr=True,
            )
            if not result.stdout.strip():
                raise PgsoError(f"startup command produced empty stdout: {command_name}")

        samples_by_label: dict[str, list[float]] = {
            "control": [],
            "candidate": [],
        }
        for round_index, count in enumerate(round_samples, start=1):
            order = (
                (
                    ("control", control_binary),
                    ("candidate", candidate_binary),
                )
                if round_index % 2 == 1
                else (
                    ("candidate", candidate_binary),
                    ("control", control_binary),
                )
            )
            export_path = logs / f"{command_name}-round-{round_index}-samples.json"
            benchmark_argv: list[str] = [
                str(hyperfine_binary),
                "--shell=none",
                "--style",
                "none",
                "--warmup",
                str(STARTUP_WARMUP_RUNS),
                "--runs",
                str(count),
                "--export-json",
                str(export_path),
            ]
            for label, binary in order:
                benchmark_argv.extend(
                    (
                        "--command-name",
                        label,
                        shlex.join((str(binary), *command_argv)),
                    )
                )
            run_checked(
                benchmark_argv,
                cwd=repo_root,
                env=_measurement_environment(home),
                timeout_s=timeout_s,
                log_path=logs / f"{command_name}-round-{round_index}.json",
                require_empty_stderr=False,
            )
            round_results = _read_hyperfine_samples(
                export_path,
                expected_samples=count,
            )
            for label, measured in round_results.items():
                samples_by_label[label].extend(measured)

        comparison = compare_samples(
            samples_by_label["control"],
            samples_by_label["candidate"],
            minimum_samples=startup_samples,
        )
        results.append(
            MeasurementResult(
                name=f"startup-{command_name}",
                argv=command_argv,
                requested_samples=startup_samples,
                control_samples=tuple(samples_by_label["control"]),
                candidate_samples=tuple(samples_by_label["candidate"]),
                control_failures=0,
                candidate_failures=0,
                errors=(),
                comparison=comparison,
                passed=comparison.passed,
            )
        )
    return tuple(results)


def measure_heavy_workloads(
    *,
    toolchain: Toolchain | None,
    repo_root: pathlib.Path,
    output_dir: pathlib.Path,
    samples: int,
    timeout_s: float,
    workload_names: Sequence[str] | None = None,
    prebuilt_pairs: Mapping[str, BenchmarkPair] | None = None,
) -> tuple[MeasurementResult, ...]:
    output_dir.mkdir(parents=True, exist_ok=False)
    home = output_dir / "home"
    logs = output_dir / "logs"
    home.mkdir()
    logs.mkdir()
    results: list[MeasurementResult] = []

    for plan in select_benchmark_plans(workload_names):
        if prebuilt_pairs is None:
            if toolchain is None:
                raise PgsoError("heavy workload build requires an LLVM toolchain")
            pair = build_benchmark_pair(
                toolchain,
                repo_root,
                output_dir / plan.selector,
                plan,
            )
        else:
            pair = prebuilt_pairs.get(plan.selector)
            if pair is None:
                raise PgsoError(
                    f"missing prebuilt benchmark pair: {plan.selector}"
                )
            if pair.selector != plan.selector:
                raise PgsoError(
                    f"prebuilt benchmark selector mismatch: {plan.selector}"
                )
            for label, binary in (
                ("control", pair.control_binary),
                ("candidate", pair.candidate_binary),
            ):
                if not binary.is_file() or binary.stat().st_size == 0:
                    raise PgsoError(
                        f"prebuilt benchmark {label} is missing: {binary}"
                    )
        for workload in plan.workloads:
            workload_logs = logs / workload.name

            def sample_runner(
                label: str,
                binary: pathlib.Path,
                argv: tuple[str, ...],
                sample_index: int,
            ) -> float:
                result = run_checked(
                    (str(binary), *argv),
                    cwd=repo_root,
                    env=_measurement_environment(home),
                    timeout_s=timeout_s,
                    log_path=(
                        workload_logs
                        / f"{sample_index:03d}-{label}.json"
                    ),
                    require_empty_stderr=True,
                )
                if not result.stdout.strip():
                    raise PgsoError(
                        f"heavy workload produced empty stdout: {workload.name}"
                    )
                return result.elapsed_seconds

            results.append(
                measure_alternating(
                    name=workload.name,
                    control_binary=pair.control_binary,
                    candidate_binary=pair.candidate_binary,
                    argv=workload.argv,
                    samples=samples,
                    sample_runner=sample_runner,
                )
            )
    return tuple(results)


def measurement_payload(
    results: Sequence[MeasurementResult],
) -> list[dict[str, object]]:
    return [dataclasses.asdict(result) for result in results]


def require_measurements_passed(
    label: str,
    results: Sequence[MeasurementResult],
) -> None:
    failed = tuple(result.name for result in results if not result.passed)
    if failed:
        raise PgsoError(f"{label} qualification failed: {', '.join(failed)}")
