from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts import release_examples as examples

SHA = "a" * 40
BASE = "b" * 40
CANDIDATE = {"version": "0.0.9", "source_sha": SHA}
TOKENS = {ident: f"fixture-{ident}-token" for ident in examples.PROJECTS}


def fixture(root: pathlib.Path) -> None:
    directory = root / "examples"
    directory.mkdir()
    (directory / "examples.json").write_text(json.dumps([{"id": ident} for ident in examples.PROJECTS]))
    (directory / "shared").mkdir()
    (directory / "shared/gateway.test.mjs").write_text("// fixture\n")
    for ident in examples.PROJECTS:
        app = directory / ident
        app.mkdir()
        (app / "package.json").write_text(json.dumps({"dependencies": {"libfx": "0.0.8"}}))
        (app / "package-lock.json").write_text(json.dumps({"packages": {
            "": {"dependencies": {"libfx": "0.0.8"}}, "node_modules/libfx": {"version": "0.0.8"}}}))


def prepared(ident: str) -> dict:
    slug = ident.replace("-", "")
    return dict(id=ident, project_id=examples.PROJECTS[ident], source_sha=SHA,
                sdk_version="0.0.8", validation="passed", affected=True,
                deployment_id=f"dpl_{slug}Prepared", previous_deployment_id=f"dpl_{slug}Previous",
                url=f"https://{ident}-prepared.vercel.app")


class Platform:
    def __init__(self, changed: list[str]):
        self.changed = changed
        self.events = []
        self.active = {ident: prepared(ident)["previous_deployment_id"] for ident in examples.PROJECTS}
        self.foreign = None

    def api(self, path: str, *, cwd: pathlib.Path, token: str) -> dict:
        self.events.append(("api", path))
        ident = next(ident for ident, expected in TOKENS.items() if token == expected)
        record = prepared(ident)
        if path.startswith("/v9/projects/"):
            return dict(id=examples.PROJECTS[ident], accountId="team_000000000000000000000000",
                        rootDirectory=f"examples/{ident}",
                        targets={"production": {"id": self.active[ident]}})
        if path.startswith("/v13/deployments/"):
            return dict(id=record["deployment_id"],
                        projectId=self.foreign or record["project_id"], readyState="READY",
                        target="production", url=record["url"].removeprefix("https://"),
                        meta=dict(fxSourceSha=SHA, fxExampleId=ident, fxSdkVersion="0.0.8"))
        raise AssertionError(path)

    def run(self, args: list[str], *, cwd: pathlib.Path, token: str | None = None) -> str:
        self.events.append(("run", tuple(args), cwd, token))
        if args[:3] == ["git", "rev-parse", "HEAD"]:
            return SHA
        if args[:3] == ["git", "rev-parse", "--verify"]:
            return BASE
        if args[:4] == ["git", "diff", "--name-only", "--no-renames"]:
            return "\0".join(self.changed) + ("\0" if self.changed else "")
        if args[0] == "git":
            return ""
        if args[:2] == ["node", "-p"]:
            return "24.18.0"
        if args[:2] == ["vercel", "deploy"]:
            project = json.loads((cwd / ".vercel/project.json").read_text())
            ident = next(ident for ident, value in examples.PROJECTS.items() if value == project["projectId"])
            return prepared(ident)["url"]
        if args[:2] == ["vercel", "promote"]:
            ident = next(ident for ident in examples.PROJECTS if prepared(ident)["deployment_id"] == args[2])
            self.active[ident] = args[2]
        return ""


