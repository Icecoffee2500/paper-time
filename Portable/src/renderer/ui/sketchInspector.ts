/**
 * The Tools tab of the inspector while the pencil is out — Figma's design
 * panel, for what a reader draws on a paper. The Mac's `SketchInspector`,
 * docked, in TypeScript.
 *
 * Position, layout, appearance, fill, stroke, text: each a section, each
 * with the numbers in it, so a box can be put at exactly 40 from the top and
 * made exactly 120 wide, two things lined up on their left edges, a frame
 * given a row with a gap of 6. A change with something selected changes it
 * and sets the default for the next; with nothing selected it sets the
 * default alone.
 *
 * Everything it does to the page goes through `sketchEditor.current` — the
 * view over the page that holds the selection — and it redraws itself when
 * that view says the selection changed. Number fields commit on Enter or on
 * leaving the field, and a field being typed in is never rebuilt under the
 * hand: the rebuild waits until the field is left.
 */
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { store, type SketchTool } from '../state.js'
import {
  SketchColor,
  STYLE_WIDTHS,
  TEXT_POINTS,
  type Dash,
  type Head,
  type Kind,
  type Rect,
  type SketchElement,
  type SketchLayout,
  type SketchStyle,
  type TextAlign,
  type TextSize,
} from '../../shared/sketch.js'
import { defaultLayout, sketchEditor, type SketchAlignment, type SketchEditing } from './sketchEditing.js'
import { toolLabel } from './sketchToolbar.js'
import { L } from '../../shared/lang.js'

// MARK: - What the tools are

/** The kind of element a tool draws, when it draws one. */
function makes(tool: SketchTool): Kind | null {
  switch (tool) {
    case 'frame': return 'frame'
    case 'rectangle': return 'rectangle'
    case 'ellipse': return 'ellipse'
    case 'arrow': return 'arrow'
    case 'line': return 'line'
    case 'text': return 'text'
    default: return null
  }
}

function inkTool(tool: SketchTool): 'pen' | 'highlighter' | 'eraser' | null {
  return tool === 'pen' || tool === 'highlighter' || tool === 'eraser' ? tool : null
}

const KIND_NAME = (): Record<Kind, string> => ({
  rectangle: L('네모', 'Rectangle'),
  ellipse: L('동그라미', 'Ellipse'),
  line: L('선', 'Line'),
  arrow: L('화살표', 'Arrow'),
  text: L('글', 'Text'),
  frame: L('프레임', 'Frame'),
  group: L('묶음', 'Group'),
})

const ALIGNMENTS: { alignment: SketchAlignment; icon: string; label: () => string }[] = [
  { alignment: 'left', icon: 'align.horizontal.left', label: () => L('왼쪽 맞춤', 'Align Left') },
  { alignment: 'centerX', icon: 'align.horizontal.center', label: () => L('가로 가운데', 'Align Horizontal Centers') },
  { alignment: 'right', icon: 'align.horizontal.right', label: () => L('오른쪽 맞춤', 'Align Right') },
  { alignment: 'top', icon: 'align.vertical.top', label: () => L('위 맞춤', 'Align Top') },
  { alignment: 'centerY', icon: 'align.vertical.center', label: () => L('세로 가운데', 'Align Vertical Centers') },
  { alignment: 'bottom', icon: 'align.vertical.bottom', label: () => L('아래 맞춤', 'Align Bottom') },
]

// MARK: - Colour as a design tool writes it

/** Six hex digits: `1F5FFA`. */
export function hexOf(color: SketchColor): string {
  const byte = (v: number) => Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16).padStart(2, '0').toUpperCase()
  return `${byte(color.red)}${byte(color.green)}${byte(color.blue)}`
}

/** Reads `1F5FFA`, `#1f5ffa` or the short `F00`; the alpha is the one handed in. */
export function colorFromHex(raw: string, alpha: number): SketchColor | null {
  let text = raw.trim()
  if (text.startsWith('#')) text = text.slice(1)
  if (text.length === 3) text = [...text].map((c) => c + c).join('')
  if (!/^[0-9a-fA-F]{6}$/.test(text)) return null
  const value = parseInt(text, 16)
  return new SketchColor(((value >> 16) & 0xff) / 255, ((value >> 8) & 0xff) / 255, (value & 0xff) / 255, alpha)
}

// MARK: - The fonts this machine has

