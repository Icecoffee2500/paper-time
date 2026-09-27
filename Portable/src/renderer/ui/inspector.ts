/**
 * What is known about the paper in front of you.
 *
 * Four tabs, the same four as the Mac: the record, the marks made on it, the
 * note written about it, and — while the pencil is out — the tools. The
 * record is editable in place — the whole reason the confidence field exists
 * is that a parsed title is a guess, and a guess you cannot correct is worse
 * than no guess. The tools tab is `sketchInspector.ts`, docked here rather
 * than floating over the page, and it comes forward when drawing begins.
 */
import { icon, type IconName } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { store, type Paper } from '../state.js'
import { cslFullTitle, cslYear, fullName, type CSLItem, type CSLName } from '../../shared/model.js'
import { L, prefersKorean } from '../../shared/lang.js'
import { buildAuthorEditor } from './authorEditor.js'
import { type DocumentKind } from '../../shared/documentKind.js'
import { buildSketchInspector } from './sketchInspector.js'
import { renderNotesTab } from './notesTab.js'
import { quotationInsertion } from '../../shared/noteQuote.js'
import { cssColor, type Mark } from '../../shared/marks.js'
import type { MenuEntry } from './toolbar.js'

export interface InspectorActions {
  editMeta: (id: string, patch: Record<string, unknown>) => void
  editState: (id: string, patch: Record<string, unknown>) => void
  reveal: (id: string) => void
  /** Renames the file on disk. Answers with what went wrong, or nothing. */
  rename: (id: string, name: string) => Promise<string | null>
  copyKey: (id: string) => void
  openAuthor: (name: CSLName) => void
  /** The answer to "paper or document?", which decides the rest of this form. */
  setKind: (id: string, kind: DocumentKind) => void
  /** The default drawing style changed; the rack and the page should follow. */
  sketchChanged: () => void
  /** Another paper, shown — a supplement's parent, or one of its supplements. */
  open: (id: string) => void
  /** A supplement made a paper of its own again. */
  detach: (id: string) => void
  /** One paper put under another, as supplementary material. */
  attach: (child: string, parent: string) => void
  /** The paper a supplement looks like it belongs to, or null. */
  suggestedParent: (id: string) => string | null
  /** A lookup's candidate taken as the record. */
  acceptCandidate: (id: string, candidate: Candidate) => void
  /** Where the file stands against the one imported. */
  provenance: (id: string) => Promise<string>
  /** What is on the clipboard — «Paste Names». */
  paste: () => Promise<string>
  /** A quotation's page link followed: that paper, at that passage. */
  openAnchor: (place: { pageIndex: number; rect: { x: number; y: number; width: number; height: number }; paperID?: string }) => void
  /** A `[[link]]` in a note followed: that note, wherever it is shown. */
  openNote: (id: string) => void
  /** The marks of the paper in front, in reading order — the Marks tab. */
  /** Every mark in reading order, or null while the paper is still opening. */
  marks: () => { pageIndex: number; mark: Mark }[] | null
  /** The inspector, showing, on its Marks tab. */
  showMarksTab: () => void
  revealMark: (pageIndex: number, id: string) => void
  removeMark: (pageIndex: number, id: string) => void
  commentMark: (pageIndex: number, id: string, comment: string) => void
  copyText: (text: string) => void
  markMenu: (anchor: Element, entries: MenuEntry[]) => void
}

export interface InspectorPanel {
  node: HTMLElement
  update: () => void
  /** The caret in the note, at its end — Command-N. False when no note is showing. */
  focusNote: () => boolean
  /** A block typed into the note at its caret, as a keystroke would be:
   *  undoable, and saved like typing — Command-L's quotation. */
  insertIntoNote: (block: string) => boolean
  /** A mark clicked on the page: its row in the Marks tab comes forward. */
  showMark: (id: string) => void
}

