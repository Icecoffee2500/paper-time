// MathJax for the Mac's notes, run inside JavaScriptCore.
//
// The Mac set its notes' formulas with a typesetter of its own, which knew
// the mathematics of a sentence and nothing of amsmath's environments —
// align, cases, the matrices. MathJax knows all of it, and the Portable
// build already sets with it; this bundles the Portable build's own setter
// (Portable/src/shared/mathJax.ts) for a JSContext, so the two builds set a
// formula with the same engine, the same packages and the same numbers.
//
//   Scripts/mathjax-bundle.sh      # writes App/Resources/MathJax.js
//
// Answers are JSON strings, so a JSContext hands them back in one piece:
// `render(latex, display, start, known, width)` gives {svg, next, labels}, or
// "" for a formula MathJax cannot set,
// `number` gives [{start, known}] for a note's formulas in order.
import { mathSetter, numberFormulas } from '../../Portable/src/shared/mathJax.ts'

// The Mac hands in somewhere to keep what was set (`PaperTimeStore`, a folder
// in its caches), so a note opened again is not set again.
const setter = mathSetter({ fontCache: 'none', store: globalThis.PaperTimeStore })

globalThis.PaperTimeMath = {
  render(latex, display, start, known, width) {
    const made = setter.set(String(latex), Boolean(display), Number(start) || 0,
      known ? JSON.parse(String(known)) : {}, Number(width) || undefined)
    return made ? JSON.stringify(made) : ''
  },
  number(formulas) {
    try {
      const list = JSON.parse(String(formulas))
      return JSON.stringify(numberFormulas(list, setter.set))
    } catch (error) {
      return ''
    }
  },
}
