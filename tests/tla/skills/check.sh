#!/bin/sh
# Model-check the project skill walk (src/core/skills/skill_runtime.zig
# appendWorkspaceRoots) with TLC and require each config's expected verdict.
#
# skill-walk.cfg is the design and must pass. skill-walk-today.cfg is fx
# before it, where HOME was the only stop, so a workspace outside HOME scanned
# every folder up to `/` (NoSkillAboveBoundary). Each
# skill-walk-mutation-*.cfg plants one defect, and the rule it names must
# catch it:
#
#   no-workspace-stop        outside a repository the walk climbs to `/`      NoSkillAboveBoundary
#   farthest-repository      the outermost .git ends the walk                 NoSkillAboveBoundary
#   stop-inside-home         the repository stop applies under HOME too       InsideHomeUnchanged
#   skip-repository-root     the repository root itself is not scanned        RepositoryLoaded
#   string-prefix            /tmp/home counts as above /tmp/home2             NoSkillAboveBoundary
#
# SkillWalkTrace.tla checks runs of the built fx binary against the model;
# tests/tla/drivers/skills/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh skill-walk skill-walk-today
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SkillWalk skill-walk -
SkillWalk skill-walk-today NoSkillAboveBoundary
SkillWalk skill-walk-mutation-no-workspace-stop NoSkillAboveBoundary
SkillWalk skill-walk-mutation-farthest-repository NoSkillAboveBoundary
SkillWalk skill-walk-mutation-stop-inside-home InsideHomeUnchanged
SkillWalk skill-walk-mutation-skip-repository-root RepositoryLoaded
SkillWalk skill-walk-mutation-string-prefix NoSkillAboveBoundary
VERDICTS
