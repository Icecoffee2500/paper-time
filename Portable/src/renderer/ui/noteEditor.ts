/**
 * One note in the slip-box, open for writing — the Mac's `ZettelEditorView`.
 *
 * A title, the note itself, and under it what this note is connected to.
 * The connections are the point of a Zettelkasten: a note that links to
 * nothing and is linked from nothing is a note that will never be found
 * again. The note is written as Markdown and shown as Markdown — the Mac
 * sets it as it is typed; here the formula card under the caret is the one
 * thing set — with Latex Suite in the field, and a page link or a `[[link]]`
 * followed with Ctrl-click (⌘-click on a Mac), since a textarea cannot hold
 * a link and a plain click puts the caret there, as in any editor.
 *
 * Kept across redraws: the inspector is rebuilt whenever anything about the
 * library changes, and rebuilding the editor would take the field out from
 * under the hand typing in it. A host keeps one editor and hands it back for
 * the same note.
 */
import { copyText } from './clipboard.js'
import { clear, el, on } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { L } from '../../shared/lang.js'
import { isCommand, platform } from '../bridge.js'
import { anchorAt } from '../../shared/noteQuote.js'
import { zettelDisplayTitle, zettelPreviewBody, zettelTags } from '../../shared/zettel.js'
import { noteByID, type Note } from '../state.js'
import { deleteNote, flushNote, linkedFrom, linksOut, updateNote } from '../notesModel.js'
import { attachLatexSuite, type LatexSuiteField } from './latexSuiteInput.js'
import { attachMathPreview, type MathPreview } from './mathPreview.js'
import { showMenu } from './toolbar.js'

export interface NoteEditorActions {
  /** A quotation's page link followed: that paper, at that passage. */
  openAnchor: (place: { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; paperID?: string }) => void
  /** A `[[link]]` or a connection followed: that note, wherever it is shown. */
  openNote: (id: string) => void
  /** The way back to the list, when there is one behind this. */
  close?: () => void
}

export interface NoteEditor {
  readonly id: string
  readonly node: HTMLElement
  readonly area: HTMLTextAreaElement
  /** What the store says now, into the fields — unless a hand is in them. */
  refresh(): void
  /** Writes the note out and lets go of the fields. */
  detach(): void
}

/** Ctrl on Windows and Linux, ⌘ on a Mac: the key that follows a link. */
const COMMAND = platform === 'darwin' ? '⌘' : 'Ctrl'

/** The `[[id|label]]` a character of a note sits in, read back into the id, or null. */
export function wikiLinkAt(text: string, index: number): string | null {
  for (const match of text.matchAll(/\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]/g)) {
    const start = match.index ?? 0
    if (index >= start && index <= start + match[0].length) return match[1]
  }
  return null
}

