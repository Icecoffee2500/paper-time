#!/bin/bash
# Writes Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-format.json:
# what the Mac's NoteFormat answers to Scripts/note-format-cases.py, which
# Portable's `shared/noteFormat.ts` is held to (`src/test/noteFormat.ts`).
# Run after `xcodebuild` (Debug, build/mac); the app is asked off-screen.
set -euo pipefail
cd "$(dirname "$0")/.."
BOX=~/Library/Containers/com.imtaeheon.PaperTime/Data/tmp
mkdir -p "$BOX/FormatFixtureLibrary"
python3 Scripts/note-format-cases.py > "$BOX/note-format-cases.json"
rm -f "$BOX/note-format.json"
Scripts/probe.sh -s 20 -- --papertime-library="$BOX/FormatFixtureLibrary" \
  --papertime-format-fixture="$BOX/note-format-cases.json" \
  --papertime-format-fixture-out="$BOX/note-format.json" >/dev/null 2>&1 || true
test -s "$BOX/note-format.json"
cp "$BOX/note-format.json" Packages/PaperTimeKit/Tests/PaperCoreTests/Fixtures/note-format.json
rm -rf "$BOX/note-format-cases.json" "$BOX/note-format.json" "$BOX/FormatFixtureLibrary"
echo "wrote note-format.json"
