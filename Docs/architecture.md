# Paper Time — Architecture Notes

Companion to `PLAN.md`. This file records the decisions that are not obvious
from reading the code, and the measurements behind them.

## 1. The library is a folder, not a database

A Paper Time library is a directory the user picks once per device:

```
<library>/
├── library.json          identity, tags
├── collections.json      manual and smart collections
└── papers/
    └── 4F3A1C08-attention-is-all-you-need/
        ├── attention-is-all-you-need.pdf
        ├── meta.json     CSL-JSON record, confidence, identifiers
        ├── state.json    reading position, status, rating, note
        └── ink/p0003.drawing
```

Why a folder rather than SwiftData + CloudKit:

- A free Apple Developer account cannot use CloudKit entitlements at all.
- The same code then supports iCloud Drive, Google Drive, Dropbox and anything
  else that presents a folder, with no per-provider integration.
- The PDFs stay visible in Finder and Files, so the user is never locked in.
  Deleting the app does not delete the library.

Consequences the code has to handle, and does:

- **Folder names never change.** They are minted at import from the original
  file name. Renaming reads as delete-plus-create to most sync engines, which
  risks losing the ink sidecars for a cosmetic gain.
- **Metadata and reading state are separate files.** `meta.json` changes rarely;
  `state.json` changes constantly. Splitting them means two devices rarely write
  the same bytes at the same time.
- **Every write is coordinated and atomic.** `NSFileCoordinator` plus a
  temporary file and `replaceItemAt`. A coordinated *read* is also what makes a
  cloud provider materialise a file that has been evicted — the same call works
  for iCloud and for any File Provider, which is why there is no provider code.
- **Nothing is silently overwritten.** `save(meta:)` re-reads the file first and
  merges: a hand-edited record beats an automatic one regardless of timestamps,
  tags and collections are unioned rather than replaced, and reading progress
  never moves backwards.

## 2. Annotations are written into the PDF

This is the requirement the app exists for, and it is met in two different ways
because PDF can only represent one of them faithfully.

| Mark | Stored as | Notes |
|---|---|---|
| Highlight, underline, strikethrough, note | Standard `PDFAnnotation` in the PDF | Opens correctly in Preview, Acrobat, Zotero |
| Pen strokes | `PDFAnnotation(.ink)` in the PDF **and** the original `PKDrawing` beside it | The PDF ink annotation carries one width per stroke, so pressure taper is lost; the sidecar keeps the original for editing in the app |

A page's ink annotations are **regenerated wholesale** from the sidecar on every
save rather than diffed stroke by stroke. That keeps the file and the sidecar in
step by construction. The cost is that edits made to *our* ink in another app
are replaced on the next save; highlights and notes are untouched because they
are not tagged as ours (`/PTInk`). The reader shows a note when a file already
contained ink from elsewhere.

Saving is split by cost: the sidecar is written the moment the pencil lifts (a
few kilobytes), while the PDF is rewritten on a four-second idle delay, on page
change, and when the app goes to the background. PDFKit can only serialise a
whole document at once, and doing that after every stroke would stall on a
six-hundred-page book.

`PageGeometry` isolates the coordinate conversion — PDF's bottom-left origin,
the crop box offset, and page rotation — because every one of those is silent
when wrong. It has direct unit tests; the 270° case was wrong until they caught
it.

## 3. Metadata resolution is ordered by trustworthiness

```
1. identifier printed in the document
     DOI            → doi.org content negotiation (CSL-JSON)
     arXiv ID       → 10.48550/arXiv.<id> through doi.org
2. the PDF's own /Title and /Author, confirmed against a registrar
3. typography: the largest font on page one, expanded to whole lines
4. on-device language model (Apple silicon Macs only)
5. anything unconfirmed → "needs review" with one-tap candidates
```

Two findings from the 62-paper corpus shaped this:

- **Only 4 of 62 papers print a DOI on the first two pages**, but 32 carry an
  arXiv ID and 33 have a usable embedded `/Title`. An implementation that leans
  on DOIs alone — as the tools this app replaces appear to — resolves almost
  nothing in a machine-learning library.
- **arXiv's own API allows one request every three seconds** and refuses the
  rest. Resolving preprints through their DataCite DOI instead removes the
  bottleneck entirely.

Verification is one-directional on purpose: a record is only marked `verified`
when the title matches at 0.90 or better *and* the first author or the year
agrees, or when an identifier printed in the document produced it. Everything
else is flagged. A wrong record stored silently is worse than a two-second
confirmation, because the first one ends up in a submitted manuscript.

Candidate ranking is lexicographic — verified first, then title similarity, then
the blended score. An earlier version ranked by score alone, and a candidate
whose title matched 72% beat one that matched 96% because the first record
happened to list an author the other omitted.

## 4. What runs where

| Capability | Mac (M1 Pro) | iPad Air 4 | iPhone 12 Pro |
|---|---|---|---|
| Reading, search, outline | yes | yes | yes |
| Highlight / underline / strikethrough | yes | yes | yes (long press) |
| Pen annotation | no — `PKCanvasView` does not exist on macOS | yes | yes |
| On-device model for title extraction | yes | no — needs M1 or A17 Pro | no |
| Metadata resolution over the network | yes | yes | yes |

The two gaps cancel out in practice: the Mac cannot draw but can run the model,
the iPad can draw but cannot run the model, and the library folder carries the
results between them.

## 5. Developer tools

- `swift run papertime-eval <folder> [--online]` — runs the real pipeline over a
  folder of PDFs and reports how many resolved, from which source, and where the
  resolved title disagrees with the embedded one. This is how the accuracy
  numbers in `Docs/metadata-accuracy.md` were produced.
- `swift run papertime-seed <library> <pdf folder>` — fills a library using the
  same import and resolution code the app runs, for manual testing without
  driving the document picker by hand.
- `Tools/CorpusDump` — dumps the raw signals (embedded metadata, first-page
  lines, detected identifiers, largest font) for a corpus.
