/**
 * «Add Paper by Address…»: one field, and what came of it.
 *
 * The sheet stays up while the paper is fetched and says what it is doing,
 * because a field that closes on Return and a toast that comes ten seconds
 * later is a press that did nothing. When the address gave no paper, the
 * reason stands under the field and the field keeps what was typed, so a
 * mistyped identifier is fixed rather than typed again. The frame is the
 * name sheet's (`ask.ts`) — one shape of sheet on both desktops.
 */
import { el, on } from '../dom.js'
import { L } from '../../shared/lang.js'
import type { FetchFailure } from '../../shared/api.js'
import { readPaperAddress } from '../../shared/paperAddress.js'

/** What the sheet hands back, once. */
export type AddressOutcome =
  | { added: string }
  | { already: string }
  | { failed: FetchFailure | null; message?: string }

/**
 * Why there is no paper, in the app's words — with what the network said
 * (`detail`) when that is the whole story: a reader whose company proxy
 * turns the lookup away sees «OpenAlex HTTP 403», not «try again in a
 * moment». The Mac's `whyNoPaper` says the same.
 */
export function whyNoPaper(why: FetchFailure | null, detail?: string): string {
  const said = detail ? `(${[...detail].slice(0, 120).join('')})` : null
  switch (why) {
    case 'notAnAddress':
      return L('논문 주소가 아니에요. arXiv 번호나 주소, DOI, PDF 주소를 넣어주세요.', 'That is not a paper address. Enter an arXiv number or address, a DOI, or the address of a PDF.')
    case 'noPDF':
      return L('열린 PDF가 없는 논문이에요. 브라우저에서 받은 PDF를 Paper Time에 끌어다 놓거나, 그 PDF의 주소를 넣어주세요.', "This paper has no open PDF. Drop the PDF from your browser onto Paper Time, or enter the PDF's address.")
    case 'notFound':
      return L('이 주소에는 아무것도 없어요.', 'There is nothing at this address.')
    case 'offline':
      return [L('인터넷에 닿지 않아요.', "Paper Time can't reach the internet."), said].filter((s) => s).join(' ')
    case 'tooLarge':
      return L('파일이 너무 커요.', 'The file is too large.')
    default:
      return [
        L('받지 못했어요.', "Paper Time couldn't fetch it."), said,
        L('네트워크가 막고 있다면 PDF 주소를 직접 넣어주세요.', "If the network is in the way, enter the PDF's address instead."),
      ].filter((s) => s).join(' ')
  }
}

/**
 * Asks for an address and runs `add` on it; resolves with what came of it,
 * or null when the sheet was put away. `initial` fills the field — the
 * clipboard's address, when it holds one.
 */
export function askForAddress(add: (text: string) => Promise<AddressOutcome>, initial = ''): Promise<AddressOutcome | null> {
  return new Promise((resolve) => {
    const backdrop = el('div', { class: 'sheet-backdrop' })
    const sheet = el('div', { class: 'fb-sheet set-sheet ask-sheet ask-address', role: 'dialog', 'aria-modal': 'true' })
    const input = el('input', {
      type: 'text',
      class: 'ask-field',
      spellcheck: 'false',
      autocomplete: 'off',
      placeholder: L('arXiv 번호나 주소, DOI, PDF 주소', 'arXiv number or address, DOI, or PDF address'),
      'aria-label': L('논문 주소', 'Paper address'),
    }) as HTMLInputElement
    input.value = initial
    const hint = el('p', { class: 'set-note ask-hint', text: L(
      '예: 2512.11732, https://arxiv.org/abs/2512.11732, 10.1145/3292500.3330701, 논문 PDF의 주소. DOI는 열린 사본이 있거나 이 네트워크가 구독 중일 때 받아져요.',
      'For example 2512.11732, https://arxiv.org/abs/2512.11732, 10.1145/3292500.3330701, or the address of a PDF. A DOI is fetched when an open copy exists or this network has a subscription.',
    ) })
    const status = el('p', { class: 'set-note ask-status', role: 'status', 'aria-live': 'polite' })
    const cancel = el('button', { class: 'plain-button', text: L('취소', 'Cancel') })
    const confirm = el('button', { class: 'filled-button', text: L('더하기', 'Add') }) as HTMLButtonElement
    const foot = el('div', { class: 'set-foot' }, [el('span', { class: 'fb-spacer' }), cancel, confirm])
    sheet.append(
      el('h2', { class: 'fb-title', text: L('주소로 논문 더하기', 'Add Paper by Address') }),
      el('div', { class: 'set-body ask-body' }, [input, hint, status]),
      foot,
    )
    backdrop.append(sheet)
    document.body.append(backdrop)

    let settled = false
    let busy = false
    const finish = (value: AddressOutcome | null) => {
      if (settled) return
      settled = true
      backdrop.remove()
      resolve(value)
    }
    const text = () => input.value.trim()
    const refresh = () => {
      confirm.toggleAttribute('disabled', busy || readPaperAddress(text()) === null)
      if (!busy && text().length > 0 && readPaperAddress(text()) === null) {
        status.textContent = whyNoPaper('notAnAddress')
        status.classList.add('ask-status-failed')
      } else if (!busy) {
        status.textContent = ''
        status.classList.remove('ask-status-failed')
      }
    }
    refresh()

    const go = async () => {
      const typed = text()
      if (busy || readPaperAddress(typed) === null) return
      busy = true
      input.toggleAttribute('disabled', true)
      status.classList.remove('ask-status-failed')
      status.textContent = L('받는 중…', 'Fetching…')
      refresh()
      let outcome: AddressOutcome
      try {
        outcome = await add(typed)
      } catch (error) {
        outcome = { failed: null, message: String(error) }
      }
      if (settled) return
      busy = false
      input.toggleAttribute('disabled', false)
      if ('failed' in outcome) {
        // The reason that is ours to say, and what the network said when
        // that is the reason — not the message of a `noPDF`, which is only
        // which address was not a PDF.
        const telling = outcome.failed === null || outcome.failed === 'failed' || outcome.failed === 'offline'
        status.textContent = whyNoPaper(outcome.failed, telling ? outcome.message : undefined)
        status.classList.add('ask-status-failed')
        refresh()
        input.focus()
        return
      }
      finish(outcome)
    }

    on(input, 'input', refresh)
    on(input, 'keydown', (event: KeyboardEvent) => {
      // The window's own keys — a letter picks a drawing tool — must not see
      // what is typed here.
      event.stopPropagation()
      if (event.key === 'Enter') {
        event.preventDefault()
        void go()
      } else if (event.key === 'Escape') {
        event.preventDefault()
        finish(null)
      }
    })
    on(cancel, 'click', () => finish(null))
    on(confirm, 'click', () => void go())
    on(backdrop, 'mousedown', (event: MouseEvent) => {
      if (event.target === backdrop && !busy) finish(null)
    })
    input.focus()
    input.select()
  })
}
