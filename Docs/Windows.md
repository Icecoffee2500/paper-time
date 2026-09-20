# Paper Time on Windows

## Installing

Download **Paper Time Setup 0.5.0.exe** and run it. It installs for the
current user, so it needs no administrator.

Windows will show a blue **"Windows protected your PC"** box the first time.
That is SmartScreen saying the installer is not signed by a certificate it
recognises — a code-signing certificate costs a few hundred dollars a year,
which this project does not have. Click **More info**, then **Run anyway**.
The same warning appears for every unsigned app, and it will stop appearing
once enough people have run this one.

If installing anything is not an option — a managed machine, a shared one —
take **Paper Time 0.5.0 portable.exe** or the zip instead. Both run from a
folder, including one on a memory stick.

## Where things go

| | |
|---|---|
| The app | `%LOCALAPPDATA%\Programs\paper-time\` |
| Preferences | `%APPDATA%\Paper Time\settings.json` |
| **Your library** | wherever you chose — the app never puts it anywhere |

Uninstalling removes the first two and never touches the third. Your papers
are your papers.

## Your library

Choose a folder the first time the app opens. A OneDrive, Dropbox, iCloud
Drive or Google Drive folder is the point: the same folder opened on a Mac
shows the same papers, the same highlights and the same handwriting, because
a library is only PDFs beside small text files — and the marks are written
into the PDFs themselves.

Two machines can have it open at once. Records are written whole and the
newer write wins; the drawing on a page belongs to whoever last drew on it.

## Keys

Everything the Mac has, with Ctrl in place of ⌘.

| | |
|---|---|
| `Ctrl+O` | Add PDFs |
| `Ctrl+K` | Search everything |
| `Ctrl+[` `Ctrl+P` `Ctrl+\` `Ctrl+]` | The four panes |
| `Alt+←` `Alt+→` | Back and forward through the papers you have opened |
| `Ctrl+Shift+H` / `Ctrl+Shift+U` | Highlight / underline the selection |
| `Ctrl+Shift+D` | Put the pen down (and pick it up) |
| `V P H E R O A L T` | The drawing tools, while the pen is out |
| `B` | Draw a frame round what is selected |
| `Ctrl+Z` / `Ctrl+Shift+Z` | Undo, redo |
| `Ctrl+Shift+F` | Focus mode — the paper and nothing else |

## Drawing with a pen

A Surface pen, a Wacom tablet or anything else Windows reports as a pointer
works, and the pressure goes into the width of the stroke. A mouse reports no
pressure, so a mouse line is an even line — which is the honest behaviour
rather than a fake taper.

## Building it yourself

```powershell
cd Portable
npm install
npm run dist:win
```

`dist\` gets the installer, the portable exe and the zip. The build works from
a Mac or a Linux machine too; electron-builder brings its own toolchain.

## If something goes wrong

The app writes nothing you cannot inspect. `%APPDATA%\Paper Time\settings.json`
is plain JSON and deleting it resets the window and the panes, not the library.
`Ctrl+R` re-reads the library folder if a sync has just brought something in.
