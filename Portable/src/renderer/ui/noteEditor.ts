/**
 * One note in the slip-box, open for writing — the Mac's `ZettelEditorView`.
 *
 * A title, the note itself, and under it what this note is connected to.
 * The connections are the point of a Zettelkasten: a note that links to
 * nothing and is linked from nothing is a note that will never be found
 * again. The note is written as Markdown and read set, as on the Mac: a
 * CodeMirror editor over the Markdown itself, drawn by `note/markdownView.ts`
 * — headings, lists, quotations with their rule, passages as chips, formulas
 * set — with the line under the caret shown as written. Latex Suite is in
 * the field (`note/latexSuiteView.ts`); a passage or a note link is followed
 * with a press, and on the line being edited with Ctrl-click (⌘ on a Mac).
 *
 * Kept across redraws: the inspector is rebuilt whenever anything about the
 * library changes, and rebuilding the editor would take the field out from
 * under the hand typing in it. A host keeps one editor and hands it back for
 * the same note.
 */
import { fromHTML, fromTabSeparated } from '../../shared/noteTable.js'
import { copyText } from './clipboard.js'
import { clear, el, on } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { L } from '../../shared/lang.js'
import { isCommand, platform } from '../bridge.js'
import { anchorAt, parseAnchorURL, quotationInsertion } from '../../shared/noteQuote.js'
import { zettelDisplayTitle, zettelPreviewBody, zettelTags } from '../../shared/zettel.js'
import { noteByID, type Note } from '../state.js'
import { deleteNote, flushNote, linkedFrom, linksOrTagsChanged, linksOut, updateNote } from '../notesModel.js'
import { indentEdit, returnEdit } from '../../shared/noteBlocks.js'
import { keyFor } from '../../shared/shortcuts.js'
import { EditorSelection, EditorState, Prec, Transaction } from '@codemirror/state'
import { EditorView, drawSelection, keymap, placeholder } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, insertTab } from '@codemirror/commands'
import { flash, markdownView, rawField, setRaw } from './note/markdownView.js'
import { latexSuiteView } from './note/latexSuiteView.js'
import { wikiLinkCompletion, type WikiLinkReport } from './wikiLinkPopover.js'
import { mathPreview } from './mathPreview.js'
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
  /** The editor of the note itself. */
  readonly view: EditorView
  /** What the store says now, into the fields — unless a hand is in them. */
  refresh(): void
  /** Writes the note out and lets go of the fields. */
  detach(): void
  /** The caret into the note — at its end, where the next thought goes, unless it is already in it. */
  focus(): void
  /** A block (a quotation) in at the caret, as one step of the note's undo. */
  insert(block: string): void
  /** A passage found by meaning, scrolled to and glowing; true when it was found. */
  reveal(words: string): boolean
  /** The formula card and the `[[` card, for a probe. */
  report(): { math: string; links: WikiLinkReport; raw: boolean }
}

/** The `[[id|label]]` a character of a note sits in, read back into the id, or null. */
export function wikiLinkAt(text: string, index: number): string | null {
  for (const match of text.matchAll(/\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]/g)) {
    const start = match.index ?? 0
    if (index >= start && index <= start + match[0].length) return match[1]
  }
  return null
}

/**
 * Where a passage found by meaning is in the note: the first eight words of
 * it, else five, else three, matched through whatever spaces and marks the
 * Markdown has. The index cuts the note's plain text, so an offset would
 * miss in the Markdown; the words do not.
 */
