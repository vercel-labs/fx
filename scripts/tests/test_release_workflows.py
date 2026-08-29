import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RELEASE = REPO_ROOT / ".github" / "workflows" / "release.yml"
CANDIDATE = REPO_ROOT / ".github" / "workflows" / "dev-release.yml"
NPM_PUBLISH = REPO_ROOT / ".github" / "workflows" / "publish-libohmyfx.yml"
PACKAGE = REPO_ROOT / "sdk" / "package.json"
UPGRADE_HELPERS = REPO_ROOT / "src" / "core" / "upgrade" / "upgrade_helpers.zig"


class ReleaseWorkflowTests(unittest.TestCase):
    def test_stable_release_is_self_hosted_on_github(self) -> None:
        workflow = RELEASE.read_text(encoding="utf-8")
        self.assertIn("printf '%s' \"${{ needs.check-version.outputs.version }}\" > latest.txt", workflow)
        self.assertIn("make_latest: true", workflow)
        self.assertIn("            latest.txt", workflow)
        self.assertIn('TAG="omyfx-v${VERSION}"', workflow)
        self.assertNotIn("BLOB_READ_WRITE_TOKEN", workflow)
        self.assertNotIn("blob.vercel-storage.com", workflow)

    def test_candidate_release_is_a_moving_github_prerelease(self) -> None:
        workflow = CANDIDATE.read_text(encoding="utf-8")
        self.assertIn("name: Release Candidate", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn('git tag --force dev "$RELEASE_SHA"', workflow)
        self.assertIn("git push --force origin refs/tags/dev", workflow)
        self.assertIn("tag_name: dev", workflow)
        self.assertIn("prerelease: true", workflow)
        self.assertIn("            dev.json", workflow)
        self.assertNotIn("BLOB_READ_WRITE_TOKEN", workflow)
        self.assertNotIn("blob.vercel-storage.com", workflow)

    def test_updater_targets_this_repository_releases(self) -> None:
        source = UPGRADE_HELPERS.read_text(encoding="utf-8")
        self.assertIn('pub const release_base = "https://github.com/y0usaf/oh-my-fx/releases";', source)
        self.assertIn('"{s}/latest/download/latest.txt"', source)
        self.assertIn('"{s}/download/dev/dev.json"', source)
        self.assertIn('"{s}/download/{s}/fx-{s}.tar.gz{s}"', source)
        self.assertNotIn("releases.fx.sh", source)

    def test_npm_package_uses_fork_identity_and_supports_one_time_bootstrap(self) -> None:
        manifest = PACKAGE.read_text(encoding="utf-8")
        workflow = NPM_PUBLISH.read_text(encoding="utf-8")
        self.assertIn('"name": "libohmyfx"', manifest)
        self.assertIn("github.com/y0usaf/oh-my-fx", manifest)
        self.assertIn("name: Publish libohmyfx", workflow)
        self.assertIn('npm view "libohmyfx@${LIBFX_VERSION}"', workflow)
        self.assertIn('TAG="omyfx-v${BASE_VERSION}"', workflow)
        self.assertIn("secrets.NPM_TOKEN", workflow)
        self.assertIn("vars.LIBOHMYFX_PUBLISH_ENABLED == 'true'", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertNotIn('.name == "libfx"', workflow)


if __name__ == "__main__":
    unittest.main()
