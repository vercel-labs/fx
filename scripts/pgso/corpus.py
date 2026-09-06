from __future__ import annotations

import argparse
import contextlib
import dataclasses
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Callable, Iterator, Mapping, Sequence

from scripts.pgso.model import PgsoError, sha256_file
from scripts.pgso.pipeline import merge_profile_batch
from scripts.pgso.runner import CommandResult, hermetic_environment, run_checked


REQUIRED_DIRECT_COMMANDS = (
    ("help",),
    ("--version",),
    ("status", "--json"),
    ("doctor", "--json"),
    ("sessions", "--json"),
)
MAX_PROFILE_RUNS = 100

REQUIRED_EXCLUSIONS = (
    "notifications.test.ts",
    "tui-agent.test.ts",
    "tui-command-permissions.test.ts",
)

ISOLATED_ENVIRONMENT_KEYS = (
    "AI_GATEWAY_API_KEY",
    "VERCEL_OIDC_TOKEN",
    "LLVM_PROFILE_FILE",
    "TMUX",
    "TMUX_PANE",
    "TMUX_TMPDIR",
    "FX_TRACE_LOG",
    "FX_TRACE_SCOPES",
    "FX_E2E_DISABLE_DOTENV",
)

@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    argv: tuple[str, ...]
    cwd: str
    env_set: tuple[tuple[str, str], ...]
    env_unset: tuple[str, ...]
    timeout_seconds: float
    requires_tmux: bool
    allow_keychain: bool
    test_file: str | None
    profile_runs: int = 1


@dataclasses.dataclass(frozen=True)
class Corpus:
    repo_root: pathlib.Path
    manifest_path: pathlib.Path
    manifest_sha256: str
    scenarios: tuple[Scenario, ...]
    intentional_exclusions: tuple[tuple[str, str], ...]
    verification_scenarios: tuple[Scenario, ...] = ()

    @property
    def training_test_files(self) -> tuple[str, ...]:
        return tuple(
            scenario.test_file
            for scenario in self.scenarios
            if scenario.test_file is not None
        )

    @property
    def verification_test_files(self) -> tuple[str, ...]:
        return tuple(
            scenario.test_file
            for scenario in self.verification_scenarios
            if scenario.test_file is not None
        )

    @property
    def test_files(self) -> tuple[str, ...]:
        return (*self.training_test_files, *self.verification_test_files)

    @property
    def candidate_scenarios(self) -> tuple[Scenario, ...]:
        return (*self.scenarios, *self.verification_scenarios)


@dataclasses.dataclass(frozen=True)
class ScenarioResult:
    name: str
    status: str
    elapsed_seconds: float
    raw_profiles: int
    error: str | None = None


@dataclasses.dataclass(frozen=True)
class CorpusResult:
    passed: int
    skipped: int
    failed: int
    merged_raw_profiles: int
    results: tuple[ScenarioResult, ...]


class CorpusRunError(PgsoError):
    def __init__(self, message: str, result: CorpusResult) -> None:
        super().__init__(message)
        self.result = result


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise PgsoError(f"{label} must be an object")
    if not all(isinstance(key, str) for key in value):
        raise PgsoError(f"{label} keys must be strings")
    return value


def _string_mapping(value: object, label: str) -> dict[str, str]:
    mapping = _mapping(value, label)
    if not all(isinstance(item, str) for item in mapping.values()):
        raise PgsoError(f"{label} values must be strings")
    return {key: item for key, item in mapping.items() if isinstance(item, str)}


def _string_sequence(
    value: object,
    label: str,
    *,
    allow_empty: bool = False,
) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or (not value and not allow_empty)
        or not all(
            isinstance(item, str) and item for item in value
        )
    ):
        raise PgsoError(f"{label} must be a list of nonempty strings")
    return tuple(value)


def _resolve_cwd(repo_root: pathlib.Path, cwd: str) -> pathlib.Path:
    repo_root = repo_root.resolve()
    resolved = (repo_root / cwd).resolve()
    try:
        resolved.relative_to(repo_root)
    except ValueError as error:
        raise PgsoError(f"scenario cwd escapes repository: {cwd}") from error
    if not resolved.is_dir():
        raise PgsoError(f"scenario cwd does not exist: {cwd}")
    return resolved


def _is_live_test(test_file: str) -> bool:
    return re.search(r"(?:^|-)live(?:-|\.)", test_file) is not None