export function buildInspector(actions: InspectorActions): InspectorPanel {
  const node = el('div', { class: 'panel' })
  const body = el('div', { class: 'panel-body' })
  node.append(body)
  // Built once and kept: it redraws itself when the selection on the page
  // changes, and rebuilding it from here would lose a field being typed in.
  const tools = buildSketchInspector({ changed: actions.sketchChanged })
  /** Whose record is on screen, so a redraw knows whether it is the same one. */
  let shownPaperID: string | null = null

  function update() {
    // A memo half typed is written before the form it is in goes.
    if (shownPaperID !== store.selectedID) flushInspector()
    // Nothing chosen is said on every tab, the Tools tab too (`RootView`).
    if (!store.papers.some((entry) => entry.id === store.selectedID)) {
      shownPaperID = store.selectedID
      clear(body)
      body.append(el('div', { class: 'empty' }, [
        el('h2', { text: L('고른 논문이 없어요', 'No Paper Selected') }),
        el('p', { text: L('논문을 고르면 서지를 보고 고칠 수 있어요.', 'Choose a paper to see its details.') }),
      ]))
      return
    }
    if (store.settings.inspectorTab === 'tools') {
      if (tools.node.parentElement !== body) {
        clear(body)
        body.append(tools.node)
      }
      tools.update()
      return
    }
    // Not while somebody is typing in it. The record is rebuilt whenever
    // anything about the library changes — a star pressed on another row is
    // enough — and rebuilding it takes the field out of the window with the
    // half-written title still in it.
    const typing = document.activeElement
    if (typing instanceof HTMLElement && body.contains(typing)
      && (typing.tagName === 'INPUT' || typing.tagName === 'TEXTAREA' || typing.isContentEditable)
      && shownPaperID === store.selectedID) {
      return
    }
    shownPaperID = store.selectedID
    clear(body)
    const paper = store.papers.find((entry) => entry.id === store.selectedID)
    if (!paper) {
      body.append(el('div', { class: 'empty' }, [
        el('h2', { text: L('고른 논문이 없어요', 'No Paper Selected') }),
        el('p', { text: L('논문을 고르면 서지를 보고 고칠 수 있어요.', 'Choose a paper to see its details.') }),
      ]))
      return
    }
    switch (store.settings.inspectorTab) {
      case 'details': details(body, paper, actions, update); break
      case 'marks': marks(body, paper, actions, update); break
      case 'note': renderNotesTab(body, paper, { openAnchor: actions.openAnchor, openNote: actions.openNote }); break
    }
  }

  const noteArea = () => body.querySelector<HTMLTextAreaElement>('.note-area')

  function focusNote(): boolean {
    const area = noteArea()
    if (!area) return false
    area.focus()
    area.setSelectionRange(area.value.length, area.value.length)
    area.scrollTop = area.scrollHeight
    return true
  }

  function insertIntoNote(block: string): boolean {
    const area = noteArea()
    if (!area) return false
    // Where the caret was left — the end, in a note just opened.
    const caret = area.selectionStart ?? area.value.length
    const { insert } = quotationInsertion(area.value, caret, block)
    area.focus()
    area.setSelectionRange(caret, caret)
    // The one way into a textarea that keeps its undo: Command-Z takes the
    // quotation back out, as it would anything typed.
    document.execCommand('insertText', false, insert)
    return true
  }

  /** A mark clicked on the page: the Marks tab comes forward with its row
   *  pulsing — shown whatever the filter was, as `reveal(inList:)` does. */
  function showMark(id: string) {
    if (store.settings.inspectorTab !== 'marks') {
      actions.showMarksTab()
    }
    if (!body.querySelector(`.mark-row[data-mark="${CSS.escape(id)}"]`) && markFilter !== 'all') {
      markFilter = 'all'
      update()
    }
    flashMarkRow(body, id)
  }

  update()
  return { node, update, focusNote, insertIntoNote, showMark }
}

function field(label: string, value: Node | string): HTMLElement {
  return el('div', { class: 'field' }, [
    el('div', { class: 'field-label', text: label }),
    typeof value === 'string' ? el('div', { class: 'field-value', text: value }) : value,
  ])
}

/** One of the form's sections, with its name over it — the Mac's grouped
 *  `Form`, so the reader sees where the record ends and the file begins. */
function section(title: string | null, ...nodes: Node[]): HTMLElement {
  return el('div', { class: 'insp-section' }, [
    ...(title ? [el('div', { class: 'insp-section-title', text: title })] : []),
    ...nodes,
  ])
}

// MARK: - The draft

/**
 * The record being edited, as the Mac's form holds it: a copy of the CSL
 * that the fields write into, saved all at once with «Save» and thrown away
 * with «Revert». Every field used to write the record as it lost focus, and
 * each carried the whole CSL it was built with — so a second field, edited
 * before the form was drawn again, put the first one back.
 */
let draft: { paperID: string; csl: Record<string, unknown> } | null = null
/** The memo as typed, written when it is left or the paper goes. */
let memo: { paperID: string; text: string; save: (text: string) => void } | null = null

function draftFor(paper: Paper): Record<string, unknown> {
  if (!draft || draft.paperID !== paper.id) draft = { paperID: paper.id, csl: structuredClone(paper.meta.csl) as Record<string, unknown> }
  return draft.csl
}

function isDirty(paper: Paper): boolean {
  return Boolean(draft && draft.paperID === paper.id && JSON.stringify(draft.csl) !== JSON.stringify(paper.meta.csl))
}

/** The memo written now — before the paper changes, or the window goes. */
export function flushInspector() {
  const pending = memo
  if (!pending) return
  memo = null
  pending.save(pending.text)
}

/** A text field over the draft: an empty field takes the key off, as the
 *  Mac's `stringBinding` does, rather than writing `""` into the record. */
function draftText(paper: Paper, label: string, key: string, dirtied: () => void, options: { multiline?: boolean; placeholder?: string } = {}): HTMLElement {
  const csl = draftFor(paper)
  const input = options.multiline
    ? (el('textarea', { rows: '2', class: 'grow' }) as HTMLTextAreaElement)
    : (el('input', { type: 'text' }) as HTMLInputElement)
  input.value = typeof csl[key] === 'string' ? csl[key] as string : ''
  if (options.placeholder) input.placeholder = options.placeholder
  on(input, 'input', () => {
    if (input.value) csl[key] = input.value
    else delete csl[key]
    dirtied()
  })
  on(input, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter' && !options.multiline) {
      event.preventDefault()
      input.blur()
    }
  })
  return el('div', { class: 'field' }, [el('div', { class: 'field-label', text: label }), input])
}

/** The year, which lives inside `issued`: digits kept, the rest let go —
 *  «c. 2019» is 2019, not nothing (`yearBinding`). */
