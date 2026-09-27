#!/bin/bash
# Writes the fixtures Portable's MathReader port is held to, from the Mac's own
# code (`Scripts/mathreader-fixtures.swift` compiled with MathReader,
# MathTranscriber, PDFContentScanner and TeXGlyphNames):
#
#   Portable/src/shared/mathReader/texTables.json      TeXGlyphNames' tables
#   Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz
#       for each page in mathreader-pages.json: the glyphs and rules the
#       scanner read, the line boxes and characters MathReader asked PDFKit
#       for, and the pieces, structured Markdown and LaTeX it made of them.
#
# The corpus PDFs stay outside the repository (`~/Documents/Bookends`); only
# what was read off them is written. `src/test/mathReader.ts` runs both.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift App/Model/PDFContentScanner.swift \
  App/Model/TeXGlyphNames.swift Scripts/mathreader-fixtures.swift -o "$WORK/mathreader-fixtures"
"$WORK/mathreader-fixtures" tables > Portable/src/shared/mathReader/texTables.json
python3 - "$WORK/pages.json" <<'PY'
import json, os, sys
pages = json.load(open('Tests/PaperCoreTests/Fixtures/mathreader-pages.json'))
for page in pages:
    page['pdf'] = os.path.expanduser(page['pdf'])
json.dump(pages, open(sys.argv[1], 'w'))
PY
"$WORK/mathreader-fixtures" cases "$WORK/pages.json" | gzip -9n > Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz
echo "texTables.json and mathreader-cases.json.gz written"
