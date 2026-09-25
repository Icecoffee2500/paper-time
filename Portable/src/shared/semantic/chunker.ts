/**
 * Pages cut into passages — `SemanticChunker.swift`, word for word.
 *
 * About 100 words with 25 of overlap. The model reads at most 256 tokens and
 * quietly drops the rest: windows of 150 words ran past that 31% of the time,
 * so the end of those passages was never seen by anything. 100 words of
 * English is about 130 tokens, which leaves room for the formulas and URLs
 * that tokenize long. The overlap is so that a sentence cut by one window's
 * edge is whole in the next.
 *
 * A word is a run of characters that are not Unicode white space. The last
 * window ends at the page's last word, so the tail of a page is never
 * dropped, and a page with no words has no passages.
 */
import { hex, sha256 } from './sha256.js'

export const WINDOW_WORDS = 100
export const OVERLAP_WORDS = 25

/**
 * What a vector is stored under: the first 128 bits of the SHA-256 of the
 * passage's text, as 32 hexadecimal digits — the Mac's `ChunkKey.description`.
 *
 * Keyed by the text and nothing else — not by paper, not by page — so that a
 * page whose text changed re-embeds only the passages that actually changed,
 * and a paper that exists twice in the folder costs one vector per passage.
 */
export type ChunkKey = string

export function chunkKey(text: string): ChunkKey {
  return hex(sha256(text).subarray(0, 16))
}

/**
 * A passage of one page: what gets a vector, and where to go when it is
 * chosen.
 *
 * `location`/`length` are UTF-16 offsets into that page's text, from the
 * first word's first character to the last word's last — the same units as
 * the Mac's `NSRange`, and as a JavaScript string's own indices.
 */
export interface SemanticChunk {
  paperID: string
  pageIndex: number
  location: number
  length: number
  /** The passage's words joined by single spaces. */
  text: string
  key: ChunkKey
}

const WHITE_SPACE = /\p{White_Space}/u

/** Each word's [start, end) in UTF-16 units. */
export function wordRanges(text: string): Array<[number, number]> {
  const words: Array<[number, number]> = []
  let start = -1
  let offset = 0
  for (const ch of text) {
    if (WHITE_SPACE.test(ch)) {
      if (start >= 0) words.push([start, offset])
      start = -1
    } else if (start < 0) {
      start = offset
    }
    offset += ch.length
  }
  if (start >= 0) words.push([start, offset])
  return words
}

export function chunksOfPage(
  text: string,
  paperID: string,
  pageIndex: number,
  windowWords = WINDOW_WORDS,
  overlapWords = OVERLAP_WORDS,
): SemanticChunk[] {
  const words = wordRanges(text)
  if (words.length === 0 || windowWords <= 0) return []
  const stride = Math.max(windowWords - Math.max(overlapWords, 0), 1)
  const chunks: SemanticChunk[] = []
  let start = 0
  for (;;) {
    const end = Math.min(start + windowWords, words.length)
    const pieces: string[] = []
    for (let i = start; i < end; i++) pieces.push(text.slice(words[i][0], words[i][1]))
    const joined = pieces.join(' ')
    const location = words[start][0]
    chunks.push({
      paperID,
      pageIndex,
      location,
      length: words[end - 1][1] - location,
      text: joined,
      key: chunkKey(joined),
    })
    if (end === words.length) break
    start += stride
  }
  return chunks
}
