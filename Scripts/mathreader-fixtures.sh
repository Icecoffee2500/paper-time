#!/bin/bash
# Writes the fixtures Portable's MathReader port is held to, from the Mac's own
# code (`Scripts/mathreader-fixtures.swift` compiled with MathReader,
# MathTranscriber, PDFContentScanner and TeXGlyphNames):
#
#   Portable/src/shared/mathReader/texTables.json      TeXGlyphNames' tables
#   Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz
#       for each page in mathreader-pages.json: the glyphs and rules the
#       scanner read, the line boxes and characters MathReader asked PDFKit
#       for, what the paper's first pages say about its variables, and the
#       pieces, structured Markdown and LaTeX it made of them.
#
#   Scripts/mathreader-fixtures.sh [bench-dir]
#
# A page is a corpus paper's (`"pdf"`, outside the repository in
# `~/Documents/Bookends`) or a bench setup's (`"bench"`: one formula of
# `Scripts/ultracopy-bench/formulas.txt` a page, set the way that setup sets
# it). The bench PDFs are read from <bench-dir>, or made in a temporary one
# with `Scripts/ultracopy-bench/make.sh`, which needs TeX Live. Neither kind
# of PDF is written into the repository; only what was read off them is.
# `src/test/mathReader.ts` runs both.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BENCH="${1:-}"
if [ -z "$BENCH" ]; then
  BENCH="$WORK/bench"
  setups=$(python3 -c "import json; print(' '.join(sorted({p['bench'] for p in json.load(open('Tests/PaperCoreTests/Fixtures/mathreader-pages.json')) if 'bench' in p})))")
  # shellcheck disable=SC2086
  Scripts/ultracopy-bench/make.sh "$BENCH" $setups >&2
fi
swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift App/Model/PDFContentScanner.swift \
  App/Model/TeXGlyphNames.swift Scripts/probe-localized.swift Scripts/mathreader-fixtures.swift \
  -o "$WORK/mathreader-fixtures"
"$WORK/mathreader-fixtures" tables > Portable/src/shared/mathReader/texTables.json
python3 - "$WORK/pages.json" "$BENCH" <<'PY'
import json, os, sys
pages = json.load(open('Tests/PaperCoreTests/Fixtures/mathreader-pages.json'))
bench = sys.argv[2]
out = []
for page in pages:
    numbers = page['pages'] if 'pages' in page else [page['page']]
    for number in numbers:
        item = {'page': number}
        if 'rect' in page:
            item['rect'] = page['rect']
        if 'bench' in page:
            item['pdf'] = os.path.join(bench, page['bench'] + '.pdf')
            item['bench'] = page['bench']
            item['name'] = 'bench %s p%d' % (page['bench'], number)
        else:
            item['pdf'] = os.path.expanduser(page['pdf'])
        out.append(item)
json.dump(out, open(sys.argv[1], 'w'))
PY
"$WORK/mathreader-fixtures" cases "$WORK/pages.json" | gzip -9n > Tests/PaperCoreTests/Fixtures/mathreader-cases.json.gz
echo "texTables.json and mathreader-cases.json.gz written"