def _parse_scenario(
    raw: object,
    *,
    defaults: Mapping[str, object],
    repo_root: pathlib.Path,
) -> Scenario:
    values = dict(defaults)
    values.update(_mapping(raw, "scenario"))

    name = values.get("name")
    if not isinstance(name, str) or re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) is None:
        raise PgsoError(f"invalid scenario name: {name!r}")
    argv = _string_sequence(values.get("argv"), f"scenario {name} argv")

    cwd = values.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        raise PgsoError(f"scenario {name} cwd must be a nonempty string")
    _resolve_cwd(repo_root, cwd)

    default_env_set = _string_mapping(
        defaults.get("env_set", {}),
        "default env_set",
    )
    scenario_raw = _mapping(raw, "scenario")
    scenario_env_set = _string_mapping(
        scenario_raw.get("env_set", {}),
        f"scenario {name} env_set",
    )
    env_set = {**default_env_set, **scenario_env_set}
    reserved = set(env_set) & ({"HOME"} | set(ISOLATED_ENVIRONMENT_KEYS))
    if reserved:
        raise PgsoError(
            f"scenario {name} sets reserved environment key: "
            f"{', '.join(sorted(reserved))}"
        )
    env_unset = _string_sequence(
        values.get("env_unset", []),
        f"scenario {name} env_unset",
        allow_empty=True,
    )
    overlap = set(env_set) & set(env_unset)
    if overlap:
        raise PgsoError(
            f"scenario {name} sets and unsets the same environment key: "
            f"{', '.join(sorted(overlap))}"
        )

    timeout_seconds = values.get("timeout_seconds")
    if (
        isinstance(timeout_seconds, bool)
        or not isinstance(timeout_seconds, (int, float))
        or timeout_seconds <= 0
    ):
        raise PgsoError(f"scenario {name} timeout must be positive")
    requires_tmux = values.get("requires_tmux")
    if not isinstance(requires_tmux, bool):
        raise PgsoError(f"scenario {name} requires_tmux must be a boolean")
    allow_keychain = values.get("allow_keychain", False)
    if not isinstance(allow_keychain, bool):
        raise PgsoError(f"scenario {name} allow_keychain must be a boolean")
    profile_runs = values.get("profile_runs", 1)
    if (
        isinstance(profile_runs, bool)
        or not isinstance(profile_runs, int)
        or not 1 <= profile_runs <= MAX_PROFILE_RUNS
    ):
        raise PgsoError(
            f"scenario {name} profile_runs must be an integer from 1 to "
            f"{MAX_PROFILE_RUNS}"
        )

    test_file = values.get("test_file")
    if test_file is not None:
        if not isinstance(test_file, str) or pathlib.Path(test_file).name != test_file:
            raise PgsoError(f"invalid corpus test file: {test_file!r}")
        if test_file in REQUIRED_EXCLUSIONS or _is_live_test(test_file):
            raise PgsoError(f"forbidden corpus test: {test_file}")
        expected_argv = (
            "bun",
            "test",
            "--max-concurrency",
            "1",
            f"./{test_file}",
        )
        if argv != expected_argv:
            raise PgsoError(f"scenario {name} test command mismatch")
        expected_test = repo_root / "tests" / "e2e" / test_file
        if not expected_test.is_file():
            raise PgsoError(f"test file does not exist: {test_file}")
    if profile_runs != 1 and (
        argv[0] != "{binary}"
        or test_file is not None
        or requires_tmux
        or allow_keychain
    ):
        raise PgsoError(
            f"scenario {name} profile_runs is only supported for "
            "noninteractive direct training commands without Keychain access"
        )

    if "skip_reason" in defaults or "skip_reason" in scenario_raw:
        raise PgsoError(f"scenario {name} cannot be skipped")

    return Scenario(
        name=name,
        argv=argv,
        cwd=cwd,
        env_set=tuple(sorted(env_set.items())),
        env_unset=env_unset,
        timeout_seconds=float(timeout_seconds),
        requires_tmux=requires_tmux,
        allow_keychain=allow_keychain,
        test_file=test_file,
        profile_runs=profile_runs,
    )


