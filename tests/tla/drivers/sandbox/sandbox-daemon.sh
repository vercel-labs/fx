#!/bin/sh
# A stand-in for a remote sandbox for the sandbox driver. The driver starts it
# before each run, in its own session, outside fx's process tree, as a remote
# sandbox runs a command outside fx. fx's cleanup of its own descendants cannot
# reach a command that runs here.
#
# The provider fixture hands each command over through the spool folder:
# job-N.cwd and job-N.cmd. The daemon starts the command in its own session,
# writes the command's pid to job-N.pid, and its exit status to job-N.status.
# The fixture asks for a kill by creating job-N.kill; the daemon then sends
# SIGTERM to each process the command started, child first, by pid. The wrapper
# stays alive, so it still writes the command's status.
spool=$1
echo $$ > "$spool/daemon.pid"

stop_tree() {
  for child in $(pgrep -P "$1" 2>/dev/null); do stop_tree "$child"; done
  kill -TERM "$1" 2>/dev/null
}
while :; do
  for request in "$spool"/job-*.cmd; do
    [ -e "$request" ] || continue
    job=${request%.cmd}
    [ -e "$job.started" ] && continue
    : > "$job.started"
    cwd=$(cat "$job.cwd")
    command=$(cat "$request")
    ( cd "$cwd" && exec perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sh -c 'echo $$ > "$1"; sh -c "$2"; status=$?; echo $status > "$3"; exit $status' fxjob "$job.pid" "$command" "$job.status" ) &
  done
  for kill_request in "$spool"/job-*.kill; do
    [ -e "$kill_request" ] || continue
    job=${kill_request%.kill}
    [ -e "$job.killed" ] && continue
    : > "$job.killed"
    wrapper=$(cat "$job.pid" 2>/dev/null)
    [ -n "$wrapper" ] || continue
    for child in $(pgrep -P "$wrapper" 2>/dev/null); do stop_tree "$child"; done
  done
  sleep 0.05
done
