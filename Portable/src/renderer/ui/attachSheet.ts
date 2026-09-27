/**
 * «다른 논문에 붙이기…» — the Mac's `AttachSheet`.
 *
 * A search, not a list: the paper wanted is a supplement's parent, as likely
 * to be at Z as at A, and it is found from any part of its title or its
 * file's name (`shared/attachmentSearch.ts`). The top hit is chosen as it is
 * typed, so the sheet is answered by typing and pressing Return; ↑/↓ move
 * the choice, a double-click takes it.
 */
import { clear, el, on } from '../dom.js'
import { iconNode } from '../icons.js'
import { L } from '../../shared/lang.js'
import { attachCandidate, rankAttachments, suggestedParent, type AttachCandidate } from '../../shared/attachmentSearch.js'

export interface AttachSheetInput {
  /** The paper being attached: what it shows, and the full title and file
   *  name the suggestion reads. */
  child: { id: string; title: string; fullTitle?: string; fileName?: string }
  /** Every paper it could go under: standing on its own, and not itself. */
  candidates: { id: string; title: string; fileName: string }[]
  attach: (parentID: string) => void
}

let open = false

export function showAttachSheet(input: AttachSheetInput) {
  if (open) return
  open = true
  const shelf: AttachCandidate[] = input.candidates.map((one) => attachCandidate(one.id, one.title, one.fileName))

  const backdrop = el('div', { class: 'sheet-backdrop' })
  const sheet = el('div', { class: 'fb-sheet attach-sheet', role: 'dialog', 'aria-modal': 'true' })
  const clip = iconNode('paperclip')
  const header = el('div', { class: 'attach-head' }, [
    el('div', { class: 'attach-title', text: L('어느 논문에 붙일까요?', 'Attach to Which Paper?') }),
    el('div', { class: 'attach-child' }, [
      ...(clip ? [clip] : []),
      el('span', { class: 'attach-child-title', text: input.child.title }),
    ]),
  ])
  const field = el('input', {
    type: 'text',
    class: 'attach-field',
    spellcheck: 'false',
    placeholder: L('제목이나 파일 이름으로 찾기', 'Search titles and file names'),
    'aria-label': L('제목이나 파일 이름으로 찾기', 'Search titles and file names'),
  }) as HTMLInputElement
  const list = el('div', { class: 'attach-list', role: 'listbox' })
  const cancel = el('button', { class: 'plain-button', text: L('취소', 'Cancel') })
  const confirm = el('button', { class: 'filled-button', text: L('붙이기', 'Attach') }) as HTMLButtonElement
  sheet.append(
    header,
    el('div', { class: 'attach-search' }, [field]),
    list,
    el('div', { class: 'set-foot attach-foot' }, [el('span', { class: 'fb-spacer' }), cancel, confirm]),
  )
  backdrop.append(sheet)
  document.body.append(backdrop)

  let ranked: AttachCandidate[] = []
  // The paper it looks like it belongs to, for a document that says it is
  // supplementary — chosen before anything is typed, under its own heading.
  const suggested = suggestedParent(
    { id: input.child.id, title: input.child.fullTitle ?? '', fileName: input.child.fileName ?? '' },
    input.candidates,
  )
  let chosen: string | null = suggested

  const close = () => {
    backdrop.remove()
    open = false
  }
  const take = () => {
    if (!chosen) return
    const parent = chosen
    close()
    input.attach(parent)
  }
  const mark = () => {
    for (const row of list.querySelectorAll<HTMLElement>('.attach-row')) {
      row.setAttribute('aria-selected', String(row.dataset.id === chosen))
    }
    confirm.disabled = chosen === null
    list.querySelector('.attach-row[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' })
  }
  const draw = () => {
    ranked = rankAttachments(shelf, field.value)
    const typed = field.value.trim().length > 0
    // The top hit once something is typed; before that the suggestion, or
    // nothing — a Return pressed at once must not attach to the first A–Z.
    chosen = typed ? ranked[0]?.id ?? null : suggested
    clear(list)
    if (ranked.length === 0) {
      // Not «no papers»: the library is full of them and none answers to this.
      list.append(el('div', { class: 'attach-empty' }, [
        el('div', { class: 'attach-empty-title', text: L('찾는 논문이 없어요', 'No Paper Matches') }),
        el('div', { text: L('제목의 다른 부분이나 파일 이름으로 찾아보세요.', 'Try another part of the title, or the file name.') }),
      ]))
    }
    // Every paper: a list that stops somewhere cannot say that it did, and
    // the one wanted is as likely to be at Z as at A.
    const row = (candidate: AttachCandidate) => {
      const node = el('div', { class: 'attach-row', role: 'option', 'data-id': candidate.id }, [
        el('div', { class: 'attach-row-title', text: candidate.title }),
        el('div', { class: 'attach-row-file', text: candidate.fileName }),
      ])
      on(node, 'click', () => {
        chosen = candidate.id
        mark()
      })
      on(node, 'dblclick', () => {
        chosen = candidate.id
        take()
      })
      return node
    }
    const offered = !typed && suggested ? ranked.find((one) => one.id === suggested) : undefined
    if (offered) {
      list.append(el('div', { class: 'attach-heading', text: L('이 논문 같아요', 'Looks Like the One') }), row(offered))
      list.append(el('div', { class: 'attach-heading', text: L('모든 논문', 'All Papers') }))
      for (const candidate of ranked) if (candidate.id !== suggested) list.append(row(candidate))
    } else {
      for (const candidate of ranked) list.append(row(candidate))
    }
    mark()
  }

  on(field, 'input', draw)
  on(field, 'keydown', (event: KeyboardEvent) => {
    event.stopPropagation()
    if (event.key === 'Enter') {
      event.preventDefault()
      take()
    } else if (event.key === 'Escape') {
      event.preventDefault()
      close()
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      const at = ranked.findIndex((one) => one.id === chosen)
      const next = ranked[Math.max(0, Math.min(ranked.length - 1, at + (event.key === 'ArrowDown' ? 1 : -1)))]
      if (next) {
        chosen = next.id
        mark()
      }
    }
  })
  on(cancel, 'click', close)
  on(confirm, 'click', take)
  // No closing on a press outside, as the Mac's sheet does not: a sheet
  // chosen in by hand is left by Cancel or Escape.
  draw()
  field.focus()
}