const CURATED_FAMILIES = [
  'Pretendard', 'Arial', 'Helvetica', 'Helvetica Neue', 'Georgia', 'Times New Roman', 'Courier New',
  'Verdana', 'Trebuchet MS', 'Segoe UI', 'Calibri', 'Cambria', 'Consolas', 'Noto Sans', 'Noto Serif',
  'Noto Sans KR', 'Noto Serif KR', 'Apple SD Gothic Neo', 'Malgun Gothic', 'Nanum Gothic', 'Nanum Myeongjo',
  'DejaVu Sans', 'DejaVu Serif', 'Liberation Sans', 'Liberation Serif', 'Cantarell', 'Ubuntu', 'Inter', 'Roboto',
]

let families: string[] | null = null
let familiesLoading = false
const familyListeners = new Set<() => void>()

/** Whether a family is on this machine: its text measures differently from the fallback's. */
function fontExists(family: string): boolean {
  const canvas = document.createElement('canvas')
  const context = canvas.getContext('2d')
  if (!context) return false
  const sample = 'mmmmmmmmmmlliWWQ한글'
  context.font = `16px monospace`
  const fallback = context.measureText(sample).width
  context.font = `16px "${family}", monospace`
  const measured = context.measureText(sample).width
  context.font = `16px serif`
  const serif = context.measureText(sample).width
  context.font = `16px "${family}", serif`
  const measuredSerif = context.measureText(sample).width
  return measured !== fallback || measuredSerif !== serif
}

/**
 * The families this machine has, with what the browser can tell us first and
 * the desktop's own list when it is allowed to give one. A `<select>` rather
 * than a font panel: the panel is a window, and this is a row.
 */
function fontFamilies(): string[] {
  if (families) return families
  families = CURATED_FAMILIES.filter(fontExists).sort((a, b) => a.localeCompare(b))
  if (!familiesLoading) {
    familiesLoading = true
    const query = (window as unknown as { queryLocalFonts?: () => Promise<{ family: string }[]> }).queryLocalFonts
    if (typeof query === 'function') {
      query.call(window).then((fonts) => {
        const names = new Set(families ?? [])
        for (const font of fonts) if (font.family && !font.family.startsWith('.')) names.add(font.family)
        families = [...names].sort((a, b) => a.localeCompare(b))
        for (const listener of familyListeners) listener()
      }).catch(() => {
        // Not allowed, or not there: the curated list stands.
      })
    }
  }
  return families
}

// MARK: - The panel

export interface SketchInspectorHost {
  /** Announces that the default style changed, so the rack and the page redraw. */
  changed: () => void
}

