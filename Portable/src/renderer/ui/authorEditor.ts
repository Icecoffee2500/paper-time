/**
 * The byline, and the way to correct it — the Mac's `AuthorListEditor`.
 *
 * Folded until asked for: two fields per author is forty controls on a paper
 * with twenty of them, and the byline reads fine as text. Open, each author
 * is Given and Family, moved up or down or taken out; «Add Author» adds one
 * and «Paste Names» replaces the whole list from a block copied off an
 * abstract page or a BibTeX entry — the most common correction after the
 * title, and one there was no way to make here.
 */
import { el, on } from '../dom.js'
import { icon } from '../icons.js'
import { L } from '../../shared/lang.js'
import { fullName, parseNames, type CSLName } from '../../shared/model.js'

export function buildAuthorEditor(options: {
  title: string
  authors: CSLName[]
  /** The list as it now stands — into the draft, saved with the rest. */
  changed: (authors: CSLName[]) => void
  /** What is on the clipboard, for «Paste Names». */
  paste: () => Promise<string>
  /** A name in the byline pressed: that author's shelf. */
  openAuthor?: (name: CSLName) => void
}): HTMLElement {
  let authors = options.authors.map((one) => ({ ...one }))
  let editing = false
  const section = el('div', { class: 'insp-section' })
  const draw = () => {
    section.replaceChildren()
    section.append(el('div', { class: 'insp-section-title', text: options.title }))
    const toggle = el('button', { class: 'author-byline', 'aria-expanded': String(editing) })
    const byline = authors.length === 0 ? L('저자 없음', 'No authors') : authors.map(fullName).join(', ')
    toggle.append(
      el('span', { class: 'fold-chevron', html: icon('chevron.right') }),
      el('span', { class: 'author-lines' }, [
        el('span', { class: authors.length === 0 ? 'author-names empty' : 'author-names', text: byline }),
        el('span', { class: 'author-count', text: authors.length === 1 ? L('저자 1명', '1 author') : L(`저자 ${authors.length}명`, `${authors.length} authors`) }),
      ]),
    )
    on(toggle, 'click', () => {
      editing = !editing
      draw()
    })
    section.append(toggle)
    if (!editing) {
      // Closed, each name is still a way to that author's shelf.
      if (options.openAuthor && authors.length > 0) {
        const chips = el('div', { class: 'chip-row' })
        for (const name of authors) {
          const chip = el('button', { class: 'chip', text: fullName(name) })
          on(chip, 'click', () => options.openAuthor?.(name))
          chips.append(chip)
        }
        section.append(chips)
      }
      return
    }
    const commit = () => options.changed(authors.map((one) => ({ ...one })))
    authors.forEach((name, index) => {
      const field = (key: 'given' | 'family', placeholder: string) => {
        const input = el('input', { type: 'text', class: 'author-field', placeholder, 'aria-label': placeholder }) as HTMLInputElement
        input.value = name[key] ?? ''
        on(input, 'input', () => {
          if (input.value) authors[index][key] = input.value
          else delete authors[index][key]
          commit()
        })
        on(input, 'keydown', (event: KeyboardEvent) => event.stopPropagation())
        return input
      }
      const move = (by: number, glyph: string, label: string) => {
        const button = el('button', { class: 'author-move', title: label, 'aria-label': label, html: icon(glyph as never) }) as HTMLButtonElement
        const to = index + by
        button.disabled = to < 0 || to >= authors.length
        on(button, 'click', () => {
          const [taken] = authors.splice(index, 1)
          authors.splice(to, 0, taken)
          commit()
          draw()
        })
        return button
      }
      const remove = el('button', { class: 'author-move', title: L('빼기', 'Remove'), 'aria-label': L('빼기', 'Remove'), html: icon('xmark') })
      on(remove, 'click', () => {
        authors.splice(index, 1)
        commit()
        draw()
      })
      section.append(el('div', { class: 'author-row' }, [
        field('given', L('이름', 'Given')),
        field('family', L('성', 'Family')),
        move(-1, 'chevron.up', L('위로', 'Move Up')),
        move(1, 'chevron.down', L('아래로', 'Move Down')),
        remove,
      ]))
    })
    const add = el('button', { class: 'plain-button', text: L('저자 더하기', 'Add Author') })
    on(add, 'click', () => {
      authors.push({})
      commit()
      draw()
      section.querySelectorAll<HTMLInputElement>('.author-field')[authors.length * 2 - 2]?.focus()
    })
    const pasteButton = el('button', { class: 'plain-button', text: L('이름 붙여넣기', 'Paste Names') })
    on(pasteButton, 'click', () => {
      void options.paste().then((text) => {
        const names = parseNames(text)
        if (names.length === 0) return
        authors = names
        commit()
        draw()
      })
    })
    section.append(el('div', { class: 'chip-row author-actions' }, [add, pasteButton]))
  }
  draw()
  return section
}
