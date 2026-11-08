#!/bin/sh
# Model-check the ACP models with TLC and require each config's expected
# verdict.
#
# AcpPermissionModes: the ACP permission-mode contract, which matches the CLI's
# /permissions. AcpSpeed: the per-session Standard, Fast, and Ultrafast speed
# contract. Both configs must pass.
#
# The planted bugs and the runs of the real `fx acp` binary are in
# ../drivers/acp/:
#   bun ../drivers/acp/permission_modes/check-spec.ts
#   bun ../drivers/acp/permission_modes/driver.ts
#   bun ../drivers/acp/speed/check-spec.ts
#   bun ../drivers/acp/speed/driver.ts
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes.
set -eu

cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh

tlc_verdicts "$@" <<'EOF'
MCAcpPermissionModes MCAcpPermissionModes -
# AcpNotices: what a client with and without ACP v1 Session Notices gets for
# each kind of text fx emits about a turn, and for the text of each cause that
# ends a turn. MCAcpNotices must pass; Before is fx before the rule, the two
# Head configs are fx before the turn-failure notice (the provider error exit
# or the response-language exit still sends a system notice), and the other
# five are planted bugs, each caught by the invariant named.
# ../drivers/acp/notices/driver.ts runs the real fx acp.
AcpNotices MCAcpNotices -
AcpNotices MCAcpNoticesBefore OperationalAsNotice
AcpNotices MCAcpNoticesHeadProviderError NoTurnEndingNotice
AcpNotices MCAcpNoticesHeadLanguage NoTurnEndingNotice
AcpNotices MCAcpNoticesFailureNotice FailureReportIsMessage
AcpNotices MCAcpNoticesSavedReplyNotice ConversationStaysMessages
AcpNotices MCAcpNoticesFragmentNotice OneNoticePerMessage
AcpNotices MCAcpNoticesPlainNotice NoticeNeedsCapability
AcpNotices MCAcpNoticesNoRotate AssistantSplit
MCAcpSpeed MCAcpSpeed -
EOF