function draftYear(paper: Paper, dirtied: () => void): HTMLElement {
  const csl = draftFor(paper)
  const input = el('input', { type: 'text', inputmode: 'numeric' }) as HTMLInputElement
  const issued = csl.issued as { 'date-parts'?: number[][] } | undefined
  input.value = issued?.['date-parts']?.[0]?.[0] ? String(issued['date-parts'][0][0]) : (paper.meta.year ? String(paper.meta.year) : '')
  on(input, 'input', () => {
    const digits = input.value.replace(/\D/g, '')
    if (!digits) delete csl.issued
    else csl.issued = { 'date-parts': [[Number(digits)]] }
    dirtied()
  })
  on(input, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter') input.blur()
  })
  return el('div', { class: 'field' }, [el('div', { class: 'field-label', text: L('해', 'Year') }), input])
}

/** A picker over the draft's `type`. */
function draftType(paper: Paper, label: string, types: string[], dirtied: (redraw?: boolean) => void): HTMLElement {
  const csl = draftFor(paper)
  const select = el('select', { class: 'field-select' }) as HTMLSelectElement
  const current = typeof csl.type === 'string' ? csl.type : 'document'
  for (const type of types.includes(current) ? types : [current, ...types]) {
    const option = el('option', { value: type, text: typeName(type) }) as HTMLOptionElement
    option.selected = type === current
    select.append(option)
  }
  on(select, 'change', () => {
    csl.type = select.value
    dirtied(true)
  })
  return el('div', { class: 'field' }, [el('div', { class: 'field-label', text: label }), select])
}

/** Every CSL type the Mac's picker offers, in its words. */
const PAPER_TYPES = ['article-journal', 'paper-conference', 'book', 'chapter', 'thesis', 'report', 'dataset', 'software', 'webpage', 'patent', 'speech', 'manuscript', 'document']
/** The kinds a document can be: the list minus the half only a paper is. */
const DOCUMENT_TYPES = ['report', 'book', 'chapter', 'manuscript', 'webpage', 'speech', 'dataset', 'software', 'patent', 'document']

function typeName(type: string): string {
  switch (type) {
    case 'article-journal': return L('학술지 논문', 'Journal Article')
    case 'paper-conference': return L('학회 논문', 'Conference Paper')
    case 'book': return L('책', 'Book')
    case 'chapter': return L('책의 장', 'Book Chapter')
    case 'thesis': return L('학위 논문', 'Thesis')
    case 'report': return L('보고서', 'Report')
    case 'dataset': return L('데이터셋', 'Dataset')
    case 'software': return L('소프트웨어', 'Software')
    case 'webpage': return L('웹 페이지', 'Web Page')
    case 'patent': return L('특허', 'Patent')
    case 'speech': return L('발표', 'Speech')
    case 'manuscript': return L('프리프린트 / 원고', 'Preprint / Manuscript')
    default: return L('그 밖', 'Other')
  }
}

/**
 * The name of the file, as a field.
 *
 * Typing here renames it on disk, on Return or on leaving the field — a
 * rename should not happen a letter at a time. Only the file moves: the
 * record is named after the paper's identifier, so marks, ink and notes stay
 * put. A name the disk refuses is said, and the field goes back to the name
 * the file has.
 */
function fileName(paper: Paper, actions: InspectorActions): HTMLElement {
  const shown = () => paper.meta.file.originalName
    || paper.meta.file.relativePath.split(/[\\/]/).pop()
    || paper.meta.file.relativePath
  const input = el('input', { type: 'text' }) as HTMLInputElement
  input.value = shown()
  const trouble = el('div', { class: 'field-error' })
  let last = input.value
  const send = async () => {
    const wanted = input.value.trim()
    if (wanted === last) {
      input.value = last
      return
    }
    last = wanted
    let message: string | null
    try {
      message = await actions.rename(paper.id, wanted)
    } catch {
      message = L('이름을 바꾸지 못했어요.', 'The file kept its name.')
    }
    trouble.textContent = message ?? ''
    if (message) {
      input.value = shown()
      last = input.value
    }
  }
  on(input, 'blur', () => void send())
  on(input, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter') {
      event.preventDefault()
      input.blur()
    }
  })
  return el('div', { class: 'field' }, [
    el('div', { class: 'field-label', text: L('이름', 'Name') }),
    input,
    trouble,
  ])
}

/** The Mac's four words for how sure a record is, as a badge. */
function confidenceBadge(confidence: string): HTMLElement {
  const [label, glyph] = confidence === 'verified' ? [L('확인됨', 'Confirmed'), 'checkmark.circle']
    : confidence === 'needsReview' ? [L('살펴볼 것', 'Needs Review'), 'exclamationmark.triangle.fill']
      : confidence === 'manual' ? [L('직접 고침', 'Edited by You'), 'person']
        : [L('아직 모름', 'Unresolved'), 'circle']
  return el('span', { class: 'insp-badge', 'data-confidence': confidence }, [
    el('span', { html: icon(glyph as IconName) }),
    el('span', { text: label }),
  ])
}

/**
 * One question, asked once, with the app's own guess offered.
 *
 * Everything under it hangs on the answer — which fields the form has,
 * whether the record is looked up online at all — so it is asked plainly
 * rather than inferred and quietly acted on.
 */
