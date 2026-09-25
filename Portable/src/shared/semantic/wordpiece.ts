/**
 * Text into token ids, exactly as the model was trained to read it.
 *
 * all-MiniLM-L6-v2 reads BERT's uncased WordPiece, and a vector is only
 * comparable with the reference if the ids that made it are the same ids —
 * one piece different and the passage is a different passage to the model.
 * So this is not "a WordPiece tokenizer"; it is the one sentence-transformers
 * runs, which is Hugging Face's Rust `tokenizers` crate: `BertNormalizer`
 * (clean, pad CJK ideographs, strip accents, lowercase — in that order), then
 * `BertPreTokenizer` (split on whitespace, isolate punctuation), then WordPiece
 * (greedy longest match, `##` for a continuation, a word longer than 100
 * characters is `[UNK]`, and so is a word any part of which is not in the
 * vocabulary), then `[CLS] … [SEP]` with the pieces cut to fit 256.
 *
 * The one thing that cannot be read off the crate's code is its idea of
 * Unicode. It classifies characters with the `unicode_categories` crate, whose
 * tables are years older than any engine this runs on, and lowercases with
 * Rust's, which are newer. Leaning on JavaScript's `\p{…}`, `normalize('NFD')`
 * and `toLowerCase()` agreed on all but 659 code points — and which 659
 * depends on the engine's ICU, so the tests on Node and the app on Electron
 * would each have been right about a different set. So none of it is asked of
 * the engine: `Scripts/semantic-unicode.py` puts every code point to the
 * reference itself, and `unicodeTables.ts` is its answers.
 */
import { DROPPED, EXPANDED, ISOLATES, MAPPED, PADDED, PADDED_MAPPED, SPLITS } from './unicodeTables.js'

export const MAX_TOKENS = 256
const MAX_WORD_CHARACTERS = 100

export class WordPiece {
  readonly vocab: Map<string, number>
  readonly cls: number
  readonly sep: number
  readonly unk: number

  /** `vocab.txt` of the model: one piece a line, the id is the line number. */
  constructor(vocabText: string) {
    this.vocab = new Map()
    const lines = vocabText.split('\n')
    // A trailing newline is not a piece.
    if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
    lines.forEach((line, id) => {
      // The file is written with "\n"; a "\r" would be a Windows checkout
      // rewriting it, and is not part of the piece.
      this.vocab.set(line.endsWith('\r') ? line.slice(0, -1) : line, id)
    })
    this.cls = this.id('[CLS]')
    this.sep = this.id('[SEP]')
    this.unk = this.id('[UNK]')
  }

  private id(piece: string): number {
    const id = this.vocab.get(piece)
    if (id === undefined) throw new Error(`vocab.txt has no ${piece}`)
    return id
  }

  /** The ids the model is fed: `[CLS]`, at most `maxTokens − 2` pieces, `[SEP]`. */
  encode(text: string, maxTokens = MAX_TOKENS): number[] {
    const ids = [this.cls]
    const room = maxTokens - 1
    outer: for (const word of words(text)) {
      for (const id of this.pieces(word)) {
        if (ids.length >= room) break outer
        ids.push(id)
      }
    }
    ids.push(this.sep)
    return ids
  }

  /** The pieces of one word: the longest prefix in the vocabulary, again and again. */
  pieces(word: string): number[] {
    const chars = Array.from(word)
    if (chars.length > MAX_WORD_CHARACTERS) return [this.unk]
    const out: number[] = []
    let start = 0
    while (start < chars.length) {
      let end = chars.length
      let found: number | undefined
      while (start < end) {
        const piece = (start > 0 ? '##' : '') + chars.slice(start, end).join('')
        found = this.vocab.get(piece)
        if (found !== undefined) break
        end -= 1
      }
      // One part the vocabulary has no piece for makes the whole word
      // unknown — not the known parts with a hole in the middle.
      if (found === undefined) return [this.unk]
      out.push(found)
      start = end
    }
    return out
  }
}

// ------------------------------------------------------------------ normalise

