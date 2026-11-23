/**
 * The note's format — the Mac's `NoteFormatPanel`, the panel Pages has
 * down its right-hand side: the paragraph's kind first, then the face, the
 * four ways a word is marked, its size, the five colours for the words and
 * the five for the highlighter, how the line is set across the page, and
 * the list it is in. In the inspector's Tools tab while a note has the
 * caret (`noteFormatCenter.ts`), and beside its button for a note that is
 * in the inspector itself.
 *
 * Every control keeps the note's selection: a press on the panel is not a
 * press in the note.
 */
import { el, on, clear } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { L } from '../../shared/lang.js'
import { LISTS, PARAGRAPHS, type ListKind, type Paragraph } from '../../shared/noteFormat.js'
import { ALIGNMENTS, INKS, type NoteAlignment } from '../../shared/noteSpan.js'
import { HIGHLIGHT_NAMES } from '../../shared/noteBlocks.js'
import { cssColor, highlightSwatch } from '../../shared/marks.js'
import { showMenu, type MenuEntry } from './menu.js'
import { familyListeners, fontFamilies } from './sketchInspector.js'
import { formatCenter } from './noteFormatCenter.js'
import type { PanelState } from './noteEditor.js'

const paragraphName = (kind: Paragraph) => ({
  title: L('제목', 'Title'), heading: L('머리말', 'Heading'), subheading: L('작은 머리말', 'Subheading'),
  body: L('본문', 'Body'), quote: L('인용', 'Quote'),
})[kind]

const listName = (kind: ListKind) => ({
  none: L('없음', 'None'), bullet: L('글머리표', 'Bullet'), numbered: L('번호', 'Numbered'),
  task: L('할 일', 'Checklist'), toggle: L('토글', 'Toggle'),
})[kind]

const alignmentName = (kind: NoteAlignment) => ({
  left: L('왼쪽 맞춤', 'Align Left'), center: L('가운데 맞춤', 'Center'), right: L('오른쪽 맞춤', 'Align Right'), justify: L('양쪽 맞춤', 'Justify'),
})[kind]

const alignmentIcon: Record<NoteAlignment, IconName> = {
  left: 'text.alignleft', center: 'text.aligncenter', right: 'text.alignright', justify: 'text.justify',
}

const SIZES = [10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64]

function sizeText(size: number): string {
  return Number.isInteger(size) ? String(size) : size.toFixed(1)
}

/** A control that does not take the caret out of the note. */
function button(attributes: Record<string, string>, children: (Node | string)[] = []): HTMLElement {
  const node = el('button', { type: 'button', ...attributes }, children)
  on(node, 'mousedown', (event: MouseEvent) => event.preventDefault())
  return node
}

export interface FormatPanel {
  readonly node: HTMLElement
  update(): void
}

