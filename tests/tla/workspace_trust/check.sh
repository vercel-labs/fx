#!/bin/sh
# Model-check WorkspaceTrust, the trust prompt and saved trust handling of fx,
# and require each config's expected verdict.
#
# design-a.cfg and design-b.cfg must pass their design invariants.
# current-consent.cfg shows fx today runs TUI sessions without trust consent,
# and a-headless-content.cfg shows Design a lets untrusted headless runs load
# repo content. Each mutant-*.cfg plants a bug that its named invariant must
# catch. mutant-trust-spoof shows a folder must never borrow another folder's
# trust. The simulate-*.cfg configs run random behaviors in ideal and nonideal
# conditions for both designs; SIM_RUNS sets how many (default 20000).
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

sim="-simulate num=${SIM_RUNS:-20000} -depth 20 -seed 1"
tlc_verdicts "$@" <<EOF
WorkspaceTrust current-consent ConsentBeforeSession
WorkspaceTrust design-a -
WorkspaceTrust design-b -
WorkspaceTrust a-headless-content UntrustedHeadlessNoRepoContent
WorkspaceTrust mutant-skip-check ConsentBeforeSession
WorkspaceTrust mutant-save-on-no NoNeverSaves
WorkspaceTrust mutant-save-home HomeNeverSaved
WorkspaceTrust mutant-headless-prompt HeadlessNeverWaits
WorkspaceTrust mutant-lost-write SavedOrSaid
WorkspaceTrust mutant-headless-content UntrustedHeadlessNoRepoContent
WorkspaceTrust mutant-trust-spoof NoBorrowedTrust
WorkspaceTrust simulate-ideal-a simulate $sim
WorkspaceTrust simulate-nonideal-a simulate $sim
WorkspaceTrust simulate-ideal-b simulate $sim
WorkspaceTrust simulate-nonideal-b simulate $sim
EOF
