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
import { call, isCommand, platform } from '../bridge.js'
import { anchorAt, parseAnchorURL, quotationInsertion } from '../../shared/noteQuote.js'
import { quotedPassages } from '../../shared/quotedPassages.js'
import { zettelDisplayTitle, zettelPreviewBody, zettelTags } from '../../shared/zettel.js'
import { noteByID, type Note } from '../state.js'
import { deleteNote, flushNote, linkedFrom, linksOrTagsChanged, linksOut, updateNote } from '../notesModel.js'
import { backspaceEdit, codeIndentEdit, codeReturnEdit, deleteForwardEdit, homeTarget, indentEdit, pairBackspaceEdit, pairEdit, returnEdit, shortcutEdit, toggleEmphasisEdit, wrapEdit, type EmphasisMark, type LineEdit } from '../../shared/noteBlocks.js'
import { codeRowAt } from '../../shared/noteCode.js'
import { keyFor } from '../../shared/shortcuts.js'
import { EditorSelection, EditorState, Prec, Transaction, type Extension } from '@codemirror/state'
import { EditorView, ViewPlugin, drawSelection, keymap, placeholder, type ViewUpdate } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, insertTab, isolateHistory } from '@codemirror/commands'
import { flash, foldedField, foldedRanges, markdownView, rawField, setRaw, toggleKey } from './note/markdownView.js'
import { latexSuiteView } from './note/latexSuiteView.js'
import { noteHTML } from './note/noteHTML.js'
import { typesetter } from '../sketchMath.js'
import { wikiLinkCompletion, type WikiLinkReport } from './wikiLinkPopover.js'
import { mathPreview } from './mathPreview.js'
import { showMenu, toast } from './toolbar.js'

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
  /** Scrolls to the quotation whose page link is this address and makes it glow; the caret stays where it was. */
  revealQuotation(url: string): boolean
  /** The formula card, the `[[` card, the selection bar and the folds, for a probe. */
  report(): { math: string; links: WikiLinkReport; raw: boolean; toolbar: ToolbarReport; folded: number[] }
}

export interface ToolbarReport { showing: boolean; buttons: string[] }

/** The marks the keys and the selection bar put on, in the bar's order. */
const EMPHASIS_BUTTONS: { mark: EmphasisMark; label: string; title: string }[] = [
  { mark: '**', label: 'B', title: L('굵게', 'Bold') },
  { mark: '*', label: 'I', title: L('기울임', 'Italic') },
  { mark: '`', label: '<>', title: L('코드', 'Code') },
  { mark: '$', label: '$', title: L('수식', 'Math') },
]

/** The editor has the caret — not whether the window is in front. */
function holdsCaret(view: EditorView): boolean {
  return view.root.activeElement === view.contentDOM
}

const TOOLBAR_DELAY_MS = 250

/**
 * B, I, <>, $ in a small bar over the selection — Notion's. It comes after
 * the pointer is let go, or a beat after a selection made with the keys,
 * and goes when the selection collapses, the note loses the caret, the page
 * scrolls, or the note is shown as Markdown. A press on it keeps the
 * selection: the bar does the same as the key would.
 */
