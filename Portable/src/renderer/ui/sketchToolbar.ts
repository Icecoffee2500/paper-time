/**
 * The tool rack and the style panel.
 *
 * Both float over the page rather than living in the window's toolbar: the
 * tools belong to the page you are drawing on, and reaching to the top of the
 * window for a pen breaks the line you were about to draw. The rack carries
 * its keys on the buttons, because the keys are how anyone who draws for more
 * than a minute actually picks a tool.
 *
 * The panel offers what Excalidraw puts in its side panel and nothing it does
 * not — a reader should never be choosing between twelve line widths.
 */
import { icon } from '../icons.js'
import { clear, el, on } from '../dom.js'
import { store, type SketchTool } from '../state.js'
import { SketchColor, STYLE_WIDTHS, type Dash, type Head, type TextSize } from '../../shared/sketch.js'

export const TOOLS: { tool: SketchTool; key: string; icon: string; label: string }[] = [
  { tool: 'select', key: 'V', icon: 'cursorarrow', label: 'Select' },
  { tool: 'pen', key: 'P', icon: 'pen', label: 'Pen' },
  { tool: 'highlighter', key: 'H', icon: 'highlighter', label: 'Highlighter' },
  { tool: 'eraser', key: 'E', icon: 'eraser', label: 'Eraser' },
  { tool: 'rectangle', key: 'R', icon: 'rectangle', label: 'Rectangle' },
  { tool: 'ellipse', key: 'O', icon: 'ellipse', label: 'Ellipse' },
  { tool: 'arrow', key: 'A', icon: 'arrow', label: 'Arrow' },
  { tool: 'line', key: 'L', icon: 'line', label: 'Line' },
  { tool: 'text', key: 'T', icon: 'textbox', label: 'Text' },
]

export interface SketchToolbarActions {
  setTool: (tool: SketchTool) => void
  restyle: (change: (style: import('../../shared/sketch.js').SketchStyle) => void) => void
  frameSelection: () => void
  bringToFront: () => void
  sendToBack: () => void
  deleteSelection: () => void
  duplicateSelection: () => void
}

export function buildSketchRack(actions: SketchToolbarActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'sketch-rack' })
  const buttons = new Map<SketchTool, HTMLElement>()
  for (const entry of TOOLS) {
    const button = el('button', {
      title: `${entry.label} (${entry.key})`,
      'aria-label': entry.label,
      html: `${icon(entry.icon)}<span class="key">${entry.key}</span>`,
    })
    on(button, 'click', () => actions.setTool(entry.tool))
    buttons.set(entry.tool, button)
    node.append(button)
  }

  function update() {
    for (const [tool, button] of buttons) {
      button.setAttribute('aria-pressed', String(store.sketch.tool === tool))
    }
    node.style.display = store.reader.drawing ? '' : 'none'
  }

  update()
  return { node, update }
}