class ReleaseExamplesTests(unittest.TestCase):
    def setUp(self):
        environment = mock.patch.dict(examples.os.environ, {"FX_RELEASE_VERCEL_TEAM_ID": "team_000000000000000000000000"})
        environment.start()
        self.addCleanup(environment.stop)

    def test_vercel_requests_require_a_configured_team_before_network_access(self):
        for value in ("", "invalid", "team_000000000000000000000000&other=1"):
            with mock.patch.dict(examples.os.environ, {"FX_RELEASE_VERCEL_TEAM_ID": value}), \
                    mock.patch.object(examples, "run", return_value="{}") as run:
                with self.assertRaisesRegex(ValueError, "FX_RELEASE_VERCEL_TEAM_ID"):
                    examples.vercel("/v9/projects/example", cwd=pathlib.Path("."), token="fixture")
                run.assert_not_called()
        with mock.patch.object(examples, "run", return_value="{}") as run:
            examples.vercel("/v9/projects/example", cwd=pathlib.Path("."), token="fixture")
        self.assertEqual(["vercel", "api", "/v9/projects/example?teamId=team_000000000000000000000000", "--scope", "team_000000000000000000000000", "--raw"], run.call_args.args[0])

    def test_affected_selection_covers_shared_catalog_and_individual_apps(self) -> None:
        self.assertEqual(set(), examples.affected_examples(["src/main.zig"]))
        self.assertEqual({"node-chat"}, examples.affected_examples(["examples/node-chat/handler.mjs"]))
        self.assertEqual({"node-chat", "nuxt-agent"}, examples.affected_examples(
            ["examples/node-chat/handler.mjs", "examples/nuxt-agent/package.json"]))
        for path in ("examples/shared/gateway.mjs", "examples/examples.json", "examples/README.md"):
            self.assertEqual(set(examples.PROJECTS), examples.affected_examples([path]))
        with self.assertRaisesRegex(ValueError, "no configured"):
            examples.affected_examples(["examples/unknown-app/package.json"])

    def test_catalog_rejects_new_ids_and_mutated_sdk_pins(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            fixture(root)
            self.assertEqual(dict.fromkeys(examples.PROJECTS, "0.0.8"), examples.catalog(root))
            path = root / "examples/node-chat/package.json"
            path.write_text('{"dependencies":{"libfx":"0.0.9"}}')
            with self.assertRaisesRegex(ValueError, "lockfile"):
                examples.catalog(root)
            path.write_text('{"dependencies":{"libfx":"^0.0.8"}}')
            with self.assertRaisesRegex(ValueError, "exact"):
                examples.catalog(root)
            (root / "examples/examples.json").write_text('[{"id":"unknown"}]')
            with self.assertRaisesRegex(ValueError, "exactly"):
                examples.catalog(root)

    def test_missing_multiple_credentials_fails_before_any_staging_or_tests(self) -> None:
        platform = Platform(["examples/shared/gateway.mjs"])
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            fixture(root)
            with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": '{"node-chat":"fixture"}'}), \
                    mock.patch.object(examples, "run", side_effect=platform.run), \
                    mock.patch.object(examples, "vercel", side_effect=platform.api):
                with self.assertRaisesRegex(ValueError, "browser-agent, nextjs-agent, nuxt-agent"):
                    examples.prepare_examples(CANDIDATE, "v0.0.8", root, root / "out")
        self.assertFalse(any(event[0] == "api" or (event[0] == "run" and event[1][0] != "git")
                             for event in platform.events))

    def test_all_four_are_qualified_with_unchanged_pins_when_nothing_is_affected(self) -> None:
        platform = Platform([])
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            fixture(root)
            before = {path: path.read_bytes() for path in (root / "examples").rglob("*") if path.is_file()}
            with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": "{}"}), \
                    mock.patch.object(examples, "run", side_effect=platform.run), \
                    mock.patch.object(examples, "vercel", side_effect=platform.api):
                records = examples.prepare_examples(CANDIDATE, "0.0.9", root, root / "out")
            self.assertEqual(set(examples.PROJECTS), {record["id"] for record in records})
            self.assertTrue(all(not record["affected"] and record["sdk_version"] == "0.0.8" for record in records))
            installs = [event for event in platform.events if event[0] == "run" and event[1] == ("npm", "ci")]
            self.assertEqual(4, len(installs))
            builds = [event for event in platform.events if event[0] == "run" and event[1] == ("npm", "run", "build")]
            self.assertEqual(3, len(builds))
            self.assertEqual(before, {path: path.read_bytes() for path in (root / "examples").rglob("*") if path.is_file()})
            self.assertFalse(any(event[0] == "api" for event in platform.events))

    def test_staging_qualifies_every_app_first_and_never_promotes(self) -> None:
        platform = Platform(["examples/browser-agent/main.js", "examples/nuxt-agent/app/app.vue"])
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            fixture(root)
            with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                    mock.patch.object(examples, "run", side_effect=platform.run), \
                    mock.patch.object(examples, "vercel", side_effect=platform.api):
                records = examples.prepare_examples(CANDIDATE, "0.0.8", root, root / "out")
            self.assertFalse((root / ".vercel").exists())
            commands = [event for event in platform.events if event[0] == "run"]
            first_vercel = next(index for index, event in enumerate(commands) if event[1][0] == "vercel")
            self.assertEqual(4, sum(event[1] == ("npm", "ci") for event in commands[:first_vercel]))
            deployments = [event for event in commands if event[1][:2] == ("vercel", "deploy")]
            self.assertEqual(2, len(deployments))
            for event in deployments:
                self.assertEqual(root.resolve(), event[2])
                self.assertIn("--prebuilt", event[1])
                self.assertIn("--prod", event[1])
                self.assertIn("--skip-domain", event[1])
                self.assertNotIn("--token", event[1])
            self.assertFalse(any(event[1][:2] == ("vercel", "promote") for event in commands))
            for record in records:
                if record["affected"]:
                    self.assertEqual(prepared(record["id"]), record)
            self.assertEqual(records, json.loads((root / "out/examples.json").read_text()))

    def test_existing_link_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / ".vercel").mkdir()
            path = root / ".vercel/project.json"
            path.write_text("existing settings")
            with self.assertRaisesRegex(ValueError, "existing .vercel"):
                with examples.linked_project(root, "node-chat"):
                    self.fail("must not replace the existing link")
            self.assertEqual("existing settings", path.read_text())

    def test_runner_passes_only_the_scoped_credential_without_changing_global_environment(self) -> None:
        environment = {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS), "VERCEL_TOKEN": "global",
                       "AI_GATEWAY_API_KEY": "gateway", "GH_TOKEN": "github"}
        with mock.patch.dict(examples.os.environ, environment), \
                mock.patch.object(examples.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "ok", "")) as run:
            self.assertEqual("ok", examples.run(["vercel", "api", "/project"], cwd=pathlib.Path("."), token="scoped"))
            passed = run.call_args.kwargs["env"]
            self.assertEqual("scoped", passed["VERCEL_TOKEN"])
            self.assertNotIn("FX_EXAMPLE_VERCEL_TOKENS", passed)
            self.assertNotIn("AI_GATEWAY_API_KEY", passed)
            self.assertNotIn("GH_TOKEN", passed)
            self.assertEqual("global", examples.os.environ["VERCEL_TOKEN"])
            self.assertNotIn("scoped", run.call_args.args[0])
            run.return_value = subprocess.CompletedProcess([], 1, "private setting", "scoped")
            with self.assertRaises(RuntimeError) as error:
                examples.run(["vercel", "build"], cwd=pathlib.Path("."), token="scoped")
            self.assertNotIn("scoped", str(error.exception))
            self.assertNotIn("private setting", str(error.exception))

    def test_unknown_duplicate_or_mixed_source_records_fail_before_api(self) -> None:
        record = prepared("node-chat")
        for records in (
            [dict(record, id="unknown")], [record, record],
            [dict(record, project_id=examples.PROJECTS["nuxt-agent"])],
            [record, dict(prepared("browser-agent"), source_sha=BASE)],
            [dict(record, validation="failed")],
        ):
            with self.subTest(records=records), mock.patch.object(examples, "vercel") as api:
                with self.assertRaises(ValueError):
                    examples.promote_examples(records)
                api.assert_not_called()

    def test_foreign_deployment_and_newer_production_fail_before_any_promotion(self) -> None:
        records = [prepared("node-chat"), prepared("nuxt-agent")]
        for foreign in (True, False):
            platform = Platform([])
            if foreign:
                platform.foreign = "prj_foreign"
            else:
                platform.active["nuxt-agent"] = "dpl_newer"
            with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                    mock.patch.object(examples, "run", side_effect=platform.run), \
                    mock.patch.object(examples, "vercel", side_effect=platform.api):
                with self.assertRaises(ValueError):
                    examples.promote_examples(records)
            self.assertFalse(any(event[0] == "run" for event in platform.events))

    def test_same_project_deployments_still_require_matching_source_sdk_and_example(self) -> None:
        record = prepared("node-chat")
        for key, wrong in (("fxSourceSha", BASE), ("fxSdkVersion", "0.0.9"), ("fxExampleId", "nuxt-agent")):
            platform = Platform([])

            def api(path: str, **kwargs) -> dict:
                result = platform.api(path, **kwargs)
                if path.startswith("/v13/deployments/"):
                    result["meta"][key] = wrong
                return result

            with self.subTest(key=key), \
                    mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                    mock.patch.object(examples, "run", side_effect=platform.run), \
                    mock.patch.object(examples, "vercel", side_effect=api):
                with self.assertRaisesRegex(ValueError, "identity differs"):
                    examples.promote_examples([record])
            self.assertFalse(any(event[0] == "run" for event in platform.events))

    def test_wrong_project_root_fails_before_any_staging(self) -> None:
        platform = Platform(["examples/shared/gateway.mjs"])

        def api(path: str, **kwargs) -> dict:
            result = platform.api(path, **kwargs)
            if result.get("id") == examples.PROJECTS["nuxt-agent"]:
                result["rootDirectory"] = "apps/marketing"
            return result

        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            fixture(root)
            with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                    mock.patch.object(examples, "run", side_effect=platform.run), \
                    mock.patch.object(examples, "vercel", side_effect=api):
                with self.assertRaisesRegex(ValueError, "rootDirectory"):
                    examples.prepare_examples(CANDIDATE, "0.0.8", root, root / "out")
        self.assertFalse(any(event[0] == "run" and event[1][0] == "vercel" for event in platform.events))

    def test_promotion_preflights_all_records_and_is_idempotent(self) -> None:
        platform = Platform([])
        records = [prepared("node-chat"), prepared("nuxt-agent")]
        with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                mock.patch.object(examples, "run", side_effect=platform.run), \
                mock.patch.object(examples, "vercel", side_effect=platform.api):
            examples.promote_examples(records)
            promotions = [event for event in platform.events if event[0] == "run"]
            self.assertEqual(2, len(promotions))
            first_promotion = next(index for index, event in enumerate(platform.events) if event[0] == "run")
            self.assertGreaterEqual(first_promotion, 5)
            examples.promote_examples(records)
            self.assertEqual(2, sum(event[0] == "run" for event in platform.events))
        for record in records:
            self.assertEqual(record["deployment_id"], platform.active[record["id"]])

    def test_preflight_accepts_the_actual_team_domain_without_promoting(self) -> None:
        platform = Platform([])
        record = dict(prepared("node-chat"), url="https://fx-demo-node-chat-gl8istcnw.labs.vercel.dev")

        def api(path: str, **kwargs) -> dict:
            result = platform.api(path, **kwargs)
            if path.startswith("/v13/deployments/"):
                result["url"] = record["url"].removeprefix("https://")
            return result

        with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                mock.patch.object(examples, "run") as run, \
                mock.patch.object(examples, "vercel", side_effect=api):
            examples.preflight_examples([record])
            run.assert_not_called()
        self.assertEqual(record["previous_deployment_id"], platform.active["node-chat"])

    def test_deployment_urls_reject_credentials_paths_and_other_hosts(self) -> None:
        for url in (
            "http://demo.labs.vercel.dev",
            "https://user:password@demo.labs.vercel.dev",
            "https://demo.labs.vercel.dev/path",
            "https://demo.labs.vercel.dev?token=value",
            "https://demo.labs.vercel.dev#fragment",
            "https://demo.labs.vercel.dev.attacker.example",
            "https://demo.vercel.dev",
            "https://attacker.example",
        ):
            with self.subTest(url=url), mock.patch.object(examples, "vercel") as api:
                with self.assertRaisesRegex(ValueError, "deployment"):
                    examples.preflight_examples([dict(prepared("node-chat"), url=url)])
                api.assert_not_called()

    def test_readonly_preflight_rejects_newer_production_before_publication(self) -> None:
        platform = Platform([])
        platform.active["nuxt-agent"] = "dpl_newer"
        records = [prepared("node-chat"), prepared("nuxt-agent")]
        with mock.patch.dict(examples.os.environ, {"FX_EXAMPLE_VERCEL_TOKENS": json.dumps(TOKENS)}), \
                mock.patch.object(examples, "run") as run, \
                mock.patch.object(examples, "vercel", side_effect=platform.api):
            with self.assertRaisesRegex(ValueError, "newer production"):
                examples.preflight_examples(records)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
