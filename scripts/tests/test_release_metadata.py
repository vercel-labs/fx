from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
CHECKOUT_SHA = "a" * 40
SOURCE_SHA = "0123456789abcdef" * 2 + "01234567"
WEBSITE_SHA = "c" * 40


def workflow_script(filename: str, step_name: str) -> str:
    workflow = (WORKFLOWS / filename).read_text(encoding="utf-8")
    step = workflow.split(f"      - name: {step_name}\n", 1)[1]
    lines = []
    for line in step.split("        run: |\n", 1)[1].splitlines():
        if line.strip() and not line.startswith("          "):
            break
        lines.append(line)
    return textwrap.dedent("\n".join(lines))


GIT_FIXTURE = r'''
import json
import os
import pathlib
import sys

root = pathlib.Path(os.environ["FX_METADATA_FIXTURE"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a", encoding="utf-8") as log:
    log.write(json.dumps(["git", *args]) + "\n")
fixture = json.loads((root / "fixture.json").read_text(encoding="utf-8"))
if len(args) == 4 and args[:2] == ["merge-base", "--is-ancestor"]:
    raise SystemExit(0 if args[2:] in fixture["ancestors"] else 1)
if len(args) == 2 and args[0] == "show":
    if args[1] not in fixture["sources"]:
        print("fatal: source revision not present", file=sys.stderr)
        raise SystemExit(128)
    print(fixture["sources"][args[1]], end="")
    raise SystemExit(0)
if len(args) == 2 and args[0] == "rev-parse":
    if args[1] in fixture["tags"]:
        print(fixture["tags"][args[1]])
        raise SystemExit(0)
    raise SystemExit(1)
raise SystemExit(f"unexpected git arguments: {args!r}")
'''


QUALIFICATION_FIXTURE = r'''
import json
import os
import pathlib
import sys

root = pathlib.Path(os.environ["FX_METADATA_FIXTURE"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a", encoding="utf-8") as log:
    log.write(json.dumps(["python3", *args]) + "\n")
fixture = json.loads((root / "fixture.json").read_text(encoding="utf-8"))
expected = fixture["qualification"]
if expected is None or args != expected["args"]:
    raise SystemExit(f"unexpected qualification command: {args!r}")
if expected["exit_code"]:
    print("release preparation is not qualified", file=sys.stderr)
raise SystemExit(expected["exit_code"])
'''


