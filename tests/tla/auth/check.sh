#!/bin/sh
# Model-check what a Vercel sign-in does with its team list
# (src/core/auth/login_flow.zig runLogin and completeSignIn) with TLC and
# require each config's expected verdict.
#
# sign-in-teams.cfg and sign-in-teams-deep.cfg are the design and must pass: for
# `fx login`, the in-app /login, and the picker's team column.
# Each sign-in-teams-today-*.cfg is fx before it, and each rule it names must
# catch it:
#
#   today-crash    a control sequence in a team name ends the in-app sign-in   NoCrash
#   today-raw      fx login writes a team name's control characters            NoRawControls
#   today-save     a failed list saves a session with no team over the old one KeepsPriorSession
#   today-message  a failed list is reported as an account with no teams       TellsTheTruth
#
# Each sign-in-teams-mutation-*.cfg plants one defect in the design:
#
#   name        team names keep their control characters                      NoCrash
#   slug        a slug with a control character is kept                       NoRawControls
#   save        the teams could not be loaded, but the session is saved       KeepsPriorSession
#   swallow     a failed team request is read as an empty list                TellsTheTruth
#   unreadable  a list with no usable entry is read as an empty list          TellsTheTruth
#   strict      a team whose name holds control characters is dropped         OffersEveryTeam
#   id          a team id the gateway rejects is kept and saved               SavesOnlyUsableTeam
#   picker      the picker reports a list it cannot read as a credential      SameOutcomeEverywhere
#               problem
#
# SignInTeamsTrace.tla checks sign-ins of the built fx binary against the
# model; tests/tla/drivers/auth/driver.ts runs it.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
#
# Usage:
#   ./check.sh
#   ./check.sh sign-in-teams sign-in-teams-mutation-slug
#   TLA2TOOLS_JAR=/path/tla2tools.jar ./check.sh
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'VERDICTS'
SignInTeams sign-in-teams -
SignInTeams sign-in-teams-deep -
SignInTeams sign-in-teams-today-crash NoCrash
SignInTeams sign-in-teams-today-raw NoRawControls
SignInTeams sign-in-teams-today-save KeepsPriorSession
SignInTeams sign-in-teams-today-message TellsTheTruth
SignInTeams sign-in-teams-mutation-name NoCrash
SignInTeams sign-in-teams-mutation-slug NoRawControls
SignInTeams sign-in-teams-mutation-save KeepsPriorSession
SignInTeams sign-in-teams-mutation-swallow TellsTheTruth
SignInTeams sign-in-teams-mutation-unreadable TellsTheTruth
SignInTeams sign-in-teams-mutation-strict OffersEveryTeam
SignInTeams sign-in-teams-mutation-id SavesOnlyUsableTeam
SignInTeams sign-in-teams-mutation-picker SameOutcomeEverywhere
VERDICTS
