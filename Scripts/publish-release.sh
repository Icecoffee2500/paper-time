#!/bin/sh
# Closes a version out to the world: builds the DMG at a tag, puts it on a
# GitHub release, and rewrites the download list the page reads.
#
#   Scripts/publish-release.sh 0.1.0 ["한 줄 설명"]
#
# The tag must exist and the repo must have a GitHub remote. Run it once per
# closed version; running it again for the same version replaces the DMG.
set -e

TAG="$1"; [ -n "$TAG" ] || { echo "usage: $0 <tag> [note]"; exit 64; }
NOTE="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "no such tag: $TAG"; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || {
  echo "no GitHub remote — create one first"; exit 1; }

DMG="dist/Paper Time $TAG.dmg"
[ -f "$DMG" ] || Scripts/make-dmg.sh "$TAG" >/dev/null
[ -f "$DMG" ] || { echo "the disk image was not built"; exit 1; }

# The release itself. Notes come from the version's own entry in the log
# rather than being written twice.
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
else
  gh release create "$TAG" "$DMG" \
    --title "Paper Time $TAG" \
    --notes "${NOTE:-Paper Time $TAG. 설치 방법과 이전 버전은 배포 페이지에.}"
fi

# The page reads this and nothing else: one line per version, newest first,
# with the address of the disk image on the release.
python3 - "$REPO" "$TAG" "$NOTE" <<'PY'
import json, subprocess, sys, pathlib

repo, tag, note = sys.argv[1], sys.argv[2], sys.argv[3]
raw = subprocess.run(
    ["gh", "release", "list", "--limit", "100",
     "--json", "tagName,publishedAt,isDraft,isPrerelease"],
    capture_output=True, text=True, check=True).stdout
releases = []
for item in json.loads(raw):
    if item.get("isDraft"):
        continue
    name = item["tagName"]
    assets = json.loads(subprocess.run(
        ["gh", "release", "view", name, "--json", "assets"],
        capture_output=True, text=True, check=True).stdout)["assets"]
    dmg = next((a for a in assets if a["name"].lower().endswith(".dmg")), None)
    if not dmg:
        continue
    releases.append({
        "version": name,
        "date": item.get("publishedAt"),
        "asset": dmg["url"],
        "size": dmg.get("size"),
        "note": note if name == tag and note else None,
    })

# Newest first, by version number rather than by the day it was pushed.
def key(entry):
    return [int(part) if part.isdigit() else 0
            for part in entry["version"].split("-")[0].split(".")]
releases.sort(key=key, reverse=True)

# A note written for one version stays with it across later runs.
page = pathlib.Path("Website/releases.json")
if page.exists():
    old = {r["version"]: r.get("note") for r in json.loads(page.read_text()).get("releases", [])}
    for entry in releases:
        if not entry["note"]:
            entry["note"] = old.get(entry["version"])

page.write_text(json.dumps({"repo": repo, "releases": releases}, indent=2, ensure_ascii=False) + "\n")
print(f"Website/releases.json — {len(releases)} version(s)")
PY

# The page lives on its own branch, holding nothing but itself: the site is
# what a visitor gets, and the source is what a reader of the source gets.
WORK="/tmp/papertime-pages"
rm -rf "$WORK"
git worktree add -q "$WORK" gh-pages 2>/dev/null || {
  git worktree add -q --detach "$WORK"
  git -C "$WORK" checkout -q --orphan gh-pages
  git -C "$WORK" rm -rq --cached . 2>/dev/null || true
  rm -f "$WORK"/* 2>/dev/null || true
}
trap 'git -C "$ROOT" worktree remove --force "$WORK" 2>/dev/null || true' EXIT
cp Website/index.html Website/releases.json "$WORK/"
git -C "$WORK" add -A
git -C "$WORK" commit -qm "Paper Time $TAG on the page" || echo "the page was already up to date"
git -C "$WORK" push -q origin gh-pages

echo "published $TAG to $REPO"
echo "the page: https://$(echo "$REPO" | cut -d/ -f1 | tr "A-Z" "a-z").github.io/$(echo "$REPO" | cut -d/ -f2)/"
echo "commit Website/releases.json here too, so the source keeps the list"
