#!/bin/sh
# A third-party provider for the sandbox driver (spec L2). fx starts it as
#   sh provider-fixture.sh run --mode M --root R --cwd C --state S [--env N]... [--profile P]... -- CMD
# It records what it does as JSON lines in $L2_PROVIDER_LOG. It hands CMD to the
# sandbox daemon through the spool folder $L2_SPOOL (sandbox-daemon.sh runs
# CMD outside fx's process tree), waits for the result, and ends with the
# spec's notes (N1, N24, N5).
#
# The driver shapes each run with environment variables:
#   L2_ACT=create-fails   refuse before the command is sent (exit 125, N1)
#   L2_HOLD_S=N           wait N seconds before the command starts
#   L2_KILL_DELAY_S=N     take N seconds for a kill to land after SIGTERM
set -u

log=${L2_PROVIDER_LOG:?L2_PROVIDER_LOG must name the log file}
spool=${L2_SPOOL:?L2_SPOOL must name the spool folder}
act=${L2_ACT:-}
hold=${L2_HOLD_S:-0}
kill_delay=${L2_KILL_DELAY_S:-0}

emit() {
  printf '%s\n' "$1" >> "$log"
}

if [ "${1:-}" != run ]; then
  echo "fx: did not run: the runner arguments are wrong: the first word must be run" >&2
  exit 125
fi
shift

mode=""
cwd="$PWD"
env_names=""
command=""
while [ $# -gt 0 ]; do
  case "$1" in
    --)
      shift
      command=${1:-}
      break
      ;;
    --mode) mode=$2; shift 2 ;;
    --cwd) cwd=$2; shift 2 ;;
    --env) env_names="$env_names $2"; shift 2 ;;
    --root|--state|--profile) shift 2 ;;
    *)
      echo "fx: did not run: the runner arguments are wrong: unknown $1" >&2
      exit 125
      ;;
  esac
done

json_names=""
for name in $env_names; do
  json_names="$json_names\"$name\","
done
json_names=${json_names%,}
emit "{\"ev\":\"provider\",\"mode\":\"$mode\",\"env\":[$json_names]}"

child=""
job=""
hold_pid=""
on_term() {
  if [ -z "$child" ]; then
    [ -n "$hold_pid" ] && kill "$hold_pid" 2>/dev/null
    emit '{"ev":"termexit"}'
    echo "fx: stopped before the command was sent; it did not run" >&2
    exit 143
  fi
  emit '{"ev":"killsent"}'
  # The kill takes kill_delay to land, as the model's KillTicks does. A SIGKILL
  # from fx during that wait leaves the command running in the sandbox.
  sleep "$kill_delay"
  : > "$job.kill"
  while [ ! -s "$job.status" ]; do sleep 0.05; done
  emit '{"ev":"killed"}'
  echo "fx: stopped; the remote command was killed" >&2
  exit 143
}
trap on_term TERM INT

if [ "$act" = create-fails ]; then
  emit '{"ev":"createfail"}'
  echo "fx: did not run: the sandbox could not start: the fixture refused" >&2
  exit 125
fi

if [ "$hold" != 0 ]; then
  sleep "$hold" &
  hold_pid=$!
  wait "$hold_pid"
fi

job="$spool/job-$$"
printf '%s\n' "$cwd" > "$job.cwd"
printf '%s\n' "$command" > "$job.cmd.tmp" && mv "$job.cmd.tmp" "$job.cmd"
while [ ! -s "$job.pid" ]; do sleep 0.02; done
child=$(cat "$job.pid")
emit "{\"ev\":\"start\",\"child\":$child}"
while [ ! -s "$job.status" ]; do sleep 0.05; done
status=$(cat "$job.status")
emit "{\"ev\":\"exit\",\"code\":$status}"
exit "$status"
