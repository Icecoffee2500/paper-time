#!/bin/bash
# Records a download we made ourselves, so the page's tally stays a count of
# other people. GitHub counts every download of a release asset and cannot
# tell whose it was; check a build by downloading it and the page reports a
# stranger. Run this after doing that.
#
#   Scripts/note-download.sh 0.8.0        # one of ours
#   Scripts/note-download.sh 0.8.0 3      # three
#   Scripts/note-download.sh 0.8.0 --set 0   # forget what was recorded
#
# Writes Website/releases.json; `publish-release.sh` keeps the number across
# later runs, and the page subtracts it from both the version's row and the
# total. Better still: check the copy in dist/ instead of downloading.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
if [ -z "$TAG" ]; then echo "usage: Scripts/note-download.sh <tag> [n | --set n]" >&2; exit 2; fi
MODE=add
shift
if [ "${1:-}" = "--set" ]; then MODE=set; shift; fi
N="${1:-1}"

MODE="$MODE" TAG="$TAG" N="$N" python3 - <<'PY'
import json, os, pathlib

tag, n, mode = os.environ["TAG"], int(os.environ["N"]), os.environ["MODE"]
path = pathlib.Path("Website/releases.json")
data = json.loads(path.read_text())
for release in data.get("releases", []):
    if release["version"] != tag:
        continue
    count = n if mode == "set" else release.get("ours", 0) + n
    if count > 0:
        release["ours"] = count
    else:
        release.pop("ours", None)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"{tag}: {count} of its downloads are ours")
    break
else:
    raise SystemExit(f"{tag} is not in Website/releases.json")
PY
