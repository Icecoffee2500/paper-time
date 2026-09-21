#!/bin/bash
# Builds installable files from the working tree and leaves them in
# `Installers/` — for the person who owns the app to install and try before
# anything is published.
#
#   Scripts/build-installers.sh            # every platform
#   Scripts/build-installers.sh mac        # just the disk image
#   Scripts/build-installers.sh portable   # just Windows and Linux
#
# This publishes nothing, tags nothing and touches no git state. It builds
# **what is in the working tree**, not what is at a tag, which is the whole
# point: the version being checked is the one just changed.
#
# `Scripts/publish-release.sh` is the other half, and comes after — only once
# the files here have been installed and found to work.
set -euo pipefail

cd "$(dirname "$0")/.."
WHAT="${1:-all}"
VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | tr -d ' "' | cut -d: -f2)"
OUT="Installers"
mkdir -p "$OUT"

echo "Paper Time $VERSION → $OUT/"

if [ "$WHAT" = "all" ] || [ "$WHAT" = "mac" ]; then
  echo "· the Mac app, Release — a Debug build is several seconds slower to open"
  [ -d PaperTime.xcodeproj ] || xcodegen generate >/dev/null
  DD="build/installers"
  xcodebuild -project PaperTime.xcodeproj -scheme PaperTime -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" build \
    | grep -E "error:|BUILD" || true

  APP="$DD/Build/Products/Release/Paper Time.app"
  [ -d "$APP" ] || { echo "the app was not built"; exit 1; }

  # FoundationModels has to be weakly linked or Sonoma's dyld refuses to launch
  # the app at all. Cheap to check, and catastrophic to miss.
  if ! otool -l "$APP/Contents/MacOS/Paper Time" | grep -B3 FoundationModels | grep -q LC_LOAD_WEAK_DYLIB; then
    echo "FoundationModels is not weakly linked — this will not open on Sonoma"; exit 1
  fi

  STAGE="/tmp/papertime-installer-dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$OUT/Paper Time $VERSION.dmg"
  hdiutil create -volname "Paper Time $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
    "$OUT/Paper Time $VERSION.dmg" >/dev/null
  rm -rf "$STAGE"
  # Nothing left behind to be opened by mistake: the disk image is the only
  # copy this script leaves, and it is the one to install from.
  rm -rf "$DD"
  echo "  $OUT/Paper Time $VERSION.dmg"
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "portable" ]; then
  echo "· Windows and Linux"
  (cd Portable && npm run build >/dev/null && npm run dist:win >/dev/null && npm run dist:linux >/dev/null)
  # `dist:*` refuse to report success on a package that came out the wrong
  # size, so anything here is real. Only this version's files are copied, so a
  # stale one cannot be installed by mistake.
  found=0
  for file in Portable/dist/*"$VERSION"*.exe \
              Portable/dist/*"$VERSION"*.zip \
              Portable/dist/*"$VERSION"*.AppImage \
              Portable/dist/*"$VERSION"*.tar.gz; do
    [ -e "$file" ] || continue
    cp "$file" "$OUT/"
    echo "  $OUT/$(basename "$file")"
    found=$((found + 1))
  done
  [ "$found" -gt 0 ] || { echo "no packages were built for $VERSION"; exit 1; }
fi

echo
echo "Install one and try it. Publish only after that:"
echo "  Scripts/publish-release.sh $VERSION \"한 줄\" \"one line\""
