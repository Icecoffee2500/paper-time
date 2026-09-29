#!/bin/bash
# Writes Tests/PaperCoreTests/Fixtures/note-render.json: what the Mac's note
# editor shows for Tests/PaperCoreTests/Fixtures/note-render.md, run by run,
# as `NoteMarkdown.dump` prints it (`PAPERTIME_DUMP_NOTE`). Portable's
# `shared/noteMarkdown.ts` is checked against it (`src/test/noteMarkdown.ts`).
#
# Build the Mac app first (build/mac, Debug). The app is launched through
# Scripts/probe.sh — hidden, off every screen — and quits after the dump.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTE=Tests/PaperCoreTests/Fixtures/note-render.md
OUT=Tests/PaperCoreTests/Fixtures/note-render.json
LIB="$HOME/Library/Containers/com.imtaeheon.PaperTime/Data/tmp/note-render-fixture"
mkdir -p "$LIB"
LOG="$(mktemp)"
Scripts/probe.sh -s 8 -l "$LOG" -- --papertime-library="$LIB" --papertime-dump-note="$(cat "$NOTE")" >/dev/null
python3 - "$NOTE" "$LOG" "$OUT" <<'PY'
import json, re, sys
note, log, out = sys.argv[1:]
runs = []
length = None
for line in open(log, encoding='utf-8'):
    line = line.rstrip('\n')
    m = re.match(r'^— (\d+) characters from', line)
    if m:
        length = int(m.group(1))
        continue
    m = re.match(r'^\s*(\d+) (\S*indent \d+(?:\+\S+)?|\S+)', line)
    if not m:
        continue
    marks = m.group(2)
    # `%-14@` does not pad an NSString: the text starts one space after the marks.
    text = line[m.end() + 1:].replace('⏎', '\n').replace('·', '\u200b')
    runs.append({'location': int(m.group(1)), 'marks': marks, 'text': text})
# The note as the app was handed it: `$(cat …)` drops the trailing line breaks.
json.dump({'markdown': open(note, encoding='utf-8').read().rstrip('\n'), 'length': length, 'runs': runs},
          open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(f'{out}: {len(runs)} runs, {length} characters')
PY
rm -f "$LOG"
