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
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { store, type Paper } from '../state.js'
import { fullName, type CSLName } from '../../shared/model.js'
import { L } from '../../shared/lang.js'
import { type DocumentKind } from '../../shared/documentKind.js'
import { buildSketchInspector } from './sketchInspector.js'

export interface InspectorActions {
  editMeta: (id: string, patch: Record<string, unknown>) => void
  editState: (id: string, patch: Record<string, unknown>) => void
  reveal: (id: string) => void
  copyKey: (id: string) => void
  openAuthor: (name: string) => void
  /** The answer to "paper or document?", which decides the rest of this form. */
  setKind: (id: string, kind: DocumentKind) => void
  /** The default drawing style changed; the rack and the page should follow. */
  sketchChanged: () => void
}

export function buildInspector(actions: InspectorActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'panel' })
  const body = el('div', { class: 'panel-body' })
  node.append(body)
  // Built once and kept: it redraws itself when the selection on the page
  // changes, and rebuilding it from here would lose a field being typed in.
  const tools = buildSketchInspector({ changed: actions.sketchChanged })

  function update() {
    if (store.settings.inspectorTab === 'tools') {
      if (tools.node.parentElement !== body) {
        clear(body)
        body.append(tools.node)
      }
      tools.update()
      return
    }
    clear(body)
    const paper = store.papers.find((entry) => entry.id === store.selectedID)
    if (!paper) {
      body.append(el('div', { class: 'empty' }, [
        el('h2', { text: L('고른 논문이 없어요', 'No paper selected') }),
        el('p', { text: L('목록에서 하나를 고르면 그 기록이 보여요.', 'Pick one from the list to see its record.') }),
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

const CONFIDENCE_LABEL = (): Record<string, string> => ({
  unparsed: L('아직 안 읽음', 'Not read yet'),
  low: L('확신 낮음', 'Low confidence'),
  medium: L('확신 보통', 'Medium confidence'),
  high: L('확신 높음', 'High confidence'),
  verified: L('등록기관에서 확인함', 'Verified against a registrar'),
  manual: L('직접 고침', 'Edited by you'),
  needsReview: L('살펴볼 것', 'Needs review'),
})

/**
 * One question, asked once, with the app's own guess offered.
 *
 * Everything under it hangs on the answer — which fields the form has,
 * whether the record is looked up online at all — so it is asked plainly
 * rather than inferred and quietly acted on.
 */
function kindQuestion(body: HTMLElement, paper: Paper, actions: InspectorActions) {
  const answered = !paper.meta.kindIsUnanswered
  const guess = paper.meta.guessedKind
  const hint = guess === 'paper'
    ? L('논문 같아요 — 안에 DOI나 참고문헌이 보여요. 맞으면 그대로 눌러주세요.',
        'It looks like a paper — there is a DOI or a reference list in it. Press it again to agree.')
    : guess === 'document'
      ? L('논문은 아닌 것 같아요. 일반 문서면 학술지 같은 칸은 숨길게요.',
          "It doesn't look like a paper. As a document, the journal fields go away.")
      : L('고르면 아래 칸들이 그에 맞게 바뀌어요.', 'The fields below follow your answer.')

  const choices = el('div', { class: 'choices' })
  for (const [value, label] of [
    ['paper', L('논문', 'A paper')],
    ['document', L('일반 문서', 'A document')],
  ] as const) {
    // The chosen one is marked, and the other one is the way back: an answer
    // with no way back is a trap, and the wrong button gets pressed.
    const button = el('button', {
      text: label,
      'aria-pressed': String(paper.meta.effectiveKind === value),
    })
    on(button, 'click', () => actions.setKind(paper.id, value))
    choices.append(button)
  }

  body.append(el('div', { class: 'field' }, [
    el('div', {
      class: 'field-label',
      text: answered ? L('이 PDF는', 'This PDF is') : L('이 PDF는 무엇인가요?', 'What is this PDF?'),
    }),
    ...(answered ? [] : [el('p', { class: 'hint', text: hint })]),
    choices,
  ]))
}

function details(body: HTMLElement, paper: Paper, actions: InspectorActions) {
  const meta = paper.meta
  const isPaper = meta.effectiveKind === 'paper'

  kindQuestion(body, paper, actions)

  body.append(editable(L('제목', 'Title'), meta.csl.title ?? '', (next) => {
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
      el('div', { class: 'field-label', text: isPaper ? L('저자', 'Authors') : L('쓴 사람', 'Written by') }),
      authors,
    ]))
  }

  // A manual has no journal, no volume and no DOI, so it is not asked for
  // them. What it has instead is where it came from.
  if (isPaper) {
    body.append(editable(L('학술지·학회', 'Venue'), meta.csl['container-title'] ?? '', (next) => {
      actions.editMeta(paper.id, { csl: { ...meta.csl, 'container-title': next }, confidence: 'manual' })
    }))
  } else {
    body.append(editable(L('펴낸 곳', 'From'), meta.csl.publisher ?? '', (next) => {
      actions.editMeta(paper.id, { csl: { ...meta.csl, publisher: next }, confidence: 'manual' })
    }))
  }

  body.append(editable(L('해', 'Year'), meta.year ? String(meta.year) : '', (next) => {
    const year = Number(next)
    const issued = Number.isInteger(year) && year > 0 ? { 'date-parts': [[year]] } : undefined
    actions.editMeta(paper.id, { csl: { ...meta.csl, issued }, confidence: 'manual' })
  }))

  if (isPaper) {
    if (meta.csl.DOI) body.append(field('DOI', meta.csl.DOI))
    body.append(editable(L('인용 키', 'Citation key'), meta.bibKey, (next) => {
      actions.editMeta(paper.id, { bibKey: next })
    }))
  }

  const status = el('div', { class: 'choices' })
  for (const [value, label] of [
    ['unread', L('안 읽음', 'Unread')],
    ['reading', L('읽는 중', 'Reading')],
    ['read', L('읽음', 'Read')],
  ] as const) {
    const button = el('button', {
      text: label,
      'aria-pressed': String(paper.state.readingStatus === value),
    })
    on(button, 'click', () => actions.editState(paper.id, { readingStatus: value }))
    status.append(button)
  }
  body.append(el('div', { class: 'field' }, [
    el('div', { class: 'field-label', text: L('읽기 상태', 'Reading') }),
    status,
  ]))

  // "Confidence" is about a registrar agreeing with us, and no registrar has
  // an opinion about a manual.
  if (isPaper) {
    body.append(field(L('확신', 'Confidence'), CONFIDENCE_LABEL()[meta.confidence] ?? meta.confidence))
  } else {
    body.append(field(L('종류', 'Kind'), L('일반 문서', 'Document')))
  }
  body.append(field(L('파일', 'File'), meta.file.originalName || meta.file.relativePath))
  body.append(field(L('쪽', 'Pages'), String(meta.file.pageCount)))
  body.append(field(L('더한 날', 'Added'), meta.addedAt.toLocaleDateString()))

  const row = el('div', { class: 'field' })
  const reveal = el('button', { class: 'plain-button', text: L('폴더에서 보기', 'Show in Folder') })
  on(reveal, 'click', () => actions.reveal(paper.id))
  const chips = [reveal]
  if (isPaper) {
    const copy = el('button', { class: 'plain-button', text: L('인용 키 복사', 'Copy Citation Key') })
    on(copy, 'click', () => actions.copyKey(paper.id))
    chips.push(copy)
  }
  row.append(el('div', { class: 'chip-row' }, chips))
  body.append(row, el('div', { style: 'height: 14px' }))
}

function marks(body: HTMLElement, paper: Paper) {
  body.append(el('div', { class: 'empty' }, [
    el('span', { html: icon('highlighter') }),
    el('h2', { text: L('표시', 'Marks') }),
    el('p', {
      text: L(
        '쪽에 칠한 형광펜과 밑줄이 여기에 모여요. 펜으로 그린 것은 이미 PDF 안에 있어요.',
        'Highlights and underlines from the page will appear here. '
          + 'Pen strokes already live in the PDF.',
      ),
    }),
  ]))
}

function note(body: HTMLElement, paper: Paper, actions: InspectorActions) {
  const area = el('textarea', {
    rows: '20',
    placeholder: L('이 논문에 대한 노트…', 'A note about this paper…'),
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