def load_corpus(
    path: pathlib.Path,
    *,
    repo_root: pathlib.Path | None = None,
) -> Corpus:
    path = path.resolve()
    if not path.is_file():
        raise PgsoError(f"corpus manifest does not exist: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PgsoError(f"could not read corpus manifest: {error}") from error
    root = path.parents[2] if repo_root is None else repo_root.resolve()
    document = _mapping(payload, "corpus manifest")
    if document.get("version") != 1:
        raise PgsoError("unsupported corpus manifest version")

    exclusions = _string_mapping(
        document.get("intentional_exclusions"),
        "intentional_exclusions",
    )
    for required in REQUIRED_EXCLUSIONS:
        if required not in exclusions:
            raise PgsoError(f"missing required corpus exclusion: {required}")

    defaults = _mapping(document.get("defaults", {}), "corpus defaults")
    raw_scenarios = document.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise PgsoError("corpus scenarios must be a nonempty list")
    scenarios = tuple(
        _parse_scenario(raw, defaults=defaults, repo_root=root)
        for raw in raw_scenarios
    )
    raw_verification_scenarios = document.get("verification_scenarios", [])
    if not isinstance(raw_verification_scenarios, list):
        raise PgsoError("verification_scenarios must be a list")
    verification_scenarios = tuple(
        _parse_scenario(raw, defaults=defaults, repo_root=root)
        for raw in raw_verification_scenarios
    )
    candidate_scenarios = (*scenarios, *verification_scenarios)
    names = [scenario.name for scenario in candidate_scenarios]
    if len(set(names)) != len(names):
        raise PgsoError("duplicate scenario name in corpus manifest")

    test_files = [
        scenario.test_file
        for scenario in candidate_scenarios
        if scenario.test_file is not None
    ]
    if len(set(test_files)) != len(test_files):
        raise PgsoError("duplicate corpus test file")
    duplicated_exclusions = set(test_files) & set(exclusions)
    if duplicated_exclusions:
        raise PgsoError(
            "E2E test file has multiple corpus classifications: "
            + ", ".join(sorted(duplicated_exclusions))
        )

    discovered_test_files = {
        test_file.name
        for test_file in (root / "tests" / "e2e").glob("*.test.ts")
    }
    classified_test_files = set(test_files) | set(exclusions)
    unclassified = sorted(discovered_test_files - classified_test_files)
    if unclassified:
        label = "file" if len(unclassified) == 1 else "files"
        raise PgsoError(
            f"unclassified E2E test {label}: " + ", ".join(unclassified)
        )
    stale_exclusions = sorted(set(exclusions) - discovered_test_files)
    if stale_exclusions:
        label = "file" if len(stale_exclusions) == 1 else "files"
        verb = "does" if len(stale_exclusions) == 1 else "do"
        raise PgsoError(
            f"excluded E2E test {label} {verb} not exist: "
            + ", ".join(stale_exclusions)
        )

    direct_commands = {
        scenario.argv[1:]
        for scenario in scenarios
        if scenario.argv[0] == "{binary}" and scenario.test_file is None
    }
    for required in REQUIRED_DIRECT_COMMANDS:
        if required not in direct_commands:
            raise PgsoError(
                "missing required direct command: " + " ".join(required)
            )

    return Corpus(
        repo_root=root,
        manifest_path=path,
        manifest_sha256=sha256_file(path),
        scenarios=scenarios,
        intentional_exclusions=tuple(sorted(exclusions.items())),
        verification_scenarios=verification_scenarios,
    )


@contextlib.contextmanager
def _installed_training_binary(
    corpus: Corpus,
    binary: pathlib.Path,
) -> Iterator[pathlib.Path]:
    if not binary.is_file() or binary.stat().st_size == 0:
        raise PgsoError(f"training binary is missing or empty: {binary}")
    canonical = corpus.repo_root / "zig-out" / "bin" / "fx"
    canonical.parent.mkdir(parents=True, exist_ok=True)
    if canonical.is_symlink():
        raise PgsoError(f"canonical training binary cannot be a symlink: {canonical}")
    if binary.resolve() == canonical.resolve():
        yield canonical
        return

    backup: pathlib.Path | None = None
    original_hash: str | None = None
    if canonical.exists():
        if not canonical.is_file():
            raise PgsoError(f"canonical training binary is not a file: {canonical}")
        original_hash = sha256_file(canonical)
        backup = canonical.with_name(
            f".{canonical.name}.pgso-backup-{uuid.uuid4().hex}"
        )
        os.replace(canonical, backup)

    try:
        with tempfile.NamedTemporaryFile(
            dir=canonical.parent,
            prefix=f".{canonical.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary = pathlib.Path(temporary_file.name)
        try:
            shutil.copy2(binary, temporary)
            os.replace(temporary, canonical)
        finally:
            temporary.unlink(missing_ok=True)
        if sha256_file(canonical) != sha256_file(binary):
            raise PgsoError("canonical training binary hash mismatch after installation")
        yield canonical
    finally:
        if canonical.is_file() or canonical.is_symlink():
            canonical.unlink(missing_ok=True)
        if backup is not None:
            os.replace(backup, canonical)
            if original_hash is None or sha256_file(canonical) != original_hash:
                raise PgsoError("canonical training binary hash mismatch after restoration")


def _cleanup_tmux(
    environment: Mapping[str, str],
    tmux_dir: pathlib.Path,
) -> None:
    if (
        tmux_dir.parent != pathlib.Path("/tmp")
        or not tmux_dir.name.startswith("fxp-tmux-")
        or tmux_dir.is_symlink()
    ):
        raise PgsoError(f"refusing to remove unowned tmux directory: {tmux_dir}")

    cleanup_failure: tuple[str, BaseException] | None = None
    try:
        subprocess.run(
            ("tmux", "kill-server"),
            env=dict(environment),
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except FileNotFoundError as error:
        cleanup_failure = ("tmux is required by the corpus scenario", error)
    except subprocess.TimeoutExpired as error:
        cleanup_failure = ("tmux cleanup timed out", error)

    removal_failure: OSError | None = None
    try:
        shutil.rmtree(tmux_dir)
    except FileNotFoundError:
        pass
    except OSError as error:
        removal_failure = error

    if cleanup_failure is not None:
        message, error = cleanup_failure
        raise PgsoError(message) from error
    if removal_failure is not None:
        raise PgsoError(
            f"could not remove tmux directory: {tmux_dir}"
        ) from removal_failure


def _new_tmux_dir() -> pathlib.Path:
    tmux_dir = pathlib.Path(tempfile.mkdtemp(prefix="fxp-tmux-", dir="/tmp"))
    tmux_dir.chmod(0o700)
    return tmux_dir


def _scenario_environment(runtime_home: pathlib.Path) -> dict[str, str]:
    environment = hermetic_environment(runtime_home)
    environment["FX_E2E_DISABLE_DOTENV"] = "1"
    return environment


def _prepare_runtime_home(
    runtime_home: pathlib.Path,
    *,
    allow_keychain: bool,
) -> None:
    runtime_home.mkdir(parents=True, exist_ok=True)
    tmux_config = runtime_home / ".tmux.conf"
    if tmux_config.is_symlink():
        raise PgsoError(f"isolated tmux config cannot be a symlink: {tmux_config}")
    tmux_config.write_text(
        "set-option -g history-limit 100000\n",
        encoding="utf-8",
    )
    if allow_keychain:
        source = pathlib.Path.home() / "Library" / "Keychains"
        if not source.is_dir():
            raise PgsoError(f"host Keychains directory does not exist: {source}")
        library = runtime_home / "Library"
        library.mkdir()
        destination = library / "Keychains"
        destination.symlink_to(source, target_is_directory=True)


def _result(
    results: Sequence[ScenarioResult],
    merged_raw_profiles: int,
) -> CorpusResult:
    return CorpusResult(
        passed=sum(item.status == "passed" for item in results),
        skipped=sum(item.status == "skipped" for item in results),
        failed=sum(item.status == "failed" for item in results),
        merged_raw_profiles=merged_raw_profiles,
        results=tuple(results),
    )


def _scenario_argv(
    scenario: Scenario,
    canonical: pathlib.Path,
    bun: pathlib.Path | str,
) -> tuple[str, ...]:
    resolved: list[str] = []
    for argument in scenario.argv:
        if argument == "{binary}":
            resolved.append(str(canonical))
        elif argument == "bun":
            resolved.append(str(bun))
        else:
            resolved.append(argument)
    return tuple(resolved)


def _execute_scenario(
    corpus: Corpus,
    scenario: Scenario,
    canonical: pathlib.Path,
    bun: pathlib.Path | str,
    runtime_home: pathlib.Path,
    log_dir: pathlib.Path,
    environment: dict[str, str],
    command_runner: Callable[..., CommandResult],
    run_index: int = 0,
    run_count: int = 1,
    attempt_index: int = 0,
) -> CommandResult:
    scenario_home = runtime_home / scenario.name
    _prepare_runtime_home(scenario_home, allow_keychain=scenario.allow_keychain)
    environment.update(_scenario_environment(scenario_home))
    for key in scenario.env_unset:
        environment.pop(key, None)
    environment.update(dict(scenario.env_set))
    environment["HOME"] = str(scenario_home)
    environment["FX_E2E_DISABLE_DOTENV"] = "1"
    tmux_dir: pathlib.Path | None = None
    if scenario.requires_tmux:
        tmux_dir = _new_tmux_dir()
        environment["TMUX_TMPDIR"] = str(tmux_dir)

    primary_error: BaseException | None = None
    try:
        log_name = (
            scenario.name
            if run_count == 1
            else f"{scenario.name}-run-{run_index + 1:03d}"
        )
        if attempt_index > 0:
            log_name += f"-attempt-{attempt_index + 1}"
        return command_runner(
            _scenario_argv(scenario, canonical, bun),
            cwd=_resolve_cwd(corpus.repo_root, scenario.cwd),
            env=environment,
            timeout_s=scenario.timeout_seconds,
            log_path=log_dir / f"{log_name}.json",
        )
    except BaseException as error:
        primary_error = error
        raise
    finally:
        if tmux_dir is not None:
            try:
                _cleanup_tmux(environment, tmux_dir)
            except Exception:
                if primary_error is None:
                    raise


def _reset_failed_tmux_e2e_attempt(
    runtime_home: pathlib.Path,
    scenario: Scenario,
    environment: Mapping[str, str],
    state: object,
) -> None:
    scenario_home = runtime_home / scenario.name
    if scenario_home.parent != runtime_home or scenario_home.is_symlink():
        raise PgsoError(f"refusing to reset unsafe scenario home: {scenario_home}")
    shutil.rmtree(scenario_home, ignore_errors=False)

    profile_pattern = environment.get("LLVM_PROFILE_FILE")
    if profile_pattern is not None:
        if not isinstance(state, set):
            raise PgsoError("invalid training profile snapshot")
        profile_dir = pathlib.Path(profile_pattern).parent
        for profile in set(profile_dir.glob("*.profraw")) - state:
            if profile.parent != profile_dir or profile.suffix != ".profraw":
                raise PgsoError(f"refusing to remove unsafe profile path: {profile}")
            profile.unlink()

    trace_path = environment.get("FX_TRACE_LOG")
    if trace_path is not None:
        pathlib.Path(trace_path).unlink(missing_ok=True)


def _run_scenarios(
    corpus: Corpus,
    binary: pathlib.Path,
    scenarios: Sequence[Scenario],
    *,
    bun: pathlib.Path | str,
    runtime_home: pathlib.Path,
    log_dir: pathlib.Path,
    prepare: Callable[[Scenario, dict[str, str]], object],
    finish: Callable[[Scenario, CommandResult, object], int],
    failure_label: str,
    command_runner: Callable[..., CommandResult],
    repeat_profile_runs: bool = False,
) -> CorpusResult:
    results: list[ScenarioResult] = []
    merged_raw_profiles = 0
    with _installed_training_binary(corpus, binary) as canonical:
        for scenario in scenarios:
            command_result: CommandResult | None = None
            elapsed_seconds = 0.0
            try:
                environment: dict[str, str] = {}
                state = prepare(scenario, environment)
                run_count = scenario.profile_runs if repeat_profile_runs else 1
                for run_index in range(run_count):
                    attempts = 2 if (
                        scenario.test_file is not None and
                        scenario.requires_tmux and
                        run_count == 1
                    ) else 1
                    for attempt_index in range(attempts):
                        try:
                            command_result = _execute_scenario(
                                corpus,
                                scenario,
                                canonical,
                                bun,
                                runtime_home,
                                log_dir,
                                environment,
                                command_runner,
                                run_index,
                                run_count,
                                attempt_index,
                            )
                            break
                        except Exception:
                            if attempt_index + 1 >= attempts:
                                raise
                            _reset_failed_tmux_e2e_attempt(
                                runtime_home,
                                scenario,
                                environment,
                                state,
                            )
                            print(
                                f"[pgso] retrying failed tmux E2E scenario "
                                f"after isolated state reset: {scenario.name}",
                                file=sys.stderr,
                            )
                    elapsed_seconds += command_result.elapsed_seconds
                assert command_result is not None
                raw_profiles = finish(scenario, command_result, state)
                merged_raw_profiles += raw_profiles
            except Exception as error:
                results.append(
                    ScenarioResult(
                        name=scenario.name,
                        status="failed",
                        elapsed_seconds=(
                            elapsed_seconds
                        ),
                        raw_profiles=0,
                        error=str(error),
                    )
                )
                result = _result(results, merged_raw_profiles)
                raise CorpusRunError(
                    f"{failure_label} scenario failed: {scenario.name}: {error}",
                    result,
                ) from error

            results.append(
                ScenarioResult(
                    name=scenario.name,
                    status="passed",
                    elapsed_seconds=elapsed_seconds,
                    raw_profiles=raw_profiles,
                )
            )
    return _result(results, merged_raw_profiles)


def run_corpus(
    corpus: Corpus,
    binary: pathlib.Path,
    profile_dir: pathlib.Path,
    merged_profile: pathlib.Path,
    *,
    toolchain: object,
    bun: pathlib.Path | str = "bun",
    command_runner: Callable[..., CommandResult] = run_checked,
    profile_merger: Callable[..., int] = merge_profile_batch,
) -> CorpusResult:
    profile_dir.mkdir(parents=True, exist_ok=True)
    log_dir = profile_dir.parent.parent / "logs" / "corpus"
    log_dir.mkdir(parents=True, exist_ok=True)
    runtime_home = profile_dir.parent / "home"
    runtime_home.mkdir(parents=True, exist_ok=True)
    def prepare(scenario: Scenario, environment: dict[str, str]) -> object:
        environment["LLVM_PROFILE_FILE"] = str(
            profile_dir / f"{scenario.name}-%m-%p-%c.profraw"
        )
        return set(profile_dir.glob("*.profraw"))

    def finish(
        scenario: Scenario,
        _command_result: CommandResult,
        state: object,
    ) -> int:
        before = state
        if not isinstance(before, set):
            raise PgsoError("invalid training profile snapshot")
        generated = tuple(sorted(set(profile_dir.glob("*.profraw")) - before))
        if not generated or any(
            not profile.is_file() or profile.stat().st_size == 0
            for profile in generated
        ):
            raise PgsoError("produced no raw profile")
        try:
            return profile_merger(
                toolchain,
                generated,
                merged_profile,
                log_dir / f"{scenario.name}-merge.json",
            )
        except Exception as error:
            raise PgsoError(f"profile merge failed: {error}") from error

    return _run_scenarios(
        corpus,
        binary,
        corpus.scenarios,
        bun=bun,
        runtime_home=runtime_home,
        log_dir=log_dir,
        prepare=prepare,
        finish=finish,
        failure_label="training corpus",
        command_runner=command_runner,
        repeat_profile_runs=True,
    )


def run_behavior_corpus(
    corpus: Corpus,
    binary: pathlib.Path,
    output_dir: pathlib.Path,
    *,
    bun: pathlib.Path | str = "bun",
    command_runner: Callable[..., CommandResult] = run_checked,
) -> CorpusResult:
    log_dir = output_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    trace_dir = output_dir / "traces"
    trace_dir.mkdir(parents=True, exist_ok=True)
    runtime_home = output_dir / "home"
    runtime_home.mkdir(parents=True, exist_ok=True)
    def prepare(scenario: Scenario, environment: dict[str, str]) -> object:
        trace_path = trace_dir / f"{scenario.name}.log"
        trace_path.unlink(missing_ok=True)
        environment["FX_TRACE_LOG"] = str(trace_path)
        return None

    def finish(
        _scenario: Scenario,
        _command_result: CommandResult,
        _state: object,
    ) -> int:
        return 0

    return _run_scenarios(
        corpus,
        binary,
        corpus.candidate_scenarios,
        bun=bun,
        runtime_home=runtime_home,
        log_dir=log_dir,
        prepare=prepare,
        finish=finish,
        failure_label="behavior corpus",
        command_runner=command_runner,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inspect the fx PGSO corpus")
    parser.add_argument(
        "--manifest",
        required=True,
        type=pathlib.Path,
    )
    parser.add_argument("--list", action="store_true")
    arguments = parser.parse_args(argv)
    corpus = load_corpus(arguments.manifest)
    if not arguments.list:
        parser.error("only --list is supported by this module")
    for scenario in corpus.scenarios:
        source = scenario.test_file or "direct"
        print(f"training\t{scenario.name}\t{source}")
    for scenario in corpus.verification_scenarios:
        source = scenario.test_file or "direct"
        print(f"verification\t{scenario.name}\t{source}")
    print("intentional exclusions:")
    for test_file, reason in corpus.intentional_exclusions:
        print(f"{test_file}\t{reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
