/**
 * The tool rack while the pencil is out, laid out the way Figma's is and the
 * Mac's `SketchToolbar` is: one button for each kind of tool — select, frame,
 * a shape, the pen, text — and the kinds that come in several (the shapes;
 * the pen, the highlighter and the eraser) behind a chevron beside their
 * button. The button shows the member last used, so the rack stays five
 * buttons wide however many tools it holds. Then a divider, undo and redo.
 *
 * It floats over the page rather than living in the window's toolbar: the
 * tools belong to the page you are drawing on, and reaching to the top of the
 * window for a pen breaks the line you were about to draw.
 *
 * There is no Done button. The pencil goes away with Escape, or with the pen
 * on the paper's title row. The chosen tool is a filled square with its icon
 * in white; the icons are drawn in Figma's own line weight (`figmaIcon`).
 * Every tool keeps its one-letter key, listed beside its name in the menu.
 */
import { figmaIcon, icon } from '../icons.js'
import { clear, el, on, place } from '../dom.js'
import { INK_TOOLS, SHAPE_TOOLS, store, type SketchTool } from '../state.js'
import { L } from '../../shared/lang.js'

// The labels are getters so they are read when a button is built, not when
// the module loads — the language is settled before anything draws, and this
// keeps that true whatever order the modules happen to load in.
export const TOOLS: { tool: SketchTool; key: string; label: string }[] = [
  { tool: 'select', key: 'V', get label() { return L('선택', 'Select') } },
  { tool: 'frame', key: 'F', get label() { return L('프레임', 'Frame') } },
  { tool: 'rectangle', key: 'R', get label() { return L('네모', 'Rectangle') } },
  { tool: 'ellipse', key: 'O', get label() { return L('동그라미', 'Ellipse') } },
  { tool: 'line', key: 'L', get label() { return L('선', 'Line') } },
  { tool: 'arrow', key: 'A', get label() { return L('화살표', 'Arrow') } },
  { tool: 'pen', key: 'P', get label() { return L('펜', 'Pen') } },
  { tool: 'highlighter', key: 'H', get label() { return L('형광펜', 'Highlighter') } },
  { tool: 'eraser', key: 'E', get label() { return L('지우개', 'Eraser') } },
  { tool: 'text', key: 'T', get label() { return L('글', 'Text') } },
]

export function toolEntry(tool: SketchTool) {
  return TOOLS.find((entry) => entry.tool === tool)!
}

/** What a tool is called, in the language the window is in. */
export function toolLabel(tool: SketchTool): string {
  return toolEntry(tool).label
}

export interface SketchRackActions {
  setTool: (tool: SketchTool) => void
  undo: () => void
  redo: () => void
}

export function buildSketchRack(actions: SketchRackActions): { node: HTMLElement; update: () => void } {
  const node = el('div', { class: 'sketch-rack', role: 'toolbar' })

  function toolButton(tool: SketchTool): HTMLElement {
    const entry = toolEntry(tool)
    const button = el('button', {
      class: 'sketch-tool',
      title: `${entry.label} (${entry.key})`,
      'aria-label': entry.label,
      'data-tool': tool,
      html: figmaIcon(tool),
    })
    on(button, 'click', () => actions.setTool(tool))
    return button
  }

  /** A button for the member last used, and beside it a chevron that lists the group. */
  function grouped(tools: SketchTool[], shown: SketchTool): HTMLElement {
    const group = el('div', { class: 'sketch-tool-group' })
    const chevron = el('button', {
      class: 'sketch-tool-chevron',
      title: L('다른 도구', 'More tools'),
      'aria-haspopup': 'menu',
      html: icon('chevron.down'),
    })
    on(chevron, 'click', () => openMenu(chevron, tools))
    group.append(toolButton(shown), chevron)
    return group
  }

  function openMenu(anchor: HTMLElement, tools: SketchTool[]) {
    const scrim = el('div', { class: 'scrim' })
    const menu = el('div', { class: 'menu sketch-tool-menu', role: 'menu' })
    for (const tool of tools) {
      const entry = toolEntry(tool)
      const item = el('button', { role: 'menuitem', 'aria-checked': String(store.sketch.tool === tool) }, [
        el('span', { class: 'menu-icon', html: figmaIcon(tool) }),
        el('span', { class: 'menu-label', text: entry.label }),
        el('span', { class: 'menu-key', text: entry.key }),
      ])
      on(item, 'click', () => {
        close()
        actions.setTool(tool)
      })
      menu.append(item)
    }
    const close = () => {
      scrim.remove()
      menu.remove()
    }
    on(scrim, 'pointerdown', close)
    document.body.append(scrim)
    place(menu, anchor)
  }

  function update() {
    clear(node)
    node.style.display = store.reader.drawing ? '' : 'none'
    if (!store.reader.drawing) return
    const chosen = store.sketch.tool
    node.append(
      toolButton('select'),
      toolButton('frame'),
      grouped(SHAPE_TOOLS, store.sketch.lastShape),
      grouped(INK_TOOLS, store.sketch.lastInk),
      toolButton('text'),
      el('div', { class: 'sketch-rack-divider' }),
    )
    const undo = el('button', { class: 'sketch-tool', title: L('되돌리기 (⌘Z)', 'Undo (⌘Z)'), html: icon('arrow.uturn.backward') })
    const redo = el('button', { class: 'sketch-tool', title: L('다시 하기 (⇧⌘Z)', 'Redo (⇧⌘Z)'), html: icon('arrow.uturn.forward') })
    on(undo, 'click', actions.undo)
    on(redo, 'click', actions.redo)
    node.append(undo, redo)

    // The pressed square: the button of the tool, or of the group holding it.
    for (const button of node.querySelectorAll<HTMLElement>('button.sketch-tool[data-tool]')) {
      const tool = button.dataset.tool as SketchTool
      const pressed = tool === chosen
        || (SHAPE_TOOLS.includes(tool) && SHAPE_TOOLS.includes(chosen))
        || (INK_TOOLS.includes(tool) && INK_TOOLS.includes(chosen))
      button.setAttribute('aria-pressed', String(pressed))
    }
  }

  update()
  return { node, update }
}