function kindQuestion(paper: Paper, actions: InspectorActions): HTMLElement {
  const guess = paper.meta.guessedKind
  const hint = guess === 'paper'
    ? L('논문 같아요 — 안에 DOI나 참고문헌이 보여요. 맞으면 그대로 눌러주세요.',
        'It looks like a paper — there is a DOI or a reference list in it. Press it again to agree.')
    : guess === 'book'
      ? L('책 같아요 — 쪽이 아주 많고 뒤에 참고문헌이 있어요. 책이면 출판사와 판, ISBN을 물어볼게요.',
          'It looks like a book — hundreds of pages, with a reference list at the back. '
          + 'As a book it is asked for a publisher, an edition and an ISBN.')
      : guess === 'lecture'
        ? L('강의자료 같아요 — 쪽이 가로로 넓거나, 이름이 강의를 가리켜요. 강의자료는 인용하지 않아요.',
            'It looks like course material — the pages are landscape, or the name names a course. '
            + 'Course material is read, not cited.')
        : guess === 'document'
          ? L('논문은 아닌 것 같아요. 일반 문서면 학술지 같은 칸은 숨길게요.',
              "It doesn't look like a paper. As a document, the journal fields go away.")
          : L('고르면 이 칸들이 그에 맞게 바뀌어요.', 'The fields below follow your answer.')

  const choices = el('div', { class: 'choices kind-choices' })
  for (const [value, label] of [
    ['paper', L('논문', 'A paper')],
    ['book', L('책', 'A book')],
    ['lecture', L('강의자료', 'Course material')],
    ['document', L('일반 문서', 'A document')],
  ] as const) {
    // The chosen one is marked, and the other one is the way back: an answer
    // with no way back is a trap, and the wrong button gets pressed.
    const button = el('button', {
      text: label,
      title: label,
      'aria-pressed': String(paper.meta.effectiveKind === value),
    })
    on(button, 'click', () => actions.setKind(paper.id, value))
    choices.append(button)
  }
  return section(null,
    el('div', { class: 'insp-question', text: L('이 PDF는 무엇인가요?', 'What is this PDF?') }),
    choices,
    el('p', { class: 'insp-hint', text: hint }),
  )
}

/** «Is this the right paper?» — the records a lookup offered for a paper
 *  it was unsure of, each one press from being the record. */
function candidatesSection(paper: Paper, actions: InspectorActions): HTMLElement | null {
  const candidates = (paper.meta.raw.candidates ?? []) as Candidate[]
  if (paper.meta.effectiveKind !== 'paper' || paper.meta.confidence !== 'needsReview' || candidates.length === 0) return null
  const list = el('div', { class: 'candidate-list' })
  for (const candidate of candidates) {
    const csl = (candidate.csl ?? {}) as CSLItem
    const venue = csl['container-title']
    const year = cslYear(csl)
    const button = el('button', { class: 'candidate' }, [
      el('span', { class: 'candidate-title', text: cslFullTitle(csl) ?? L('제목 없음', 'Untitled') }),
      ...((csl.author ?? []).length > 0 ? [el('span', { class: 'candidate-authors', text: (csl.author ?? []).map(fullName).join(', ') })] : []),
      el('span', { class: 'candidate-where', text: [year ? String(year) : null, venue || null].filter(Boolean).join('  ') }),
      ...(candidate.matchExplanation ? [el('span', { class: 'candidate-where', text: candidate.matchExplanation })] : []),
      el('span', { class: 'candidate-score', text: L(`${Math.round((candidate.score ?? 0) * 100)}% 일치`, `${Math.round((candidate.score ?? 0) * 100)}% match`) }),
    ])
    on(button, 'click', () => actions.acceptCandidate(paper.id, candidate))
    list.append(button)
  }
  return section(L('이 논문이 맞나요?', 'Is this the right paper?'), list)
}

/** What a lookup offered, as the Mac writes it into `candidates`. */
export interface Candidate {
  csl?: Record<string, unknown>
  identifiers?: Record<string, unknown>
  provenance?: { source?: string }
  score?: number
  matchExplanation?: string
}

/**
 * What a paper is attached to, or what is attached to it — the Mac's
 * «Belongs To» and «Supplementary Material» — and, for a document that says
 * it is supplementary, the paper it looks like it belongs to.
 */
