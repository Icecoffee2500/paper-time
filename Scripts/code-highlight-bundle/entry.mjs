// The colours of a note's fenced code, for the Mac, run inside JavaScriptCore.
//
// This is the Portable build's own highlighter (Portable/src/shared/codeHighlight.ts)
// with highlight.js inside it, so a block of code is coloured the same on a
// Mac and on a PC — the same languages, the same roles.
//
//   Scripts/code-highlight-bundle.sh      # writes App/Resources/CodeHighlight.js
//
// `highlight(code, language)` answers a JSON string, [[from, to, role], …] in
// UTF-16 offsets into the code, or "" when something went wrong.
import { highlightCode } from '../../Portable/src/shared/codeHighlight.ts'

globalThis.PaperTimeCode = {
  highlight(code, language) {
    try {
      return JSON.stringify(highlightCode(String(code), String(language)).map((run) => [run.from, run.to, run.role]))
    } catch (error) {
      return ''
    }
  },
}
