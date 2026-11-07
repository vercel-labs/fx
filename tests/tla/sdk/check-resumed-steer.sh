#!/bin/sh
# Model-checks ResumedSteer.tla with TLC: what a reader of a libfx session sees
# of the steers a resumed turn places. Every config must give its verdict.
#
#   - durable: a durable session. The resume shows each steer it places once
#     the progress that places it is written, and drops a line its stream
#     already holds.
#   - drive: the same without cancels. It writes the state graph that
#     ../drivers/drive-resumed-steer.mjs walks against the real code;
#     sdk/tests/test-durable.mjs covers a cancel.
#   - engine: a plain engine. Nothing shows a steer twice that the model
#     did not get twice, but its host can see one line twice.
#   - NoPublish is the resume before this model: it places a steer and shows
#     nothing, and breaks SeenOrLost.
#   - AtResume shows a steer at the resume, before its progress places it, and
#     breaks ResumeShowsPlaced.
#   - NoDedupe is a durable session that does not drop a line its stream
#     holds, and breaks ShownOnce.
#   - EngineRepeat checks ShownOnce on the plain engine and breaks it: the
#     repeat that sdk/README.md documents.
#   - Window breaks NeverLost: a crash between the progress and the line loses
#     the line. The PR states this limit.
#
# Needs Java 11+ and tla2tools.jar, as ../README.md describes. Then walk the
# real code along the graph:
#   bun ../drivers/drive-resumed-steer.mjs
set -eu
cd "$(dirname "$0")"
# shellcheck source=../lib/tlc.sh
. ../lib/tlc.sh
mkdir -p graphs

tlc_verdicts "$@" <<'EOF'
ResumedSteer ResumedSteer-durable - -deadlock
ResumedSteer ResumedSteer-drive - -deadlock -dump dot,actionlabels graphs/resumed-steer
ResumedSteer ResumedSteer-engine - -deadlock
ResumedSteer ResumedSteer-NoPublish SeenOrLost -deadlock
ResumedSteer ResumedSteer-AtResume ResumeShowsPlaced -deadlock
ResumedSteer ResumedSteer-NoDedupe ShownOnce -deadlock
ResumedSteer ResumedSteer-EngineRepeat ShownOnce -deadlock
ResumedSteer ResumedSteer-Window NeverLost -deadlock
EOF
