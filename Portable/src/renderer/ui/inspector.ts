/**
 * What is known about the paper in front of you.
 *
 * Three tabs, the same three as the Mac: the record, the marks made on it,
 * and the note written about it. The record is editable in place — the whole
 * reason the confidence field exists is that a parsed title is a guess, and a
 * guess you cannot correct is worse than no guess.
 */
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { store, type Paper } from '../state.js'
import { fullName, type CSLName } from '../../shared/model.js'

export interface InspectorActions {
  editMeta: (id: string, patch: Record<string, unknown>) => void
  editState: (id: string, patch: Record<string, unknown>) => void
  reveal: (id: string) => void
  copyKey: (id: string) => void
  openAuthor: (name: string) => void
}

export function buildInspector(actions: InspectorActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'panel' })
  const body = el('div', { class: 'panel-body' })
  node.append(body)

  function update() {
    clear(body)
    const paper = store.papers.find((entry) => entry.id === store.selectedID)
    if (!paper) {
      body.append(el('div', { class: 'empty' }, [
        el('h2', { text: 'No paper selected' }),
        el('p', { text: 'Pick one from the list to see its record.' }),
      ]))
      return
    }
    switch (store.settings.inspectorTab) {
      case 'details': details(body, paper, actions); break
      case 'marks': marks(body, paper); break
      case 'note': note(body, paper, actions); break
    }
  }

  update()
  return { node, update }
}

function field(label: string, value: Node | string): HTMLElement {
  return el('div', { class: 'field' }, [
    el('div', { class: 'field-label', text: label }),
    typeof value === 'string' ? el('div', { class: 'field-value', text: value }) : value,
  ])
}

function editable(
  label: string,
  value: string,
  commit: (next: string) => void,
  options: { multiline?: boolean } = {},
): HTMLElement {
  const input = options.multiline
    ? (el('textarea', { rows: '3' }) as HTMLTextAreaElement)
    : (el('input', { type: 'text' }) as HTMLInputElement)
  input.value = value
  let last = value
  const send = () => {
    if (input.value === last) return
    last = input.value
    commit(input.value)
  }
  on(input, 'blur', send)
  on(input, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter' && !options.multiline) {
      event.preventDefault()
      input.blur()
    }
  })
  return el('div', { class: 'field' }, [
    el('div', { class: 'field-label', text: label }),
    input,
  ])
}

const CONFIDENCE_LABEL: Record<string, string> = {
  unparsed: 'Not read yet',
  low: 'Low confidence',
  medium: 'Medium confidence',
  high: 'High confidence',
  verified: 'Verified against a registrar',
  manual: 'Edited by you',
  needsReview: 'Needs review',
}

function details(body: HTMLElement, paper: Paper, actions: InspectorActions) {
  const meta = paper.meta

  body.append(editable('Title', meta.csl.title ?? '', (next) => {
    actions.editMeta(paper.id, { csl: { ...meta.csl, title: next }, confidence: 'manual' })
  }, { multiline: true }))

  const authors = el('div', { class: 'chip-row' })
  for (const name of (meta.csl.author ?? []) as CSLName[]) {
    const chip = el('button', { class: 'chip', text: fullName(name) })
    on(chip, 'click', () => actions.openAuthor(fullName(name)))
    authors.append(chip)
  }
  if (authors.childElementCount > 0) {
    body.append(el('div', { class: 'field' }, [
      el('div', { class: 'field-label', text: 'Authors' }),
      authors,
    ]))
  }

  body.append(editable('Venue', meta.csl['container-title'] ?? '', (next) => {
    actions.editMeta(paper.id, { csl: { ...meta.csl, 'container-title': next }, confidence: 'manual' })
  }))

  body.append(editable('Year', meta.year ? String(meta.year) : '', (next) => {
    const year = Number(next)
    const issued = Number.isInteger(year) && year > 0 ? { 'date-parts': [[year]] } : undefined
    actions.editMeta(paper.id, { csl: { ...meta.csl, issued }, confidence: 'manual' })
  }))

  if (meta.csl.DOI) body.append(field('DOI', meta.csl.DOI))
  body.append(editable('Citation key', meta.bibKey, (next) => {
    actions.editMeta(paper.id, { bibKey: next })
  }))

  const status = el('div', { class: 'choices' })
  for (const [value, label] of [['unread', 'Unread'], ['reading', 'Reading'], ['read', 'Read']] as const) {
    const button = el('button', {
      text: label,
      'aria-pressed': String(paper.state.readingStatus === value),
    })
    on(button, 'click', () => actions.editState(paper.id, { readingStatus: value }))
    status.append(button)
  }
  body.append(el('div', { class: 'field' }, [
    el('div', { class: 'field-label', text: 'Reading' }),
    status,
  ]))

  body.append(field('Confidence', CONFIDENCE_LABEL[meta.confidence] ?? meta.confidence))
  body.append(field('File', meta.file.originalName || meta.file.relativePath))
  body.append(field('Pages', String(meta.file.pageCount)))
  body.append(field('Added', meta.addedAt.toLocaleDateString()))

  const row = el('div', { class: 'field' })
  const reveal = el('button', { class: 'plain-button', text: 'Show in Folder' })
  on(reveal, 'click', () => actions.reveal(paper.id))
  const copy = el('button', { class: 'plain-button', text: 'Copy Citation Key' })
  on(copy, 'click', () => actions.copyKey(paper.id))
  row.append(el('div', { class: 'chip-row' }, [reveal, copy]))
  body.append(row, el('div', { style: 'height: 14px' }))
}

function marks(body: HTMLElement, paper: Paper) {
  body.append(el('div', { class: 'empty' }, [
    el('span', { html: icon('highlighter') }),
    el('h2', { text: 'Marks' }),
    el('p', {
      text: 'Highlights and underlines made on the page will be listed here. '
        + 'Everything drawn with the pen is already written into the PDF itself.',
    }),
  ]))
}

function note(body: HTMLElement, paper: Paper, actions: InspectorActions) {
  const area = el('textarea', {
    rows: '20',
    placeholder: 'A note about this paper…',
  }) as HTMLTextAreaElement
  area.value = paper.state.summaryNote
  area.style.minHeight = '60vh'
  let last = area.value
  const save = () => {
    if (area.value === last) return
    last = area.value
    actions.editState(paper.id, { summaryNote: area.value })
  }
  on(area, 'blur', save)
  on(area, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
  // A note is worth saving without waiting for the focus to leave it.
  let timer: ReturnType<typeof setTimeout> | null = null
  on(area, 'input', () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(save, 900)
  })
  body.append(el('div', { class: 'field' }, [area]))
}
