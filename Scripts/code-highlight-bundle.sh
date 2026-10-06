#!/bin/bash
# Bundles the note's code highlighter for the Mac (see code-highlight-bundle/entry.mjs)
# into App/Resources/CodeHighlight.js, from the Portable build's node_modules —
# the same highlight.js, at the same version, as the Portable build colours
# its notes with.
set -euo pipefail
cd "$(dirname "$0")/.."
ESBUILD=Portable/node_modules/.bin/esbuild
[ -x "$ESBUILD" ] || { echo "run npm install in Portable/ first" >&2; exit 1; }
# highlight.js is BSD-3-Clause, which asks for its notice to travel with the
# binary: the licence goes at the top of the bundle, as a comment.
LICENSE="$(cat Portable/node_modules/highlight.js/LICENSE)"
"$ESBUILD" Scripts/code-highlight-bundle/entry.mjs --bundle --format=iife --platform=neutral \
  --main-fields=module,main --target=es2019 --minify --legal-comments=none \
  --define:process.env.NODE_ENV='"production"' \
  --banner:js="/* highlight.js — $LICENSE */" \
  --outfile=App/Resources/CodeHighlight.js --log-level=warning
ls -l App/Resources/CodeHighlight.js | awk '{print "App/Resources/CodeHighlight.js", $5, "bytes"}'
