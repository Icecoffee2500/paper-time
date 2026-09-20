#!/bin/sh
# Closes a version out to the world: puts every platform's build on a GitHub
# release, and rewrites the download list the page reads.
#
#   Scripts/publish-release.sh 0.5.0 ["한 줄 설명"]
#
# The Mac's disk image is built here if it is not already in dist/. The
# Windows and Linux packages are *not* — they take several minutes and pull
# down a hundred megabytes of Electron per platform, which is not something a
# release script should do behind your back. Build them first:
#
#   cd Portable && npm run dist:win && npm run dist:linux
#
# and this picks them up out of Portable/dist/. Without them it publishes the
# Mac build alone and says so.
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

# Everything to upload: the Mac's image, plus whichever cross-platform
# packages have been built. Named one per line so a file name with a space in
# it — which all of these have — survives.
ASSETS="$(mktemp)"
trap 'rm -f "$ASSETS"' EXIT
printf '%s\n' "$DMG" > "$ASSETS"

for pattern in \
  "Portable/dist/Paper Time Setup $TAG.exe" \
  "Portable/dist/Paper Time-$TAG-win.zip" \
  "Portable/dist/Paper Time-$TAG-x86_64.AppImage" \
  "Portable/dist/Paper Time-$TAG-arm64.AppImage"
do
  [ -f "$pattern" ] && printf '%s\n' "$pattern" >> "$ASSETS"
done

COUNT="$(wc -l < "$ASSETS" | tr -d ' ')"
echo "uploading $COUNT file(s):"
while IFS= read -r file; do
  echo "  $(basename "$file")  $(du -h "$file" | cut -f1)"
done < "$ASSETS"
[ "$COUNT" -eq 1 ] && echo "  (no Windows or Linux packages in Portable/dist — see the top of this script)"

# The release itself. Notes come from the version's own entry in the log
# rather than being written twice.
if gh release view "$TAG" >/dev/null 2>&1; then
  while IFS= read -r file; do
    gh release upload "$TAG" "$file" --clobber
  done < "$ASSETS"
else
  # `xargs -0` so the names keep their spaces on the way to gh.
  tr '\n' '\0' < "$ASSETS" | xargs -0 gh release create "$TAG" \
    --title "Paper Time $TAG" \
    --notes "${NOTE:-Paper Time $TAG. 설치 방법과 이전 버전은 배포 페이지에.}"
fi

# The page reads this and nothing else: one entry per version, newest first,
# with every platform's file under it.
python3 - "$REPO" "$TAG" "$NOTE" <<'PY'
import json, subprocess, sys, pathlib

repo, tag, note = sys.argv[1], sys.argv[2], sys.argv[3]

raw = subprocess.run(
    ["gh", "api", "repos/" + repo + "/releases", "--paginate"],
    capture_output=True, text=True, check=True).stdout


def platform_of(name):
    """Which desktop a file is for, from its name alone."""
    lower = name.lower()
    if lower.endswith(".dmg"):
        return "mac"
    if lower.endswith(".exe") or lower.endswith("-win.zip") or "win" in lower and lower.endswith(".zip"):
        return "windows"
    if lower.endswith((".appimage", ".deb", ".rpm", ".tar.gz")):
        return "linux"
    return None


def describe(name):
    """What to call it, and which machines it is for."""
    lower = name.lower()
    if lower.endswith(".dmg"):
        return "디스크 이미지", "Apple Silicon"
    if lower.endswith(".exe"):
        return "설치본", "64비트 · ARM"
    if lower.endswith(".zip"):
        return "압축본 — 설치 없이", "ARM64" if "arm64" in lower else "64비트"
    if lower.endswith(".appimage"):
        return "AppImage", "ARM64" if "arm64" in lower else "x86_64"
    if lower.endswith(".deb"):
        return "deb — 데비안·우분투", "ARM64" if "arm64" in lower else "x86_64"
    if lower.endswith(".rpm"):
        return "rpm — 페도라", "x86_64"
    if lower.endswith(".tar.gz"):
        return "tar.gz — 풀어서 실행", "ARM64" if "arm64" in lower else "x86_64"
    return name, ""


# The order a platform's files are offered in: the one most people want first.
def rank(name):
    lower = name.lower()
    for index, suffix in enumerate((".dmg", ".exe", ".appimage", ".zip", ".deb", ".rpm", ".tar.gz")):
        if lower.endswith(suffix):
            # Within a kind, 64-bit Intel before ARM — it is the commoner machine.
            return index * 2 + (1 if "arm64" in lower else 0)
    return 99


releases = []
for item in json.loads(raw):
    if item.get("draft"):
        continue
    builds = {}
    total = 0
    for asset in sorted(item.get("assets", []), key=lambda a: rank(a["name"])):
        platform = platform_of(asset["name"])
        if not platform:
            continue
        label, arch = describe(asset["name"])
        total += asset.get("download_count", 0)
        builds.setdefault(platform, []).append({
            "label": label,
            "arch": arch,
            "url": asset["browser_download_url"],
            "size": asset.get("size"),
            "downloads": asset.get("download_count", 0),
        })
    if not builds:
        continue
    mac = (builds.get("mac") or [{}])[0]
    releases.append({
        "version": item["tag_name"],
        "date": item.get("published_at"),
        # Kept so a page served from a cache, or an older copy of it, still
        # finds the Mac build where it always was.
        "asset": mac.get("url"),
        "size": mac.get("size"),
        # GitHub's own tally across every file of this version, as of this
        # run: a snapshot for the page to show when the live API is out of
        # reach.
        "downloads": total,
        "builds": builds,
        "note": note if item["tag_name"] == tag and note else None,
    })

# Newest first, by version number rather than by the day it was pushed.
def key(entry):
    return [int(part) if part.isdigit() else 0
            for part in entry["version"].split("-")[0].split(".")]
releases.sort(key=key, reverse=True)

# A note written for one version stays with it across later runs.
page = pathlib.Path("Website/releases.json")
if page.exists():
    old = {r["version"]: r.get("note")
           for r in json.loads(page.read_text()).get("releases", [])}
    for entry in releases:
        if not entry["note"]:
            entry["note"] = old.get(entry["version"])

page.write_text(json.dumps({"repo": repo, "releases": releases},
                           indent=2, ensure_ascii=False) + "\n")
print("Website/releases.json - " + str(len(releases)) + " version(s), "
      + str(sum(len(b) for r in releases for b in r["builds"].values())) + " file(s)")
PY

# What readers asked for, photographed from the issues so the page has an
# answer when a visitor is rate-limited and so the app's About wall — which
# asks no server for anything — is current in this build.
Scripts/feedback-sync.sh || true

# Onto gh-pages, by the script that does only that.
Scripts/publish-page.sh "Paper Time $TAG on the page" >/dev/null

echo "published $TAG to $REPO"
echo "the page: https://$(echo "$REPO" | cut -d/ -f1 | tr "A-Z" "a-z").github.io/$(echo "$REPO" | cut -d/ -f2)/"
echo "commit Website/releases.json here too, so the source keeps the list"
