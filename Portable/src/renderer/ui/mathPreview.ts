/**
 * The formula being typed, set as it will read, in a small card under the
 * line — `MathPreviewCard.swift`, for a textarea.
 *
 * The note here is plain text in a textarea, so a formula is a string of
 * backslashes and braces until it is read somewhere else. While the caret is
 * inside `$…$` or a `$$` block, this shows the formula set by the same
 * MathJax the text cards use, a keystroke behind the fingers, and takes
 * itself away when the caret leaves the formula or the note loses focus.
 * It never takes a key: the card is `pointer-events: none` and nothing in
 * it can be focused, so Tab still goes to the next placeholder.
 *
 * A half-typed formula does not set. Rather than an error, the card keeps
 * the last formula that did, dimmed; before anything has set it shows the
 * words as they are, in the secondary colour.
 */
import { mathSpanAt, type MathSpan } from '../../shared/noteMath.js'
import { typeset } from '../sketchMath.js'

/** The textarea's styles a measuring mirror has to share to wrap like it. */
const MIRRORED = [
  'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'fontVariant', 'fontStretch', 'fontFeatureSettings',
  'fontVariationSettings', 'lineHeight', 'letterSpacing', 'wordSpacing', 'textTransform', 'textIndent', 'textAlign',
  'whiteSpace', 'wordBreak', 'overflowWrap', 'tabSize', 'direction', 'boxSizing',
  'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
  'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth',
] as const

export interface MathPreview {
  /** Whether the card is on screen, and where and what — for a probe. */
  report(): string
  detach(): void
}

const DEBOUNCE_MS = 80

export function attachMathPreview(area: HTMLTextAreaElement): MathPreview {
  let card: HTMLDivElement | null = null
  let mirror: HTMLDivElement | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastGood: string | null = null
  let shown: { span: MathSpan; face: 'set' | 'stale' | 'raw' } | null = null

  const host = () => {
    const parent = area.parentElement
    if (parent && getComputedStyle(parent).position === 'static') parent.style.position = 'relative'
    return parent
  }

  const hide = () => {
    if (timer) clearTimeout(timer)
    timer = null
    shown = null
    card?.remove()
    card = null
  }

  /** Where a character offset falls in the textarea, in the host's coordinates. */
  const place = (offset: number): { left: number; top: number; bottom: number } | null => {
    const parent = host()
    if (!parent) return null
    if (!mirror) {
      mirror = document.createElement('div')
      mirror.className = 'math-preview-mirror'
      mirror.setAttribute('aria-hidden', 'true')
      parent.append(mirror)
    }
    const style = getComputedStyle(area)
    for (const key of MIRRORED) mirror.style[key] = style[key]
    mirror.style.left = `${area.offsetLeft}px`
    mirror.style.top = `${area.offsetTop}px`
    mirror.style.width = `${area.clientWidth + parseFloat(style.borderLeftWidth) + parseFloat(style.borderRightWidth)}px`
    const marker = document.createElement('span')
    marker.textContent = '​'
    mirror.replaceChildren(area.value.slice(0, offset), marker, area.value.slice(offset) + '​')
    const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4
    return {
      left: marker.offsetLeft,
      top: marker.offsetTop - area.scrollTop,
      bottom: marker.offsetTop - area.scrollTop + lineHeight,
    }
  }

  const show = () => {
    timer = null
    const parent = host()
    if (!parent || document.activeElement !== area || area.selectionStart !== area.selectionEnd) return hide()
    const span = mathSpanAt(area.value, area.selectionStart)
    if (!span) return hide()

    let face: 'set' | 'stale' | 'raw'
    let markup: string | null = typeset(span.latex, span.display)
    if (markup) {
      lastGood = markup
      face = 'set'
    } else if (lastGood) {
      markup = lastGood
      face = 'stale'
    } else {
      face = 'raw'
    }

    if (!card) {
      card = document.createElement('div')
      card.className = 'math-preview'
      card.setAttribute('aria-hidden', 'true')
      parent.append(card)
    }
    card.classList.toggle('stale', face === 'stale')
    card.classList.toggle('raw', face === 'raw')
    if (face === 'raw') card.textContent = span.latex
    else card.innerHTML = markup ?? ''

    const start = place(span.range.from)
    const end = place(span.range.to - 1)
    if (!start || !end) return hide()
    const room = area.clientWidth - 16
    card.style.maxWidth = `${Math.max(120, Math.min(480, room))}px`
    const width = card.offsetWidth
    const height = card.offsetHeight
    const areaTop = area.offsetTop
    const areaBottom = area.offsetTop + area.clientHeight
    let top = area.offsetTop + end.bottom + 4
    if (top + height > areaBottom) top = area.offsetTop + end.top - height - 4
    if (top < areaTop) top = areaTop + 4
    const left = Math.min(Math.max(area.offsetLeft + start.left, area.offsetLeft),
                          Math.max(area.offsetLeft, area.offsetLeft + area.clientWidth - width - 8))
    card.style.left = `${left}px`
    card.style.top = `${top}px`
    shown = { span, face }
  }

  const schedule = () => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(show, DEBOUNCE_MS)
  }

  const onSelection = () => {
    if (document.activeElement === area) schedule()
  }
  const onScroll = () => {
    if (card) show()
  }

  area.addEventListener('input', schedule)
  area.addEventListener('keyup', schedule)
  area.addEventListener('click', schedule)
  area.addEventListener('focus', schedule)
  area.addEventListener('blur', hide)
  area.addEventListener('scroll', onScroll)
  document.addEventListener('selectionchange', onSelection)

  return {
    report() {
      if (!card || !shown) return 'math preview: hidden'
      const box = card.getBoundingClientRect()
      return `math preview: visible ${shown.face} at ${Math.round(box.left)},${Math.round(box.top)} `
        + `${Math.round(box.width)}×${Math.round(box.height)} for ${JSON.stringify(shown.span.latex)}`
    },
    detach() {
      hide()
      mirror?.remove()
      mirror = null
      area.removeEventListener('input', schedule)
      area.removeEventListener('keyup', schedule)
      area.removeEventListener('click', schedule)
      area.removeEventListener('focus', schedule)
      area.removeEventListener('blur', hide)
      area.removeEventListener('scroll', onScroll)
      document.removeEventListener('selectionchange', onSelection)
    },
  }
}
