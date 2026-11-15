#!/bin/sh
# Runs the integration test on one device and retries a run that started no
# test.
#
# Usage: run_device_test.sh [--max-attempts N] [--android-app ID] <device-id>
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
#
# With --android-app the device is an Android device and ID is the
# application ID of the app. Flutter runs adb install with no time limit.
# Each attempt therefore first installs the APK the app directory already
# holds, with a limit of two minutes. An install that fails or does not
# return counts as an attempt that started no test, and the test is not run.
# Flutter still builds and installs its own APK after this one, and that
# install keeps no limit but the 12 minute load timeout.
# Before a retry the adb server is restarted and the app is uninstalled.
# After two of these installs in a row did not return the device is also
# rebooted. A failed attempt prints the boot state, the installed packages,
# the install processes, the free space and the package manager log. Without
# the option adb is never called.
# DEVICE_TEST_INSTALL_LIMIT, DEVICE_TEST_ADB_LIMIT and DEVICE_TEST_BOOT_LIMIT
# override the limits in seconds for tests of this script.

set -u

max_attempts=3
android_app=
device=

usage() {
  echo "usage: $0 [--max-attempts N] [--android-app ID] <device-id>" >&2
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
    --android-app)
      [ "$#" -ge 2 ] || usage
      android_app=$2
      shift 2
      ;;
    --android-app=*)
      android_app=${1#--android-app=}
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
case $android_app in
  *[!A-Za-z0-9_.]*) usage ;;
esac

load_timeout='TimeoutException after 0:12:00.000000: Test timed out after 12 minutes'
log_reader='Error waiting for a debug connection: The log reader failed unexpectedly'
apk=build/app/outputs/flutter-apk/app-debug.apk
install_limit=${DEVICE_TEST_INSTALL_LIMIT:-120}
adb_limit=${DEVICE_TEST_ADB_LIMIT:-30}
boot_limit=${DEVICE_TEST_BOOT_LIMIT:-180}

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

# Runs a command and stops it after $1 seconds. The status is then 124.
# A command that is still there 5 seconds after SIGTERM gets SIGKILL.
bounded() {
  bounded_limit=$1
  shift
  "$@" &
  bounded_pid=$!
  bounded_waited=0
  while kill -0 "$bounded_pid" 2> /dev/null; do
    if [ "$bounded_waited" -ge "$bounded_limit" ]; then
      kill "$bounded_pid" 2> /dev/null
      bounded_waited=0
      while kill -0 "$bounded_pid" 2> /dev/null && [ "$bounded_waited" -lt 5 ]; do
        sleep 1
        bounded_waited=$((bounded_waited + 1))
      done
      kill -9 "$bounded_pid" 2> /dev/null
      wait "$bounded_pid"
      return 124
    fi
    sleep 1
    bounded_waited=$((bounded_waited + 1))
  done
  wait "$bounded_pid"
}

device_adb() {
  bounded "$adb_limit" adb -s "$device" "$@"
}

# Prints the state of the device after a failed attempt. Every adb call has a
# limit and none of them fails the script.
android_diagnostics() {
  echo "::group::Android state after attempt $attempt"
  echo "sys.boot_completed: $(device_adb shell getprop sys.boot_completed)"
  echo "Installed packages matching $android_app"
  device_adb shell pm list packages "$android_app"
  echo 'Free space on /data'
  device_adb shell df /data
  echo 'Install and compile processes'
  # Android 8 and later list only the shell's own processes without -A.
  # Android 7 has no -A and lists every process with plain ps.
  {
    device_adb shell ps -A
    device_adb shell ps
  } > "$logs/ps-$attempt.txt"
  grep -E 'installd|dex2oat|cmd|/system/bin/pm' "$logs/ps-$attempt.txt"
  echo 'Package manager log, last 200 lines'
  device_adb logcat -d -s PackageManager PackageInstaller installd > "$logs/logcat-$attempt.txt"
  tail -n 200 "$logs/logcat-$attempt.txt"
  echo '::endgroup::'
}

# Waits until the device is attached and has booted. The boot limit counts
# the time of the getprop calls too.
android_wait_for_boot() {
  bounded "$adb_limit" adb -s "$device" wait-for-device || return 1
  boot_deadline=$(($(date +%s) + boot_limit))
  until [ "$(device_adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do
    [ "$(date +%s)" -lt "$boot_deadline" ] || return 1
    sleep 5
  done
}

# Clears what a hung install may have left behind before the next attempt.
android_reset() {
  echo "Restarting the adb server before attempt $attempt"
  bounded "$adb_limit" adb kill-server
  bounded "$adb_limit" adb start-server
  if [ "$install_hangs" -ge 2 ]; then
    echo "Rebooting $device after $install_hangs installs in a row that did not return"
    device_adb reboot
    # The device stays attached for a moment after the reboot command.
    sleep 10
  fi
  android_wait_for_boot || echo "$device did not finish booting"
  echo "Uninstalling $android_app"
  device_adb uninstall "$android_app"
}

# Installs the APK once with a time limit. Sets the reason if it failed.
android_install() {
  if [ ! -f "$apk" ]; then
    echo "No $apk to install before the test"
    return 0
  fi
  echo "Installing $apk with a limit of $install_limit seconds"
  bounded "$install_limit" adb -s "$device" install -r -t "$apk" > "$logs/install-$attempt.txt" 2>&1
  install_status=$?
  cat "$logs/install-$attempt.txt"
  if [ "$install_status" = 124 ]; then
    install_hangs=$((install_hangs + 1))
    reason="adb install did not return within $install_limit seconds"
    return 1
  fi
  install_hangs=0
  if [ "$install_status" != 0 ] || grep -q '^Failure' "$logs/install-$attempt.txt"; then
    reason="adb install failed with status $install_status"
    return 1
  fi
}

echo 'suite_load_timeout: 12m' > dart_test.yaml || exit 1

logs=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/device-test.XXXXXX") || exit 1

attempt=1
install_hangs=0
while :; do
  echo "Attempt $attempt of $max_attempts on $device"
  log=$logs/attempt-$attempt.log
  if [ -n "$android_app" ] && [ "$attempt" -gt 1 ]; then
    android_reset
  fi
  if [ -n "$android_app" ] && ! android_install; then
    echo "$reason"
    status=1
    android_diagnostics
  else
    # The status goes through a file. A pipeline only reports the status of tee.
    {
      flutter test integration_test -d "$device" 2>&1
      echo "$?" > "$log.status"
    } | tee "$log"
    status=$(cat "$log.status") || status=1
    if [ "$status" = 0 ]; then
      exit 0
    fi
    [ -z "$android_app" ] || android_diagnostics
    if ! reason=$(started_no_test "$log"); then
      exit "$status"
    fi
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    exit "$status"
  fi
  echo "::warning::Attempt $attempt of $max_attempts started no test because $reason. Retrying."
  attempt=$((attempt + 1))
done
