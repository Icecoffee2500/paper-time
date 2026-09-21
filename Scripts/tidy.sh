#!/bin/bash
# Takes the built app bundles out of `build/`.
#
# Run it when you stop working. What is left in `build/` after a session is a
# Debug copy of the app, which is the one thing nobody should open — Swift's
# Debug build is several seconds slower to start, and a copy sitting in a
# folder is a copy somebody eventually double-clicks. The indexes and object
# files stay, because they are what makes the next build quick.
#
#   Scripts/tidy.sh          # the app bundles
#   Scripts/tidy.sh --all    # and the packages in Installers/, dist/, Portable/dist
#
# `publish-release.sh` does the same at the end of a release; this is for the
# days that do not end in one.
set -euo pipefail
cd "$(dirname "$0")/.."

before=$(du -sh build 2>/dev/null | cut -f1 || echo "0")
found=$(find build -maxdepth 6 -name "Paper Time.app" -prune 2>/dev/null | wc -l | tr -d ' ')
find build -maxdepth 6 -name "Paper Time.app" -prune -exec rm -rf {} + 2>/dev/null || true
echo "build/ - removed $found app bundle(s), $before → $(du -sh build 2>/dev/null | cut -f1 || echo 0)"

if [ "${1:-}" = "--all" ]; then
  for dir in Installers dist Portable/dist; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*; do
      [ -e "$file" ] || continue
      case "$(basename "$file")" in README.md|*.yml) ;; *) rm -rf "$file" ;; esac
    done
    echo "$dir - emptied"
  done
fi