function supplements(paper: Paper, actions: InspectorActions): HTMLElement[] {
  const parentID = paper.meta.parentID
  const parent = parentID ? store.papers.find((entry) => entry.id === parentID) : undefined
  if (parent) {
    const open = el('button', { class: 'plain-button supplement-link', html: icon('doc.text') })
    open.append(el('span', { text: parent.meta.displayTitle }))
    on(open, 'click', () => actions.open(parent.id))
    const free = el('button', { class: 'plain-button', text: L('따로 논문으로 두기', 'Make a Paper of Its Own') })
    on(free, 'click', () => actions.detach(paper.id))
    return [section(L('붙어 있는 논문', 'Belongs To'), el('div', { class: 'chip-row' }, [open]), el('div', { class: 'chip-row' }, [free]))]
  }
  const out: HTMLElement[] = []
  // By title, as the Mac lists them.
  const children = store.papers.filter((entry) => entry.meta.parentID === paper.id)
    .sort((a, b) => a.meta.displayTitle.localeCompare(b.meta.displayTitle))
  if (children.length > 0) {
    const list = el('div', { class: 'supplement-list' })
    for (const child of children) {
      const open = el('button', { class: 'plain-button supplement-link', html: icon('paperclip') })
      open.append(el('span', { text: child.meta.displayTitle }))
      on(open, 'click', () => actions.open(child.id))
      const detach = el('button', { class: 'plain-button', text: L('떼기', 'Detach') })
      on(detach, 'click', () => actions.detach(child.id))
      list.append(el('div', { class: 'supplement-row' }, [open, detach]))
    }
    out.push(section(L('보충 자료', 'Supplementary Material'), list))
  }
  const suggested = actions.suggestedParent(paper.id)
  const offered = suggested ? store.papers.find((entry) => entry.id === suggested) : undefined
  if (offered && children.length === 0) {
    const attach = el('button', { class: 'filled-button', text: L('이 논문에 붙이기', 'Attach to This Paper') })
    on(attach, 'click', () => actions.attach(paper.id, offered.id))
    out.push(section(null,
      el('div', { class: 'insp-question', text: L('보충 자료 같아 보여요.', 'This looks like supplementary material.') }),
      el('p', { class: 'insp-hint', text: offered.meta.displayTitle }),
      el('div', { class: 'chip-row' }, [attach]),
    ))
  }
  return out
}

/** A read-only identifier with a copy button — the Mac's Identifiers rows. */
function identifierRow(label: string, value: string | undefined, actions: InspectorActions): HTMLElement | null {
  if (!value) return null
  const copy = el('button', { class: 'icon-button', title: L(`${label} 복사`, `Copy ${label}`), 'aria-label': L(`${label} 복사`, `Copy ${label}`), html: icon('doc.on.doc') })
  on(copy, 'click', () => actions.copyText(value))
  return el('div', { class: 'identifier-row' }, [
    el('span', { class: 'identifier-label', text: label }),
    el('span', { class: 'identifier-value', text: value }),
    copy,
  ])
}

/** Where the record came from (`humanized(provenance.source)`). */
function sourceName(source: string | undefined): string {
  switch (source) {
    case 'doiContentNegotiation': return L('DOI 콘텐츠 협상', 'DOI Content Negotiation')
    case 'crossref': return 'Crossref'
    case 'openAlex': return 'OpenAlex'
    case 'arxiv': return 'arXiv'
    case 'semanticScholar': return 'Semantic Scholar'
    case 'pdfDocumentInfo': return L('PDF 문서 정보', 'PDF Document Info')
    case 'onDeviceModel': return L('온디바이스 모델', 'On-Device Model')
    case 'importedBibTeX': return L('BibTeX에서 들여옴', 'Imported BibTeX')
    case 'importedRIS': return L('RIS에서 들여옴', 'Imported RIS')
    case 'manual': return L('직접 적음', 'Entered by You')
    default: return L('조판 규칙으로 읽음', 'Heuristic Extraction')
  }
}

/** What the file says about its own history, asked once per paper shown. */
const provenanceAsked = new Map<string, string>()