function selectionToolbar(apply: (view: EditorView, mark: EmphasisMark) => void): { extension: Extension; report: () => ToolbarReport } {
  let bar: HTMLElement | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  let pointerDown = false
  let current: EditorView | null = null

  const hide = () => {
    if (timer) clearTimeout(timer)
    timer = null
    bar?.remove()
    bar = null
  }

  const show = (view: EditorView) => {
    timer = null
    const range = view.state.selection.main
    if (range.empty || !holdsCaret(view) || view.state.field(rawField) || pointerDown) return hide()
    // Code is not made bold: no bar over a selection in a block of code.
    if (codeRowAt(view.state.doc.toString(), range.from)) return hide()
    if (!bar) {
      bar = el('div', { class: 'selection-toolbar', role: 'toolbar' })
      // A press on the bar would take the focus and the selection with it.
      on(bar, 'mousedown', (event: MouseEvent) => event.preventDefault())
      for (const button of EMPHASIS_BUTTONS) {
        const node = el('button', { class: 'selection-toolbar-button', type: 'button', title: button.title, text: button.label, 'data-mark': button.mark })
        on(node, 'click', () => { if (current) apply(current, button.mark) })
        bar.append(node)
      }
      document.body.append(bar)
    }
    // Over the middle of the selection's first line, a little above it.
    const start = view.coordsAtPos(range.from)
    if (!start) return hide()
    const lineEnd = Math.min(range.to, view.state.doc.lineAt(range.from).to)
    const end = view.coordsAtPos(lineEnd, -1)
    const sameLine = end && Math.abs(end.top - start.top) < 2
    const box = view.dom.getBoundingClientRect()
    const right = sameLine ? end.right : box.right
    const width = bar.offsetWidth
    const height = bar.offsetHeight
    let left = (start.left + right) / 2 - width / 2
    left = Math.max(8, Math.min(left, window.innerWidth - width - 8))
    let top = start.top - height - 6
    if (top < 8) top = start.bottom + 6
    Object.assign(bar.style, { left: `${left}px`, top: `${top}px` })
  }

  const schedule = (view: EditorView, after: number) => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => show(view), after)
  }

  const plugin = ViewPlugin.fromClass(class {
    constructor(view: EditorView) { current = view }
    update(update: ViewUpdate) {
      if (!update.selectionSet && !update.docChanged && !update.focusChanged) return
      const view = update.view
      const range = view.state.selection.main
      // Gone the moment the words under it change or the selection does; back
      // after a beat when something is still selected.
      hide()
      if (range.empty || !holdsCaret(view)) return
      if (!pointerDown) schedule(view, TOOLBAR_DELAY_MS)
    }
    destroy() {
      hide()
      current = null
    }
  })

  const released = () => {
    if (!pointerDown) return
    pointerDown = false
    if (current) schedule(current, 0)
  }
  const pressed = () => {
    pointerDown = true
    hide()
  }
  const scrolled = () => hide()
  const listening = ViewPlugin.fromClass(class {
    constructor() {
      window.addEventListener('mouseup', released)
      window.addEventListener('scroll', scrolled, true)
    }
    destroy() {
      window.removeEventListener('mouseup', released)
      window.removeEventListener('scroll', scrolled, true)
    }
  })

  return {
    extension: [
      plugin, listening,
      EditorView.domEventHandlers({
        mousedown: () => { pressed() },
        blur: () => { hide() },
      }),
      EditorView.updateListener.of((update) => {
        if (update.transactions.some((tr) => tr.effects.some((effect) => effect.is(setRaw)))) hide()
      }),
    ],
    report: () => ({ showing: bar !== null, buttons: bar ? [...bar.querySelectorAll('button')].map((button) => button.textContent ?? '') : [] }),
  }
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

