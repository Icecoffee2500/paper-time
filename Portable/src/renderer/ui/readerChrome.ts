/**
 * The reader's title strip and footer.
 */
import { clear, el, on } from '../dom.js'
import { icon, type IconName } from '../icons.js'
import { platform } from '../bridge.js'
import { L } from '../../shared/lang.js'
import { withKey } from '../../shared/shortcuts.js'
import type { KeptReason, SaveState } from '../../shared/api.js'

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
  // A pane's strip is a handle and a close box, as the Mac's is; the pen is
  // in the reader's own toolbar and on ⇧⌘D.
  if (options.pane) {
    if (options.close) header.append(closeButton(options.close))
    return
  }
  const draw = el('button', {
    class: 'icon-button',
    title: withKey(L('쪽에 그리기', 'Draw on the page'), 'draw', platform),
    'aria-pressed': String(options.drawing),
    html: icon('pen'),
  })
  on(draw, 'click', options.toggleDrawing)
  header.append(draw)
}

function closeButton(close: () => void): HTMLElement {
  const button = el('button', {
    class: 'icon-button pane-close',
    title: L('닫기', 'Close'),
    'aria-label': L('닫기', 'Close'),
    html: icon('xmark'),
  })
  on(button, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    close()
  })
  return button
}

/** Why a file would not take the marks, in the Mac's words: that they are
 *  safe, that the file is as it was, and what about the file stopped it
 *  (`ReaderScreen.keptExplanation`). */
export function keptWhy(kept: KeptReason): string {
  return {
    encrypted: L(
      '이 PDF는 잠겨 있어서 표시를 파일에 넣지 않았어요. 표시는 Paper Time에 그대로 있어요.',
      'This PDF is locked, so the marks stay in Paper Time. The file is unchanged.',
    ),
    permissions: L(
      '이 PDF는 주석을 허락하지 않아요. 파일은 그대로 두고, 표시는 Paper Time에 두었어요.',
      "This PDF doesn't allow annotations. The marks stay in Paper Time, and the file is unchanged.",
    ),
    structure: L(
      '이 PDF는 짜임이 흔하지 않아서, 표시를 넣으면 파일이 상할 수 있어요. 파일은 그대로 두고, 표시는 Paper Time에 두었어요.',
      'This PDF is built in an unusual way, and writing into it could damage it. The marks stay in Paper Time, and the file is unchanged.',
    ),
    unconfirmed: L(
      '표시를 넣고 다시 읽어 보니 맞지 않았어요. 파일은 그대로 두고, 표시는 Paper Time에 두었어요.',
      "The marks didn't read back as written. They stay in Paper Time, and the file is unchanged.",
    ),
    // Windows only, where another program can hold a file open.
    io: L(
      '다른 프로그램이 이 PDF를 쥐고 있어서 쓰지 못했어요. 다음에 표시를 고치면 다시 써요.',
      "Another program is holding this PDF, so Paper Time couldn't write into it. It tries again with your next change.",
    ),
  }[kept]
}

/**
 * The line under the pages, as the Mac has it: where you are — in a book,
 * with how far through the paper the spread is — and at the other end what
 * the file is doing with what was made here, and whether another app's ink
 * is on it. Floating over the foot of the page rather than a strip of its
 * own.
 */
export function fillFooter(footer: HTMLElement, options: {
  count: number
  /** The pages showing, counted from one. */
  left: number
  right: number
  book: boolean
  turns: boolean
  kept: KeptReason | null
  saveState: SaveState
  foreignInk: boolean
  turn: (by: number) => void
}) {
  clear(footer)
  const { count, left, right } = options
  // The Mac's words: «14쪽 중 1쪽», «Page 1 of 14» — and a spread's two
  // pages, «14쪽 중 1–2쪽», «Pages 1–2 of 14».
  footer.append(el('span', {
    class: 'reader-position',
    text: left === right
      ? L(`${count}쪽 중 ${left}쪽`, `Page ${left} of ${count}`)
      : L(`${count}쪽 중 ${left}–${right}쪽`, `Pages ${left}–${right} of ${count}`),
  }))
  if (options.book) {
    const progress = el('progress', { class: 'reader-progress', max: String(Math.max(count, 1)), value: String(right) })
    footer.append(progress)
  }
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
  const end = el('span', { class: 'reader-footer-end' })
  if (options.kept) {
    // Not a warning: nothing was lost. The marks are on screen, in the
    // journal and the sidecars; only this file said no.
    end.append(el('span', {
      class: 'reader-kept',
      text: L('표시는 Paper Time에 있어요', 'Marks stay in Paper Time'),
      title: keptWhy(options.kept),
    }))
  } else if (options.saveState === 'pending') {
    end.append(el('span', { class: 'reader-kept', text: L('저장 전', 'Unsaved changes') }))
  } else if (options.saveState === 'saving') {
    end.append(el('span', { class: 'spinner reader-saving', title: L('저장하는 중', 'Saving') }))
  }
  if (options.foreignInk) {
    end.append(el('span', {
      class: 'reader-kept',
      text: L('다른 앱의 잉크가 있어요', 'Contains ink from another app'),
      title: L('이 PDF에는 들여올 때부터 손으로 그린 잉크가 있었어요. 여기서 그리면 그 위에 덮어써요.',
        'This PDF already had freehand ink when it arrived. Drawing here replaces it.'),
    }))
  }
  if (end.childElementCount > 0) footer.append(end)
}
