# Paper Time on Linux

## Installing

**AppImage** is the one that works everywhere:

```bash
chmod +x 'Paper Time-0.5.0-x86_64.AppImage'
./'Paper Time-0.5.0-x86_64.AppImage'
```

There is an `arm64` build too, for a Raspberry Pi or an Asahi machine.

To get it into your menu rather than running it from a folder, install
[AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher), or do it
by hand:

```bash
mkdir -p ~/.local/bin ~/.local/share/applications
mv 'Paper Time-0.5.0-x86_64.AppImage' ~/.local/bin/paper-time
cat > ~/.local/share/applications/paper-time.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Paper Time
Comment=Read, annotate and cite papers
Exec=paper-time %f
Icon=paper-time
Categories=Office;Science;
MimeType=application/pdf;
EOF
update-desktop-database ~/.local/share/applications
```

**Debian and Ubuntu** can use the `.deb`; **Fedora** the `.rpm`:

```bash
sudo apt install ./paper-time_0.5.0_amd64.deb
sudo dnf install ./paper-time-0.5.0.x86_64.rpm
```

**The tar.gz** unpacks anywhere and runs from there. Nothing is installed.

## Two things that bite on Linux

**The sandbox.** Unpacking the tar.gz on a kernel with unprivileged user
namespaces disabled gives:

```
FATAL: The SUID sandbox helper binary was found, but is not configured correctly.
```

Either set it up once —

```bash
sudo chown root:root paper-time/chrome-sandbox
sudo chmod 4755 paper-time/chrome-sandbox
```

— or run with `--no-sandbox`, understanding that you are turning off a
protection that matters when the app opens files other people wrote. The
AppImage and the `.deb` handle this for you; this is only the tar.gz.

**Wayland.** The app asks for Wayland where the session offers it, because
under XWayland a fractional-scale display blurs the window *and* puts the
pointer a scale factor away from where the pen thinks it is. If your compositor
has trouble, force the other one:

```bash
paper-time --ozone-platform-hint=x11
```

## Where things go

| | |
|---|---|
| Preferences | `~/.config/Paper Time/settings.json` |
| **Your library** | wherever you chose — the app never puts it anywhere |

## Your library

Choose a folder the first time the app opens. Point it at a synced folder —
Nextcloud, Dropbox, `rclone`, a Syncthing share — and the same library opens
on a Mac and on Windows with the same highlights and the same handwriting: a
library is only PDFs beside small text files, and the marks are written into
the PDFs themselves.

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

## Drawing with a tablet

A Wacom or XP-Pen reports pressure through libinput, and it goes into the
width of the stroke. A mouse reports none, so a mouse line is an even line.

## Building it yourself

```bash
cd Portable
npm install
npm run dist:linux            # AppImage and tar.gz — buildable anywhere
npm run dist:linux-packages   # .deb and .rpm — Linux only, see below
```

`.deb` and `.rpm` go through `fpm`, which needs GNU `ar` and GNU `tar`. On a
Mac those are Apple's, and what comes out is a ninety-six byte package that
electron-builder reports as a success — so `dist:linux-packages` refuses to
run anywhere but Linux, and every build is weighed afterwards.

## Fonts

The interface carries its own typeface (Pretendard), so it looks the same here
as on Windows whatever the distribution ships. The *papers* use their own
embedded fonts, and pdf.js carries the standard fourteen and the CJK character
maps, so a Korean or Japanese paper renders without anything installed.
