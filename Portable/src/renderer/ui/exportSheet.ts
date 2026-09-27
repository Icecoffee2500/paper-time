/**
 * «BibTeX 내보내기…» — the Mac's `BibTeXExportView`: what to export, how,
 * and the file itself, previewed before it leaves the app.
 *
 * This build wrote the shelf straight to a file behind a save dialog, so
 * nothing said which papers went, or how many were left out, until LaTeX
 * said so weeks later. Now the scope is chosen (the paper in front, the list
 * showing, the whole library, a collection), the options are there, papers
 * nobody has checked are counted and can be left out, and the text is shown
 * — then copied, or saved.
 *
 * Only what is cited goes: papers and books (`isCitable`). Course material
 * and a document are read, not cited.
 */
import { clear, el, on } from '../dom.js'
import { L } from '../../shared/lang.js'
import { store, type Paper } from '../state.js'
import { isCitable, isLookedUp } from '../../shared/documentKind.js'
import { DEFAULT_EXPORT, formatBibliography, type ExportOptions } from '../../shared/bibtex.js'
import { inCollection } from '../../shared/smartRule.js'

export type ExportScope = 'selected' | 'view' | 'library' | 'collection'

export interface ExportSheetInput {
  /** The papers of the shelf showing, in its order. */
  view: () => Paper[]
  copy: (text: string) => void
  save: (text: string) => Promise<boolean>
}

let open = false

/** Nobody has checked it against a registrar — the Mac's «unverified». */
function unverified(entry: Paper): boolean {
  return isLookedUp(entry.meta.effectiveKind)
    && entry.meta.confidence !== 'verified' && entry.meta.confidence !== 'manual'
}

