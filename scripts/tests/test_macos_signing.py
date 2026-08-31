from __future__ import annotations

import base64
import json
import os
import pathlib
import re
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "sign-and-notarize-macos.sh"
RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
PUBLISH_LIBFX_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "publish-libfx.yml"
)
PGSO_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "pgso-macos-arm64.yml"
)
DEV_RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "dev-release.yml"
PGSO_SETUP_ACTION_PATH = REPO_ROOT / ".github" / "actions" / "setup-pgso" / "action.yml"
SIGNING_IDENTITY = "Developer ID Application: Vercel, Inc (JW6Y669B67)"
TEST_CDHASH = "0123456789abcdef0123456789abcdef01234567"
SECRET_NAMES = (
    "APPLE_DEVELOPER_ID_P12_BASE64",
    "APPLE_DEVELOPER_ID_P12_PASSWORD",
    "APPLE_NOTARY_KEY_P8_BASE64",
    "APPLE_NOTARY_KEY_ID",
    "APPLE_NOTARY_ISSUER_ID",
)


class MacosSigningScriptTests(unittest.TestCase):
    def write_tool(self, root: pathlib.Path, name: str, body: str) -> pathlib.Path:
        path = root / name
        path.write_text(
            "#!/usr/bin/env python3\n" + textwrap.dedent(body),
            encoding="utf-8",
        )
        path.chmod(0o755)
        return path

    def make_tools(self, root: pathlib.Path) -> dict[str, pathlib.Path]:
        tools = root / "tools"
        tools.mkdir()

        openssl = self.write_tool(
            tools,
            "openssl",
            r'''
import base64
import os
import pathlib
import sys

args = sys.argv[1:]
if args[:2] == ["rand", "-hex"]:
    print("temporary-keychain-password")
    raise SystemExit(0)
if args and args[0] == "base64":
    output = pathlib.Path(args[args.index("-out") + 1])
    output.write_bytes(base64.b64decode(sys.stdin.buffer.read()))
    raise SystemExit(0)
raise SystemExit(f"unexpected openssl arguments: {args}")
''',
        )
        security = self.write_tool(
            tools,
            "security",
            f'''
import os
import pathlib
import sys

args = sys.argv[1:]
event_log = pathlib.Path(os.environ["FX_SIGNING_TEST_LOG"])
with event_log.open("a") as log:
    log.write("security " + " ".join(args) + "\\n")
if args and args[0] == os.environ.get("FX_SIGNING_TEST_SECURITY_FAIL_COMMAND"):
    print("injected security failure", file=sys.stderr)
    raise SystemExit(1)
if args and args[0] == "set-key-partition-list":
    import_event = next(
        line
        for line in event_log.read_text(encoding="utf-8").splitlines()
        if line.startswith("security import ")
    )
    partition_list = args[args.index("-S") + 1] if "-S" in args else ""
    key_type = args[args.index("-t") + 1] if "-t" in args else ""
    search_list_configured = any(
        line.startswith("security list-keychains -d user -s ")
        for line in event_log.read_text(encoding="utf-8").splitlines()
    )
    if (
        "-s" in args
        or partition_list != "apple-tool:,apple:"
        or key_type != "private"
        or "-l" in args
        or not search_list_configured
        or " -t cert " in f" {{import_event}} "
    ):
        print("error: The specified item could not be found in the keychain.", file=sys.stderr)
        raise SystemExit(1)
if args and args[0] == "find-identity":
    print('  1) HASH "{SIGNING_IDENTITY}"')
    print("     1 valid identities found")
''',
        )
        codesign = self.write_tool(
            tools,
            "codesign",
            f'''
import os
import pathlib
import sys

args = sys.argv[1:]
with pathlib.Path(os.environ["FX_SIGNING_TEST_LOG"]).open("a") as log:
    log.write("codesign " + " ".join(args) + "\\n")
if os.environ.get("FX_SIGNING_TEST_CODESIGN_FAIL_STAGE") == "sign" and "--force" in args:
    print("injected codesign failure", file=sys.stderr)
    raise SystemExit(1)
if "--force" in args:
    binary = pathlib.Path(args[-1])
    binary.write_bytes(binary.read_bytes() + b"signed\\n")
if "--display" in args:
    identifier = os.environ.get("FX_SIGNING_TEST_IDENTIFIER", "com.vercel.fx")
    team_id = os.environ.get("FX_SIGNING_TEST_TEAM_ID", "JW6Y669B67")
    print(f"Identifier={{identifier}}", file=sys.stderr)
    print(f"TeamIdentifier={{team_id}}", file=sys.stderr)
    print("CDHash={TEST_CDHASH}", file=sys.stderr)
''',
        )
        ditto = self.write_tool(
            tools,
            "ditto",
            r'''
import os
import pathlib
import sys

args = sys.argv[1:]
with pathlib.Path(os.environ["FX_SIGNING_TEST_LOG"]).open("a") as log:
    log.write("ditto " + " ".join(args) + "\n")
pathlib.Path(args[-1]).write_bytes(b"notary archive")
''',
        )
        xcrun = self.write_tool(
            tools,
            "xcrun",
            f'''
import json
import os
import pathlib
import sys

args = sys.argv[1:]
with pathlib.Path(os.environ["FX_SIGNING_TEST_LOG"]).open("a") as log:
    log.write("xcrun " + " ".join(args[:2]) + "\\n")
if len(args) > 1 and args[1] == os.environ.get("FX_SIGNING_TEST_XCRUN_FAIL_COMMAND"):
    print("injected xcrun failure", file=sys.stderr)
    raise SystemExit(1)
if args[:2] == ["notarytool", "submit"]:
    status = os.environ.get("FX_SIGNING_TEST_SUBMISSION_STATUS", "Accepted")
    print(json.dumps({{"id": "test-submission", "status": status}}))
elif args[:2] == ["notarytool", "log"]:
    issues = json.loads(os.environ.get("FX_SIGNING_TEST_NOTARY_ISSUES", "null"))
    ticket_cdhash = os.environ.get("FX_SIGNING_TEST_TICKET_CDHASH", "{TEST_CDHASH}")
    pathlib.Path(args[-1]).write_text(json.dumps({{
        "status": "Accepted",
        "statusSummary": "Ready for distribution",
        "statusCode": 0,
        "issues": issues,
        "ticketContents": [{{"cdhash": ticket_cdhash, "arch": "arm64"}}],
    }}))
else:
    raise SystemExit(f"unexpected xcrun arguments: {{args}}")
''',
        )
        return {
            "FX_SIGNING_OPENSSL_BIN": openssl,
            "FX_SIGNING_SECURITY_BIN": security,
            "FX_SIGNING_CODESIGN_BIN": codesign,
            "FX_SIGNING_DITTO_BIN": ditto,
            "FX_SIGNING_XCRUN_BIN": xcrun,
        }

    def run_script(
        self,
        root: pathlib.Path,
        extra_env: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path, pathlib.Path, pathlib.Path]:
        runner_temp = root / "runner-temp"
        runner_temp.mkdir()
        tool_paths = self.make_tools(root)
        binary = root / "fx"
        binary.write_bytes(b"unsigned\n")
        binary.chmod(0o755)
        event_log = root / "events.log"
        env = os.environ.copy()
        env.update(
            {
                "RUNNER_TEMP": str(runner_temp),
                "FX_SIGNING_TEST_LOG": str(event_log),
                "APPLE_DEVELOPER_ID_P12_BASE64": base64.b64encode(
                    b"p12-private-material"
                ).decode(),
                "APPLE_DEVELOPER_ID_P12_PASSWORD": "p12-password",
                "APPLE_NOTARY_KEY_P8_BASE64": base64.b64encode(
                    b"p8-private-material"
                ).decode(),
                "APPLE_NOTARY_KEY_ID": "TESTKEY123",
                "APPLE_NOTARY_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
            }
        )
        env.update({key: str(value) for key, value in tool_paths.items()})
        if extra_env:
            env.update(extra_env)
        result = subprocess.run(
            [str(SCRIPT_PATH), str(binary)],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        return result, binary, runner_temp, event_log

    def test_signs_notarizes_and_cleans_credentials_without_printing_secrets(
        self,
    ) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)
            p12_secret = "p12-private-material"
            p8_secret = "p8-private-material"
            p12_password = "p12-password"
            result, binary, runner_temp, event_log = self.run_script(root)

            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            self.assertEqual(b"unsigned\nsigned\n", binary.read_bytes())
            self.assertIn("test-submission", output)
            self.assertNotIn(p12_secret, output)
            self.assertNotIn(p8_secret, output)
            self.assertNotIn(p12_password, output)
            self.assertEqual([], list(runner_temp.iterdir()))
            events = event_log.read_text(encoding="utf-8")
            self.assertIn("security import", events)
            self.assertIn("security delete-keychain", events)
            self.assertIn("codesign --force", events)
            self.assertIn("--identifier com.vercel.fx", events)
            self.assertIn("--options runtime", events)
            self.assertIn("--timestamp", events)
            self.assertIn("xcrun notarytool submit", events)
            self.assertIn("xcrun notarytool log", events)

    def test_imports_pkcs12_private_key_for_codesign_and_security(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)
            result, _, _, event_log = self.run_script(root)

            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            import_event = next(
                line
                for line in event_log.read_text(encoding="utf-8").splitlines()
                if line.startswith("security import ")
            )
            self.assertNotIn(" -t cert ", f" {import_event} ")
            self.assertIn(" -f pkcs12 ", f" {import_event} ")
            self.assertIn(" -T /usr/bin/codesign ", f" {import_event} ")
            self.assertIn(" -T /usr/bin/security ", f" {import_event} ")
            partition_event = next(
                line
                for line in event_log.read_text(encoding="utf-8").splitlines()
                if line.startswith("security set-key-partition-list ")
            )
            partition_args = partition_event.split()[2:]
            self.assertEqual(
                "apple-tool:,apple:",
                partition_args[partition_args.index("-S") + 1],
            )
            self.assertEqual(
                "private",
                partition_args[partition_args.index("-t") + 1],
            )
            self.assertNotIn("-l", partition_args)
            self.assertNotIn("-s", partition_args)
            self.assertNotIn("codesign:", partition_args)
            events = event_log.read_text(encoding="utf-8").splitlines()
            search_index = next(
                index
                for index, line in enumerate(events)
                if line.startswith("security list-keychains -d user -s ")
            )
            partition_index = events.index(partition_event)
            self.assertLess(search_index, partition_index)

    def test_reports_failing_signing_stage_without_printing_secrets(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        cases = (
            (
                {"FX_SIGNING_TEST_SECURITY_FAIL_COMMAND": "import"},
                "PKCS#12 import",
            ),
            (
                {"FX_SIGNING_TEST_SECURITY_FAIL_COMMAND": "list-keychains"},
                "keychain search configuration",
            ),
            (
                {"FX_SIGNING_TEST_SECURITY_FAIL_COMMAND": "set-key-partition-list"},
                "private-key ACL configuration",
            ),
            (
                {"FX_SIGNING_TEST_SECURITY_FAIL_COMMAND": "find-identity"},
                "signing identity lookup",
            ),
            (
                {"FX_SIGNING_TEST_CODESIGN_FAIL_STAGE": "sign"},
                "code signing",
            ),
            (
                {"FX_SIGNING_TEST_XCRUN_FAIL_COMMAND": "submit"},
                "notarization submission",
            ),
        )
        for extra_env, stage in cases:
            with self.subTest(stage=stage):
                with tempfile.TemporaryDirectory(
                    prefix="fx-macos-signing-test-"
                ) as tmp:
                    root = pathlib.Path(tmp)
                    result, _, _, _ = self.run_script(root, extra_env)

                    output = result.stdout + result.stderr
                    self.assertNotEqual(0, result.returncode, output)
                    self.assertIn(f"Apple signing failed during {stage}", output)
                    self.assertNotIn("p12-password", output)
                    self.assertNotIn("p8-private-material", output)

    def test_rejects_notarization_log_issues_and_cleans_credentials(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)
            issues = json.dumps(
                [
                    {
                        "severity": "warning",
                        "message": "unexpected notarization warning",
                    }
                ]
            )

            result, _, runner_temp, event_log = self.run_script(
                root,
                {"FX_SIGNING_TEST_NOTARY_ISSUES": issues},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("notarization log contains issues", output)
            self.assertEqual([], list(runner_temp.iterdir()))
            self.assertIn(
                "security delete-keychain",
                event_log.read_text(encoding="utf-8"),
            )

    def test_rejects_empty_secret_without_echoing_credential_material(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {"APPLE_DEVELOPER_ID_P12_BASE64": ""},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn(
                "Missing required environment variable: "
                "APPLE_DEVELOPER_ID_P12_BASE64",
                output,
            )
            self.assertNotIn("p12-password", output)
            self.assertNotIn("p8-private-material", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_signature_from_the_wrong_apple_team(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {"FX_SIGNING_TEST_TEAM_ID": "WRONGTEAM1"},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("wrong team identifier", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_signature_with_the_wrong_identifier(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {"FX_SIGNING_TEST_IDENTIFIER": "com.example.fx"},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("wrong signing identifier", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_notarization_ticket_for_another_binary(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, _ = self.run_script(
                root,
                {
                    "FX_SIGNING_TEST_TICKET_CDHASH":
                        "ffffffffffffffffffffffffffffffffffffffff"
                },
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("ticket does not match", output)
            self.assertEqual([], list(runner_temp.iterdir()))

    def test_rejects_a_failed_notarization_submission(self) -> None:
        self.assertTrue(SCRIPT_PATH.is_file(), "macOS signing helper is missing")
        with tempfile.TemporaryDirectory(prefix="fx-macos-signing-test-") as tmp:
            root = pathlib.Path(tmp)

            result, _, runner_temp, event_log = self.run_script(
                root,
                {"FX_SIGNING_TEST_SUBMISSION_STATUS": "Invalid"},
            )

            output = result.stdout + result.stderr
            self.assertNotEqual(0, result.returncode, output)
            self.assertIn("notarization failed with status: Invalid", output)
            self.assertNotIn(
                "xcrun notarytool log",
                event_log.read_text(encoding="utf-8"),
            )
            self.assertEqual([], list(runner_temp.iterdir()))


class MacosSigningWorkflowTests(unittest.TestCase):
    def test_every_privileged_publish_job_uses_an_environment_gate(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        publish_libfx = PUBLISH_LIBFX_WORKFLOW_PATH.read_text(encoding="utf-8")

        release_job = release.split("  release:\n", 1)[1]
        npm_publish_job = publish_libfx.split("  publish:\n", 1)[1]

        self.assertIn("environment: release", release_job)
        self.assertIn("environment: npm", npm_publish_job)

    def test_stable_release_is_the_only_workflow_with_signing_secrets(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        pgso = PGSO_WORKFLOW_PATH.read_text(encoding="utf-8")
        dev_release = DEV_RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")

        self.assertIn("build-macos-x86_64:", release)
        self.assertIn("runs-on: macos-15-intel", release)
        self.assertIn("sign-macos-arm64:", release)
        self.assertEqual(2, release.count("environment: apple-signing"))
        self.assertIn("scripts/sign-and-notarize-macos.sh zig-out/bin/fx", release)
        self.assertNotIn("sign-stable-release:", pgso)
        self.assertNotIn("package_release", pgso)
        self.assertNotIn("environment: apple-signing", pgso)
        self.assertIn(
            "scripts/sign-and-notarize-macos.sh "
            '"$RUNNER_TEMP/fx-pgso-aggregate/candidate/fx"',
            release,
        )
        arm64_caller = release.split("  build-macos-arm64:\n", 1)[1].split(
            "\n  sign-macos-arm64:\n", 1
        )[0]
        self.assertNotIn("secrets:", arm64_caller)
        self.assertNotIn("package_release", arm64_caller)
        sign_release = release.split("  sign-macos-arm64:\n", 1)[1].split(
            "\n  release:\n", 1
        )[0]
        self.assertIn("needs: [check-version, build-macos-arm64]", sign_release)
        self.assertIn("environment: apple-signing", sign_release)
        self.assertIn(
            "needs: [check-version, build-linux, build-macos-x86_64, sign-macos-arm64]",
            release,
        )
        workflow_call = pgso.split("  workflow_dispatch:\n", 1)[0]
        aggregate = pgso.split("  aggregate:\n", 1)[1].split(
            "\n  sign-macos-arm64:\n", 1
        )[0]
        self.assertIn(
            "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            sign_release,
        )
        self.assertIn(
            "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093",
            sign_release,
        )
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            sign_release,
        )
        report_position = sign_release.index("python3 -m scripts.pgso report")
        signing_position = sign_release.index("scripts/sign-and-notarize-macos.sh")
        package_position = sign_release.index("tar -czf")
        self.assertLess(report_position, signing_position)
        self.assertLess(signing_position, package_position)
        for secret_name in SECRET_NAMES:
            secret_reference = f"${{{{ secrets.{secret_name} }}}}"
            self.assertIn(secret_reference, release)
            self.assertIn(secret_reference, sign_release)
            self.assertNotIn(secret_name, workflow_call)
            self.assertNotIn(secret_name, aggregate)
            self.assertNotIn(secret_name, pgso)
            self.assertNotIn(secret_name, dev_release)
        self.assertNotIn("sign-and-notarize-macos", pgso)
        self.assertNotIn("sign-and-notarize-macos", dev_release)

    def test_pgso_release_chain_pins_every_external_action(self) -> None:
        mutable_references: list[str] = []
        for path in (PGSO_WORKFLOW_PATH, PGSO_SETUP_ACTION_PATH):
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(),
                start=1,
            ):
                match = re.search(r"uses:\s+([^\s@]+)@([^\s#]+)", line)
                if match and not re.fullmatch(r"[0-9a-f]{40}", match.group(2)):
                    mutable_references.append(
                        f"{path.relative_to(REPO_ROOT)}:{line_number}: {line.strip()}"
                    )

        self.assertEqual([], mutable_references)


if __name__ == "__main__":
    unittest.main()
