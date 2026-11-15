#!/bin/sh
# Runs the integration test on one device and retries a run that started no
# test.
#
# Usage: run_device_test.sh [--max-attempts N] <device-id>
#
# Run it from the app directory. It writes dart_test.yaml there with a 12
# minute suite load timeout. Flutter 3.38.10 ships test_core 0.6.12, which
# has that timeout built in. Flutter 3.50.0 ships test_core 0.6.20, which has
# none by default (dart-lang/test#2505). Without one a launch that never
# connects waits until the job is cancelled.
#
# A run is retried only when the test suite failed to load and nothing ran.
# The summary is then "0 tests passed, 1 failed." and a "loading <path>" entry
# is the failure. One of these causes must also be in the output.
#
# - The 12 minute load timeout. Seen on the Android emulator with the app
#   installed but never reporting back, or with adb install never returning.
# - The simulator log reader error of flutter/flutter#181771. The app started
#   before the log stream was ready and its VM service URL was missed.
#
# A failing test, a build error or a compile error never matches. Each one
# fails with its own message and not with these two. The exit status is that
# of the last attempt.

set -u

max_attempts=3
device=

usage() {
  echo "usage: $0 [--max-attempts N] <device-id>" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --max-attempts)
      [ "$#" -ge 2 ] || usage
      max_attempts=$2
      shift 2
      ;;
    --max-attempts=*)
      max_attempts=${1#--max-attempts=}
      shift
      ;;
    -*)
      usage
      ;;
    *)
      [ -z "$device" ] || usage
      device=$1
      shift
      ;;
  esac
done

[ -n "$device" ] || usage
case $max_attempts in
  '' | *[!0-9]* | 0*) usage ;;
esac

load_timeout='TimeoutException after 0:12:00.000000: Test timed out after 12 minutes'
log_reader='Error waiting for a debug connection: The log reader failed unexpectedly'

# Prints why the run logged in $1 started no test. Fails if it started one.
started_no_test() {
  grep -qE '(^|[^0-9])0 tests passed, 1 failed\.' "$1" || return 1
  grep -qE 'loading [^ ]+\.dart (\(failed\)|\[E\])' "$1" || return 1
  if grep -qF "$log_reader" "$1"; then
    echo 'the app never reported its VM service URL'
  elif grep -qF "$load_timeout" "$1"; then
    echo 'the suite did not load within 12 minutes'
  else
    return 1
  fi
}

echo 'suite_load_timeout: 12m' > dart_test.yaml || exit 1

logs=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/device-test.XXXXXX") || exit 1

attempt=1
while :; do
  echo "Attempt $attempt of $max_attempts on $device"
  log=$logs/attempt-$attempt.log
  # The status goes through a file. A pipeline only reports the status of tee.
  {
    flutter test integration_test -d "$device" 2>&1
    echo "$?" > "$log.status"
  } | tee "$log"
  status=$(cat "$log.status") || status=1
  if [ "$status" = 0 ]; then
    exit 0
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    exit "$status"
  fi
  if ! reason=$(started_no_test "$log"); then
    exit "$status"
  fi
  echo "::warning::Attempt $attempt of $max_attempts started no test because $reason. Retrying."
  attempt=$((attempt + 1))
done
