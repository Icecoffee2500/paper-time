/**
 * A name, asked for in a sheet of the window's own.
 *
 * `window.prompt` is what «New Collection…» used, and Electron does not have
 * it: the call throws «prompt() is not supported», so the row did nothing at
 * all and said nothing either. The Mac asks in a small sheet — a title, one
 * field, Cancel and Create, Create greyed while the field is empty — and this
 * is that sheet, in the settings sheet's frame so the window has one shape of
 * sheet to keep the same on both desktops.
 */
import { el, on } from '../dom.js'
import { L } from '../../shared/lang.js'

export interface NameQuestion {
  title: string
  /** The field's placeholder: what kind of name it is. */
  placeholder: string
  /** The confirming button's word. */
  confirm: string
  /** What the field starts with. */
  initial?: string
}

/** Resolves with the trimmed name, or null when the sheet was put away. */
export function askForName(question: NameQuestion): Promise<string | null> {
  return new Promise((resolve) => {
    const backdrop = el('div', { class: 'sheet-backdrop' })
    const sheet = el('div', { class: 'fb-sheet set-sheet ask-sheet', role: 'dialog', 'aria-modal': 'true' })
    const input = el('input', {
      type: 'text',
      class: 'ask-field',
      spellcheck: 'false',
      placeholder: question.placeholder,
      'aria-label': question.placeholder,
    }) as HTMLInputElement
    input.value = question.initial ?? ''
    const cancel = el('button', { class: 'plain-button', text: L('취소', 'Cancel') })
    const create = el('button', { class: 'filled-button', text: question.confirm }) as HTMLButtonElement
    const foot = el('div', { class: 'set-foot' }, [el('span', { class: 'fb-spacer' }), cancel, create])
    sheet.append(
      el('h2', { class: 'fb-title', text: question.title }),
      el('div', { class: 'set-body ask-body' }, [input]),
      foot,
    )
    backdrop.append(sheet)
    document.body.append(backdrop)

    let settled = false
    const finish = (value: string | null) => {
      if (settled) return
      settled = true
      backdrop.remove()
      resolve(value)
    }
    const name = () => input.value.trim()
    const refresh = () => create.toggleAttribute('disabled', name().length === 0)
    refresh()

    on(input, 'input', refresh)
    on(input, 'keydown', (event: KeyboardEvent) => {
      // The window's own keys — a letter picks a drawing tool — must not see
      // what is typed here.
      event.stopPropagation()
      if (event.key === 'Enter' && name()) {
        event.preventDefault()
        finish(name())
      } else if (event.key === 'Escape') {
        event.preventDefault()
        finish(null)
      }
    })
    on(cancel, 'click', () => finish(null))
    on(create, 'click', () => { if (name()) finish(name()) })
    on(backdrop, 'mousedown', (event: MouseEvent) => {
      if (event.target === backdrop) finish(null)
    })
    input.focus()
    input.select()
  })
}