/** Whether `cp` falls in one of the [first, last] pairs of a sorted table. */
function within(table: Uint32Array, cp: number): boolean {
  let low = 0
  let high = table.length / 2 - 1
  while (low <= high) {
    const middle = (low + high) >> 1
    if (cp < table[2 * middle]) high = middle - 1
    else if (cp > table[2 * middle + 1]) low = middle + 1
    else return true
  }
  return false
}

/** What the normaliser writes for each code point it does not keep as it is. */
const REPLACED: Map<number, string> = (() => {
  const map = new Map<number, string>()
  for (let i = 0; i < MAPPED.length; i += 2) map.set(MAPPED[i], String.fromCodePoint(MAPPED[i + 1]))
  for (let i = 0; i < PADDED_MAPPED.length; i += 2) {
    map.set(PADDED_MAPPED[i], ' ' + String.fromCodePoint(PADDED_MAPPED[i + 1]) + ' ')
  }
  for (const [cp, text] of EXPANDED) map.set(cp, text)
  return map
})()

/**
 * ASCII, which is nearly all of an English paper, answered once: what the
 * normaliser writes for it (`undefined` = keep it) and how the pre-tokenizer
 * cuts it (0 = part of a word, 1 = a space, 2 = a mark of its own).
 */
const ASCII_OUT: Array<string | undefined> = []
const ASCII_CUT = new Uint8Array(128)
for (let cp = 0; cp < 128; cp++) {
  ASCII_OUT[cp] = within(DROPPED, cp) ? '' : REPLACED.get(cp)
  ASCII_CUT[cp] = within(SPLITS, cp) ? 1 : within(ISOLATES, cp) ? 2 : 0
}

const HANGUL_FIRST = 0xac00
const HANGUL_LAST = 0xd7a3

/**
 * `BertNormalizer` over a whole string, a code point at a time — which is how
 * the reference does it too: drop what is not text, spaces to ' ', pad each
 * ideograph, decompose and drop the accents, lowercase.
 */
export function normalize(text: string): string {
  let out = ''
  for (const ch of text) {
    const cp = ch.codePointAt(0)!
    if (cp < 128) {
      const replaced = ASCII_OUT[cp]
      out += replaced === undefined ? ch : replaced
    } else if (cp >= HANGUL_FIRST && cp <= HANGUL_LAST) {
      // Hangul syllables decompose by the formula in the Unicode standard —
      // a Korean paper is thousands of these, and a table would be 11,172
      // rows of arithmetic.
      const s = cp - HANGUL_FIRST
      out += String.fromCharCode(0x1100 + Math.floor(s / 588), 0x1161 + Math.floor((s % 588) / 28))
      if (s % 28 !== 0) out += String.fromCharCode(0x11a7 + (s % 28))
    } else if (cp >= 0xd800 && cp <= 0xdfff) {
      // Half a surrogate pair is not a character; a Rust string cannot even
      // hold one, so the reference never sees it.
      continue
    } else if (within(DROPPED, cp)) {
      continue
    } else if (within(PADDED, cp)) {
      out += ' ' + ch + ' '
    } else {
      const replaced = REPLACED.get(cp)
      out += replaced === undefined ? ch : replaced
    }
  }
  return out
}

/** How the pre-tokenizer cuts at one code point: 0 = part of a word, 1 = a space, 2 = a mark of its own. */
function cutAt(cp: number): number {
  if (cp < 128) return ASCII_CUT[cp]
  return within(SPLITS, cp) ? 1 : within(ISOLATES, cp) ? 2 : 0
}

/** `BertPreTokenizer` over normalised text: words, with each punctuation mark its own. */
export function preTokenize(normalized: string): string[] {
  const out: string[] = []
  let word = ''
  for (const ch of normalized) {
    const cut = cutAt(ch.codePointAt(0)!)
    if (cut === 0) {
      word += ch
      continue
    }
    if (word) out.push(word)
    word = ''
    if (cut === 2) out.push(ch)
  }
  if (word) out.push(word)
  return out
}

/** The words WordPiece sees. */
export function words(text: string): string[] {
  return preTokenize(normalize(text))
}