export function findWords(text: string, snippet: string): { from: number; to: number } | null {
  const words = snippet.replace(/[…]/g, ' ').split(/\s+/).filter((word) => word.length > 0)
  for (const take of [8, 5, 3]) {
    if (words.length < take && take !== 3) continue
    const wanted = words.slice(0, take)
    if (wanted.length === 0) return null
    const pattern = new RegExp(wanted.map((word) => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[\\s*_`>#-]+'), 'i')
    const found = pattern.exec(text)
    if (found) return { from: found.index, to: found.index + found[0].length }
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
  // Icon only, as on the Mac: a word in the quietest corner of a writing
  // surface is one more thing to read before the note.
  const rawToggle = el('button', {
    class: 'icon-button note-raw', 'aria-pressed': 'false',
    title: L('노트를 Markdown 원문으로 보기 — 기호까지 그대로', 'Show the note as Markdown, syntax and all'),
    html: icon('chevron.left.forwardslash.chevron.right'),
  })
  on(rawToggle, 'click', () => {
    const raw = !view.state.field(rawField)
    view.dispatch({ effects: setRaw.of(raw) })
    rawToggle.setAttribute('aria-pressed', String(raw))
  })
  header.append(rawToggle)
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
        danger: true,
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
  const field = el('div', { class: 'note-field' })
  // ---- what this note is connected to
  const connections = el('div', { class: 'note-connections' })
  node.append(header, title, tags, field, connections)

  let loadedTitle = ''
  const current = (): Note | undefined => noteByID(id)

  const save = () => {
    const note = current()
    if (!note) return
    const body = view.state.doc.toString()
    if (note.title === title.value && note.body === body) return
    const moved = linksOrTagsChanged(note, { body })
    // The store now — the links, the tags, a click on a link, ⌘N — and only
    // the disk waits for the pause (`ZettelEditorView.save()`).
    updateNote({ ...note, title: title.value, body })
    loadedTitle = title.value
    if (moved) {
      drawTags()
      drawConnections()
    }
  }

  const drawTags = () => {
    clear(tags)
    for (const tag of zettelTags(view.state.doc.toString())) tags.append(el('span', { class: 'chip note-tag', text: `#${tag}` }))
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
    const section = (heading: string, list: Note[], glyph: IconName) => {
      if (list.length === 0) return
      connections.append(
        el('div', { class: 'note-connections-head', text: heading }),
        el('div', { class: 'chip-row' }, list.map((other) => chip(other, glyph))),
      )
    }
    section(L('내가 가리키는 노트', 'Links to'), linksOut(id), 'arrow.up.right')
    section(L('나를 가리키는 노트', 'Linked from'), linkedFrom(id), 'arrow.down.left')
    connections.style.display = connections.childElementCount > 0 ? '' : 'none'
  }

  /** A passage or a note link followed from the note. */
  const follow = (target: HTMLElement | null, position: number | null): boolean => {
    const anchor = target?.closest<HTMLElement>('[data-anchor]')?.dataset.anchor
    const place = anchor ? parseAnchorURL(anchor) : position !== null ? anchorAt(view.state.doc.toString(), position) : null
    if (place) {
      save()
      actions.openAnchor(place)
      return true
    }
    const noteLink = target?.closest<HTMLElement>('[data-note]')?.dataset.note
      ?? (position !== null ? wikiLinkAt(view.state.doc.toString(), position) : null)
    if (noteLink && noteByID(noteLink)) {
      save()
      void flushNote(id)
      actions.openNote(noteLink)
      return true
    }
    return false
  }

  const links = wikiLinkCompletion(id)
  const math = mathPreview()
  const listKeys = keymap.of([
    {
      key: 'Enter',
      run: (target) => {
        const range = target.state.selection.main
        if (!range.empty || target.state.selection.ranges.length > 1) return false
        const edit = returnEdit(target.state.doc.toString(), range.head)
        if (!edit) return false
        target.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.caret }, userEvent: 'input', scrollIntoView: true })
        return true
      },
    },
    {
      key: 'Tab',
      run: (target) => {
        const edit = indentEdit(target.state.doc.toString(), target.state.selection.main.head, 1)
        if (!edit) return insertTab(target)
        target.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.caret }, userEvent: 'input' })
        return true
      },
      shift: (target) => {
        const edit = indentEdit(target.state.doc.toString(), target.state.selection.main.head, -1)
        if (!edit) return false
        target.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.caret }, userEvent: 'delete' })
        return true
      },
    },
  ])

  const note = current()
  const view = new EditorView({
    parent: field,
    state: EditorState.create({
      doc: note?.body ?? '',
      // A note opens at its end, where the next thought goes.
      selection: EditorSelection.cursor((note?.body ?? '').length),
      extensions: [
        history(),
        drawSelection(),
        EditorView.lineWrapping,
        EditorView.contentAttributes.of({ class: 'note-area', spellcheck: 'false', 'aria-label': L('노트', 'Note') }),
        placeholder(L(
          `생각 하나를, 내 말로.\n\n[[ 로 다른 노트에 잇고, #태그 로 묶어요. ${keyFor('linkToNote', platform)}은 고른 구절로 가는 링크를 놓아요.`,
          `One thought, in your own words.\n\n[[ links to another note. #tag files it. ${keyFor('linkToNote', platform)} drops a link to the passage you selected.`,
        )),
        markdownView(),
        links.extension,
        math.extension,
        latexSuiteView(),
        Prec.default(listKeys),
        keymap.of([...historyKeymap, ...defaultKeymap]),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) save()
        }),
        EditorView.domEventHandlers({
          // The window's own keys — a letter picks a drawing tool — must not
          // see what is typed here.
          keydown: (event) => {
            event.stopPropagation()
            return false
          },
          // A passage or a note link, set, is followed with a press, as the
          // Mac's chip is; on the line being edited it is text, and Ctrl-click
          // (⌘ on a Mac) follows it there.
          mousedown: (event, target) => {
            const element = event.target as HTMLElement | null
            const onPiece = element?.closest('[data-anchor], [data-note]')
            if (!onPiece && !isCommand(event)) return false
            const position = target.posAtCoords({ x: event.clientX, y: event.clientY })
            if (follow(element, onPiece ? null : position)) {
              event.preventDefault()
              return true
            }
            return false
          },
          blur: () => {
            save()
            return false
          },
          // A table from ChatGPT or Obsidian arrives as HTML — pasted as it
          // was, a line a cell — or as tab-separated rows; either becomes the
          // Markdown table it is, on lines of its own (`shared/noteTable.ts`).
          paste: (event, target) => {
            const data = event.clipboardData
            const table = fromHTML(data?.getData('text/html') ?? '') ?? fromTabSeparated(data?.getData('text/plain') ?? '')
            if (!table) return false
            event.preventDefault()
            const { from, to } = target.state.selection.main
            const text = target.state.doc.toString()
            const before = from > 0 ? text[from - 1] : '\n'
            const beforeThat = from > 1 ? text[from - 2] : '\n'
            const atEnd = to >= text.length
            const after = atEnd ? '\n' : text[to]
            const lead = from === 0 ? '' : before !== '\n' ? '\n\n' : beforeThat !== '\n' ? '\n' : ''
            const tail = atEnd ? '\n' : after !== '\n' ? '\n\n' : '\n'
            const insert = lead + table + tail
            target.dispatch({ changes: { from, to, insert }, selection: { anchor: from + insert.length }, scrollIntoView: true, userEvent: 'input.paste' })
            return true
          },
        }),
      ],
    }),
  })

  on(title, 'input', save)
  on(title, 'blur', save)
  on(title, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter') {
      event.preventDefault()
      view.focus()
      view.dispatch({ selection: { anchor: 0 } })
    }
  })

  function refresh() {
    const note = current()
    if (!note) return
    const typing = (view.root.activeElement === view.contentDOM) || document.activeElement === title
    if (!typing) {
      if (note.title !== loadedTitle) title.value = loadedTitle = note.title
      if (note.body !== view.state.doc.toString()) {
        view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert: note.body },
          selection: { anchor: note.body.length },
          // Another window's words are not a step of this one's undo.
          annotations: Transaction.addToHistory.of(false),
        })
      }
    }
    drawTags()
    drawConnections()
  }

  function detach() {
    save()
    void flushNote(id)
    view.destroy()
  }

  function focus() {
    if ((view.root.activeElement === view.contentDOM)) return
    view.focus()
    const end = view.state.doc.length
    view.dispatch({ selection: { anchor: end }, scrollIntoView: true })
  }

  function insert(block: string) {
    view.focus()
    const caret = view.state.selection.main.head
    const { insert: text, caret: after } = quotationInsertion(view.state.doc.toString(), caret, block)
    view.dispatch({ changes: { from: caret, insert: text }, selection: { anchor: after ?? caret + text.length }, scrollIntoView: true, userEvent: 'input.paste' })
  }

  function reveal(words: string): boolean {
    const found = findWords(view.state.doc.toString(), words)
    if (!found) return false
    view.focus()
    view.dispatch({ selection: { anchor: found.from, head: found.to }, effects: [flash.of(found), EditorView.scrollIntoView(found.from, { y: 'center' })] })
    setTimeout(() => {
      if (!view.dom.isConnected) return
      view.dispatch({ effects: flash.of(null) })
    }, 1600)
    return true
  }

  title.value = loadedTitle = note?.title ?? ''
  drawTags()
  drawConnections()

  return {
    id, node, view, refresh, detach, focus, insert, reveal,
    report: () => ({ math: math.report(), links: links.report(), raw: view.state.field(rawField) }),
  }
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
