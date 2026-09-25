/**
 * A note's Markdown as words, for cutting into passages — the Mac's
 * `NoteText.plain` (Semantic/NoteText.swift), rule for rule.
 *
 * The notation comes out and the words stay, every word: a heading's `##`,
 * a link's `[[id|`, the `$` around a formula are for the renderer, and a
 * note that is one formula still means something. Light on purpose — the
 * passages are keyed by their text, so this rule is part of the cache's
 * key, and both builds must cut the same note to the same passages.
 */

/** In the Mac's order: fences, formulas, code, images, links, emphasis, rules, tags. */
const REPLACEMENTS: Array<[RegExp, string]> = [
  // Front matter, if a file's header was handed over with its body.
  [/^---\n[\s\S]*?\n---\n/, ''],
  // Fenced code: the fences go, the code stays.
  [/```[^\n]*\n?/g, ' '],
  // Formulas: the dollars go, the mathematics stays.
  [/\$\$/g, ' '],
  [/\$/g, ' '],
  // Inline code.
  [/`/g, ''],
  // Images, then links: the words shown stay, the address goes.
  [/!\[([^\]]*)\]\([^)\s]*\)/g, '$1'],
  [/\[\[([^\]|\n]+)\|([^\]\n]*)\]\]/g, '$2'],
  [/\[\[([^\]|\n]+)\]\]/g, '$1'],
  [/\[([^\]\n]*)\]\([^)\s]*\)/g, '$1'],
  // Emphasis marks, when they stand in pairs around something.
  [/\*\*([^*\n]+)\*\*/g, '$1'],
  [/__([^_\n]+)__/g, '$1'],
  [/(?<![\p{L}\p{N}])\*([^*\n]+)\*(?![\p{L}\p{N}])/gu, '$1'],
  [/(?<![\p{L}\p{N}])_([^_\n]+)_(?![\p{L}\p{N}])/gu, '$1'],
  // A rule, which is not a word.
  [/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/gm, ''],
  // Tags keep their word: `#robotics` is about robotics.
  [/(?<=^|\s)#(?=[\p{L}\p{N}])/gu, ''],
]

/** The words of a note, with the Markdown taken out and the white space left as it was. */
export function plainNoteText(markdown: string): string {
  let text = markdown
  for (const [pattern, replacement] of REPLACEMENTS) text = text.replace(pattern, replacement)
  return text
    .split('\n')
    .map((line) => line
      // What stands at the start of a line to say what kind of line it
      // is: a heading's hashes, a quotation's mark, a list's bullet or number.
      .replace(/^\s*(#{1,6}\s+|>\s*)+/, '')
      .replace(/^\s*([-*+]|\d+[.)])\s+/, ''))
    .join('\n')
}
