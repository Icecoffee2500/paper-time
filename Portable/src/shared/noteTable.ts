/**
 * Tables in a note: found, read, and made from what is pasted — the Mac's
 * `NoteTable` (PaperCore), held to its answers by
 * `Tests/PaperCoreTests/Fixtures/note-tables.json`.
 *
 * A note's table is a Markdown table. Read a line at a time it is several
 * lines of bars, so this finds each table's lines for the editor to draw as
 * one grid; and a table copied out of ChatGPT or Obsidian arrives as HTML,
 * or as rows of tab-separated cells, which pasted as they were became a line
 * a cell — this turns either into the Markdown table it stands for.
 */
import { lineRanges, type TextSpan } from './noteMath.js'
import { trimWhitespace } from './zettel.js'

export type Alignment = 'none' | 'left' | 'center' | 'right'
export interface Table { header: string[]; alignments: Alignment[]; rows: string[][] }

const isRow = (line: string) => line.includes('|') && trimWhitespace(line) !== ''

function isRule(line: string): boolean {
  if (!line.includes('|')) return false
  const parts = cells(line)
  if (parts.length === 0) return false
  return parts.every((part) => {
    let body = part
    if (body.startsWith(':')) body = body.slice(1)
    if (body.endsWith(':')) body = body.slice(0, -1)
    return body !== '' && /^-+$/.test(body)
  })
}

function alignmentOf(rule: string): Alignment {
  const left = rule.startsWith(':')
  const right = rule.endsWith(':')
  return left && right ? 'center' : right ? 'right' : left ? 'left' : 'none'
}

/** Each table, from the start of its header line to the end of its last row. */
export function tableBlocks(text: string): TextSpan[] {
  const lines = lineRanges(text)
  const result: TextSpan[] = []
  let index = 0
  while (index + 1 < lines.length) {
    const head = text.slice(lines[index].from, lines[index].to)
    const rule = text.slice(lines[index + 1].from, lines[index + 1].to)
    if (!(head.includes('|') && isRule(rule) && cells(head).length === cells(rule).length)) {
      index += 1
      continue
    }
    let last = index + 1
    while (last + 1 < lines.length && isRow(text.slice(lines[last + 1].from, lines[last + 1].to))) last += 1
    result.push({ from: lines[index].from, to: lines[last].to })
    index = last + 1
  }
  return result
}

/** The table a block of lines holds. */
export function parseTable(block: string): Table | null {
  const lines = block.split('\n').map((line) => (line.endsWith('\r') ? line.slice(0, -1) : line))
  if (lines.length < 2 || !lines[0].includes('|') || !isRule(lines[1])) return null
  const header = cells(lines[0])
  const alignments = cells(lines[1]).map(alignmentOf)
  if (header.length !== alignments.length) return null
  const rows = lines.slice(2).filter(isRow).map((line) => {
    const row = cells(line)
    while (row.length < header.length) row.push('')
    return row.slice(0, header.length)
  })
  return { header, alignments, rows }
}

/** A row's cells: split at every unescaped `|`, outer pipes dropped, trimmed. */
export function cells(line: string): string[] {
  let text = trimWhitespace(line)
  if (text.startsWith('|')) text = text.slice(1)
  if (text.endsWith('|') && !text.endsWith('\\|')) text = text.slice(0, -1)
  const out: string[] = []
  let current = ''
  let escaped = false
  for (const character of text) {
    if (escaped) {
      current += character === '|' ? '|' : `\\${character}`
      escaped = false
    } else if (character === '\\') {
      escaped = true
    } else if (character === '|') {
      out.push(trimWhitespace(current))
      current = ''
    } else {
      current += character
    }
  }
  if (escaped) current += '\\'
  out.push(trimWhitespace(current))
  return out
}

const escapeCell = (cell: string) => cell.replaceAll('|', '\\|').replaceAll('\r\n', ' ').replaceAll('\n', ' ')

/** A table as Markdown: a header, its rule, its rows. */
export function tableMarkdown(table: Table): string {
  const columns = Math.max(table.header.length, ...table.rows.map((row) => row.length), 0)
  if (columns === 0) return ''
  const row = (list: string[]) => {
    const padded = [...list, ...Array(Math.max(0, columns - list.length)).fill('')].slice(0, columns)
    return `| ${padded.map(escapeCell).join(' | ')} |`
  }
  const rule = `| ${Array.from({ length: columns }, (_, index) => {
    switch (table.alignments[index] ?? 'none') {
      case 'left': return ':---'
      case 'center': return ':---:'
      case 'right': return '---:'
      default: return '---'
    }
  }).join(' | ')} |`
  return [row(table.header), rule, ...table.rows.map(row)].join('\n')
}