export function buildStylePanel(actions: SketchToolbarActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'sketch-panel' })

  function heading(text: string) {
    return el('h4', { text })
  }

  function swatches(
    colours: SketchColor[],
    current: () => SketchColor | null,
    pick: (colour: SketchColor | null) => void,
    allowNone: boolean,
  ) {
    const row = el('div', { class: 'swatches' })
    if (allowNone) {
      const none = el('button', {
        class: 'swatch',
        title: 'No fill',
        style: 'background: transparent',
        'aria-pressed': String(current() === null),
      })
      none.innerHTML =
        '<svg viewBox="0 0 16 16" style="width:100%;height:100%"><path d="M3 13 13 3" stroke="var(--text-tertiary)" stroke-width="1.4"/></svg>'
      on(none, 'click', () => pick(null))
      row.append(none)
    }
    for (const colour of colours) {
      const chosen = current()
      const button = el('button', {
        class: 'swatch',
        style: `background: ${colour.css}`,
        'aria-pressed': String(Boolean(chosen && chosen.matches(colour))),
      })
      on(button, 'click', () => pick(colour))
      row.append(button)
    }
    return row
  }

  function choices<T>(
    options: { value: T; icon?: string; label?: string; title: string }[],
    current: () => T,
    pick: (value: T) => void,
  ) {
    const row = el('div', { class: 'choices' })
    for (const option of options) {
      const button = el('button', {
        title: option.title,
        'aria-pressed': String(current() === option.value),
        html: option.icon ? icon(option.icon) : undefined,
        text: option.icon ? undefined : option.label,
      })
      on(button, 'click', () => pick(option.value))
      row.append(button)
    }
    return row
  }

  /**
   * The panel is only up when it has something to say.
   *
   * With the select tool and nothing selected there is nothing to style, and
   * a panel covering a third of the page to offer choices about nothing is
   * the sort of clutter this app is supposed to be the alternative to. Pick a
   * tool or pick a shape and it comes back.
   */
  function shouldShow(): boolean {
    if (!store.reader.drawing) return false
    if (store.sketch.selection) return true
    return store.sketch.tool !== 'select' && store.sketch.tool !== 'eraser'
  }

  function update() {
    clear(node)
    node.style.display = shouldShow() ? '' : 'none'
    if (!shouldShow()) return
    const style = store.sketch.style

    node.append(heading('Stroke'))
    node.append(swatches(SketchColor.strokes, () => style.stroke, (colour) => {
      if (colour) actions.restyle((s) => { s.stroke = colour })
    }, false))

    node.append(heading('Fill'))
    node.append(swatches(SketchColor.fills, () => style.fill, (colour) => {
      actions.restyle((s) => { s.fill = colour })
    }, true))

    node.append(heading('Width'))
    node.append(choices<number>(
      STYLE_WIDTHS.map((width, index) => ({
        value: width,
        label: ['Thin', 'Regular', 'Bold'][index],
        title: `${['Thin', 'Regular', 'Bold'][index]} line`,
      })),
      () => style.width,
      (width) => actions.restyle((s) => { s.width = width }),
    ))

    node.append(heading('Line'))
    node.append(choices<Dash>(
      [
        { value: 'solid', icon: 'line.solid', title: 'Solid' },
        { value: 'dashed', icon: 'line.dashed', title: 'Dashed' },
        { value: 'dotted', icon: 'line.dotted', title: 'Dotted' },
      ],
      () => style.dash,
      (dash) => actions.restyle((s) => { s.dash = dash }),
    ))

    node.append(heading('Corners'))
    node.append(choices<'sharp' | 'round'>(
      [
        { value: 'sharp', icon: 'corner.sharp', title: 'Sharp corners' },
        { value: 'round', icon: 'corner.round', title: 'Rounded corners' },
      ],
      () => style.corners,
      (corners) => actions.restyle((s) => { s.corners = corners }),
    ))

    node.append(heading('Ends'))
    node.append(choices<Head>(
      [
        { value: 'none', icon: 'head.none', title: 'No head' },
        { value: 'arrow', icon: 'head.arrow', title: 'Arrowhead' },
        { value: 'triangle', icon: 'head.triangle', title: 'Solid head' },
        { value: 'bar', icon: 'head.bar', title: 'Bar' },
        { value: 'dot', icon: 'head.dot', title: 'Dot' },
      ],
      () => style.endHead,
      (head) => actions.restyle((s) => { s.endHead = head }),
    ))

    node.append(heading('Text'))
    node.append(choices<TextSize>(
      [
        { value: 'small', icon: 'text.small', title: 'Small' },
        { value: 'medium', icon: 'text.medium', title: 'Medium' },
        { value: 'large', icon: 'text.large', title: 'Large' },
      ],
      () => style.textSize,
      (size) => actions.restyle((s) => { s.textSize = size }),
    ))

    node.append(heading('Opacity'))
    const slider = el('input', {
      type: 'range', min: '20', max: '100', step: '5',
      value: String(Math.round(style.opacity * 100)),
      style: 'width: 100%',
    }) as HTMLInputElement
    on(slider, 'input', () => actions.restyle((s) => { s.opacity = Number(slider.value) / 100 }))
    node.append(slider)

    node.append(heading('Selection'))
    const row = el('div', { class: 'choices' })
    const action = (name: string, title: string, run: () => void) => {
      const button = el('button', { title, html: icon(name) })
      on(button, 'click', run)
      return button
    }
    row.append(
      action('border', 'Draw a frame round the selection (B)', actions.frameSelection),
      action('front', 'Bring to front', actions.bringToFront),
      action('back', 'Send to back', actions.sendToBack),
      action('doc.on.doc', 'Duplicate', actions.duplicateSelection),
      action('trash', 'Delete', actions.deleteSelection),
    )
    node.append(row)
  }

  update()
  return { node, update }
}