export function buildNoteEditor(id: string, actions: NoteEditorActions): NoteEditor {
  const node = el('div', { class: 'note-editor' })

  // ---- the header: the way back, and the menu
  const header = el('div', { class: 'note-editor-head' })
  if (actions.close) {
    const back = el('button', { class: 'plain-button note-back', html: icon('chevron.left') })
    back.append(el('span', { text: L('노트', 'Notes') }))
    on(back, 'click', () => actions.close?.())
    header.append(back)
  }
  header.append(el('span', { class: 'toolbar-spacer' }))
  const more = el('button', { class: 'icon-button', title: L('더 보기', 'More'), html: icon('ellipsis.circle') })
  on(more, 'click', () => {
    showMenu(more, [
      // The identifier is worth keeping and not worth staring at: it is what
      // another note links to, so it lives where you go when you want it.
      { label: L(`식별자 복사 — ${id}`, `Copy Identifier — ${id}`), icon: 'number', action: () => void copyText(id) },
      { separator: true },
      {
        label: L('노트 지우기', 'Delete Note'),
        icon: 'trash',
        action: () => {
          deleteNote(id)
          actions.close?.()
        },
      },
    ], 'right')
  })
  header.append(more)

  // ---- the one thing on this surface that should be read first
  const title = el('input', { type: 'text', class: 'note-title', placeholder: L('제목', 'Title'), spellcheck: 'false' }) as HTMLInputElement
  const tags = el('div', { class: 'note-tags' })

  // ---- the note itself
  const area = el('textarea', {
    class: 'note-area',
    spellcheck: 'false',
    placeholder: L(
      `생각 하나를, 내 말로.\n\n[[ 로 다른 노트에 잇고, #태그 로 묶어요. ${COMMAND}+L은 고른 구절로 가는 링크를 놓아요.`,
      `One thought, in your own words.\n\n[[ links to another note. #tag files it. ${COMMAND}+L drops a link to the passage you selected.`,
    ),
  }) as HTMLTextAreaElement
  const field = el('div', { class: 'note-field' }, [area])
  const hint = el('p', { class: 'set-note note-hint' })

  // ---- what this note is connected to
  const connections = el('div', { class: 'note-connections' })

  node.append(header, title, tags, field, hint, connections)

  let loadedTitle = ''
  let loadedBody = ''
  let latex: LatexSuiteField | null = null
  let preview: MathPreview | null = null

  const current = (): Note | undefined => noteByID(id)

  const save = () => {
    const note = current()
    if (!note) return
    if (note.title === title.value && note.body === area.value) return
    updateNote({ ...note, title: title.value, body: area.value })
    loadedTitle = title.value
    loadedBody = area.value
    drawTags(note.body !== area.value)
  }

  const drawTags = (bodyChanged: boolean) => {
    if (!bodyChanged && tags.childElementCount > 0) return
    clear(tags)
    for (const tag of zettelTags(area.value)) tags.append(el('span', { class: 'chip note-tag', text: `#${tag}` }))
    tags.style.display = tags.childElementCount > 0 ? '' : 'none'
  }

  const chip = (other: Note, glyph: IconName) => {
    const button = el('button', { class: 'plain-button note-chip', html: icon(glyph) })
    button.append(el('span', { text: zettelDisplayTitle(other) }))
    on(button, 'click', () => {
      void flushNote(id)
      actions.openNote(other.id)
    })
    return button
  }

  const drawConnections = () => {
    clear(connections)
    const outbound = linksOut(id)
    const inbound = linkedFrom(id)
    const section = (heading: string, list: Note[], glyph: string) => {
      if (list.length === 0) return
      connections.append(
        el('div', { class: 'note-connections-head', text: heading }),
        el('div', { class: 'chip-row' }, list.map((other) => chip(other, glyph))),
      )
    }
    section(L('내가 가리키는 노트', 'Links to'), outbound, 'arrow.up.right')
    section(L('나를 가리키는 노트', 'Linked from'), inbound, 'arrow.down.left')
    connections.style.display = connections.childElementCount > 0 ? '' : 'none'
  }

  const drawHint = () => {
    const hasAnchor = /\]\(papertime:\/\/anchor/.test(area.value)
    const hasLink = area.value.includes('[[')
    hint.textContent = hasAnchor || hasLink
      ? L(`인용 끝의 쪽 링크나 [[링크]]를 ${COMMAND}-클릭하면 그 자리로 가요.`, `${COMMAND}-click a page link or a [[link]] to go there.`)
      : ''
    hint.style.display = hint.textContent ? '' : 'none'
  }

  /** Typing: the note follows a moment after; the store, the tags and the hint now. */
  let timer: ReturnType<typeof setTimeout> | null = null
  const typed = () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(save, 200)
  }
  on(area, 'input', typed)
  on(title, 'input', typed)
  on(area, 'blur', save)
  on(title, 'blur', save)
  // The window's own keys — a letter picks a drawing tool — must not see
  // what is typed here.
  on(area, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
  on(title, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter') {
      event.preventDefault()
      area.focus()
      area.setSelectionRange(0, 0)
    }
  })
  on(area, 'click', (event: MouseEvent) => {
    if (!isCommand(event)) return
    const at = area.selectionStart
    const place = anchorAt(area.value, at)
    if (place) {
      event.preventDefault()
      save()
      actions.openAnchor(place)
      return
    }
    const link = wikiLinkAt(area.value, at)
    if (link && noteByID(link)) {
      event.preventDefault()
      save()
      void flushNote(id)
      actions.openNote(link)
    }
  })

  function refresh() {
    const note = current()
    if (!note) return
    const typing = document.activeElement === area || document.activeElement === title
    if (!typing) {
      if (note.title !== loadedTitle) title.value = loadedTitle = note.title
      if (note.body !== loadedBody) {
        area.value = loadedBody = note.body
        // A note opens at its end, where the next thought goes.
        area.setSelectionRange(area.value.length, area.value.length)
      }
    }
    drawTags(true)
    drawHint()
    drawConnections()
  }

  function detach() {
    if (timer) clearTimeout(timer)
    save()
    void flushNote(id)
    latex?.detach()
    preview?.detach()
  }

  const note = current()
  if (note) {
    title.value = loadedTitle = note.title
    area.value = loadedBody = note.body
    area.setSelectionRange(area.value.length, area.value.length)
  }
  drawTags(true)
  drawHint()
  drawConnections()
  // Math in the note is typed with Latex Suite: `@a`, `//`, Tab out of the
  // equation — and shown set, under the line, while the caret is inside it.
  latex = attachLatexSuite(area)
  preview = attachMathPreview(area)
  ;(window as unknown as { __mathPreview?: () => string }).__mathPreview = () => preview?.report() ?? ''

  return { id, node, area, refresh, detach }
}

