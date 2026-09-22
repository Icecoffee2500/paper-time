#!/bin/bash
# Runs a probe build without putting anything on the screen.
#
#   Scripts/probe.sh [-s SECONDS] [-l LOGFILE] -- --papertime-library=<path> [more flags]
#
# This is the only sanctioned way to launch the app for a check, and it exists
# because `open -n -a` — which is what every probe used to be run with —
# **activates** the app: the window comes to the front of whatever the person
# is doing and takes the keyboard. Done a dozen times in a session, that is the
# app elbowing its way in front of somebody's work a dozen times.
#
# `-g` does not bring it forward and `-j` starts it hidden. A hidden app has no
# visible window at all, so `--papertime-window-shot` came back "no window" —
# the probe therefore moves its window far outside every display and orders it
# on there (`WindowProbe.offscreen`). It then draws and photographs like any
# window, on no screen anybody has. That turned out to be the better picture as
# well: the sidebar, which used to come out blank, is in it.
#
# Afterwards the instance is killed by its library path rather than by name, so
# the copy in /Applications that somebody is actually reading with is never
# touched. `--papertime-window-shot-quit=1` is not enough on its own: it does
# not fire while a sheet is up.
#
# It refuses to run without `--papertime-library=`, because a probe must never
# open the real library — the app is sandboxed per bundle id, so a probe and
# the installed copy share one settings domain, and a run without that flag
# writes the folder it opened into it.
set -euo pipefail

cd "$(dirname "$0")/.."
SECONDS_TO_WAIT=15
LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SECONDS_TO_WAIT="$2"; shift 2 ;;
    -l) LOG="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

APP="${PAPERTIME_APP:-build/mac/Build/Products/Debug/Paper Time.app}"
[ -d "$APP" ] || { echo "no app at $APP — build it first" >&2; exit 1; }

LIBRARY=""
for argument in "$@"; do
  case "$argument" in --papertime-library=*) LIBRARY="${argument#--papertime-library=}" ;; esac
done
[ -n "$LIBRARY" ] || {
  echo "refusing to run without --papertime-library=<path>: a probe must not open the real library" >&2
  exit 64
}

[ -n "$LOG" ] || LOG="$(mktemp -t papertime-probe)"
: > "$LOG"

was_front() { lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | sed 's/.*="\(.*\)"/\1/'; }
BEFORE="$(was_front)"

open -g -j -n -a "$PWD/$APP" --stderr "$LOG" --stdout "$LOG" --args "$@"

# Watched the whole way, not only at the ends. Comparing before with after says
# nothing about the middle, and "did my window ever come forward" is the one
# question this script exists to answer.
SEEN=""
ELAPSED=0
while [ "$ELAPSED" -lt "$SECONDS_TO_WAIT" ]; do
  NOW="$(was_front)"
  case "$NOW" in "Paper Time") SEEN="yes" ;; esac
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
pkill -f -- "--papertime-library=$LIBRARY" 2>/dev/null || true
sleep 1

AFTER="$(was_front)"
if [ -n "$SEEN" ]; then
  echo "!! the probe came to the front — it must never do that" >&2
  echo "!! stop and find out why before running this again" >&2
elif [ "$BEFORE" != "$AFTER" ]; then
  # Not necessarily us: the person at the keyboard changes applications too.
  # Said quietly, because the line above is the one that matters.
  echo "-- the front application changed while this ran: $BEFORE -> $AFTER (not the probe)" >&2
fi

cat "$LOG"
