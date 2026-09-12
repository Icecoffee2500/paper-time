#!/bin/zsh
# Builds Paper Time for release and wraps it in a disk image.
#
# The app is signed ad hoc, because a free Apple developer account cannot
# issue a Developer ID and only a Developer ID can be notarised. That is not
# a flaw in the build: it is the account. Anyone opening this on another Mac
# has to right-click the app and choose Open the first time, or run
#   xattr -dr com.apple.quarantine "/Applications/Paper Time.app"
# because Gatekeeper cannot check an app nobody vouched for.
set -euo pipefail

root=${0:A:h:h}
cd "$root"

build=${1:-$root/.dmg-build}
entitlements=App/Resources/PaperTime-macOS.entitlements
version=$(grep -m1 'MARKETING_VERSION' project.yml | sed 's/.*"\(.*\)"/\1/')
dmg="$root/Paper Time $version.dmg"

echo "▸ generating the project"
xcodegen generate >/dev/null

echo "▸ building Release"
rm -rf "$build"
xcodebuild -project PaperTime.xcodeproj -scheme PaperTime -configuration Release \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" \
  -derivedDataPath "$build" build >/dev/null

app="$build/Build/Products/Release/Paper Time.app"
[[ -d $app ]] || { echo "no app at $app"; exit 1 }

# Xcode adds get-task-allow to anything it signs for development, which lets
# any process attach a debugger. A build meant to leave this machine should
# not carry it, so the app is signed again from the entitlements we actually
# declare.
echo "▸ signing without the debug entitlement"
codesign --force --deep --sign - --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"

echo "▸ staging"
stage=$(mktemp -d)
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

echo "▸ writing the disk image"
rm -f "$dmg"
hdiutil create -volname "Paper Time" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"

echo "▸ done: $dmg"
ls -lh "$dmg" | awk '{print "  " $5}'
