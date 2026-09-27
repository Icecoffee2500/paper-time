#!/bin/sh
# Builds `Scripts/bibtex-fixtures.swift` against the Mac's own Bibliography
# and CSL sources (their `import PaperCore` taken out, since they are compiled
# together here) and prints the cases. See the Swift file for why.
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for file in \
  Packages/PaperTimeKit/Sources/PaperCore/CSL/CSLDate.swift \
  Packages/PaperTimeKit/Sources/PaperCore/CSL/CSLItem.swift \
  Packages/PaperTimeKit/Sources/PaperCore/CSL/CSLName.swift \
  Packages/PaperTimeKit/Sources/PaperCore/CSL/CSLType.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Util/TextNormalization.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Model/Identifiers.swift \
  Packages/PaperTimeKit/Sources/Bibliography/BibTeXEntry.swift \
  Packages/PaperTimeKit/Sources/Bibliography/BibTeXExportOptions.swift \
  Packages/PaperTimeKit/Sources/Bibliography/BibTeXWriter.swift \
  Packages/PaperTimeKit/Sources/Bibliography/CaseProtection.swift \
  Packages/PaperTimeKit/Sources/Bibliography/CitationKey.swift \
  Packages/PaperTimeKit/Sources/Bibliography/LaTeXEscaping.swift; do
  sed '/^import PaperCore$/d' "$file" > "$work/$(basename "$file")"
done
swiftc -O -parse-as-library -enable-bare-slash-regex "$work"/*.swift Scripts/bibtex-fixtures.swift -o "$work/fixtures" 2>&1 >&2
"$work/fixtures"
