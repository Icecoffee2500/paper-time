#!/bin/sh
# Builds `Scripts/fresh-meta-fixture.swift` against the Mac's own PaperCore
# model (its sources compiled together, as `bibtex-fixtures.sh` does).
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for file in Packages/PaperTimeKit/Sources/PaperCore/CSL/*.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Util/*.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Model/PaperMeta.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Model/MetadataConfidence.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Model/MetadataCandidate.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Model/Identifiers.swift \
  Packages/PaperTimeKit/Sources/PaperCore/Model/DocumentKind.swift; do
  sed '/^import PaperCore$/d' "$file" > "$work/$(basename "$file")"
done
swiftc -O -parse-as-library -enable-bare-slash-regex "$work"/*.swift Scripts/fresh-meta-fixture.swift -o "$work/fresh" >&2
"$work/fresh"
