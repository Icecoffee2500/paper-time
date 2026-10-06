#!/usr/bin/env python3
"""Types the same keys into a note in both builds and says, key by key, what
the note's Markdown is in each — and where the two part.

    Scripts/note-keys.py "1. a\\n2. b" Enter Tab two Enter Enter Undo Redo
    Scripts/note-keys.py --mac "" - _ a Enter Enter t Undo

The first argument is the note to start from (`\\n` for a line break; the
caret starts at its end). Then the keys: a word is typed a character at a
time, and these are keys of their own —

    Enter Tab S-Tab BS Del L R U D Undo Redo   _ (a space)

Nothing is put on the screen and nobody's keyboard is used: the Mac's keys go
to a note in a window of the probe's own, off every display
(`--papertime-note-scroll`), and Portable's are made inside its page
(`--papertime-probe`), both through `Scripts/probe.sh`. Build first:
`build/mac` (Debug) for the Mac, `npm run build` in `Portable/` for the
other. The notes live in the app's container and in a temporary folder, never
in a library anybody reads. Written for 0.9.31, when the lists in notes were
found to behave differently from one build to the other only by doing this.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTAINER = os.path.expanduser("~/Library/Containers/com.imtaeheon.PaperTime/Data/tmp/note-keys")
PORTABLE_LIBRARY = os.path.join(tempfile.gettempdir(), "papertime-note-keys", "lib")

MAC_KEYS = {"Enter": "Enter", "Tab": "Tab", "S-Tab": "Shift+Tab", "BS": "Backspace", "Del": "Delete",
            "L": "Left", "R": "Right", "U": "Up", "D": "Down", "Undo": "Undo", "Redo": "Redo", "_": "Space"}
# What a key is in the page: its `key`, and what it is pressed with.
PAGE_KEYS = {"Enter": ("Enter", {}), "Tab": ("Tab", {}), "S-Tab": ("Tab", {"shift": True}),
             "BS": ("Backspace", {}), "Del": ("Delete", {}), "L": ("ArrowLeft", {}), "R": ("ArrowRight", {}),
             "U": ("ArrowUp", {}), "D": ("ArrowDown", {}),
             # ⇧⌘Z as a browser sends it, «Z» and its code: with a lowercase
             # «z» CodeMirror reads «Meta-z» first, and undoes.
             "Undo": ("z", {"meta": True, "code": "KeyZ", "keyCode": 90}),
             "Redo": ("Z", {"meta": True, "shift": True, "code": "KeyZ", "keyCode": 90})}

HELPERS = r"""
window.__view = () => [...document.querySelectorAll('.cm-content')].find((el) => el.isConnected && el.offsetParent !== null)
window.__key = (key, mods) => { const v = window.__view(); v.focus(); const m = mods || {}; v.dispatchEvent(new KeyboardEvent('keydown', { key, code: m.code, keyCode: m.keyCode, shiftKey: !!m.shift, metaKey: !!m.meta, bubbles: true, cancelable: true })); return 'key' }
window.__type = (text) => { const v = window.__view(); v.focus(); for (const ch of text) document.execCommand('insertText', false, ch); return 'typed' }
window.__note = () => 'NOTE ' + JSON.stringify(window.__papertimeNotes.slipBoxState().text)
'ready'
"""


def keys_of(tokens):
    """The keys, one per press, with what each is called."""
    keys = []
    for token in tokens:
        if token in MAC_KEYS:
            keys.append(token)
        else:
            keys.extend(token)
    return keys


def mac(start, keys):
    os.makedirs(os.path.join(CONTAINER, "lib"), exist_ok=True)
    note = os.path.join(CONTAINER, "note.md")
    with open(note, "w", encoding="utf-8") as file:
        file.write(start)
    # The log outside the container: launchd cannot open one in there, and
    # `open` then fails with -10810 and no reason (CLAUDE.md).
    os.makedirs(os.path.dirname(PORTABLE_LIBRARY), exist_ok=True)
    log = os.path.join(os.path.dirname(PORTABLE_LIBRARY), "mac.log")
    pressed = ",".join(MAC_KEYS.get(key, key) for key in keys)
    subprocess.run([os.path.join(ROOT, "Scripts/probe.sh"), "-s", str(15 + len(keys)), "-l", log, "--",
                    f"--papertime-library={os.path.join(CONTAINER, 'lib')}", f"--papertime-note-scroll={note}",
                    f"--papertime-note-scroll-keys={pressed}", "--papertime-note-scroll-text=1"],
                   cwd=ROOT, capture_output=True)
    texts = []
    for line in open(log, encoding="utf-8", errors="replace"):
        found = re.match(r'note text: (".*") selection \{\d+, \d+\} shown', line.strip())
        if found:
            texts.append(json.loads(found.group(1)))
    return texts


def portable(start, keys):
    os.makedirs(PORTABLE_LIBRARY, exist_ok=True)
    steps = [{"wait": 3000, "eval": HELPERS}, {"menu": "newNote"},
             {"wait": 1500, "eval": f"window.__papertimeNotes.setSlipBoxText({json.dumps(start)}); 'set'"}]
    for key in keys:
        if key in PAGE_KEYS:
            name, mods = PAGE_KEYS[key]
            press = f"window.__key({json.dumps(name)}, {json.dumps(mods)})"
        else:
            press = f"window.__type({json.dumps(' ' if key == '_' else key)})"
        steps += [{"wait": 150, "eval": press}, {"wait": 250, "eval": "window.__note()"}]
    folder = os.path.dirname(PORTABLE_LIBRARY)
    steps_file = os.path.join(folder, "steps.json")
    log = os.path.join(folder, "portable.log")
    with open(steps_file, "w", encoding="utf-8") as file:
        json.dump(steps, file)
    subprocess.run([os.path.join(ROOT, "Scripts/probe.sh"), "-p", "-s", str(20 + len(keys)), "-l", log, "--",
                    f"--papertime-library={PORTABLE_LIBRARY}", f"--papertime-probe={steps_file}"],
                   cwd=ROOT, capture_output=True)
    text = open(log, encoding="utf-8", errors="replace").read()
    at = text.rfind("\n[\n")
    if at < 0:
        return []
    answers = json.loads(text[at + 1:text.rfind("]") + 1])
    return [json.loads(answer[5:]) for answer in answers if isinstance(answer, str) and answer.startswith("NOTE ")]


def main(arguments):
    only = None
    if arguments and arguments[0] in ("--mac", "--portable"):
        only, arguments = arguments[0][2:], arguments[1:]
    if not arguments:
        print(__doc__)
        return 64
    start = arguments[0].replace("\\n", "\n")
    keys = keys_of(arguments[1:])
    shown = [] if only == "portable" else mac(start, keys)
    other = [] if only == "mac" else portable(start, keys)
    parted = 0
    for index, key in enumerate(keys):
        a = shown[index] if index < len(shown) else None
        b = other[index] if index < len(other) else None
        same = only is not None or a == b
        parted += 0 if same else 1
        print(f"{'  ' if same else '≠ '}{key:6} {(a if a is not None else b)!r}")
        if not same:
            print(f"{'':9}{'portable':6} {b!r}")
    print(f"-- {len(keys)} keys" + ("" if only else f", {parted} where the builds part"))
    return 1 if parted else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
