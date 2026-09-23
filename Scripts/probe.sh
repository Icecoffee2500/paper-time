#!/bin/bash
# Runs a probe build without putting anything on the screen.
#
#   Scripts/probe.sh [-p] [-s SECONDS] [-l LOGFILE] -- --papertime-library=<path> [more flags]
#
# `-p` runs the Portable (Electron) build instead of the Mac app, through the
# same door and under the same rules: its window used to be `show()`n, and on a
# Mac that activates the app exactly as `open -n -a` did. `npm run build` in
# `Portable/` first; the probe runs `Portable/out`.
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
PORTABLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PORTABLE="yes"; shift ;;
    -s) SECONDS_TO_WAIT="$2"; shift 2 ;;
    -l) LOG="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ -n "$PORTABLE" ]; then
  APP="Portable/node_modules/electron/dist/Electron.app"
  [ -f Portable/out/main/main.js ] || { echo "no Portable/out — run npm run build in Portable/ first" >&2; exit 1; }
else
  APP="${PAPERTIME_APP:-build/mac/Build/Products/Debug/Paper Time.app}"
fi
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

# By bundle path, not by name. The person may well have their own copy of
# Paper Time open — it is their app — and a check that compares names calls
# that "the probe came to the front" and cries wolf. The probe is the copy in
# the build folder, and nothing else.
was_front() { lsappinfo info -only bundlepath "$(lsappinfo front)" 2>/dev/null | sed 's/.*="\(.*\)"/\1/'; }
MINE="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
# And the same bundle with every link followed: a worktree's Portable/node_modules
# is a link to the main checkout's, and Launch Services may report the app by
# either path. A check that only knows one of them never sees the other come
# to the front.
MINE_REAL="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
BEFORE="$(was_front)"

if [ -n "$PORTABLE" ]; then
  # Electron takes the app's folder as its first argument.
  open -g -j -n -a "$PWD/$APP" --stderr "$LOG" --stdout "$LOG" --args "$PWD/Portable" "$@"
else
  open -g -j -n -a "$PWD/$APP" --stderr "$LOG" --stdout "$LOG" --args "$@"
fi

# Watched the whole way, not only at the ends. Comparing before with after says
# nothing about the middle, and "did my window ever come forward" is the one
# question this script exists to answer.
SEEN=""
ELAPSED=0
while [ "$ELAPSED" -lt "$SECONDS_TO_WAIT" ]; do
  NOW="$(was_front)"
  case "$NOW" in "$MINE"|"$MINE"/|"$MINE_REAL"|"$MINE_REAL"/) SEEN="yes" ;; esac
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
  # Not us: the person at the keyboard changes applications too, and one of the
  # applications they change to may well be their own copy of this one. Said
  # quietly, because the line above is the one that matters.
  echo "-- the front application changed while this ran: $(basename "$BEFORE") -> $(basename "$AFTER") (not the probe)" >&2
fi

cat "$LOG"
