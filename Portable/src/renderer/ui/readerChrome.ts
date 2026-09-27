/**
 * The reader's title strip and footer.
 */
import { clear, el, on } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { platform } from '../bridge.js'
import { L } from '../../shared/lang.js'
import { withKey } from '../../shared/shortcuts.js'
import type { KeptReason } from '../../shared/api.js'

/** The strip over the pages: the title, the pen, and in a pane the ×. */
export function fillHeader(header: HTMLElement, options: {
  title: string | null
  drawing: boolean
  pane: boolean
  toggleDrawing: () => void
  close?: () => void
}) {
  clear(header)
  header.append(el('span', { class: 'reader-title', text: options.title ?? '' }))
  // The title is the handle in a pane: drag it to another zone to move it.
  header.draggable = options.pane && options.title !== null
  if (options.title === null) return
  const draw = el('button', {
    class: 'icon-button',
    title: withKey(L('쪽에 그리기', 'Draw on the page'), 'draw', platform),
    'aria-pressed': String(options.drawing),
    html: icon('pen'),
  })
  on(draw, 'click', options.toggleDrawing)
  header.append(draw)
  if (options.pane && options.close) {
    const close = el('button', {
      class: 'icon-button pane-close',
      title: L('닫기', 'Close'),
      'aria-label': L('닫기', 'Close'),
      html: icon('xmark'),
    })
    on(close, 'click', (event: MouseEvent) => {
      event.stopPropagation()
      options.close?.()
    })
    header.append(close)
  }
}

/** Why what was made here stays out of the file — one hover away. */
function keptWhy(kept: KeptReason): string {
  return {
    encrypted: L(
      '열쇠를 모르는 PDF에는 쓰지 않아요. 다른 앱에서는 이 표시가 안 보여요.',
      "Paper Time can't unlock this PDF, so it doesn't write into it. Other apps won't show these marks.",
    ),
    permissions: L(
      '이 PDF는 표시를 더하지 못하게 되어 있어요. 다른 앱에서는 이 표시가 안 보여요.',
      "This PDF doesn't allow annotations, so Paper Time doesn't write into it. Other apps won't show these marks.",
    ),
    structure: L(
      '이 PDF는 구조를 확실히 읽지 못해서 쓰지 않아요. 다른 앱에서는 이 표시가 안 보여요.',
      "Paper Time can't read this PDF's structure for certain, so it doesn't write into it. Other apps won't show these marks.",
    ),
    io: L(
      '다른 프로그램이 이 PDF를 쥐고 있어서 쓰지 못했어요. 다음에 표시를 고치면 다시 써요.',
      'Another program is holding this PDF, so Paper Time couldn\'t write into it. It tries again with your next change.',
    ),
  }[kept]
}

/** The line under the pages: where you are, the turn buttons, the zoom. */
export function fillFooter(footer: HTMLElement, options: {
  count: number
  /** The pages showing, counted from one. */
  left: number
  right: number
  turns: boolean
  zoom: number
  kept: KeptReason | null
  turn: (by: number) => void
}) {
  clear(footer)
  const { count, left, right } = options
  // The Mac's words: «14쪽 중 1쪽», «Page 1 of 14» — and a spread's two
  // pages, «14쪽 중 1–2쪽», «Pages 1–2 of 14».
  footer.append(el('span', {
    text: left === right
      ? L(`${count}쪽 중 ${left}쪽`, `Page ${left} of ${count}`)
      : L(`${count}쪽 중 ${left}–${right}쪽`, `Pages ${left}–${right} of ${count}`),
  }))
  if (options.turns) {
    const turn = (label: IconName, by: number, disabled: boolean) => {
      const button = el('button', {
        class: 'icon-button',
        title: by < 0 ? L('이전 쪽', 'Previous page') : L('다음 쪽', 'Next page'),
        html: icon(label),
      })
      button.toggleAttribute('disabled', disabled)
      on(button, 'click', () => options.turn(by))
      return button
    }
    footer.append(el('div', { class: 'toolbar-group' }, [
      turn('chevron.left', -1, left <= 1),
      turn('chevron.right', 1, right >= count),
    ]))
  }
  const zoom = el('span', { text: `${Math.round(options.zoom * 100)}%` })
  if (!options.kept) {
    footer.append(zoom)
    return
  }
  // Beside the zoom rather than between the page and the turn buttons, so
  // the footer keeps its shape. The why is one hover away; the what is on the
  // line itself, because it is the thing a person needs to know before
  // sending this file to someone.
  const kept = el('span', {
    class: 'reader-kept',
    text: L('표시는 Paper Time에만 있어요', 'Marks stay in Paper Time'),
    title: keptWhy(options.kept),
  })
  footer.append(el('span', { class: 'reader-footer-end' }, [kept, zoom]))
}
