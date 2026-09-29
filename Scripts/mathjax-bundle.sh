#!/bin/bash
# Bundles MathJax for the Mac's notes (see mathjax-bundle/entry.mjs) into
# App/Resources/MathJax.js, from the Portable build's node_modules — the same
# MathJax, at the same version, as the Portable build sets its notes with.
set -euo pipefail
cd "$(dirname "$0")/.."
ESBUILD=Portable/node_modules/.bin/esbuild
[ -x "$ESBUILD" ] || { echo "run npm install in Portable/ first" >&2; exit 1; }
"$ESBUILD" Scripts/mathjax-bundle/entry.mjs --bundle --format=iife --platform=neutral \
  --main-fields=module,main --target=es2019 --minify --legal-comments=none \
  --define:process.env.NODE_ENV='"production"' \
  --outfile=App/Resources/MathJax.js --log-level=warning \
  --alias:mathjax-full=./Portable/node_modules/mathjax-full
ls -l App/Resources/MathJax.js | awk '{print "App/Resources/MathJax.js", $5, "bytes"}'