/** The note as one HTML document, set as the editor sets it — what «Export as PDF…» prints. */
export function exportNoteHTML(note: Pick<Note, 'title' | 'body'>): string {
  return noteHTML(zettelDisplayTitle(note), note.body, { set: typesetter().set, lang: document.documentElement.lang || 'en' })
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
      {
        label: L('PDF로 내보내기…', 'Export as PDF…'),
        icon: 'doc.text',
        action: () => {
          save()
          const note = current()
          if (!note) return
          void call('notes:exportPDF', { title: zettelDisplayTitle(note), html: exportNoteHTML(note) }).then((result) => {
            if ('path' in result) toast(L('PDF로 내보냈어요.', 'Exported as PDF.'))
            else if ('error' in result) toast(result.error)
          })
        },
      },
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
  /** Tab and Shift-Tab in a block of code: four spaces, or the selected lines in or out (`codeIndentEdit`). */
  const indentCode = (target: EditorView, by: 1 | -1): boolean => {
    if (target.state.selection.ranges.length > 1) return false
    const range = target.state.selection.main
    const edit = codeIndentEdit(target.state.doc.toString(), range.from, range.to, by)
    if (!edit) return false
    target.dispatch({
      changes: { from: edit.from, to: edit.to, insert: edit.insert },
      selection: EditorSelection.range(edit.selectFrom, edit.selectTo),
      userEvent: by > 0 ? 'input' : 'delete', scrollIntoView: true,
    })
    return true
  }
  /**
   * A list's edit, as one step of the history of its own: never joined to the
   * typing before it or after it. Joined, a Return or a Backspace at a
   * marker went with the words around it, and ⌘Z took both — as it did on the
   * Mac, where a whole list of bullets was one ⌘Z.
   */
  const applyListEdit = (target: EditorView, edit: LineEdit) => {
    if (edit.from === edit.to && edit.insert === '') {
      // At the left already: the key is taken, and nothing moves.
      return
    }
    target.dispatch({
      changes: { from: edit.from, to: edit.to, insert: edit.insert },
      selection: EditorSelection.range(edit.caret, edit.caret + (edit.length ?? 0)),
      annotations: isolateHistory.of('full'),
      userEvent: 'input.list', scrollIntoView: true,
    })
  }
  /** Whether the caret's line is a toggle with its children folded away. */
  const onFoldedToggle = (target: EditorView, head: number): boolean => {
    const line = target.state.doc.lineAt(head)
    return target.state.field(foldedField, false)?.has(toggleKey(line.text)) ?? false
  }
  const listKeys = keymap.of([
    {
      key: 'Enter',
      run: (target) => {
        const range = target.state.selection.main
        if (!range.empty || target.state.selection.ranges.length > 1) return false
        // In a block of code, a code editor's Return: the indent kept, the
        // fence just typed closed under the caret (`codeReturnEdit`).
        const source = target.state.doc.toString()
        const code = codeReturnEdit(source, range.head)
        if (code) {
          target.dispatch({ changes: { from: code.from, to: code.to, insert: code.insert }, selection: { anchor: code.caret }, userEvent: 'input', scrollIntoView: true })
          return true
        }
        const edit = returnEdit(source, range.head, onFoldedToggle(target, range.head))
        if (!edit) return false
        applyListEdit(target, edit)
        return true
      },
    },
    {
      // At a marker's edge: a nested item steps out, one at the left is
      // plain words again (Notion). Anywhere else the ordinary Backspace.
      key: 'Backspace',
      run: (target) => {
        const range = target.state.selection.main
        if (!range.empty || target.state.selection.ranges.length > 1) return false
        const edit = backspaceEdit(target.state.doc.toString(), range.head)
        if (!edit) return false
        applyListEdit(target, edit)
        return true
      },
    },
    {
      // At the end of a line before a marked one: the next line's words come
      // up without their marker. Anywhere else the ordinary Delete.
      key: 'Delete',
      run: (target) => {
        const range = target.state.selection.main
        if (!range.empty || target.state.selection.ranges.length > 1) return false
        const edit = deleteForwardEdit(target.state.doc.toString(), range.head)
        if (!edit) return false
        applyListEdit(target, edit)
        return true
      },
    },
    {
      // The item — or every item selected — a level in or out.
      key: 'Tab',
      run: (target) => {
        if (indentCode(target, 1)) return true
        if (target.state.selection.ranges.length > 1) return insertTab(target)
        const { anchor, head } = target.state.selection.main
        const edit = indentEdit(target.state.doc.toString(), anchor, head, 1)
        if (!edit) return insertTab(target)
        applyListEdit(target, edit)
        return true
      },
      shift: (target) => {
        if (indentCode(target, -1)) return true
        if (target.state.selection.ranges.length > 1) return false
        const { anchor, head } = target.state.selection.main
        const edit = indentEdit(target.state.doc.toString(), anchor, head, -1)
        if (!edit) return false
        applyListEdit(target, edit)
        return true
      },
    },
  ])

  // ⌘B, ⌘I, ⌘E, ⌘⇧M: emphasis put on or taken off, as Notion's. Ahead of
  // every other key so neither the editor's defaults nor the window's take
  // them. (⌘M on its own is the window's Minimize.)
  const applyEmphasis = (target: EditorView, mark: EmphasisMark) => {
    const { from, to } = target.state.selection.main
    // Code is not made bold: the keys do nothing in a block of code.
    if (codeRowAt(target.state.doc.toString(), from)) return
    const edit = toggleEmphasisEdit(target.state.doc.toString(), from, to, mark)
    target.dispatch({
      changes: { from: edit.from, to: edit.to, insert: edit.insert },
      selection: EditorSelection.range(edit.selectFrom, edit.selectTo),
      userEvent: 'input', scrollIntoView: true,
    })
  }
  const emphasis = (mark: EmphasisMark) => (target: EditorView) => {
    applyEmphasis(target, mark)
    return true
  }
  const emphasisKeys = Prec.high(keymap.of([
    { key: 'Mod-b', run: emphasis('**') },
    { key: 'Mod-i', run: emphasis('*') },
    { key: 'Mod-e', run: emphasis('`') },
    { key: 'Mod-Shift-m', run: emphasis('$') },
  ]))
  const toolbar = selectionToolbar(applyEmphasis)
  // Home (⌘←) on a marked line: to the words first, then to the very start
  // (`homeTarget`); the shifted keys extend the selection there. On any
  // other line the editor's own keys.
  const home = (extend: boolean) => (target: EditorView) => {
    const range = target.state.selection.main
    const line = target.state.doc.lineAt(range.head)
    if (codeRowAt(target.state.doc.toString(), range.head)) return false
    const offset = homeTarget(line.text, range.head - line.from, extend)
    if (offset === null) return false
    const head = line.from + offset
    target.dispatch({ selection: extend ? EditorSelection.range(range.anchor, head) : EditorSelection.cursor(head), scrollIntoView: true })
    return true
  }
  const homeKeys = Prec.high(keymap.of([
    { key: 'Home', run: home(false), shift: home(true) },
    { key: 'Cmd-ArrowLeft', run: home(false), shift: home(true) },
  ]))
  // Brackets and quotes bring their closers (`pairEdit`), after Latex Suite
  // and the wrapping above have had the character: only a character typed
  // into an empty, single selection, never while an input method composes.
  const autoPairs = Prec.low(EditorView.inputHandler.of((target, _from, _to, text) => {
    if (target.composing || target.state.selection.ranges.length > 1) return false
    const range = target.state.selection.main
    if (!range.empty) return false
    const edit = pairEdit(target.state.doc.toString(), range.head, text)
    if (!edit) return false
    target.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.caret }, userEvent: 'input.type', scrollIntoView: true })
    return true
  }))
  // Backspace between an empty pair takes both — after Latex Suite's own
  // Backspace, which deletes a `$$` pair of its own making.
  const pairBackspace = Prec.high(keymap.of([{
    key: 'Backspace',
    run: (target) => {
      const range = target.state.selection.main
      if (!range.empty || target.state.selection.ranges.length > 1) return false
      const edit = pairBackspaceEdit(target.state.doc.toString(), range.head)
      if (!edit) return false
      target.dispatch({ changes: { from: edit.from, to: edit.to, insert: edit.insert }, selection: { anchor: edit.caret }, userEvent: 'delete', scrollIntoView: true })
      return true
    },
  }]))
  // An opening character typed over a selection wraps it (Obsidian), «[]»
  // with a space becomes a checkbox and «--» with a space a toggle (Notion)
  // — before Latex Suite reads the character.
  const wrapping = Prec.high(EditorView.inputHandler.of((target, _from, _to, text) => {
    if (target.composing || target.state.selection.ranges.length > 1) return false
    const range = target.state.selection.main
    const source = target.state.doc.toString()
    if (!range.empty) {
      const edit = wrapEdit(source, range.from, range.to, text)
      if (!edit) return false
      target.dispatch({
        changes: { from: edit.from, to: edit.to, insert: edit.insert },
        selection: EditorSelection.range(edit.selectFrom, edit.selectTo),
        userEvent: 'input.type', scrollIntoView: true,
      })
      return true
    }
    if (text !== ' ') return false
    const edit = shortcutEdit(source, range.head)
    if (!edit) return false
    applyListEdit(target, edit)
    return true
  }))

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
        toolbar.extension,
        emphasisKeys,
        homeKeys,
        wrapping,
        latexSuiteView(),
        pairBackspace,
        autoPairs,
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

  /**
   * The quotation a page link closes — its block quote, or the link's own line
   * for a passage in a sentence (`quotedPassages`) — brought into view and
   * glowing for a moment, as the Mac's `revealQuotation` does it. The caret
   * stays where it was: put on the quotation, its lines would turn back into
   * their Markdown.
   */
  function revealQuotation(url: string): boolean {
    const doc = view.state.doc.toString()
    const passage = quotedPassages(doc).find((one) => one.url === url)
    const at = passage ? -1 : doc.indexOf(url)
    const range = passage ? passage.quote : at >= 0 ? { from: at, to: at + url.length } : null
    if (!range) return false
    view.dispatch({ effects: [flash.of(range), EditorView.scrollIntoView(range.from, { y: 'center' })] })
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
    id, node, view, refresh, detach, focus, insert, reveal, revealQuotation,
    report: () => ({
      math: math.report(), links: links.report(), raw: view.state.field(rawField),
      toolbar: toolbar.report(), folded: foldedRanges(view.state).map((fold) => fold.from),
    }),
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