export function buildFormatPanel(): FormatPanel {
  const node = el('div', { class: 'note-format-panel' })
  on(node, 'mousedown', (event: MouseEvent) => {
    // Anywhere on the panel that is not a field of its own.
    if (!(event.target instanceof HTMLInputElement)) event.preventDefault()
  })
  familyListeners.add(() => { if (node.isConnected) update() })

  function update() {
    const state: PanelState | null = formatCenter.state()
    clear(node)
    const idle = !state || !state.editing || state.code
    node.classList.toggle('idle', idle)
    const shown: PanelState = state ?? {
      style: { color: null, size: null, family: null, bold: false, italic: false, underline: false, strike: false, highlight: null },
      paragraph: 'body', list: 'none', alignment: 'left', size: 16, ownSize: 16, editing: false, code: false,
    }
    const apply = formatCenter.apply
    const menu = (anchor: HTMLElement, entries: MenuEntry[]) => showMenu(anchor, entries, 'left')

    node.append(el('div', { class: 'nf-title', text: L('글', 'Text') }))

    // The paragraph's kind, named in its own weight — the first thing in the panel, as it is in Pages.
    const paragraph = button({ class: `nf-paragraph${shown.paragraph === 'body' || shown.paragraph === 'quote' ? '' : ' heavy'}` }, [
      el('span', { text: paragraphName(shown.paragraph) }), el('span', { class: 'nf-chevron', html: icon('chevron.down') }),
    ])
    on(paragraph, 'click', () => menu(paragraph, PARAGRAPHS.map((kind) => ({
      label: paragraphName(kind), checked: kind === shown.paragraph, action: () => apply({ paragraph: kind }),
    }))))
    node.append(paragraph, el('div', { class: 'nf-rule' }))

    node.append(el('div', { class: 'nf-head', text: L('글꼴', 'Font') }))
    const family = button({ class: 'nf-field' }, [
      el('span', { class: 'nf-field-text', text: shown.style.family ?? L('노트 기본', 'Note Default') }),
      el('span', { class: 'nf-chevron', html: icon('chevron.up.chevron.down') }),
    ])
    on(family, 'click', () => menu(family, [
      { label: L('노트 기본', 'Note Default'), checked: shown.style.family === null, action: () => apply({ style: { family: null } }) },
      { separator: true },
      ...fontFamilies().map((name) => ({ label: name, checked: name === shown.style.family, action: () => apply({ style: { family: name } }) })),
    ]))
    node.append(family)

    const marks = el('div', { class: 'nf-segments' })
    const mark = (text: string, kind: 'bold' | 'italic' | 'underline' | 'strike', title: string) => {
      const cell = button({ class: `nf-segment nf-mark-${kind}`, title, 'aria-pressed': String(shown.style[kind]) }, [text])
      on(cell, 'click', () => apply({ style: { [kind]: !shown.style[kind] } }))
      marks.append(cell)
    }
    mark('B', 'bold', L('굵게', 'Bold'))
    mark('I', 'italic', L('기울임', 'Italic'))
    mark('U', 'underline', L('밑줄', 'Underline'))
    mark('S', 'strike', L('취소선', 'Strikethrough'))

    // The size, with a step either way and the usual sizes under a press.
    const setSize = (size: number) => {
      const bounded = Math.min(Math.max(size, 6), 200)
      apply({ style: { size: bounded === shown.ownSize ? null : bounded } })
    }
    const sizeField = button({ class: 'nf-field nf-size', title: L('글자 크기', 'Size') }, [`${sizeText(shown.size)} pt`])
    on(sizeField, 'click', () => menu(sizeField, SIZES.map((size) => ({ label: `${size} pt`, checked: size === shown.size, action: () => setSize(size) }))))
    const up = button({ class: 'nf-step', title: L('크게', 'Larger'), html: icon('chevron.up') })
    const down = button({ class: 'nf-step', title: L('작게', 'Smaller'), html: icon('chevron.down') })
    on(up, 'click', () => setSize(Math.floor(shown.size + 1)))
    on(down, 'click', () => setSize(Math.ceil(shown.size - 1)))
    node.append(el('div', { class: 'nf-row' }, [marks, el('div', { class: 'nf-size-box' }, [sizeField, el('div', { class: 'nf-steps' }, [up, down])])]))

    // The five colours, as the highlighter's are offered — a letter in the
    // ink for the words, a dot for the band.
    const inks = el('div', { class: 'nf-dots' })
    for (const [name, hex] of INKS) {
      const lit = shown.style.color === hex
      const cell = button({ class: 'nf-ink', 'aria-pressed': String(lit), 'data-ink': name, title: lit ? L('글자 색 지우기', 'Remove Text Color') : L('글자 색', 'Text Color') }, ['A'])
      cell.style.color = `var(--hl-${name}-ink)`
      on(cell, 'click', () => apply({ style: { color: lit ? null : hex } }))
      inks.append(cell)
    }
    node.append(el('div', { class: 'nf-row nf-between' }, [el('span', { text: L('글자 색', 'Text Color') }), inks]))
    const dots = el('div', { class: 'nf-dots' })
    for (const name of HIGHLIGHT_NAMES) {
      const lit = shown.style.highlight === name
      const cell = button({ class: 'nf-dot', 'aria-pressed': String(lit), 'data-highlight': name, title: lit ? L('하이라이트 지우기', 'Remove Highlight') : L('하이라이트', 'Highlight') })
      cell.style.setProperty('--dot-ink', cssColor(highlightSwatch(name as Parameters<typeof highlightSwatch>[0])))
      on(cell, 'click', () => apply({ style: { highlight: lit ? null : name } }))
      dots.append(cell)
    }
    node.append(el('div', { class: 'nf-row nf-between' }, [el('span', { text: L('형광펜', 'Highlight') }), dots]), el('div', { class: 'nf-rule' }))

    // A list's items and a quotation keep their own edge.
    const aligns = el('div', { class: `nf-segments${shown.list !== 'none' || shown.paragraph === 'quote' ? ' off' : ''}` })
    for (const kind of ALIGNMENTS) {
      const cell = button({ class: 'nf-segment', title: alignmentName(kind), 'aria-pressed': String(shown.alignment === kind), html: icon(alignmentIcon[kind]) })
      on(cell, 'click', () => apply({ alignment: kind }))
      aligns.append(cell)
    }
    const indents = el('div', { class: `nf-segments${shown.list === 'none' ? ' off' : ''}` })
    const outdent = button({ class: 'nf-segment', title: L('내어쓰기', 'Outdent'), html: icon('decrease.indent') })
    const indent = button({ class: 'nf-segment', title: L('들여쓰기', 'Indent'), html: icon('increase.indent') })
    on(outdent, 'click', () => apply({ indent: -1 }))
    on(indent, 'click', () => apply({ indent: 1 }))
    indents.append(outdent, indent)
    node.append(aligns, indents, el('div', { class: 'nf-rule' }))

    const list = button({ class: 'nf-field nf-list' }, [
      el('span', { class: 'nf-field-text', text: listName(shown.list) }), el('span', { class: 'nf-chevron', html: icon('chevron.up.chevron.down') }),
    ])
    on(list, 'click', () => menu(list, LISTS.map((kind) => ({ label: listName(kind), checked: kind === shown.list, action: () => apply({ list: kind }) }))))
    node.append(el('div', { class: 'nf-row nf-between' }, [el('span', { class: 'nf-head', text: L('목록', 'Bullets & Lists') }), list]))
  }

  update()
  return { node, update }
}