/** Rows of tab-separated cells, as a table (the first row its header). */
export function fromTabSeparated(text: string): string | null {
  const lines = text.replaceAll('\r\n', '\n').split('\n').filter((line) => trimWhitespace(line) !== '')
  if (lines.length < 2) return null
  const rows = lines.map((line) => line.split('\t').map(trimWhitespace))
  const width = rows[0].length
  if (width < 2 || !rows.every((row) => row.length === width)) return null
  return tableMarkdown({ header: rows[0], alignments: [], rows: rows.slice(1) })
}

const ENTITIES: Record<string, string> = {
  amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
  ndash: '–', mdash: '—', hellip: '…', times: '×', middot: '·',
}

export function decodeEntities(text: string): string {
  if (!text.includes('&')) return text.replaceAll('\u00A0', ' ')
  const characters = [...text]
  let out = ''
  for (let index = 0; index < characters.length; index += 1) {
    if (characters[index] === '&') {
      const window = characters.slice(index, index + 12)
      const semicolon = window.indexOf(';')
      if (semicolon > 0) {
        const name = window.slice(1, semicolon).join('')
        let replacement: string | undefined
        const scalar = (value: number) => (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff) ? undefined : String.fromCodePoint(value))
        if (/^#[xX][0-9a-fA-F]+$/.test(name)) replacement = scalar(parseInt(name.slice(2), 16))
        else if (/^#[0-9]+$/.test(name)) replacement = scalar(parseInt(name.slice(1), 10))
        else replacement = ENTITIES[name]
        if (replacement !== undefined) {
          out += replacement
          index += semicolon
          continue
        }
      }
    }
    out += characters[index]
  }
  return out.replaceAll('\u00A0', ' ')
}

/** An HTML fragment with a table in it, as Markdown; null without one. */
export function fromHTML(html: string): string | null {
  if (!/<table/i.test(html)) return null
  const out: string[] = []
  let prose = ''
  const tables: string[][][] = []
  let row: string[] | null = null
  let cell: string | null = null
  let depth = 0

  const flushProse = () => {
    const lines = prose.split('\n').map((line) => line.split(' ').filter((word) => word !== '').join(' ')).filter((line) => line !== '')
    if (lines.length > 0) out.push(lines.join('\n'))
    prose = ''
  }
  const text = (piece: string) => {
    const decoded = decodeEntities(piece).replaceAll('\r', ' ').replaceAll('\n', ' ').replaceAll('\t', ' ')
    if (cell !== null) cell += decoded
    else if (depth === 0) prose += decoded
  }

  let index = 0
  while (index < html.length) {
    const open = html.indexOf('<', index)
    if (open < 0) {
      text(html.slice(index))
      break
    }
    text(html.slice(index, open))
    const close = html.indexOf('>', open)
    if (close < 0) break
    const tag = html.slice(open + 1, close).toLowerCase()
    index = close + 1
    const closing = tag.startsWith('/')
    const name = (/^[\p{L}\p{N}]*/u.exec(tag.replace(/^\/+/, '')) ?? [''])[0]
    if (tag.startsWith('!--')) {
      const end = html.indexOf('-->', open)
      if (end >= 0) index = end + 3
      continue
    }
    if (!closing && (name === 'style' || name === 'script')) {
      const end = html.toLowerCase().indexOf(`</${name}`, index)
      const after = end >= 0 ? html.indexOf('>', end) : -1
      if (after >= 0) index = after + 1
      continue
    }
    if (name === 'table' && !closing) {
      depth += 1
      if (depth === 1) {
        flushProse()
        tables.push([])
      }
    } else if (name === 'table' && closing) {
      if (depth > 0) {
        depth -= 1
        if (depth === 0) {
          const rows = tables.pop() ?? []
          const width = Math.max(0, ...rows.map((one) => one.length))
          if (width > 0 && rows.length > 0) {
            const filled = rows.map((one) => [...one, ...Array(width - one.length).fill('')])
            out.push(tableMarkdown({ header: filled[0], alignments: [], rows: filled.slice(1) }))
          }
          row = null
          cell = null
        }
      }
    } else if (name === 'tr' && depth === 1) {
      if (!closing) row = []
      else {
        if (row && row.length > 0) tables[tables.length - 1].push(row)
        row = null
      }
    } else if ((name === 'td' || name === 'th') && depth === 1) {
      if (!closing) {
        if (row === null) row = []
        cell = ''
      } else {
        if (cell !== null) row?.push(cell.split(/\p{White_Space}+/u).filter((word) => word !== '').join(' '))
        cell = null
      }
    } else if (/^h[1-6]$/.test(name) && !closing) {
      if (depth === 0) prose += `\n${'#'.repeat(Number(name.slice(1)))} `
    } else if (name === 'br' || (closing && ['p', 'div', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre'].includes(name))) {
      if (cell !== null) cell += ' '
      else if (depth === 0) prose += '\n'
    } else if (name === 'li' && !closing) {
      if (depth === 0) prose += '\n- '
    }
  }
  flushProse()
  const result = out.join('\n\n')
  return result === '' ? null : result
}
