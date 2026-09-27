/**
 * `RecordSanitizer` (MetadataPipeline): a registrar's title filed as LaTeX —
 * `$\pi_0$: A Vision-Language-Action Flow Model` — cleaned before it reaches
 * the list, a citation or a `.bib` file.
 */

import type { CSLItem } from '../model.js'
import { trimWhitespaceAndNewlines } from '../zettel.js'
import { graphemes } from './chars.js'
import { unescapeLaTeX } from './latexUnescape.js'
import { collapsingWhitespace } from './text.js'

const FIELDS = ['title', 'subtitle', 'title-short', 'container-title', 'collection-title', 'event-title', 'publisher'] as const

export function sanitized(item: CSLItem): CSLItem {
  const out: CSLItem = { ...item }
  for (const key of FIELDS) {
    const value = out[key]
    if (typeof value === 'string') out[key] = clean(value)
  }
  return out
}

export function clean(raw: string): string {
  let text = collapsingWhitespace(raw)
  if (text.includes('\\') || text.includes('{')) text = unescapeLaTeX(text)
  text = strippingInlineMath(text)
  return trimWhitespaceAndNewlines(text)
}

/** `$…$` taken off what it wrapped, only when the dollars pair up. */
export function strippingInlineMath(raw: string): string {
  const characters = graphemes(raw)
  const dollars = characters.filter((character) => character === '$').length
  if (dollars < 2 || dollars % 2 !== 0) return raw
  let result = ''
  let inside = false
  for (const character of characters) {
    if (character === '$') {
      inside = !inside
      continue
    }
    if (inside && (character === '_' || character === '^')) continue
    result += character
  }
  return collapsingWhitespace(result)
}