/** The panel beside its button, for a note that is in the inspector itself: there until a press outside it. */
export function showFormatPopover(anchor: HTMLElement) {
  document.querySelector('.note-format-popover')?.remove()
  const panel = buildFormatPanel()
  const box = el('div', { class: 'note-format-popover' }, [panel.node])
  document.body.append(box)
  const at = anchor.getBoundingClientRect()
  const width = 264
  const left = Math.max(8, Math.min(at.right - width, window.innerWidth - width - 8))
  Object.assign(box.style, { left: `${left}px`, top: `${Math.min(at.bottom + 6, window.innerHeight - 440)}px`, width: `${width}px` })
  const stop = formatCenter.subscribe(() => { if (box.isConnected && !document.querySelector('.menu')) panel.update() })
  const outside = (event: MouseEvent) => {
    const target = event.target as Node | null
    if (target && (box.contains(target) || anchor.contains(target) || (target as Element).closest?.('.menu, .scrim'))) return
    close()
  }
  const key = (event: KeyboardEvent) => { if (event.key === 'Escape') close() }
  function close() {
    stop()
    box.remove()
    window.removeEventListener('mousedown', outside, true)
    window.removeEventListener('keydown', key, true)
  }
  window.addEventListener('mousedown', outside, true)
  window.addEventListener('keydown', key, true)
}