class WorkflowShellTests(unittest.TestCase):
    def run_workflow(
        self,
        filename: str,
        step_name: str,
        environment: dict[str, str],
        *,
        sources: dict[str, str] | None = None,
        tags: dict[str, str] | None = None,
        ancestors: list[list[str]] | None = None,
        qualification: dict[str, object] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, str], list[list[str]]]:
        with tempfile.TemporaryDirectory(prefix="fx-release-metadata-") as tmp:
            root = pathlib.Path(tmp)
            tools = root / "tools"
            tools.mkdir()
            for name, body in (
                ("git", GIT_FIXTURE),
                ("python3", QUALIFICATION_FIXTURE),
            ):
                executable = tools / name
                executable.write_text(
                    f"#!{sys.executable}\n" + textwrap.dedent(body),
                    encoding="utf-8",
                )
                executable.chmod(0o755)
            sed = shutil.which("sed")
            bash = shutil.which("bash")
            self.assertIsNotNone(sed)
            self.assertIsNotNone(bash)
            (tools / "sed").symlink_to(sed)
            (root / "src").mkdir()
            (root / "src/main.zig").write_text(
                'pub const version = "99.99.99";\n', encoding="utf-8"
            )
            (root / "fixture.json").write_text(
                json.dumps(
                    {
                        "sources": sources or {},
                        "tags": tags or {},
                        "ancestors": ancestors or [],
                        "qualification": qualification,
                    }
                ),
                encoding="utf-8",
            )
            output = root / "outputs"
            output.touch()
            calls = root / "calls.jsonl"
            calls.touch()
            result = subprocess.run(
                [bash, "--noprofile", "--norc", "-euo", "pipefail", "-c",
                 workflow_script(filename, step_name)],
                cwd=root,
                env={
                    "PATH": str(tools),
                    "LC_ALL": "C",
                    "FX_METADATA_FIXTURE": str(root),
                    "GITHUB_OUTPUT": str(output),
                    **environment,
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            outputs: dict[str, str] = {}
            for line in output.read_text(encoding="utf-8").splitlines():
                name, separator, value = line.partition("=")
                self.assertEqual("=", separator, f"invalid workflow output: {line!r}")
                self.assertNotIn(name, outputs, f"duplicate workflow output: {name}")
                outputs[name] = value
            return result, outputs, [
                json.loads(line)
                for line in calls.read_text(encoding="utf-8").splitlines()
            ]

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("", result.stderr)

    def assert_rejected(
        self, result: subprocess.CompletedProcess[str], outputs: dict[str, str]
    ) -> None:
        self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual({}, outputs, "rejected input emitted release metadata")


class PublicationMetadataTests(WorkflowShellTests):
    def resolve(
        self,
        *,
        source: str = 'pub const version = "0.8.12";\n',
        missing_source: bool = False,
        **environment: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, str], list[list[str]]]:
        env = {
            "EVENT_NAME": "workflow_run",
            "REQUESTED_CHANNEL": "",
            "REQUESTED_RUN": "",
            "WORKFLOW_NAME": "CI",
            "WORKFLOW_SHA": SOURCE_SHA,
            "WORKFLOW_RUN": "800",
            "GITHUB_SHA": CHECKOUT_SHA,
            "GITHUB_RUN_NUMBER": "42",
            "GITHUB_RUN_ID": "900",
            **environment,
        }
        sha = (
            env["GITHUB_SHA"]
            if env["EVENT_NAME"] == "workflow_dispatch"
            else env["WORKFLOW_SHA"]
        )
        return self.run_workflow(
            "publish-libfx.yml",
            "Resolve publication input",
            env,
            sources={} if missing_source else {f"{sha}:src/main.zig": source},
        )

    def test_dev_workflow_run_uses_source_version_and_commit(self) -> None:
        result, outputs, calls = self.resolve(
            REQUESTED_CHANNEL="stable", REQUESTED_RUN="123"
        )
        self.assert_success(result)
        self.assertEqual(
            {
                "channel": "dev",
                "npm_tag": "dev",
                "sha": SOURCE_SHA,
                "version": f"0.8.12-dev.42.g{SOURCE_SHA[:12]}",
                "run_id": "900",
            },
            outputs,
        )
        self.assertEqual([["git", "show", f"{SOURCE_SHA}:src/main.zig"]], calls)

    def test_manual_dev_uses_dispatch_commit_and_own_artifact_run(self) -> None:
        result, outputs, calls = self.resolve(
            EVENT_NAME="workflow_dispatch",
            REQUESTED_CHANNEL="dev",
            REQUESTED_RUN="123",
            WORKFLOW_NAME="Release",
        )
        self.assert_success(result)
        self.assertEqual(
            {
                "channel": "dev",
                "npm_tag": "dev",
                "sha": CHECKOUT_SHA,
                "version": f"0.8.12-dev.42.g{CHECKOUT_SHA[:12]}",
                "run_id": "900",
            },
            outputs,
        )
        self.assertEqual([["git", "show", f"{CHECKOUT_SHA}:src/main.zig"]], calls)

    def test_stable_workflow_run_selects_parent_before_version_or_tag_lookup(self) -> None:
        result, outputs, calls = self.resolve(
            WORKFLOW_NAME="Release", REQUESTED_RUN="123", missing_source=True
        )
        self.assert_success(result)
        self.assertEqual(
            {
                "channel": "stable",
                "npm_tag": "latest",
                "sha": SOURCE_SHA,
                "version": "",
                "run_id": "800",
            },
            outputs,
        )
        self.assertEqual([], calls)

    def test_manual_stable_selects_requested_prepared_run_without_source_lookup(self) -> None:
        result, outputs, calls = self.resolve(
            EVENT_NAME="workflow_dispatch",
            REQUESTED_CHANNEL="stable",
            REQUESTED_RUN="123",
            missing_source=True,
        )
        self.assert_success(result)
        self.assertEqual(
            {
                "channel": "stable",
                "npm_tag": "latest",
                "sha": CHECKOUT_SHA,
                "version": "",
                "run_id": "123",
            },
            outputs,
        )
        self.assertEqual([], calls)

    def test_stable_rejects_missing_or_malformed_prepared_run(self) -> None:
        for event in ("workflow_dispatch", "workflow_run"):
            for run_id in ("", "0", "01", "-1", "1.5", "abc", "12\nrun_id=34"):
                with self.subTest(event=event, run_id=run_id):
                    result, outputs, calls = self.resolve(
                        EVENT_NAME=event,
                        REQUESTED_CHANNEL="stable",
                        REQUESTED_RUN=run_id,
                        WORKFLOW_NAME="Release",
                        WORKFLOW_RUN=run_id,
                    )
                    self.assert_rejected(result, outputs)
                    self.assertEqual([], calls)

    def test_rejects_malformed_source_sha_in_both_trigger_paths(self) -> None:
        for event in ("workflow_dispatch", "workflow_run"):
            for channel in ("dev", "stable"):
                for sha in ("", "main", "a" * 39, "a" * 41, "A" * 40, SOURCE_SHA + "\n"):
                    with self.subTest(event=event, channel=channel, sha=sha):
                        result, outputs, calls = self.resolve(
                            EVENT_NAME=event,
                            REQUESTED_CHANNEL=channel,
                            REQUESTED_RUN="123",
                            WORKFLOW_NAME="Release" if channel == "stable" else "CI",
                            GITHUB_SHA=sha,
                            WORKFLOW_SHA=sha,
                        )
                        self.assert_rejected(result, outputs)
                        self.assertEqual([], calls)

    def test_manual_publication_rejects_unknown_channel(self) -> None:
        for channel in ("", "Stable", "latest", "next", "dev\nversion=9.0.0"):
            with self.subTest(channel=channel):
                result, outputs, calls = self.resolve(
                    EVENT_NAME="workflow_dispatch", REQUESTED_CHANNEL=channel
                )
                self.assert_rejected(result, outputs)
                self.assertIn("unknown publication channel", result.stdout)
                self.assertEqual([], calls)

    def test_dev_rejects_invalid_source_version_before_emitting_metadata(self) -> None:
        for version in ("", "0.8", "v0.8.12", "01.8.12", "0.08.12", "0.8.012",
                        "0.8.12-rc.1", "0.8.12+build", "0.8.12 ", "0.8.12\nrun_id=1"):
            with self.subTest(version=version):
                result, outputs, calls = self.resolve(
                    source=f'pub const version = "{version}";\n'
                )
                self.assert_rejected(result, outputs)
                self.assertEqual([["git", "show", f"{SOURCE_SHA}:src/main.zig"]], calls)

    def test_dev_rejects_missing_or_ambiguous_source_version(self) -> None:
        for source in (
            "// no version declaration\n",
            'pub const version = "0.8.12";\npub const version = "0.8.13";\n',
        ):
            with self.subTest(source=source):
                result, outputs, _ = self.resolve(source=source)
                self.assert_rejected(result, outputs)
        result, outputs, _ = self.resolve(missing_source=True)
        self.assert_rejected(result, outputs)
        self.assertIn("source revision not present", result.stderr)

    def test_dev_accepts_zero_and_multidigit_semver_components(self) -> None:
        for version in ("0.0.0", "10.20.300"):
            with self.subTest(version=version):
                result, outputs, _ = self.resolve(
                    source=f'pub const version = "{version}";\n'
                )
                self.assert_success(result)
                self.assertEqual(f"{version}-dev.42.g{SOURCE_SHA[:12]}", outputs["version"])


class ReleaseCheckMetadataTests(WorkflowShellTests):
    def check(
        self,
        *,
        source: str = 'pub const version = "0.8.12";\n',
        tag_exists: bool = False,
        missing_source: bool = False,
        qualified: bool | None = None,
        source_on_main: bool = True,
        **environment: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, str], list[list[str]]]:
        env = {
            "VALIDATE_ONLY": "false",
            "SOURCE_OVERRIDE": "",
            "WEB_OVERRIDE": "",
            "RELEASE_PR": "",
            "GITHUB_SHA": CHECKOUT_SHA,
            **environment,
        }
        sha = env["SOURCE_OVERRIDE"] or env["GITHUB_SHA"]
        qualification = None
        if qualified is not None:
            qualification = {
                "args": [
                    "-m", "scripts.release_preparation", "wait",
                    "--pr", env["RELEASE_PR"], "--source-sha", sha,
                ],
                "exit_code": 0 if qualified else 1,
            }
        return self.run_workflow(
            "release.yml",
            "Check if release needed",
            env,
            sources={} if missing_source else {f"{sha}:src/main.zig": source},
            tags={"v0.8.12": SOURCE_SHA} if tag_exists else {},
            ancestors=[[sha, env["GITHUB_SHA"]]] if source_on_main else [],
            qualification=qualification,
        )

    def expected_outputs(
        self, *, needed: str, publish: str, sha: str = CHECKOUT_SHA, pr: str = "0"
    ) -> dict[str, str]:
        return {
            "version": "v0.8.12",
            "sdk_version": "0.8.12",
            "source_sha": sha,
            "release_pr": pr,
            "needed": needed,
            "publish": publish,
        }

    def test_existing_tag_skips_normal_release_but_never_skips_rehearsal(self) -> None:
        for validate, tag_exists, needed, publish in (
            ("true", True, "true", "false"),
            ("true", False, "true", "false"),
            ("false", True, "false", "false"),
            ("false", False, "true", "true"),
        ):
            with self.subTest(validate=validate, tag_exists=tag_exists):
                result, outputs, calls = self.check(
                    VALIDATE_ONLY=validate, tag_exists=tag_exists
                )
                self.assert_success(result)
                self.assertEqual(self.expected_outputs(needed=needed, publish=publish), outputs)
                expected_calls = [
                    ["git", "merge-base", "--is-ancestor", CHECKOUT_SHA, CHECKOUT_SHA],
                    ["git", "show", f"{CHECKOUT_SHA}:src/main.zig"],
                ]
                if validate == "false":
                    expected_calls.append(["git", "rev-parse", "v0.8.12"])
                self.assertEqual(expected_calls, calls)

    def test_publishing_source_override_requires_release_pr(self) -> None:
        result, outputs, calls = self.check(SOURCE_OVERRIDE=SOURCE_SHA)
        self.assert_rejected(result, outputs)
        self.assertIn("requires a qualified release PR", result.stdout)
        self.assertEqual([], calls)

    def test_release_pr_qualification_precedes_source_and_tag_lookup(self) -> None:
        for override in ("", SOURCE_SHA):
            with self.subTest(override=override):
                sha = override or CHECKOUT_SHA
                result, outputs, calls = self.check(
                    SOURCE_OVERRIDE=override, RELEASE_PR="321", qualified=True,
                    source_on_main=False,
                )
                self.assert_success(result)
                self.assertEqual(
                    self.expected_outputs(needed="true", publish="true", sha=sha, pr="321"),
                    outputs,
                )
                self.assertEqual(
                    [
                        ["python3", "-m", "scripts.release_preparation", "wait",
                         "--pr", "321", "--source-sha", sha],
                        ["git", "show", f"{sha}:src/main.zig"],
                        ["git", "rev-parse", "v0.8.12"],
                    ],
                    calls,
                )

    def test_failed_release_pr_qualification_emits_no_metadata(self) -> None:
        for validate in ("true", "false"):
            with self.subTest(validate=validate):
                result, outputs, calls = self.check(
                    VALIDATE_ONLY=validate,
                    SOURCE_OVERRIDE=SOURCE_SHA,
                    RELEASE_PR="321",
                    qualified=False,
                )
                self.assert_rejected(result, outputs)
                self.assertIn("not qualified", result.stderr)
                self.assertEqual(
                    [["python3", "-m", "scripts.release_preparation", "wait",
                      "--pr", "321", "--source-sha", SOURCE_SHA]],
                    calls,
                )

    def test_rejects_malformed_release_pr_before_qualification(self) -> None:
        for pr in ("0", "01", "-1", "1.5", "abc", "321\nrelease_pr=1"):
            with self.subTest(pr=pr):
                result, outputs, calls = self.check(RELEASE_PR=pr)
                self.assert_rejected(result, outputs)
                self.assertIn("positive PR number", result.stdout)
                self.assertEqual([], calls)

    def test_rehearsal_accepts_reviewed_source_override_without_release_pr(self) -> None:
        result, outputs, calls = self.check(
            VALIDATE_ONLY="true", SOURCE_OVERRIDE=SOURCE_SHA
        )
        self.assert_success(result)
        self.assertEqual(
            self.expected_outputs(needed="true", publish="false", sha=SOURCE_SHA), outputs
        )
        self.assertEqual(
            [
                ["git", "merge-base", "--is-ancestor", SOURCE_SHA, CHECKOUT_SHA],
                ["git", "show", f"{SOURCE_SHA}:src/main.zig"],
            ],
            calls,
        )

    def test_rehearsal_rejects_source_not_reviewed_on_main_before_reading_version(self) -> None:
        result, outputs, calls = self.check(
            VALIDATE_ONLY="true", SOURCE_OVERRIDE=SOURCE_SHA, source_on_main=False
        )
        self.assert_rejected(result, outputs)
        self.assertIn("only build source already reviewed on main", result.stdout)
        self.assertEqual(
            [["git", "merge-base", "--is-ancestor", SOURCE_SHA, CHECKOUT_SHA]], calls
        )

    def test_website_override_is_rehearsal_only_even_with_qualified_release_pr(self) -> None:
        result, outputs, calls = self.check(
            WEB_OVERRIDE=WEBSITE_SHA, RELEASE_PR="321", qualified=True
        )
        self.assert_rejected(result, outputs)
        self.assertIn("website source overrides are allowed only for rehearsals", result.stdout)
        self.assertEqual([], calls)

        result, outputs, calls = self.check(
            VALIDATE_ONLY="true", WEB_OVERRIDE=WEBSITE_SHA
        )
        self.assert_success(result)
        self.assertEqual(self.expected_outputs(needed="true", publish="false"), outputs)
        self.assertEqual(
            [
                ["git", "merge-base", "--is-ancestor", CHECKOUT_SHA, CHECKOUT_SHA],
                ["git", "show", f"{CHECKOUT_SHA}:src/main.zig"],
            ],
            calls,
        )

    def test_rejects_malformed_source_and_website_overrides(self) -> None:
        for name in ("SOURCE_OVERRIDE", "WEB_OVERRIDE"):
            for sha in ("main", "a" * 39, "a" * 41, "A" * 40, SOURCE_SHA + "\n"):
                with self.subTest(name=name, sha=sha):
                    result, outputs, calls = self.check(VALIDATE_ONLY="true", **{name: sha})
                    self.assert_rejected(result, outputs)
                    self.assertIn("source overrides must be full commit SHAs", result.stdout)
                    self.assertEqual([], calls)

    def test_rejects_invalid_source_version_before_emitting_publish_outputs(self) -> None:
        for version in ("", "0.8", "v0.8.12", "01.8.12", "0.08.12", "0.8.012",
                        "0.8.12-rc.1", "0.8.12+build", "0.8.12 ", "0.8.12\npublish=true"):
            with self.subTest(version=version):
                result, outputs, calls = self.check(
                    source=f'pub const version = "{version}";\n'
                )
                self.assert_rejected(result, outputs)
                self.assertIn("version is not strict SemVer", result.stdout)
                self.assertEqual(
                    [
                        ["git", "merge-base", "--is-ancestor", CHECKOUT_SHA, CHECKOUT_SHA],
                        ["git", "show", f"{CHECKOUT_SHA}:src/main.zig"],
                    ],
                    calls,
                )

    def test_missing_or_ambiguous_version_cannot_enable_publication(self) -> None:
        for source in (
            "// no version declaration\n",
            'pub const version = "0.8.12";\npub const version = "0.8.13";\n',
        ):
            with self.subTest(source=source):
                result, outputs, _ = self.check(source=source)
                self.assert_rejected(result, outputs)
        result, outputs, _ = self.check(missing_source=True)
        self.assert_rejected(result, outputs)
        self.assertIn("source revision not present", result.stderr)


