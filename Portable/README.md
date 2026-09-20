# Paper Time — the Windows and Linux build

The same app, built for the desktops that have no PDFKit.

The Mac version is the Swift app in the repository root. This is a second
implementation of it: one Chromium, one stylesheet, one bundled typeface, so
the Windows build and the Linux build are the same program to look at and to
use — and near enough the same as the Mac's that a reader moving between them
does not have to find anything twice.

**The two halves share their files, not their code.** A library folder is a
folder of PDFs beside small JSON records, and both builds read and write it
byte for byte the same way. Open the same folder on a Mac and on a PC — through
a cloud drive, or a memory stick — and each sees what the other did.

---

## Running it

```bash
npm install
npm start
```

`npm run dev` opens the developer tools with it. `npm run watch` rebuilds on
every save; run `npx electron .` beside it.

To open a folder without disturbing whichever library you last had open —
which is how every check in this project is run:

```bash
npx electron . --papertime-library=/path/to/a/test/library
```

## Building the packages

```bash
npm run dist:win      # NSIS installer and a zip
npm run dist:linux    # AppImage and a tar.gz, x64 and arm64
```

Both can be built from any of the three platforms. `.deb` and `.rpm` cannot:
they go through `fpm`, which needs GNU `ar` and GNU `tar`, and on a Mac those
are Apple's — the result is a ninety-six byte package that electron-builder
reports as a success. `npm run dist:linux-packages` refuses to run anywhere
but Linux for that reason, and `tools/package.mjs` weighs everything it builds
so a broken installer cannot leave the room quietly.

## Checking it

```bash
npm test          # 37 conformance tests — mostly "does this match the Mac?"
npm run typecheck
```

The tests that matter are the ones that read files the Swift build actually
wrote and check this one reproduces them exactly: a real `meta.json`, a real
sketch sidecar, a BibTeX entry compared against the Swift exporter's output.

To look at the window without touching the machine — no synthesised system
events, nothing sent to whatever is in front:

```bash
npx electron . --papertime-library=<folder> --papertime-shot=<file.png>
npx electron . --papertime-library=<folder> --papertime-probe=<steps.json>
npx electron . --papertime-chrome=win32 …    # draw another desktop's chrome
```

A probe is a list of steps — `eval`, `click`, `drag`, `key`, `shot` — run
inside the page, with the events made and delivered in-process. `shot` takes
an optional `rect`, because cropping afterwards is a good way to end up
looking at the wrong part of the picture.

## How it is put together

```
src/
  shared/     the model, shared by both processes — and ported from Swift
    coding.ts       Swift's JSON, byte for byte
    model.ts        meta.json, state.json, library.json, collections.json
    sketch.ts       SketchElement: shapes, arrows, text cards
    sketchRender.ts one renderer, for the canvas and for measuring
    ink.ts          handwriting in a form that is not PencilKit's
    marks.ts        highlights and underlines
    bibtex.ts       .bib export, matching the Swift writer's output
    latexTable.ts   GENERATED from the Swift source — see tools/
  main/       the process that owns the files
    library.ts      reading and writing a library folder
    pdfwrite.ts     annotations into the PDF, and back out
    probe.ts        looking at the window without touching the machine
  renderer/   the window
    ui/reader.ts        pages, text layer, marks
    ui/sketchInput.ts   drawing with a mouse
```

`Docs/Porting.md` in the repository root has the reasoning: what crosses
between the two builds, what cannot, and what is not here yet.

## Licences

The app bundles [Pretendard](https://github.com/orioncactus/pretendard) (SIL
Open Font License 1.1, `assets/fonts/Pretendard-LICENSE.txt`),
[pdf.js](https://mozilla.github.io/pdf.js/) and
[pdf-lib](https://pdf-lib.js.org/) (both Apache-2.0 / MIT), and Electron.

The icons are drawn in `src/renderer/icons.ts`. SF Symbols are licensed for
Apple's platforms only and are not used here.
