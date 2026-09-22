#!/bin/sh
# Builds the Mac app at a tag and leaves a DMG in dist/. Run when a version closes:
#   Scripts/make-dmg.sh 0.1.0
set -e
TAG="$1"; [ -n "$TAG" ] || { echo "usage: $0 <tag>"; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="/tmp/papertime-$TAG"; DD="/tmp/papertime-$TAG-dd"; STAGE="/tmp/papertime-$TAG-dmg"
rm -rf "$WORK"; git -C "$ROOT" worktree add -q "$WORK" "$TAG"
# Everything this makes outside dist/ goes away again, however it ends. The
# worktree was already being removed; the derived data and the staging folder
# were not, and they are the big ones — a release leaves 380 MB of them, which
# nobody ever looks at again. Found 6.6 GB in /tmp across twenty-odd versions.
trap 'git -C "$ROOT" worktree remove --force "$WORK"; rm -rf "$DD" "$STAGE"' EXIT
cd "$WORK"
[ -d PaperTime.xcodeproj ] || xcodegen generate >/dev/null
xcodebuild -project PaperTime.xcodeproj -scheme PaperTime -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" build | grep -E "error:|BUILD"
APP="$DD/Build/Products/Release/Paper Time.app"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
mkdir -p "$ROOT/dist"; rm -f "$ROOT/dist/Paper Time $TAG.dmg"
hdiutil create -volname "Paper Time $TAG" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/Paper Time $TAG.dmg" >/dev/null
echo "dist/Paper Time $TAG.dmg"
