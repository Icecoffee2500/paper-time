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
# The same line in English. The page is read in two languages, so a note
# that exists only in Korean is a Korean sentence in an English list.
NOTE_EN="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "no such tag: $TAG"; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || {
  echo "no GitHub remote — create one first"; exit 1; }

DMG="dist/Paper Time $TAG.dmg"
[ -f "$DMG" ] || Scripts/make-dmg.sh "$TAG" >/dev/null
[ -f "$DMG" ] || { echo "the disk image was not built"; exit 1; }

# Never upload out from under a build. A package that is still being written
# has a size that changes between the header and the body, and GitHub rejects
# it with "request body larger than specified content length" — after it has
# already taken the other seven files.
if pgrep -f "electron-builder" >/dev/null 2>&1; then
  echo "electron-builder is still running — wait for it before publishing" >&2
  exit 1
fi

# Everything to upload: the Mac's image, plus whichever cross-platform
# packages have been built. Named one per line so a file name with a space in
# it — which all of these have — survives.
ASSETS="$(mktemp)"
trap 'rm -f "$ASSETS"' EXIT
printf '%s\n' "$DMG" > "$ASSETS"

for pattern in \
  "Portable/dist/Paper Time Setup $TAG.exe" \
  "Portable/dist/Paper Time-$TAG-win.zip" \
  "Portable/dist/Paper Time-$TAG-arm64-win.zip" \
  "Portable/dist/Paper Time-$TAG-x86_64.AppImage" \
  "Portable/dist/Paper Time-$TAG-arm64.AppImage" \
  "Portable/dist/paper-time-$TAG.tar.gz" \
  "Portable/dist/paper-time-$TAG-arm64.tar.gz"
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
python3 - "$REPO" "$TAG" "$NOTE" "$NOTE_EN" <<'PY'
import json, subprocess, sys, pathlib

repo, tag, note, note_en = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

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
    """What to call it, and which machines it is for — in both languages.

    The page is read in Korean or in English, so a label that exists only in
    Korean is a Korean word sitting in an English sentence. Both travel; the
    page picks."""
    lower = name.lower()
    arm = "arm64" in lower
    if lower.endswith(".dmg"):
        return ("디스크 이미지", "Disk image"), ("Apple Silicon", "Apple Silicon")
    if lower.endswith(".exe"):
        return ("설치본", "Installer"), ("64비트 · ARM", "64-bit and ARM")
    if lower.endswith(".zip"):
        return ("압축본 — 설치 없이", "Zip — no install"), (
            ("ARM64", "ARM64") if arm else ("64비트", "64-bit")
        )
    if lower.endswith(".appimage"):
        return ("AppImage", "AppImage"), (("ARM64", "ARM64") if arm else ("x86_64", "x86_64"))
    if lower.endswith(".deb"):
        return ("deb — 데비안·우분투", "deb — Debian and Ubuntu"), (
            ("ARM64", "ARM64") if arm else ("x86_64", "x86_64")
        )
    if lower.endswith(".rpm"):
        return ("rpm — 페도라", "rpm — Fedora"), ("x86_64", "x86_64")
    if lower.endswith(".tar.gz"):
        return ("tar.gz — 풀어서 실행", "tar.gz — unpack and run"), (
            ("ARM64", "ARM64") if arm else ("x86_64", "x86_64")
        )
    return (name, name), ("", "")


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
            "label": label[0],
            "label_en": label[1],
            "arch": arch[0],
            "arch_en": arch[1],
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
        "note_en": note_en if item["tag_name"] == tag and note_en else None,
    })

# Newest first, by version number rather than by the day it was pushed.
def key(entry):
    return [int(part) if part.isdigit() else 0
            for part in entry["version"].split("-")[0].split(".")]
releases.sort(key=key, reverse=True)

# A note written for one version stays with it across later runs.
page = pathlib.Path("Website/releases.json")
if page.exists():
    old = {r["version"]: r for r in json.loads(page.read_text()).get("releases", [])}
    for entry in releases:
        was = old.get(entry["version"], {})
        if not entry["note"]:
            entry["note"] = was.get("note")
        if not entry["note_en"]:
            entry["note_en"] = was.get("note_en")
        # How many of this version's downloads were ours, counted while
        # checking the build. The page takes them off the tally, so it says
        # how many other people took it.
        if was.get("ours"):
            entry["ours"] = was["ours"]

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

# Only the version that just went up stays on this disk. The release holds
# the copies that matter — these are for installing and checking before that,
# and a year of them is gigabytes of packages nobody will open again. Run
# after the upload, so nothing is thrown away until GitHub has it.
# This file is /bin/sh: a plain glob, not process substitution.
prune() {
  dir="$1"; kept=0; gone=0
  [ -d "$dir" ] || return 0
  for file in "$dir"/*; do
    [ -e "$file" ] || continue
    case "$(basename "$file")" in
      *"$TAG"*) kept=$((kept + 1)) ;;
      README.md|*.yml) ;;
      *) rm -rf "$file"; gone=$((gone + 1)) ;;
    esac
  done
  [ "$gone" -gt 0 ] && echo "$dir - kept $kept file(s) of $TAG, removed $gone older one(s)"
  return 0
}
prune Installers
prune Portable/dist
prune dist   # where make-dmg leaves the disk image

# And the app bundles left in the build folders: a Debug copy nobody should
# be opening, and the Release copy the disk image was made from. The indexes
# and object files stay — they are what makes the next build quick.
find build -maxdepth 6 -name "Paper Time.app" -prune -exec rm -rf {} + 2>/dev/null || true

echo "published $TAG to $REPO"
echo "the page: https://$(echo "$REPO" | cut -d/ -f1 | tr "A-Z" "a-z").github.io/$(echo "$REPO" | cut -d/ -f2)/"
echo "commit Website/releases.json here too, so the source keeps the list"