export function showExportSheet(input: ExportSheetInput) {
  if (open) return
  open = true
  let scope: ExportScope = 'view'
  let collectionID: string | null = store.collections[0]?.id ?? null
  // The Mac's options and the Mac's defaults — unverified records left out
  // unless asked for; the warning counts them and says how to put them in.
  const options: ExportOptions = {
    ...DEFAULT_EXPORT,
    protectCase: store.settings.bibtexProtectCase !== false,
    preprintStyle: store.settings.bibtexPreprintStyle === 'arxivPreprintArticle' ? 'arxivPreprintArticle' : 'eprint',
  }
  let includeUnverified = store.settings.bibtexIncludeUnverified === true

  const backdrop = el('div', { class: 'sheet-backdrop' })
  const sheet = el('div', { class: 'fb-sheet export-sheet', role: 'dialog', 'aria-modal': 'true' })
  const body = el('div', { class: 'set-body export-body' })
  const preview = el('pre', { class: 'export-preview' })
  const warning = el('p', { class: 'export-warning' })
  const cancel = el('button', { class: 'plain-button', text: L('취소', 'Cancel') })
  const copy = el('button', { class: 'plain-button', text: L('복사', 'Copy') }) as HTMLButtonElement
  const save = el('button', { class: 'plain-button', text: L('저장…', 'Save…') }) as HTMLButtonElement
  const done = el('button', { class: 'filled-button', text: L('완료', 'Done') }) as HTMLButtonElement
  sheet.append(
    el('h2', { class: 'fb-title', text: L('BibTeX 내보내기', 'Export BibTeX') }),
    body,
    el('div', { class: 'set-foot export-foot' }, [cancel, el('span', { class: 'fb-spacer' }), copy, save, done]),
  )
  backdrop.append(sheet)
  document.body.append(backdrop)

  const close = () => {
    backdrop.remove()
    open = false
    document.removeEventListener('keydown', onKey)
  }
  function onKey(event: KeyboardEvent) {
    if (event.key === 'Escape') close()
  }

  /** The papers the scope names, before the unchecked are left out. */
  const inScope = (): Paper[] => {
    const standing = store.papers.filter((entry) => !entry.meta.parentID)
    switch (scope) {
      case 'selected': return standing.filter((entry) => entry.id === store.selectedID)
      // The shelf's papers, never a supplement hanging off one.
      case 'view': return input.view().filter((entry) => !entry.meta.parentID)
      case 'library': return standing
      case 'collection': {
        const collection = store.collections.find((one) => one.id === collectionID)
        return collection ? standing.filter((entry) => inCollection(collection, entry.meta, entry.state, store.tags)) : []
      }
    }
  }

  /** What is written: cited kinds only, the unchecked unless asked for,
   *  sorted by key so the same library writes the same file twice. */
  const chosen = (): Paper[] => inScope()
    .filter((entry) => isCitable(entry.meta.effectiveKind))
    .filter((entry) => includeUnverified || !unverified(entry))

  const text = () => {
    const metas = chosen().map((entry) => entry.meta)
    if (metas.length === 0) return ''
    return formatBibliography(metas, options)
  }

  const draw = () => {
    clear(body)
    const scopes: [ExportScope, string][] = [
      ['selected', L('고른 논문', 'Selected Paper')],
      ['view', L('지금 보이는 목록', 'Current View')],
      ['library', L('라이브러리 전체', 'Whole Library')],
      ['collection', L('컬렉션', 'Collection')],
    ]
    const group = el('div', { class: 'segmented set-seg export-scopes', role: 'group' })
    for (const [value, name] of scopes) {
      const button = el('button', { type: 'button', text: name, 'aria-selected': String(scope === value) }) as HTMLButtonElement
      if (value === 'collection' && store.collections.length === 0) button.disabled = true
      on(button, 'click', () => {
        scope = value
        draw()
      })
      group.append(button)
    }
    body.append(el('div', { class: 'set-section', text: L('내보내기', 'Export') }), el('div', { class: 'set-row' }, [group]))
    if (scope === 'collection') {
      const select = el('select', { class: 'export-collection' }) as HTMLSelectElement
      for (const collection of store.collections) {
        const option = el('option', { value: collection.id, text: collection.name }) as HTMLOptionElement
        option.selected = collection.id === collectionID
        select.append(option)
      }
      on(select, 'change', () => {
        collectionID = select.value
        draw()
      })
      body.append(el('div', { class: 'set-row' }, [el('span', { class: 'set-label', text: L('컬렉션', 'Collection') }), select]))
    }

    body.append(el('div', { class: 'set-section', text: L('옵션', 'Options') }))
    const style = el('select', { class: 'export-collection' }) as HTMLSelectElement
    for (const [value, name] of [
      ['eprint', L('eprint 필드 (biblatex)', 'eprint fields (biblatex)')],
      ['arxivPreprintArticle', L('arXiv preprint (일반 BibTeX)', 'arXiv preprint (plain BibTeX)')],
    ] as const) {
      const option = el('option', { value, text: name }) as HTMLOptionElement
      option.selected = options.preprintStyle === value
      style.append(option)
    }
    on(style, 'change', () => {
      options.preprintStyle = style.value as ExportOptions['preprintStyle']
      draw()
    })
    body.append(el('div', { class: 'set-row' }, [el('span', { class: 'set-label', text: L('프리프린트 양식', 'Preprint Style') }), style]))
    const toggle = (label: string, value: boolean, flip: (next: boolean) => void) => {
      const row = el('label', { class: 'set-row' })
      const box = el('input', { type: 'checkbox', class: 'set-check' }) as HTMLInputElement
      box.checked = value
      on(box, 'change', () => {
        flip(box.checked)
        draw()
      })
      row.append(el('span', { class: 'set-label', text: label }), box)
      return row
    }
    // No «Include Keywords»: the Mac's toggle hands the writer no keywords,
    // so it writes the same file either way — a switch that does nothing.
    body.append(
      toggle(L('제목 대소문자 지키기', 'Protect Case in Titles'), options.protectCase, (next) => { options.protectCase = next }),
      toggle(L('학술지 이름 줄이기', 'Abbreviate Journal Names'), options.abbreviateJournals, (next) => { options.abbreviateJournals = next }),
      toggle(L('초록 넣기', 'Include Abstract'), options.includeAbstract, (next) => { options.includeAbstract = next }),
      toggle(L('URL 넣기', 'Include URL'), options.includeURL, (next) => { options.includeURL = next }),
      toggle(L('확인 안 된 항목도 넣기', 'Include Unverified Records'), includeUnverified, (next) => { includeUnverified = next }),
    )

    // The Mac's warning, counting papers only: neither a book nor a document
    // has a registrar to be checked against.
    const review = inScope().filter((entry) => isCitable(entry.meta.effectiveKind) && unverified(entry)).length
    warning.textContent = review === 0 ? '' : L(
      `${review}편은 아직 확인하지 못했어요. ${includeUnverified ? '그래도 들어가요' : '이번 내보내기에서는 빠져요'}. 바꾸려면 “확인 안 된 항목도 넣기”를 ${includeUnverified ? '끄면' : '켜면'} 돼요.`,
      `${review} ${review === 1 ? "paper hasn't" : "papers haven't"} been verified and ${includeUnverified ? 'will still be included' : 'will be left out of this export'}. Turn ${includeUnverified ? 'off' : 'on'} “Include Unverified Records” to change that.`,
    )
    if (store.unreadable.length > 0 && scope !== 'selected') {
      warning.textContent += (warning.textContent ? ' ' : '') + L(
        `기록 ${store.unreadable.length}개가 아직 안 와서 빠지는 논문이 있을 수 있어요.`,
        `${store.unreadable.length} record${store.unreadable.length === 1 ? '' : 's'} ${store.unreadable.length === 1 ? "hasn't" : "haven't"} arrived, so this export may be short.`,
      )
    }
    if (warning.textContent) body.append(warning)

    body.append(el('div', { class: 'set-section', text: L('미리 보기', 'Preview') }))
    const written = text()
    const lines = written.split('\n')
    preview.textContent = written
      ? (lines.length > 200
        ? L(`${lines.slice(0, 200).join('\n')}\n… 그리고 ${lines.length - 200}줄 더`, `${lines.slice(0, 200).join('\n')}\n… and ${lines.length - 200} more lines`)
        : written)
      : L('아직 내보낼 것이 없어요.', 'Nothing to export yet.')
    body.append(preview)
    body.append(overleaf())
    copy.disabled = !written
    save.disabled = !written
  }

  /** How to use the file in Overleaf, folded (`ExportInstructionsView`). */
  const overleaf = () => {
    const details = el('details', { class: 'export-overleaf' })
    details.append(el('summary', { text: L('이 파일을 Overleaf에서 쓰기', 'Using this file in Overleaf') }))
    const steps = el('ol')
    for (const step of [
      L('내보낸 .bib 파일을 찾기 쉬운 곳에 저장하세요.', 'Save the exported .bib file where you can find it.'),
      L('Overleaf에서 프로젝트를 여세요.', 'Open your project on Overleaf.'),
      L('파일을 왼쪽 파일 목록에 끌어다 놓으세요. 프로젝트의 Upload 단추를 써도 돼요.', "Drag the file into the file list on the left, or use the project's Upload button."),
      L('문서에서는 BibTeX이면 \\bibliography{refs}로, biblatex이면 \\addbibresource{refs.bib}로 불러요. refs 자리에는 파일에 붙인 이름을 쓰면 돼요.',
        'Reference it from your document with \\bibliography{refs} for plain BibTeX, or \\addbibresource{refs.bib} for biblatex — using the name you gave the file.'),
    ]) steps.append(el('li', { text: step }))
    details.append(steps, el('p', { class: 'fine', text: L('같은 이름으로 올리면 프로젝트에 이미 있던 파일을 대신해요.', 'Uploading a file with the same name replaces the one already in the project.') }))
    return details
  }

  on(cancel, 'click', close)
  // Copying and saving leave the sheet up, as the Mac's do: the next step
  // is often another scope, or the same file again after one more change.
  on(copy, 'click', () => {
    const written = text()
    if (!written) return
    input.copy(written)
  })
  on(save, 'click', () => {
    const written = text()
    if (!written) return
    void input.save(written)
  })
  on(done, 'click', close)
  on(backdrop, 'mousedown', (event: MouseEvent) => {
    if (event.target === backdrop) close()
  })
  document.addEventListener('keydown', onKey)
  draw()
  done.focus()
}
