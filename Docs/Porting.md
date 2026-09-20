# Porting Paper Time off the Mac

Written 2026-09-20, when the Windows and Linux builds were made.

## What the decision was

The Mac app is Swift, SwiftUI, AppKit, PDFKit, PencilKit and Foundation
Models. Of those, exactly one — Foundation — exists off Apple's platforms.
There was no version of "port the code" that was not a rewrite, so the
question was only what to rewrite it in, and what the two halves should share.

They share **the files**, not the code.

That was not a compromise. It is what the app already was: a library is a
folder of PDFs beside small JSON records, and the marks and handwriting are
written into the PDFs themselves. Two implementations that agree on those
files are interchangeable by construction — no server, no protocol, no
migration, and no version of one that can read a folder the other cannot. A
shared *codebase* would have bought much less: the Mac's value is that it is
a Mac app, and a lowest-common-denominator UI toolkit would have taken that
away to save work on a second implementation that is mostly UI anyway.

The second implementation is Electron with a TypeScript renderer. Not because
Electron is elegant, but because the requirement was that Windows and Linux
look and behave *identically*, and one Chromium is the only honest way to
promise that. A Qt or GTK build would be two more appearances to maintain.
The cost is a hundred megabytes per package, which for a desktop app that
opens two-megabyte PDFs is not the binding constraint.

## What crosses between the two builds

| | how it crosses | lossless? |
|---|---|---|
| The library, the records, the collections | `.papertime/*.json` | yes, byte for byte |
| Shapes, arrows, text cards | sidecar `sketch/pNNNN.json`, **and** `/PTSketch` on each annotation | yes, either way |
| Highlights, underlines | standard PDF annotations, plus the per-device journal | yes |
| Handwriting | PDF ink annotations | shape, width and colour — not pressure |
| Reading state, notes, favourites | `state.json` | yes |
| BibTeX export | — | identical output, verified |

Two things make this work, and both were already in the Mac app before the
port started:

**Every sketch annotation carries its own source.** `/PTSketch` holds the
element's JSON, base64'd. So a machine with the PDF and no sidecar rebuilds
the sidecar exactly — the curve of a bent arrow, the roundness of a corner,
none of which a PDF annotation can say on its own. This was tested by giving
the Mac a PDF this build had drawn on, with every sidecar deleted: it wrote
back a `sketch/p0000.json` **byte for byte identical** to the one this build
had written.

**The JSON is written the same way.** Swift's `JSONEncoder` pretty-prints with
a space before the colon, sorts keys by their UTF-8 bytes, writes an empty
array as a bracket, a blank line and a bracket, and ends at the closing brace
with no newline. `src/shared/coding.ts` reproduces all of that, and the tests
read a real `meta.json` off disk and check it round-trips unchanged. Getting
this wrong would not have broken anything visibly — it would have made every
file either build touched look like a whole-file change to the cloud drive
they share, and turned a quiet sync into a conflict.

Two date shapes, because Swift uses two: the library's records go through
`JSONCoding`, which is `.iso8601`; the sketch sidecars use a plain
`JSONEncoder`, whose default is seconds since 2001-01-01. A `Date` only holds
whole milliseconds, so re-encoding a timestamp the Mac wrote
(`811492215.409792`) would come back `…4089999` and change every shape in a
file merely opened. The number the file held is kept and written back.

## What does not cross

**PencilKit's `.drawing`.** It is a private binary — a magic number, then
protobuf with Apple's own point compression. This build cannot read it and
does not try. Handwriting crosses through the PDF instead, which the Mac
writes on save; what is lost there is the pressure at each point, which is
exactly what the Mac loses too and why both sides keep a sidecar of their own.

When a page has a `.drawing` and the PDF has no ink — a page drawn on a Mac
that has not been saved since — this build says so rather than showing the
page with the writing missing. And when a page that has a `.drawing` is drawn
on *here*, the Mac's file is renamed `…​.drawing.superseded-<when>` rather than
deleted: both sidecars claiming one page would have the two machines showing
different things, and the Mac reads its own in preference to the file. Renamed
and not deleted, because the pressure in it is the user's work.

**Anything that is an Apple framework by definition.** On-device metadata
extraction is Foundation Models; there is no equivalent and no cloud LLM is
going in (`CLAUDE.md`). A paper imported here gets a record marked `unparsed`,
which the Mac fills in the next time it sees it.

## What is in this build

The reader, the four panes and the toolbar, with the Mac's arrangement and the
Mac's keys (⌘ becomes Ctrl and nothing else changes). Library open, import,
adopt-in-place, trash, folder watching. The shelves, sort, search over the
library. Highlights and underlines, with the selection bar. The whole drawing
layer — select, pen, highlighter, eraser, rectangle, ellipse, arrow, line,
text, the style panel, handles, bending, marquee, framing a selection, z-order,
undo. The inspector's details, editable. BibTeX export. Page tint, zoom, dark
mode.

## What is not, yet

Named plainly, because a list of what is missing is more use than a claim that
nothing is:

- **Metadata resolution** — no OpenAlex or Crossref lookup. New records are
  `unparsed` until a Mac sees them.
- **The slip-box** — one summary note per paper, not the note list, the
  editor, the links between notes, or the typeset maths.
- **⌘L, quote into a note** — and the maths transcription behind it.
- **Full-text search** — the palette searches titles, authors, venues and
  citation keys, not the text of the papers.
- **Find in document.**
- **The citation graph.**
- **The marks list** in the inspector — marks are made and saved, but the
  inspector's Marks tab does not list them yet.
- **Book trim**, the margin mask.
- **The feature demos and What's New.**
- **A settings window** — the preferences that exist are in the ⋯ menu.

## Where the appearance is deliberately not identical

The window's own buttons. A Mac keeps its traffic lights at the left, where a
Mac user reaches for them; Windows and Linux draw minimise, maximise and close
at the right in their own idiom. Those buttons belong to the desktop, not to
Paper Time, and a green traffic light on Windows reads as a bug. Everything
between the two ends of the toolbar is the same on all three.

`--papertime-chrome=win32` draws another desktop's chrome on the machine you
are on, so this can be checked without that machine.

## Branches

`mac`, `windows` and `linux`, as asked for: the Apple app on one, and the
shared build with each platform's packaging on the other two. `windows` and
`linux` are branched from the same commit and their shared files are
identical, so merging between them is a fast-forward of whatever changed.
