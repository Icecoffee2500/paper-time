#!/bin/bash
# Writes the fixtures Portable's metadata port is held to, from the Mac's own
# pipeline (`papertime-metadata-fixtures`, in Packages/PaperTimeKit):
#
#   Tests/MetadataPipelineTests/Fixtures/metadata-signals.json.gz
#       what DocumentSignalsExtractor reads off each corpus PDF, with the first
#       page's font runs, the guess and the header candidates;
#   …/metadata-pure.json.gz      8,000-odd calls and what the Mac answered;
#   …/metadata-responses.json.gz the registrars' answers, recorded once;
#   …/metadata-resolve.json.gz   what MetadataResolver concluded for each
#       input, with those answers — and with none (offline), with every one a
#       429, with doi.org saying 404, with Crossref sending something unreadable.
#
# `--record` asks doi.org, Crossref, OpenAlex and arXiv again (the same
# requests the app makes, with the papers' public titles); without it the
# committed answers are replayed and nothing leaves this machine.
# The corpus stays outside the repository; the three commercial books are
# left out of what is written.
set -euo pipefail
cd "$(dirname "$0")/.."
RECORD=""
[[ "${1:-}" == "--record" ]] && RECORD="--record"
OUT=Tests/MetadataPipelineTests/Fixtures
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
(cd Packages/PaperTimeKit && swift build --product papertime-metadata-fixtures >/dev/null)
TOOL=Packages/PaperTimeKit/.build/debug/papertime-metadata-fixtures
PDFS=()
while IFS= read -r -d '' pdf; do
  case "$(basename "$pdf")" in
    "Casella Berger"*|"Sutton Barto"*|"The_book_of_why"*) ;;
    *) PDFS+=("$pdf") ;;
  esac
done < <(find "$HOME/Documents/Bookends/Attachments" "$HOME/Documents/Bookends/vla" -maxdepth 1 -name '*.pdf' -print0 | sort -z)
"$TOOL" signals "$WORK/signals.json" "${PDFS[@]}" 2>/dev/null
python3 Scripts/metadata-cases.py - "$WORK/signals.json" "$WORK/cases.json"
"$TOOL" pure "$WORK/cases.json" > "$WORK/pure.json"
python3 - "$WORK" "$OUT" <<'PY'
import json, sys, os, gzip
work, out = sys.argv[1:]
rows = json.load(open(f'{work}/signals.json'))
wanted = ['kirkpatrick', 'Xu_Scene_Graph', 'Fast Machine Unlearning', '2403.18293v1.pdf', 'LeJEPA', 'I-JEPA',
          'Karmanov_Efficient_Test-Time_Adaptation_of_Vision-Language_Models_CVPR', 'Suhail_Energy-Based_Learning_for_Scene',
          'Changqian_Yu', 'Elastic Weight',
          'NeurIPS-2020-what-neural-networks-memorize-and-why-discovering-the-long-tail-via-influence-estimation-Paper',
          'A Vision-Language-Action Flow', 'SalUn', 'auto-encoding', '2410.04144v1.pdf',
          'Suhail_Energy-Based_Learning_for_CVPR',
          'NeurIPS-2020-what-neural-networks-memorize-and-why-discovering-the-long-tail-via-influence-estimation-Supplemental',
          'towards_casual', 'Pan et al 2025', 'Can Neural Network Memorization', '(optional) 4', 'Liu et al 2020']
inputs = []
for w in wanted:
    match = [r for r in rows if r['file'].startswith(w)]
    if match: inputs.append({'file': match[0]['file'], 'signals': match[0]['signals']})
empty = {'pageCount': 3, 'embeddedAuthors': [], 'embeddedKeywords': [], 'firstPageLines': [], 'openingText': '',
         'hasTextLayer': False, 'hasAbstract': False, 'hasReferences': False, 'isLandscape': False}
inputs.append({'file': 'scan.pdf', 'signals': empty})
inputs.append({'file': 'blank-text.pdf', 'signals': dict(empty, firstPageLines=['x'], openingText='x ' * 300, hasTextLayer=True)})
yu = [r for r in rows if r['file'].startswith('Changqian_Yu')][0]['signals']
inputs.append({'file': 'with-email.pdf', 'email': 'someone@example.org', 'signals': yu})
json.dump(inputs, open(f'{work}/inputs.json', 'w'), ensure_ascii=False)
json.dump([i for i in inputs if i['file'].startswith(('kirkpatrick', '2403.18293', 'Karmanov', 'Changqian', 'LeJEPA'))],
          open(f'{work}/inputs-sub.json', 'w'), ensure_ascii=False)
if os.path.exists(f'{out}/metadata-responses.json.gz'):
    json.dump(json.load(gzip.open(f'{out}/metadata-responses.json.gz')), open(f'{work}/responses.json', 'w'))
PY
"$TOOL" resolve "$WORK/inputs.json" "$WORK/responses.json" $RECORD > "$WORK/resolve-recorded.json" 2>/dev/null
python3 - "$WORK" <<'PY'
import json, sys
work = sys.argv[1]
r = json.load(open(f'{work}/responses.json'))
json.dump({}, open(f'{work}/resp-offline.json', 'w'))
json.dump({k: {'status': 429, 'body': '', 'retryAfter': '0'} for k in r}, open(f'{work}/resp-rateLimited.json', 'w'))
json.dump({k: (dict(v, status=404, body='') if k.startswith('https://doi.org/') else v) for k, v in r.items()},
          open(f'{work}/resp-doiNotFound.json', 'w'))
json.dump({k: (dict(v, body='{not json') if 'crossref' in k else v) for k, v in r.items()},
          open(f'{work}/resp-crossrefMalformed.json', 'w'))
PY
for scenario in offline rateLimited doiNotFound crossrefMalformed; do
  "$TOOL" resolve "$WORK/inputs-sub.json" "$WORK/resp-$scenario.json" > "$WORK/resolve-$scenario.json" 2>/dev/null
done
python3 - "$WORK" "$OUT" <<'PY'
import json, sys, gzip
work, out = sys.argv[1:]
def put(name, value):
    with gzip.GzipFile(f'{out}/{name}', 'wb', mtime=0) as f:
        f.write(json.dumps(value, ensure_ascii=False, sort_keys=True).encode())
put('metadata-signals.json.gz', json.load(open(f'{work}/signals.json')))
put('metadata-pure.json.gz', json.load(open(f'{work}/pure.json')))
put('metadata-responses.json.gz', json.load(open(f'{work}/responses.json')))
scenarios = {'recorded': ('inputs', 'responses')}
for s in ['offline', 'rateLimited', 'doiNotFound', 'crossrefMalformed']: scenarios[s] = ('inputs-sub', f'resp-{s}')
put('metadata-resolve.json.gz', {
    # The scenarios' answers are the recorded ones changed the same way
    # above; the reader of this file changes them again rather than carry
    # four copies.
    name: {'inputs': json.load(open(f'{work}/{i}.json')), 'results': json.load(open(f'{work}/resolve-{name}.json'))}
    for name, (i, r) in scenarios.items()})
PY
ls -l "$OUT"/metadata-*.json.gz