/**
 * Keeps one editor for whichever note a surface has open, so a redraw of
 * the surface hands the same fields back rather than new empty ones.
 */
export function editorHost() {
  let kept: NoteEditor | null = null
  return {
    /** The editor for this note, made if it is another note's or none. */
    show(id: string, actions: NoteEditorActions): NoteEditor {
      if (kept && kept.id === id) {
        kept.refresh()
        return kept
      }
      kept?.detach()
      kept = buildNoteEditor(id, actions)
      return kept
    },
    /** Lets go of the editor: the note is written out. */
    drop() {
      kept?.detach()
      kept = null
    },
    current(): NoteEditor | null {
      return kept
    },
  }
}

/** One note as it appears in a list of them — the Mac's `NoteRow`. */
export function noteRow(note: Note, options: { source?: string; selected?: boolean } = {}): HTMLElement {
  const row = el('div', { class: 'note-row', role: 'option', 'aria-selected': String(Boolean(options.selected)), 'data-note': note.id })
  const head = el('div', { class: 'note-row-head' }, [
    el('span', { class: 'note-row-title', text: zettelDisplayTitle(note) }),
    // When it was written, at the right edge where a date goes.
    el('span', { class: 'note-row-date', text: note.created.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) }),
  ])
  row.append(head)
  // What is left after the title, not the whole preview: a note with no
  // title of its own takes its first words as one, and showing the preview
  // under it would print the same sentence twice.
  const preview = zettelPreviewBody(note)
  if (preview) row.append(el('div', { class: 'note-row-preview', text: preview }))
  const tags = zettelTags(note.body).slice(0, 3)
  if (options.source || tags.length > 0) {
    const line = el('div', { class: 'note-row-tags' })
    if (options.source) line.append(el('span', { class: 'note-row-source', text: options.source }))
    for (const tag of tags) line.append(el('span', { class: 'note-row-tag', text: `#${tag}` }))
    row.append(line)
  }
  return row
}

/**
 * Finds a passage in a note and shows it — a passage search by meaning found
 * in a note (`NoteEditor`'s `reveal`): the first eight words of it, else
 * five, else three, matched through whatever spaces the note has; selected,
 * scrolled to, and made to glow for a moment. The index cuts the note's
 * plain text, so an offset would miss in the Markdown; the words do not.
 * True when it was found.
 */
export function revealWords(area: HTMLTextAreaElement, snippet: string): boolean {
  const words = snippet.replace(/[…]/g, ' ').split(/\s+/).filter((word) => word.length > 0)
  for (const take of [8, 5, 3]) {
    if (words.length < take && take !== 3) continue
    const wanted = words.slice(0, take)
    if (wanted.length === 0) return false
    const pattern = new RegExp(wanted.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[\\s*_`>#-]+'), 'i')
    const found = pattern.exec(area.value)
    if (!found) continue
    area.focus({ preventScroll: true })
    area.setSelectionRange(found.index, found.index + found[0].length)
    // The line it is on, into view: a textarea scrolls to its caret only
    // when it is typed into.
    const before = area.value.slice(0, found.index).split('\n').length - 1
    const lineHeight = parseFloat(getComputedStyle(area).lineHeight) || 20
    area.scrollTop = Math.max(0, before * lineHeight - area.clientHeight / 3)
    area.classList.remove('revealed')
    void area.offsetWidth
    area.classList.add('revealed')
    return true
  }
  return false
}