export function buildSketchInspector(host: SketchInspectorHost): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'sketch-inspector' })
  let dirty = false

  /** The one editor, when the page has one. */
  const editor = (): SketchEditing | null => sketchEditor.current

  const selected = (): SketchElement[] => editor()?.selectedElements() ?? []
  const strokeCount = (): number => editor()?.selectedStrokeCount() ?? 0
  const hasSelection = (): boolean => selected().length > 0 || strokeCount() > 0
  const selectedOne = (): SketchElement | null => {
    const chosen = selected()
    return chosen.length === 1 && strokeCount() === 0 ? chosen[0] : null
  }
  const selectedFrame = (): SketchElement | null => {
    const one = selectedOne()
    return one && one.kind === 'frame' ? one : null
  }
  /** The style the panel shows: the selection's, when there is one, and the tool's otherwise. */
  const shownStyle = (): SketchStyle => selected()[0]?.style ?? store.sketch.style

  /** The kinds the controls are about: the selection's, or the tool's. */
  function kinds(): Set<Kind> {
    if (hasSelection()) return new Set(selected().map((element) => element.kind))
    const made = makes(store.sketch.tool)
    return made ? new Set([made]) : new Set()
  }

  /**
   * Applies a style change: to the selection when there is one, and to the
   * style the next shape gets either way — choosing red with a box selected
   * means "this one red, and the next ones too".
   */
  function change(edit: (style: SketchStyle) => void) {
    edit(store.sketch.style)
    const current = editor()
    if (current && hasSelection()) current.applyStyle(edit)
    host.changed()
    update()
  }

  function edit(changeElement: (element: SketchElement) => void) {
    editor()?.editSelection(changeElement)
  }

  // ------------------------------------------------------------ pieces

  function section(title: string, content: (Node | null)[], trailing?: Node): HTMLElement {
    const head = el('div', { class: 'sk-section-head' }, [el('span', { class: 'sk-section-title', text: title })])
    if (trailing) head.append(trailing)
    return el('div', { class: 'sk-section' }, [head, ...content.filter((piece): piece is Node => piece !== null)])
  }

  function row(children: (Node | null)[], extraClass = ''): HTMLElement {
    return el('div', { class: `sk-row ${extraClass}`.trim() }, children.filter((piece): piece is Node => piece !== null))
  }

  function caption(text: string, width?: number): HTMLElement {
    const node = el('span', { class: 'sk-caption', text })
    if (width) node.style.width = `${width}px`
    return node
  }

  function divider(): HTMLElement {
    return el('div', { class: 'sk-divider' })
  }

  /** Keeps the window's keys out of a field, and lets Escape leave it. */
  function fieldKeys(input: HTMLElement, submit?: () => void) {
    on(input, 'keydown', (event: KeyboardEvent) => {
      event.stopPropagation()
      if (event.key === 'Enter' && submit) {
        event.preventDefault()
        submit()
        ;(input as HTMLInputElement).blur()
      }
      if (event.key === 'Escape') {
        event.preventDefault()
        ;(input as HTMLInputElement).blur()
      }
    })
  }

  function shownNumber(value: number): string {
    const rounded = Math.round(value * 10) / 10
    return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1)
  }

  /**
   * A number with a label in front of it, the way a design tool's panel has
   * them: type, press Return or leave, and it takes.
   */
  function numberField(options: {
    label: string
    value: number
    unit?: string
    placeholder?: string
    wide?: boolean
    disabled?: boolean
    commit: (value: number) => void
  }): HTMLElement {
    const input = el('input', {
      type: 'text',
      inputmode: 'decimal',
      spellcheck: 'false',
      placeholder: options.placeholder ?? '',
      'aria-label': options.label || undefined,
    }) as HTMLInputElement
    input.value = options.placeholder ? '' : shownNumber(options.value)
    if (options.disabled) input.disabled = true
    let taken = false
    const take = () => {
      if (taken) return
      taken = true
      const trimmed = input.value.trim().replace(',', '.')
      if (trimmed === '') {
        input.value = options.placeholder ? '' : shownNumber(options.value)
        return
      }
      const number = Number(trimmed)
      if (!Number.isFinite(number)) {
        input.value = shownNumber(options.value)
        return
      }
      options.commit(number)
    }
    on(input, 'focus', () => { taken = false })
    on(input, 'blur', take)
    fieldKeys(input, take)
    const field = el('div', { class: `sk-field ${options.wide ? 'wide' : ''}`.trim() })
    if (options.label) field.append(el('span', { class: 'sk-field-label', text: options.label }))
    field.append(input)
    if (options.unit) field.append(el('span', { class: 'sk-field-unit', text: options.unit }))
    if (options.disabled) field.classList.add('disabled')
    return field
  }

  /** Six hex digits, as a design tool shows a colour. */
  function hexField(color: SketchColor, commit: (next: SketchColor) => void): HTMLElement {
    const input = el('input', { type: 'text', spellcheck: 'false', 'aria-label': 'Hex' }) as HTMLInputElement
    input.value = hexOf(color)
    let taken = false
    const take = () => {
      if (taken) return
      taken = true
      const next = colorFromHex(input.value, color.alpha)
      if (next) commit(next)
      else input.value = hexOf(color)
    }
    on(input, 'focus', () => { taken = false })
    on(input, 'blur', take)
    fieldKeys(input, take)
    return el('div', { class: 'sk-field mono' }, [input])
  }

  /** A swatch that opens the colour picker, the hex beside it, and — for a fill — how much of it shows. */
  function colorRow(color: SketchColor, alpha: boolean, set: (next: SketchColor) => void): HTMLElement {
    const well = el('input', { type: 'color', class: 'sk-well', 'aria-label': L('색', 'Colour') }) as HTMLInputElement
    well.value = `#${hexOf(color).toLowerCase()}`
    on(well, 'change', () => {
      const next = colorFromHex(well.value, color.alpha)
      if (next) set(next)
    })
    return row([
      well,
      hexField(color, set),
      alpha
        ? numberField({
          label: '', value: Math.round(color.alpha * 100), unit: '%',
          commit: (value) => set(color.withAlpha(Math.min(Math.max(value / 100, 0.05), 1))),
        })
        : null,
    ])
  }

  function option(chosen: boolean, title: string, content: string, pick: () => void, disabled = false): HTMLElement {
    const button = el('button', { class: 'sk-option', title, 'aria-pressed': String(chosen), html: content })
    if (disabled) button.disabled = true
    on(button, 'click', pick)
    return button
  }

  function dot(color: SketchColor, chosen: boolean, title: string, pick: () => void): HTMLElement {
    const button = el('button', { class: 'sk-dot', title, 'aria-pressed': String(chosen) }, [
      el('span', { class: 'sk-dot-fill', style: `background: ${color.css}` }),
    ])
    on(button, 'click', pick)
    return button
  }

  function checkbox(label: string, checked: boolean, set: (on: boolean) => void): HTMLElement {
    const input = el('input', { type: 'checkbox' }) as HTMLInputElement
    input.checked = checked
    on(input, 'change', () => set(input.checked))
    fieldKeys(input)
    return el('label', { class: 'sk-check' }, [input, el('span', { text: label })])
  }

  function smallButton(name: string, title: string, run: () => void): HTMLElement {
    const button = el('button', { class: 'sk-small', title, html: icon(name) })
    on(button, 'click', run)
    return button
  }

  function link(text: string, run: () => void): HTMLElement {
    const button = el('button', { class: 'sk-link', text })
    on(button, 'click', run)
    return button
  }

  function dashSample(dash: Dash): string {
    const pattern = dash === 'solid' ? '' : dash === 'dashed' ? 'stroke-dasharray="4 3"' : 'stroke-dasharray="0.1 3.2"'
    return `<svg viewBox="0 0 16 8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true"><path d="M1 4h14" ${pattern}/></svg>`
  }

  function headSample(head: Head, flipped: boolean): string {
    const shaft = '<path d="M1 5h9"/>'
    const tip = {
      none: '<path d="M10 5h5"/>',
      arrow: '<path d="M10 5h5M12 2.4 15 5l-3 2.6"/>',
      triangle: '<path d="M10 5h1.5"/><path d="M11.5 2.6 15 5l-3.5 2.4Z" fill="currentColor"/>',
      bar: '<path d="M10 5h5M14.4 2v6"/>',
      dot: '<path d="M10 5h2"/><circle cx="13.6" cy="5" r="1.6" fill="currentColor" stroke="none"/>',
    }[head]
    const flip = flipped ? 'transform="scale(-1 1) translate(-16 0)"' : ''
    return `<svg viewBox="0 0 16 10" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><g ${flip}>${shaft}${tip}</g></svg>`
  }

  // ----------------------------------------------------------- sections

  function header(): HTMLElement {
    const one = selectedOne()
    const head = el('div', { class: 'sk-header' })
    if (one && one.isContainer) {
      // A frame or a group has a name, and this is where it is given.
      const input = el('input', {
        type: 'text',
        class: 'sk-name',
        placeholder: one.kind === 'frame' ? L('프레임', 'Frame') : L('묶음', 'Group'),
        spellcheck: 'false',
      }) as HTMLInputElement
      input.value = one.name ?? ''
      let taken = false
      const take = () => {
        if (taken) return
        taken = true
        const trimmed = input.value.trim()
        if ((one.name ?? '') === trimmed) return
        edit((element) => { element.name = trimmed === '' ? null : trimmed })
      }
      on(input, 'focus', () => { taken = false })
      on(input, 'blur', take)
      fieldKeys(input, take)
      head.append(input)
    } else if (hasSelection()) {
      const count = selected().length + strokeCount()
      const title = count === 1
        ? (one ? KIND_NAME()[one.kind] : L('손글씨', 'Handwriting'))
        : L(`${count}개 선택`, `${count} selected`)
      head.append(el('span', { class: 'sk-title', text: title }))
    } else {
      head.append(el('span', { class: 'sk-title', text: toolLabel(store.sketch.tool) }))
    }
    return head
  }

  function positionSection(): HTMLElement {
    const current = editor()
    const box = current?.selectionBox() ?? null
    const page = current?.pageBox() ?? null
    const onlyStrokes = selected().length === 0
    const aligns = row(ALIGNMENTS.map((entry) =>
      option(false, entry.label(), icon(entry.icon), () => current?.align(entry.alignment), onlyStrokes)), 'sk-aligns')
    const fields = box && page
      ? row([
        numberField({
          label: 'X', value: box.x - page.x, disabled: onlyStrokes,
          commit: (value) => current?.setSelectionOrigin(page.x + value, null),
        }),
        numberField({
          label: 'Y', value: (page.y + page.height) - (box.y + box.height), disabled: onlyStrokes,
          commit: (value) => current?.setSelectionOrigin(null, value),
        }),
      ])
      : null
    return section(L('위치', 'Position'), [aligns, fields])
  }

  function alignIcon(align: SketchLayout['align'], direction: SketchLayout['direction']): string {
    if (direction === 'vertical') {
      return { start: 'align.horizontal.left', center: 'align.horizontal.center', end: 'align.horizontal.right' }[align]
    }
    return { start: 'align.vertical.top', center: 'align.vertical.center', end: 'align.vertical.bottom' }[align]
  }

  /**
   * None, a column, a row. On a frame it sets the frame's layout; on
   * anything else it puts a frame with that layout round the selection, as
   * Figma's ⇧A does.
   */
  function setFlow(direction: SketchLayout['direction'] | null) {
    const current = editor()
    if (!current) return
    const frame = selectedFrame()
    if (frame) {
      if (direction) {
        current.editSelection((element) => {
          const layout = element.layout ?? defaultLayout()
          layout.direction = direction
          element.layout = layout
        })
      } else if (frame.layout) {
        current.editSelection((element) => { element.layout = null })
      }
    } else if (direction) {
      current.toggleAutoLayout()
      current.editSelection((element) => { if (element.layout) element.layout.direction = direction })
    }
  }

  function layoutSection(): HTMLElement {
    const current = editor()
    const frame = selectedFrame()
    const one = selectedOne()
    const box = current?.selectionBox() ?? null
    const pieces: (Node | null)[] = []
    if (hasSelection() && selected().length > 0) {
      const layout = frame?.layout ?? null
      pieces.push(row([
        caption(L('흐름', 'Flow'), 30),
        option(layout === null, L('없음', 'None'), icon('square.dashed'), () => setFlow(null)),
        option(layout?.direction === 'vertical', L('세로', 'Vertical'), icon('arrow.down'), () => setFlow('vertical')),
        option(layout?.direction === 'horizontal', L('가로', 'Horizontal'), icon('arrow.right'), () => setFlow('horizontal')),
      ]))
    }
    if (box && one && !one.isConnector) {
      pieces.push(row([
        numberField({ label: 'W', value: box.width, commit: (value) => current?.setSelectionSize(value, null) }),
        numberField({ label: 'H', value: box.height, commit: (value) => current?.setSelectionSize(null, value) }),
      ]))
    }
    if (frame && frame.layout) {
      const layout = frame.layout
      pieces.push(row([
        numberField({
          label: L('간격', 'Gap'), value: layout.gap, wide: true,
          commit: (value) => edit((element) => { if (element.layout) element.layout.gap = Math.max(0, value) }),
        }),
        numberField({
          label: L('여백', 'Pad'), value: layout.padding, wide: true,
          commit: (value) => edit((element) => { if (element.layout) element.layout.padding = Math.max(0, value) }),
        }),
      ]))
      const alignRow = row([
        caption(L('정렬', 'Align'), 30),
        ...(['start', 'center', 'end'] as const).map((align) =>
          option(layout.align === align, { start: L('시작', 'Start'), center: L('가운데', 'Center'), end: L('끝', 'End') }[align],
            icon(alignIcon(align, layout.direction)),
            () => edit((element) => { if (element.layout) element.layout.align = align }))),
        el('span', { class: 'sk-spacer' }),
        checkbox(L('내용에 맞춤', 'Hug'), layout.hugs, (on) => edit((element) => { if (element.layout) element.layout.hugs = on })),
      ])
      pieces.push(alignRow)
    }
    if (frame) {
      pieces.push(checkbox(L('넘친 내용 숨기기', 'Clip content'), frame.clips, (on) => edit((element) => { element.clips = on })))
    }
    return section(L('레이아웃', 'Layout'), pieces)
  }

  /** The corner radius a rounded box takes when none is set — the renderer's rule. */
  function automaticRadius(element: SketchElement | null): number {
    if (!element) return 0
    if (element.style.corners !== 'round') return 0
    const box = element.rect
    return Math.min(Math.min(box.width, box.height) * 0.22, 10)
  }

  function appearanceSection(about: Set<Kind>, hasBoxes: boolean): HTMLElement {
    const style = shownStyle()
    const one = selectedOne()
    const boxes = hasBoxes || about.size === 0
    const pieces: (Node | null)[] = [row([
      numberField({
        label: L('투명도', 'Opacity'), value: Math.round(style.opacity * 100), unit: '%', wide: true,
        commit: (value) => change((s) => { s.opacity = Math.min(Math.max(value / 100, 0.05), 1) }),
      }),
      boxes
        ? numberField({
          label: L('모서리', 'Radius'),
          value: style.cornerRadius ?? automaticRadius(one),
          placeholder: style.cornerRadius === null ? L('자동', 'Auto') : undefined,
          wide: true,
          commit: (value) => change((s) => { s.cornerRadius = Math.max(0, value) }),
        })
        : null,
    ])]
    if (boxes && style.cornerRadius !== null) {
      pieces.push(link(L('모서리 자동으로', 'Automatic corners'), () => change((s) => { s.cornerRadius = null })))
    }
    return section(L('외형', 'Appearance'), pieces)
  }

  function fillSection(): HTMLElement {
    const style = shownStyle()
    const trailing = style.fill === null
      ? smallButton('plus', L('채우기 더하기', 'Add fill'), () => change((s) => { s.fill = SketchColor.paleYellow }))
      : smallButton('minus', L('채우기 빼기', 'Remove fill'), () => change((s) => { s.fill = null }))
    const pieces: (Node | null)[] = []
    if (style.fill) pieces.push(colorRow(style.fill, true, (color) => change((s) => { s.fill = color })))
    pieces.push(row([
      option(style.fill === null, L('채우기 없음', 'No fill'), icon('slash.circle'), () => change((s) => { s.fill = null })),
      ...SketchColor.fills.map((fill) =>
        dot(fill.flattenedOnWhite, Boolean(style.fill && style.fill.matches(fill)), hexOf(fill), () => change((s) => { s.fill = fill }))),
    ], 'sk-swatches'))
    return section(L('채우기', 'Fill'), pieces, trailing)
  }

  /**
   * Whether the selection's edge is drawn: `border` for text, the other way
   * round for everything else, and both at once when both are chosen.
   */
  function strokeOn(about: Set<Kind>): boolean {
    const style = shownStyle()
    if (about.size === 1 && about.has('text')) return style.border
    if (about.has('text') && selected().length === about.size) return style.border || !style.strokeHidden
    return !style.strokeHidden
  }

  function strokeSection(about: Set<Kind>, hasConnectors: boolean): HTMLElement {
    const style = shownStyle()
    const on = strokeOn(about) || hasConnectors
    const setStroke = (wanted: boolean) => change((s) => {
      s.border = wanted
      s.strokeHidden = !wanted
    })
    const trailing = hasConnectors
      ? undefined
      : smallButton(on ? 'minus' : 'plus', on ? L('외곽선 빼기', 'Remove stroke') : L('외곽선 더하기', 'Add stroke'), () => setStroke(!on))
    const pieces: (Node | null)[] = []
    if (on) {
      pieces.push(colorRow(style.stroke, false, (color) => change((s) => { s.stroke = color })))
      pieces.push(row(SketchColor.strokes.map((color) =>
        dot(color, color.matches(style.stroke), hexOf(color), () => change((s) => { s.stroke = color }))), 'sk-swatches'))
      pieces.push(row([
        numberField({
          label: L('굵기', 'Width'), value: style.width, wide: true,
          commit: (value) => change((s) => { s.width = Math.min(Math.max(value, 0.5), 20) }),
        }),
        row((['solid', 'dashed', 'dotted'] as Dash[]).map((dash) =>
          option(style.dash === dash, { solid: L('실선', 'Solid'), dashed: L('파선', 'Dashed'), dotted: L('점선', 'Dotted') }[dash],
            dashSample(dash), () => change((s) => { s.dash = dash }))), 'sk-tight'),
      ]))
      if (hasConnectors) {
        const heads = (chosen: Head, flipped: boolean, pick: (head: Head) => void) =>
          row((['none', 'arrow', 'triangle', 'bar', 'dot'] as Head[]).map((head) =>
            option(chosen === head, { none: L('없음', 'No head'), arrow: L('화살촉', 'Arrowhead'), triangle: L('채운 화살촉', 'Solid head'), bar: L('막대', 'Bar'), dot: L('점', 'Dot') }[head],
              headSample(head, flipped), () => pick(head))), 'sk-tight')
        pieces.push(heads(style.startHead, true, (head) => change((s) => { s.startHead = head })))
        pieces.push(heads(style.endHead, false, (head) => change((s) => { s.endHead = head })))
      }
    }
    return section(L('외곽선', 'Stroke'), pieces, trailing)
  }

  function fontMenu(chosen: string | null): HTMLElement {
    const select = el('select', { class: 'sk-select', 'aria-label': L('글꼴', 'Font') }) as HTMLSelectElement
    select.append(el('option', { value: '', text: L('시스템 글꼴', 'System Font') }))
    const names = fontFamilies()
    if (chosen && !names.includes(chosen)) select.append(el('option', { value: chosen, text: chosen }))
    for (const family of names) select.append(el('option', { value: family, text: family }))
    select.value = chosen ?? ''
    on(select, 'change', () => change((s) => { s.fontName = select.value === '' ? null : select.value }))
    fieldKeys(select)
    return select
  }

  function textSection(): HTMLElement {
    const style = shownStyle()
    const one = selectedOne()
    const sizes: TextSize[] = ['small', 'medium', 'large']
    const aligns: TextAlign[] = ['left', 'center', 'right']
    const pieces: (Node | null)[] = [
      fontMenu(style.fontName),
      row([
        numberField({
          label: L('크기', 'Size'), value: style.points, wide: true,
          commit: (value) => change((s) => { s.fontSize = Math.min(Math.max(value, 4), 96) }),
        }),
        row(sizes.map((size) =>
          option(style.fontSize === null && style.textSize === size,
            { small: L('작게', 'Small'), medium: L('보통', 'Medium'), large: L('크게', 'Large') }[size],
            `<span class="sk-a" style="font-size:${{ small: 9, medium: 12, large: 15 }[size]}px">A</span>`,
            () => change((s) => { s.textSize = size; s.fontSize = null }))), 'sk-tight'),
      ]),
    ]
    const alignRow = row(aligns.map((align) =>
      option(style.textAlign === align,
        { left: L('왼쪽 맞춤', 'Align Left'), center: L('가운데 맞춤', 'Align Center'), right: L('오른쪽 맞춤', 'Align Right') }[align],
        icon({ left: 'text.alignleft', center: 'text.aligncenter', right: 'text.alignright' }[align]),
        () => change((s) => { s.textAlign = align }))))
    if (one && one.kind === 'text') {
      // As wide as its words, or as wide as it was made.
      alignRow.append(
        el('span', { class: 'sk-spacer' }),
        option(one.sizing === 'autoWidth', L('글 너비에 맞춤', 'Auto width'), icon('arrow.left.and.right.text.vertical'),
          () => edit((element) => { element.textSizing = 'autoWidth' })),
        option(one.sizing === 'autoHeight', L('너비는 그대로, 높이만 맞춤', 'Auto height'), icon('arrow.up.and.down.text.horizontal'),
          () => edit((element) => { element.textSizing = 'autoHeight' })),
      )
    }
    pieces.push(alignRow)
    return section(L('글', 'Text'), pieces)
  }

  /** The pen's, the highlighter's and the eraser's own controls. */
  function inkSection(ink: 'pen' | 'highlighter' | 'eraser'): HTMLElement {
    const style = store.sketch.style
    const pieces: (Node | null)[] = []
    const widths = (sample: (width: number) => string) => row(STYLE_WIDTHS.map((width, index) =>
      option(Math.abs(style.width - width) < 0.01,
        [L('가는 선', 'Thin line'), L('보통 선', 'Regular line'), L('굵은 선', 'Bold line')][index],
        sample(width), () => change((s) => { s.width = width }))), 'sk-tight')
    switch (ink) {
      case 'pen':
        pieces.push(caption(L('색', 'Colour')))
        pieces.push(row(SketchColor.strokes.map((color) =>
          dot(color, color.matches(style.stroke), hexOf(color), () => change((s) => { s.stroke = color }))), 'sk-swatches'))
        pieces.push(caption(L('굵기', 'Width')))
        pieces.push(widths((width) =>
          `<span class="sk-pen-dot" style="width:${3 + width * 1.6}px;height:${3 + width * 1.6}px"></span>`))
        break
      case 'highlighter':
        pieces.push(caption(L('색', 'Colour')))
        pieces.push(row(SketchColor.fills.map((fill) =>
          dot(fill.flattenedOnWhite, Boolean(style.fill && style.fill.matches(fill)), hexOf(fill), () => change((s) => { s.fill = fill }))), 'sk-swatches'))
        pieces.push(caption(L('굵기', 'Width')))
        pieces.push(widths((width) =>
          `<span class="sk-marker-bar" style="height:${3 + width * 1.4}px"></span>`))
        break
      case 'eraser':
        pieces.push(el('p', { class: 'sk-note', text: L('지우개는 선과 모양을 통째로 지워요.', 'The eraser removes a stroke or shape whole.') }))
        break
    }
    return section(toolLabel(ink), pieces)
  }

  function actions(): HTMLElement {
    const current = editor()
    const chosen = selected()
    const none = chosen.length === 0
    const containers = chosen.some((element) => element.isContainer)
    const button = (name: string, title: string, run: () => void, disabled = false) => {
      const node = el('button', { class: 'sk-action', title, html: icon(name) })
      node.disabled = disabled
      on(node, 'click', run)
      return node
    }
    return el('div', { class: 'sk-actions' }, [
      button('rectangle.3.group', L('묶기 (⌘G)', 'Group (⌘G)'), () => current?.groupSelection(), none),
      button('rectangle.3.group.bubble', L('묶음 풀기 (⇧⌘G)', 'Ungroup (⇧⌘G)'), () => current?.ungroupSelection(), !containers),
      button('number.square', L('프레임으로 감싸기 (⌥⌘G)', 'Frame Selection (⌥⌘G)'), () => current?.frameSelection()),
      button('rectangle.split.3x1', L('오토 레이아웃 (⇧A)', 'Auto Layout (⇧A)'), () => current?.toggleAutoLayout(), none),
      el('span', { class: 'sk-spacer' }),
      button('plus.square.on.square', L('복제 (⌘D)', 'Duplicate (⌘D)'), () => current?.duplicateSelection(), none),
      button('square.3.layers.3d.top.filled', L('맨 앞으로 (⇧⌘])', 'Bring to Front (⇧⌘])'), () => current?.bringSelectionToFront(), none),
      button('square.3.layers.3d.bottom.filled', L('맨 뒤로 (⇧⌘[)', 'Send to Back (⇧⌘[)'), () => current?.sendSelectionToBack(), none),
      button('trash', L('지우기 (⌫)', 'Delete (⌫)'), () => current?.deleteSelection()),
    ])
  }

  // -------------------------------------------------------------- render

  function render() {
    clear(node)
    if (!store.reader.drawing) {
      node.append(el('div', { class: 'empty' }, [
        el('span', { html: icon('pen') }),
        el('h2', { text: L('그리기', 'Drawing') }),
        el('p', { text: L('펜을 들면 여기서 도구와 모양을 고쳐요.', 'Pick up the pen to edit the tools and shapes here.') }),
      ]))
      return
    }
    const about = kinds()
    const selectionOn = hasSelection()
    const ink = inkTool(store.sketch.tool)
    const hasBoxes = ['rectangle', 'ellipse', 'text', 'frame'].some((kind) => about.has(kind as Kind))
    const hasConnectors = about.has('arrow') || about.has('line')
    const hasFill = hasBoxes || about.has('group') || about.size === 0
    const hasWords = about.has('text') || selected().some((element) => element.text !== '') || (!selectionOn && store.sketch.tool === 'text')
    const onlyStrokes = selectionOn && selected().length === 0

    node.append(header(), divider())
    const body = el('div', { class: 'sk-body' })
    if (ink && !selectionOn) {
      body.append(inkSection(ink))
    } else if (selectionOn || makes(store.sketch.tool)) {
      if (selectionOn) body.append(positionSection(), divider())
      body.append(layoutSection(), divider(), appearanceSection(about, hasBoxes))
      if (hasFill) body.append(divider(), fillSection())
      if (!onlyStrokes) body.append(divider(), strokeSection(about, hasConnectors))
      if (hasWords) body.append(divider(), textSection())
    } else {
      body.append(el('p', { class: 'sk-note', text: L('무엇을 고르거나 그리면 여기서 고칠 수 있어요.', 'Select or draw something to edit it here.') }))
    }
    node.append(body)
    if (selectionOn) node.append(divider(), actions())
  }

  /** Rebuilds, unless a field is being typed in — then it waits for the field to be left. */
  function update() {
    const active = document.activeElement
    if (active && node.contains(active) && (active.tagName === 'INPUT' || active.tagName === 'SELECT')) {
      dirty = true
      return
    }
    dirty = false
    render()
  }

  on(node, 'focusout', () => {
    if (dirty) setTimeout(() => { if (dirty) update() }, 0)
  })
  sketchEditor.listeners.add(update)
  familyListeners.add(update)

  update()
  return { node, update }
}
