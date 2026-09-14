# Releasing fx

Write the next entry locally in `CHANGELOG.md`, with a stable version heading
and one `<!-- release:start -->` / `<!-- release:end -->` pair. Remove the old
entry's markers, then commit and push a release PR targeting `main`.

Start **Actions > Prepare Release** on `main` in `vercel-labs/fx` and enter that
PR number. The PR must be open and non-draft, and contain only release notes,
the version declaration and an existing README install-version pin. Preparation
aligns those version values if needed; an unversioned installer stays unversioned.
It never writes `CHANGELOG.md` or calls a model.

Review your notes and the completed preview, then approve the
`npm` environment in **Publish libfx**. You do not need to prepare a separate
fx-web release.

## Before approval

Preparation keeps the native version PR open. It qualifies the exact source,
builds all four native targets, signs the macOS binaries, and builds the stable
SDK archive. It then prepares the website PR and a production-configured
deployment without assigning the public domain.

The version is taken from the marked changelog entry. Missing, malformed or
already-released notes stop preparation without changing files.

The website installs that SDK archive from an immutable, checksum-addressed
mirror. Its package version is the intended release version, not a dev build.
The same release record supplies the homepage, terminal greeting, changelog,
signed binary sizes and Markdown exports. Existing historical notes are kept.

All four examples are tested at their declared SDK versions. Changed examples
also receive staged deployments. The main website terminal must use the new
SDK; examples may retain an older compatible pin until their source changes.

The Actions summary links the preview, changelog, terminal and preparation PR.
The `fx-release-ready` artifact retains the native archives, SDK, checksums,
release record, browser report and desktop/mobile screenshots for 30 days.
Browser checks exercise the actual terminal and a synthetic Gateway response;
they do not spend model credits or disable the public site's request guards.

Edit the native preparation PR to change the notes, then rerun **Prepare
Release** with the same PR number. Existing edited notes are preserved. Only `src/main.zig`'s version,
the README install example and `CHANGELOG.md` may differ from the reviewed
main ancestor. Additional product changes must reach main first.

## Final approval

`publish-libfx.yml` remains the npm trusted publisher. Its `npm` environment
is the final human gate for the whole stable release. After approval it:

1. Rechecks source, required checks, reviews, archive identity, deployment
   identity and current public channels.
2. Publishes the retained SDK archive and verifies npm integrity.
3. Merges the native preparation PR, tags its tested source, and publishes
   the retained native archives to GitHub and the CDN.
4. Merges the website PR and checks that the merged tree is exactly the one
   tested in the preview. It advances the download channel and promotes the
   staged website and affected demo deployments.
5. Checks the public website, real terminal version, changelog and sizes.

Publication never rebuilds a binary, regenerates notes or edits website source.
Later native commits are not silently added to the tested release snapshot.
Ordinary website changes continue using Git deployments. Release-data changes
skip that automatic production build because the tested deployment is promoted.

## One-time setup

Land the website consumer before enabling the native coordinator. Keep the
existing approval rules while the new code and preparation-only rehearsal are
being verified. Activation requires all of the following:

- A private release GitHub App installed on only `fx` and `fx-web`, with
  contents and pull requests write; actions, checks and metadata read. It
  must not have environment-review authority.
- `FX_RELEASE_APP_ID` as an fx repository variable. Put
  `FX_RELEASE_APP_PRIVATE_KEY` in both `release-preparation` and `npm`, not in
  repository-wide secrets.
- A separate Vercel project token for marketing and for each hosted example.
  Set the fx repository variable `FX_RELEASE_VERCEL_TEAM_ID` to their owner
  team ID; do not commit the team's identifier in release source.
  Store `FX_WEB_VERCEL_TOKEN` and `FX_EXAMPLE_VERCEL_TOKENS` in those same two
  environments. The example secret is a JSON map keyed by `node-chat`,
  `browser-agent`, `nextjs-agent` and `nuxt-agent`. Do not use a team-wide token.
- Main-only branch policies for `release-preparation`, `apple-signing` and
  `npm`. Preparation needs no reviewer; `npm` requires the maintainer. Remove
  the separate Apple reviewer only after the trusted-main signing path is
  verified. The older `release` environment is no longer a publisher.
- The existing `BLOB_READ_WRITE_TOKEN` for the immutable archive mirror and
  downloads. Changelog preparation requires no inference API key.
- Vercel Authentication for preview and production deployment URLs
  (`prod_deployment_urls_and_all_previews`), leaving public domains open.
  Store the project automation bypass in `FX_WEB_PREVIEW_BYPASS` in
  `release-preparation`. Browser checks send it only to that deployment's
  exact origin. This is not a BotID bypass and does not change public request
  protection. Preparation rejects missing protection before building.

Check branch protections before activation. The App must be able to merge
qualified preparation PRs without bypassing required checks. If policy requires
another human review, resolve that policy explicitly; the publisher stops.

## Rehearsals and retries

Run **Release** on `main` with `validate_only=true` to rehearse preparation.
Optional source overrides must be full commits already on the corresponding
main history. The retained candidate has publication disabled. This mode can
upload candidate archives and stage deployments, but cannot publish a stable
release or move public aliases.

Repreparation is separate from publication, so an outstanding approval does
not prevent a fresh preview. A newer successful release candidate invalidates
older candidates. GitHub may still show an old approval request; reject it and
review the newest summary. The publisher rejects a superseded candidate before
public writes. It never cancels a possibly active publication to hide an old
approval request.

To retry publication, run **Publish libfx**, choose `stable`, and supply the
successful preparation run ID. It downloads the original artifact by immutable
ID and requires approval again. Existing npm versions, tags and uploaded files
must match the prepared hashes. Conflicting bytes or source stop the retry;
never delete or reuse a published npm version.

Public services cannot commit atomically. A failure may leave an immutable npm
package or GitHub release published while the site remains on the prior version.
The publisher reconciles existing artifacts and retains the prior deployment
and download pointer for recovery. A concurrent newer pointer is never rolled
back over. Inspect the failed step and retained evidence before retrying; do
not rebuild the candidate to recover a partially published version.

Dev releases remain independent and keep their existing channel behavior.
