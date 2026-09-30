#!/bin/bash
# Sets every formula in formulas.txt, inline and displayed, one page each, in
# every font setup below — the fonts papers are actually set with — and
# leaves one PDF per setup in <out>. The PDFs are generated, never committed.
#
#   Scripts/ultracopy-bench/make.sh <out-dir> [setup…]
#
# Needs TeX Live (pdflatex, lualatex, xelatex).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?usage: make.sh <out-dir> [setup…]}"
shift || true
mkdir -p "$OUT"

# name | engine | class options | preamble
SETUPS=$(cat <<'LIST'
cm|pdflatex|10pt|\usepackage{amssymb}\usepackage{mathrsfs}
cm-bbm|pdflatex|10pt|\usepackage{amssymb}\usepackage{mathrsfs}\usepackage{bbm}
lmodern|pdflatex|10pt|\usepackage{lmodern}\usepackage{amssymb}\usepackage{mathrsfs}
times|pdflatex|10pt|\usepackage{times}\usepackage{amssymb}\usepackage{mathrsfs}
times9|pdflatex|9pt|\usepackage{times}\usepackage{amssymb}\usepackage{mathrsfs}
newtx|pdflatex|10pt|\usepackage{newtxtext,newtxmath}\usepackage{mathrsfs}
newpx|pdflatex|10pt|\usepackage{newpxtext,newpxmath}\usepackage{mathrsfs}
mathptmx|pdflatex|10pt|\usepackage{mathptmx}\usepackage{amssymb}\usepackage{mathrsfs}
txfonts|pdflatex|10pt|\usepackage{txfonts}\usepackage{mathrsfs}
pxfonts|pdflatex|10pt|\usepackage{pxfonts}\usepackage{mathrsfs}
libertine|pdflatex|10pt|\usepackage{libertine}\usepackage[libertine]{newtxmath}\usepackage{mathrsfs}
fourier|pdflatex|10pt|\usepackage{fourier}\usepackage{eufrak}\usepackage{mathrsfs}
stix2|pdflatex|10pt|\usepackage{stix2}
mathpazo|pdflatex|10pt|\usepackage{mathpazo}\usepackage{amssymb}\usepackage{mathrsfs}
euler|pdflatex|10pt|\usepackage{eulervm}\usepackage{amssymb}\usepackage{mathrsfs}
lm-otf|lualatex|10pt|\usepackage{unicode-math}\setmathfont{Latin Modern Math}
stix2-otf|lualatex|10pt|\usepackage{unicode-math}\setmainfont{STIX Two Text}\setmathfont{STIX Two Math}
termes-otf|lualatex|10pt|\usepackage{unicode-math}\setmainfont{TeX Gyre Termes}\setmathfont{TeX Gyre Termes Math}
libertinus-otf|lualatex|10pt|\usepackage{unicode-math}\setmainfont{Libertinus Serif}\setmathfont{Libertinus Math}
lm-xe|xelatex|10pt|\usepackage{unicode-math}\setmathfont{latinmodern-math.otf}
LIST
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FORMULAS="$(grep -v '^#' formulas.txt | grep -v '^[[:space:]]*$' | sed 's/ => .*//')"
# A formula marked `@display` is set on its own line only; its page says
# "Inline:" with nothing after it.

while IFS='|' read -r name engine size preamble; do
  if [ $# -gt 0 ]; then
    wanted=no
    for one in "$@"; do [ "$one" = "$name" ] && wanted=yes; done
    [ $wanted = yes ] || continue
  fi
  class=article
  [ "$size" = "9pt" ] && class=extarticle
  tex="$WORK/$name.tex"
  {
    echo "\\documentclass[$size]{$class}"
    echo "\\usepackage{amsmath}"
    echo "$preamble"
    # \mathbbm is bbm's, which has no outlines: pdfTeX draws it from bitmaps,
    # as a Type 3 font with no name (the cm-bbm setup). Everywhere else it is
    # the setup's own \mathbb.
    echo "\\providecommand{\\mathbbm}{\\mathbb}"
    echo "\\usepackage[paperwidth=6.5in,paperheight=3in,margin=0.4in]{geometry}"
    echo "\\pagestyle{empty}\\setlength{\\parindent}{0pt}"
    echo "\\begin{document}"
    number=0
    while IFS= read -r formula; do
      number=$((number + 1))
      if [ "${formula#@display }" != "$formula" ]; then
        formula="${formula#@display }"
        echo "Case $number. Inline: end."
      else
        echo "Case $number. Inline: \$$formula\$ end."
      fi
      echo ""
      echo "Display:"
      echo "\\[ $formula \\]"
      echo "Done."
      echo "\\newpage"
    done <<< "$FORMULAS"
    echo "\\end{document}"
  } > "$tex"
  ( cd "$WORK" && "$engine" -interaction=nonstopmode -halt-on-error=false "$name.tex" > "$name.out" 2>&1 ) || true
  if [ -f "$WORK/$name.pdf" ]; then
    cp "$WORK/$name.pdf" "$OUT/$name.pdf"
    errors=$(grep -c '^!' "$WORK/$name.log" 2>/dev/null || true)
    echo "$name: $(grep -c . <<< "$FORMULAS") formulas, $errors TeX errors"
    if [ "$errors" != "0" ]; then grep -A2 '^!' "$WORK/$name.log" | head -12 | sed 's/^/    /'; fi
  else
    echo "$name: no PDF — see below"
    tail -20 "$WORK/$name.log" 2>/dev/null | sed 's/^/    /'
  fi
done <<< "$SETUPS"