class WorkflowTrustBoundaryTests(unittest.TestCase):
    def job(self, filename: str, name: str) -> str:
        workflow = (WORKFLOWS / filename).read_text(encoding="utf-8")
        job = workflow.split(f"\n  {name}:\n", 1)[1]
        return re.split(r"\n  [a-zA-Z0-9_-]+:\n", job, maxsplit=1)[0]

    def test_release_entry_jobs_require_the_canonical_repository_and_main(self) -> None:
        guard = "github.repository == 'vercel-labs/fx' && github.ref == 'refs/heads/main'"
        for filename, name in (
            ("prepare-release.yml", "prepare"),
            ("release.yml", "check-version"),
            ("publish-libfx.yml", "metadata"),
        ):
            with self.subTest(filename=filename, job=name):
                job = self.job(filename, name)
                condition = re.search(r"(?m)^    if: (.*(?:\n      .*)*)", job)
                self.assertIsNotNone(condition)
                expression = " ".join(condition.group(1).removeprefix(">-").split())
                if filename == "publish-libfx.yml":
                    self.assertEqual(
                        guard + " && (github.event_name == 'workflow_dispatch' || "
                        "(github.event.workflow_run.conclusion == 'success' && "
                        "(github.event.workflow_run.event == 'push' || "
                        "(github.event.workflow_run.name == 'Release' && "
                        "github.event.workflow_run.event == 'workflow_dispatch')) && "
                        "github.event.workflow_run.head_repository.full_name == "
                        "github.repository))",
                        expression,
                    )
                else:
                    self.assertEqual(guard, expression)
                    self.assertIn("    environment: release-preparation\n", job)

    def test_both_signing_jobs_execute_scripts_from_the_trusted_workflow_commit(self) -> None:
        for name, signer_calls in (("build-macos-x86_64", 1), ("sign-macos-arm64", 3)):
            with self.subTest(job=name):
                job = self.job("release.yml", name)
                checkout_header = "      - name: Check out trusted signing scripts\n"
                checkout = job.split(checkout_header, 1)[1].split("\n      - ", 1)[0]
                self.assertRegex(checkout, r"uses: actions/checkout@[0-9a-f]{40}\b")
                self.assertIn("          ref: ${{ github.sha }}\n", checkout)
                self.assertIn("          path: .release-automation\n", checkout)
                self.assertIn("          persist-credentials: false", checkout)
                self.assertLess(job.index(checkout_header), job.index("- name: Sign and notarize"))
                invocations = [
                    line.strip().removeprefix("run: ")
                    for line in job.splitlines()
                    if "sign-and-notarize-macos.sh" in line
                ]
                self.assertEqual(signer_calls, len(invocations))
                for invocation in invocations:
                    self.assertTrue(
                        invocation.startswith(".release-automation/scripts/sign-and-notarize-macos.sh "),
                        invocation,
                    )
                if name == "sign-macos-arm64":
                    eligibility = job.split("      - name: Confirm release eligibility\n", 1)[1]
                    eligibility = eligibility.split("\n      - ", 1)[0]
                    self.assertIn("        working-directory: .release-automation\n", eligibility)


if __name__ == "__main__":
    unittest.main()