function details(body: HTMLElement, paper: Paper, actions: InspectorActions, redraw: () => void) {
  const meta = paper.meta
  const kind = meta.effectiveKind
  const isPaper = kind === 'paper'
  const isBook = kind === 'book'
  const csl = draftFor(paper)

  // Save and Revert light up as soon as the draft differs from the record.
  const revert = el('button', { class: 'plain-button', text: L('되돌리기', 'Revert') }) as HTMLButtonElement
  const save = el('button', { class: 'filled-button', text: L('저장', 'Save') }) as HTMLButtonElement
  const dirtied = (rebuild = false) => {
    const dirty = isDirty(paper)
    revert.disabled = !dirty
    save.disabled = !dirty
    if (rebuild) redraw()
  }
  on(revert, 'click', () => {
    draft = null
    redraw()
  })
  on(save, 'click', () => {
    if (!draft) return
    const written = structuredClone(draft.csl)
    draft = null
    // `update(meta:)`: saved by hand is the reader's record — manual, and
    // the candidates a lookup offered are let go.
    actions.editMeta(paper.id, { csl: written, confidence: 'manual', candidates: [] })
  })

  // The header: what the paper is called, who wrote it, and how sure the
  // record is.
  body.append(section(null,
    el('div', { class: 'insp-title', text: meta.displayTitle }),
    ...(meta.displayAuthors ? [el('div', { class: 'insp-authors', text: meta.displayAuthors })] : []),
    confidenceBadge(meta.confidence),
  ))

  // Before anything else: what is this? Asked once, when nobody has
  // answered; changing it later is in the ⋯ menu and the row's menu.
  if (meta.kindIsUnanswered) body.append(kindQuestion(paper, actions))
  const candidates = candidatesSection(paper, actions)
  if (candidates) body.append(candidates)
  body.append(...supplements(paper, actions))

  const text = (label: string, key: string, options?: { multiline?: boolean; placeholder?: string }) =>
    draftText(paper, label, key, dirtied, options)
  const title = text(L('제목', 'Title'), 'title', { multiline: true, placeholder: meta.displayTitle })
  if (isPaper) {
    body.append(section(L('서지 정보', 'Details'),
      title,
      text(L('부제', 'Subtitle'), 'subtitle'),
      draftYear(paper, dirtied),
      text(L('학술지·학회', 'Venue'), 'container-title'),
      el('div', { class: 'field-row' }, [text(L('권', 'Volume'), 'volume'), text(L('호', 'Issue'), 'issue'), text(L('쪽', 'Pages'), 'page')]),
      text(L('출판사', 'Publisher'), 'publisher'),
      text('DOI', 'DOI'),
      text('URL', 'URL'),
      draftType(paper, L('종류', 'Type'), PAPER_TYPES, dirtied),
    ))
  } else if (isBook) {
    // A book has a publisher, a place, an edition, an ISBN — and none of
    // the journal's furniture. A chapter wants the book it came out of.
    const nodes: Node[] = [
      title,
      text(L('부제', 'Subtitle'), 'subtitle'),
      text(L('출판사', 'Publisher'), 'publisher'),
      text(L('펴낸 곳', 'Place'), 'publisher-place'),
      text(L('판', 'Edition'), 'edition'),
      draftYear(paper, dirtied),
      text('ISBN', 'ISBN'),
      text('URL', 'URL'),
      draftType(paper, L('종류', 'Kind'), ['book', 'chapter'], dirtied),
    ]
    if (csl.type === 'chapter') nodes.push(text(L('실린 책', 'In the book'), 'container-title'), text(L('쪽', 'Pages'), 'page'))
    body.append(section(L('책 정보', 'The book'), ...nodes))
  } else {
    // A deck has a course and a year and nothing a journal would recognise.
    body.append(section(L('문서 정보', 'Details'),
      title,
      text(L('부제', 'Subtitle'), 'subtitle'),
      text(L('펴낸 곳', 'From'), 'publisher'),
      draftYear(paper, dirtied),
      text('URL', 'URL'),
      draftType(paper, L('종류', 'Kind'), DOCUMENT_TYPES, dirtied),
    ))
  }

  const authorTitle = isPaper ? L('저자', 'Authors') : isBook ? L('지은이', 'Written by')
    : kind === 'lecture' ? L('만든 사람', 'Made by') : L('쓴 사람', 'Written by')
  body.append(buildAuthorEditor({
    title: authorTitle,
    authors: (csl.author ?? []) as CSLName[],
    changed: (authors) => {
      if (authors.length > 0) csl.author = authors
      else delete csl.author
      dirtied()
    },
    paste: actions.paste,
    openAuthor: actions.openAuthor,
  }))
  body.append(section(null, el('div', { class: 'insp-save' }, [revert, el('span', { class: 'fb-spacer' }), save])))
  dirtied()

  // Reading: straight through to the record, as the Mac's section is — a
  // change made in the list shows here at once.
  const status = el('select', { class: 'field-select' }) as HTMLSelectElement
  for (const [value, label] of [['unread', L('안 읽음', 'Unread')], ['reading', L('읽는 중', 'Reading')], ['read', L('읽음', 'Read')]] as const) {
    const option = el('option', { value, text: label }) as HTMLOptionElement
    option.selected = paper.state.readingStatus === value
    status.append(option)
  }
  on(status, 'change', () => actions.editState(paper.id, { readingStatus: status.value }))
  const favourite = el('input', { type: 'checkbox', class: 'set-check' }) as HTMLInputElement
  favourite.checked = paper.state.isFavorite
  on(favourite, 'change', () => actions.editState(paper.id, { isFavorite: favourite.checked }))
  const stars = el('div', { class: 'rating', role: 'group', 'aria-label': L('별점', 'Rating') })
  const rating = paper.state.rating ?? 0
  for (let value = 1; value <= 5; value += 1) {
    const star = el('button', {
      class: 'rating-star',
      'aria-pressed': String(value <= rating),
      title: L(`별 ${value}개`, `${value} star${value === 1 ? '' : 's'}`),
      html: icon(value <= rating ? 'star.fill' : 'star'),
    })
    // Pressing the rating it already has takes it back to none.
    on(star, 'click', () => actions.editState(paper.id, { rating: value === rating ? null : value }))
    stars.append(star)
  }
  // The memo grows from three lines to eight and is written when it is left
  // — or when the paper goes, or the window does (`flushInspector`).
  const note = el('textarea', { class: 'grow memo', rows: '3', placeholder: L('메모', 'Note') }) as HTMLTextAreaElement
  note.value = paper.state.summaryNote
  const grow = () => {
    note.rows = Math.min(8, Math.max(3, note.value.split('\n').length))
  }
  grow()
  const keep = (value: string) => {
    if (value !== paper.state.summaryNote) actions.editState(paper.id, { summaryNote: value })
  }
  on(note, 'input', () => {
    grow()
    memo = { paperID: paper.id, text: note.value, save: keep }
  })
  on(note, 'blur', () => flushInspector())
  on(note, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
  body.append(section(L('읽기', 'Reading'),
    el('div', { class: 'insp-line' }, [el('span', { text: L('상태', 'Status') }), status]),
    el('label', { class: 'insp-line' }, [el('span', { text: L('즐겨찾기', 'Favorite') }), favourite]),
    el('div', { class: 'insp-line' }, [el('span', { text: L('별점', 'Rating') }), stars]),
    note,
  ))

  if (isPaper) {
    const ids = (meta.raw.identifiers ?? {}) as Record<string, string | undefined>
    const rows = [
      identifierRow('DOI', ids.doi, actions),
      identifierRow('arXiv', ids.arxiv, actions),
      identifierRow('PMID', ids.pmid, actions),
      identifierRow(L('BibTeX 키', 'BibTeX Key'), meta.bibKey, actions),
    ].filter((row): row is HTMLElement => row !== null)
    if (rows.length > 0) body.append(section(L('식별자', 'Identifiers'), ...rows))
  }

  // The file: its name (typing renames it), its length, where it stands
  // against the one imported, and the way to it.
  const where = el('p', { class: 'insp-hint' })
  const said = provenanceAsked.get(paper.id)
  const describe = (answer: string) => {
    where.textContent = answer === 'pristine' ? L('원본 그대로예요.', 'The file is as you imported it.')
      : answer === 'appended' ? L('원본은 그대로 두고 표시만 뒤에 덧붙였어요.', 'The original is intact. Marks follow it.')
        : answer === 'rewritten' ? L('다른 앱이 파일을 다시 썼어요. 글자가 원본과 다를 수 있어요.', 'Another app rewrote this file. Its text may differ from the original.')
          : ''
    where.hidden = !where.textContent
  }
  if (said) describe(said)
  else {
    where.hidden = true
    void actions.provenance(paper.id).then((answer) => {
      provenanceAsked.set(paper.id, answer)
      describe(answer)
    })
  }
  const reveal = el('button', { class: 'plain-button', text: L('폴더에서 보기', 'Show in Folder') })
  on(reveal, 'click', () => actions.reveal(paper.id))
  body.append(section(L('파일', 'File'),
    fileName(paper, actions),
    el('div', { class: 'insp-line' }, [el('span', { text: L('쪽', 'Pages') }), el('span', { class: 'insp-value', text: String(meta.file.pageCount) })]),
    where,
    el('div', { class: 'chip-row' }, [reveal]),
  ))

  const provenance = (meta.raw.provenance ?? {}) as { source?: string; fetchedAt?: string }
  const fetched = provenance.fetchedAt ? new Date(provenance.fetchedAt) : null
  const when = fetched && !Number.isNaN(fetched.getTime())
    ? fetched.toLocaleString(prefersKorean() ? 'ko' : 'en', { dateStyle: 'medium', timeStyle: 'short' })
    : null
  body.append(el('div', { class: 'insp-footer' }, [
    el('div', { text: L(`출처: ${sourceName(provenance.source)}`, `Source: ${sourceName(provenance.source)}`) }),
    ...(when ? [el('div', { text: L(`${when}에 가져옴`, `Fetched ${when}`) })] : []),
  ]))
}

/**
 * The Marks tab: every highlight, underline and strikethrough in the paper,
 * in reading order, the Mac's `MarkupListView`. A row is the mark's colour,
 * its page and its kind, and what it says — the note written on it, or the
 * words it marks. Pressing a row goes to the mark; its menu writes a note,
 * copies the words, or takes the mark off. This tab used to be a sentence
 * promising that the marks would appear here.
 */
type MarkFilter = 'all' | 'highlight' | 'underline' | 'strikethrough' | 'notes'
let markFilter: MarkFilter = 'all'
/** The row whose note is being written in place, if one is. */
let editingMark: string | null = null

function markFilters(): [MarkFilter, string, string][] {
  return [
    ['all', L('전부', 'All'), 'list.bullet'],
    ['highlight', L('형광펜', 'Highlights'), 'highlighter'],
    ['underline', L('밑줄', 'Underlines'), 'underline'],
    ['strikethrough', L('취소선', 'Strikethroughs'), 'strikethrough'],
    ['notes', L('노트', 'Notes'), 'text.bubble'],
  ]
}

function markMatches(filter: MarkFilter, mark: Mark): boolean {
  if (filter === 'all') return true
  if (filter === 'notes') return Boolean(mark.comment)
  return mark.kind === filter
}

function markKindName(mark: Mark): string {
  switch (mark.kind) {
    case 'highlight': return L('형광펜', 'Highlight')
    case 'underline': return L('밑줄', 'Underline')
    case 'strikethrough': return L('취소선', 'Strikethrough')
  }
}

function marks(body: HTMLElement, paper: Paper, actions: InspectorActions, redraw: () => void) {
  const loaded = actions.marks()
  if (loaded === null) {
    // The marks are read with the paper; until then the tab says so rather
    // than calling a well-marked paper unmarked.
    body.append(el('div', { class: 'empty' }, [
      el('span', { class: 'spinner' }),
      el('h2', { text: L('논문을 여는 중', 'Opening the Paper') }),
    ]))
    return
  }
  const items = loaded
  const chips = el('div', { class: 'mark-filters' })
  for (const [value, label] of markFilters()) {
    const count = items.filter((item) => markMatches(value, item.mark)).length
    const chip = el('button', {
      class: 'mark-filter',
      'aria-pressed': String(markFilter === value),
      title: `${label}: ${count}`,
    }, [el('span', { text: label }), el('span', { class: 'mark-filter-count', text: String(count) })]) as HTMLButtonElement
    chip.disabled = count === 0 && value !== 'all'
    on(chip, 'click', () => {
      markFilter = value
      redraw()
    })
    chips.append(chip)
  }
  body.append(chips)

  const shown = items.filter((item) => markMatches(markFilter, item.mark))
  if (shown.length === 0) {
    const filter = markFilters().find(([value]) => value === markFilter)!
    const title = markFilter === 'all'
      ? L('아직 표시가 없어요', 'No Marks Yet')
      : L(`아직 ${filter[1]} 표시가 없어요`, `Nothing ${filter[1]} Yet`)
    const message = markFilter === 'all'
      ? L('글자를 골라 형광펜을 칠하거나, 펜으로 그려보세요.', 'Select text to highlight it, or draw with the pen.')
      : markFilter === 'notes'
        ? L('구절을 고르고 노트 단추를 누르면 돼요.', 'Select a passage, then choose the note button.')
        : L(`논문에서 글자를 고르고, 표시 막대에서 ${filter[1]}을 고르면 돼요.`,
            `Select text in the paper and pick ${filter[1].toLowerCase()} from the bar.`)
    body.append(el('div', { class: 'empty' }, [
      el('span', { html: icon(filter[2]) }),
      el('h2', { text: title }),
      el('p', { text: message }),
    ]))
    return
  }

  const list = el('div', { class: 'mark-list' })
  for (const { pageIndex, mark } of shown) {
    const words = mark.comment || mark.text
    const row = el('div', { class: 'mark-row', role: 'button', tabindex: '0', 'data-mark': mark.id }, [
      el('div', { class: 'mark-row-head' }, [
        el('span', { class: 'mark-dot', style: `background: ${cssColor(mark.color)}` }),
        el('span', { class: 'mark-page', text: L(`${pageIndex + 1}쪽`, `Page ${pageIndex + 1}`) }),
        el('span', { class: 'toolbar-spacer' }),
        el('span', { class: 'mark-kind' }, [
          el('span', { html: icon(mark.comment ? 'text.bubble' : mark.kind === 'highlight' ? 'highlighter' : mark.kind) }),
          el('span', { text: markKindName(mark) }),
        ]),
      ]),
      ...(words ? [el('div', { class: 'mark-words', text: words })] : []),
    ])
    on(row, 'click', () => actions.revealMark(pageIndex, mark.id))
    on(row, 'keydown', (event: KeyboardEvent) => {
      if (event.key === 'Enter') actions.revealMark(pageIndex, mark.id)
    })
    on(row, 'contextmenu', (event: MouseEvent) => {
      event.preventDefault()
      // Another reader's mark too: the first change takes it into this app's
      // care, as the Mac's does.
      actions.markMenu(row, [
        {
          label: mark.comment ? L('노트 고치기…', 'Edit Note…') : L('노트 더하기…', 'Add Note…'),
          icon: 'square.and.pencil',
          action: () => {
            editingMark = mark.id
            redraw()
          },
        },
        // The words it marks, and only those: copying the note under «Copy
        // Text» put the wrong thing on the clipboard.
        { label: L('글 복사', 'Copy Text'), icon: 'doc.on.doc', disabled: !mark.text, action: () => actions.copyText(mark.text) },
        { separator: true },
        { label: L('지우기', 'Delete'), icon: 'trash', danger: true, action: () => actions.removeMark(pageIndex, mark.id) },
      ])
    })
    if (editingMark === mark.id) {
      // A field that grows to four lines (`TextField(axis: .vertical)`):
      // Return keeps the note, ⇧Return starts a new line.
      const input = el('textarea', { class: 'mark-comment-field', rows: '1', placeholder: L('노트', 'Note') }) as HTMLTextAreaElement
      input.value = mark.comment ?? ''
      const grow = () => {
        input.style.height = 'auto'
        input.style.height = `${Math.min(input.scrollHeight, 4 * 19 + 10)}px`
      }
      on(input, 'input', grow)
      requestAnimationFrame(grow)
      const done = el('button', { class: 'filled-button mark-comment-done', text: L('끝', 'Done') })
      // Out of the field first: the tab does not redraw under a field that
      // has the keyboard, so the row stayed open with the old words in it.
      const commit = () => {
        if (editingMark !== mark.id) return
        editingMark = null
        input.blur()
        actions.commentMark(pageIndex, mark.id, input.value)
        redraw()
      }
      on(input, 'keydown', (event: KeyboardEvent) => {
        event.stopPropagation()
        if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
          event.preventDefault()
          commit()
        }
        if (event.key === 'Escape') {
          editingMark = null
          input.blur()
          redraw()
        }
      })
      on(input, 'click', (event: MouseEvent) => event.stopPropagation())
      on(done, 'click', (event: MouseEvent) => {
        event.stopPropagation()
        commit()
      })
      row.append(el('div', { class: 'mark-comment-edit' }, [input, done]))
      requestAnimationFrame(() => input.focus())
    }
    list.append(row)
  }
  body.append(list)
}

/** Brings a mark's row forward and pulses it — a mark clicked on the page. */
function flashMarkRow(body: HTMLElement, id: string) {
  const row = body.querySelector<HTMLElement>(`.mark-row[data-mark="${CSS.escape(id)}"]`)
  if (!row) return
  row.scrollIntoView({ block: 'nearest' })
  row.classList.remove('flash')
  void row.offsetWidth
  row.classList.add('flash')
}
