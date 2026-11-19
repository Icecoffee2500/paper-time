/**
 * The inspector, docked at the window's right or floating over it (1.1).
 *
 * Docked, it stands in the row as it always did, with «띄우기» and its × over
 * its top corner. Floating, it is a card over the window — the popover's
 * material and shadow, dragged by its head, resized from its bottom-right
 * corner, kept inside the window — and the panes have its room back: with
 * four panes in the row it is still a click away (the user, 2026-11-18). The
 * same inspector either way: the paper in focus, on the toolbar's tab.
 */
import { el, on } from '../dom.js'
import { icon } from '../icons.js'
import { L } from '../../shared/lang.js'
import { placeFloat, type InspectorPlace } from '../../shared/paneModel.js'

export interface InspectorFrameActions {
  /** Where it floats, as kept. */
  place: () => InspectorPlace
  /** Moved or resized: the frame as it is now, and whether the hand let go. */
  moved: (place: InspectorPlace, done: boolean) => void
  float: () => void
  dock: () => void
  close: () => void
  /** The panes' own box, which the panel is kept inside. */
  area: () => DOMRect
}

export interface InspectorFrame {
  /** The panel up, with the inspector in it. */
  show: () => void
  /** The panel put away; the inspector goes back to the row when the row asks for it. */
  hide: () => void
  /** The panel is up. */
  showing: () => boolean
}

export function buildInspectorFrame(inspector: HTMLElement, actions: InspectorFrameActions): InspectorFrame {
  // ---- docked: «띄우기» and the × over the top corner
  const floatButton = el('button', {
    class: 'pane-float',
    title: L('띄우기 — 창 위에 떠 있게 해요', 'Float — keep it over the window'),
    'aria-label': L('띄우기', 'Float'),
    html: icon('macwindow.on.rectangle'),
  })
  on(floatButton, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.float()
  })
  const closeDocked = el('button', { class: 'pane-close', title: L('정보 패널 닫기', 'Close the Inspector'), 'aria-label': L('정보 패널 닫기', 'Close the Inspector'), html: icon('xmark') })
  on(closeDocked, 'click', (event: MouseEvent) => {
    event.stopPropagation()
    actions.close()
  })
  inspector.append(el('div', { class: 'pane-corner inspector-corner' }, [floatButton, closeDocked]))

  // ---- floating: a head to drag, the panel, a corner to resize
  const dock = el('button', { class: 'inspector-float-dock', title: L('오른쪽에 붙이기', 'Dock at the right') }, [
    el('span', { html: icon('sidebar.right') }),
    el('span', { text: L('붙이기', 'Dock') }),
  ])
  on(dock, 'click', () => actions.dock())
  const closeFloating = el('button', { class: 'pane-close', title: L('정보 패널 닫기', 'Close the Inspector'), 'aria-label': L('정보 패널 닫기', 'Close the Inspector'), html: icon('xmark') })
  on(closeFloating, 'click', () => actions.close())
  const head = el('div', { class: 'inspector-float-head', title: L('끌어서 옮기기', 'Drag to move') }, [
    el('span', { class: 'inspector-float-title', text: L('정보 패널', 'Inspector') }),
    dock,
    closeFloating,
  ])
  const body = el('div', { class: 'inspector-float-body' })
  const grip = el('div', { class: 'inspector-float-grip', title: L('끌어서 크기 바꾸기', 'Drag to resize'), 'aria-hidden': 'true' })
  const layer = el('div', { class: 'inspector-float', role: 'dialog', 'aria-label': L('정보 패널', 'Inspector') }, [head, body, grip])
  for (const button of [dock, closeFloating]) on(button, 'pointerdown', (event: PointerEvent) => event.stopPropagation())

  /** The frame kept inside the panes, and the panel put there. */
  function settle(place: InspectorPlace): InspectorPlace {
    const area = actions.area()
    const placed = placeFloat(place, { width: area.width, height: area.height })
    layer.style.left = `${area.left + placed.x}px`
    layer.style.top = `${area.top + placed.y}px`
    layer.style.width = `${placed.width}px`
    layer.style.height = `${placed.height}px`
    return placed
  }

  function show() {
    if (inspector.parentElement !== body) body.append(inspector)
    inspector.style.flex = '1 1 auto'
    inspector.style.width = ''
    const arriving = !layer.isConnected
    if (arriving) document.body.append(layer)
    layer.classList.toggle('arriving', arriving)
    settle(actions.place())
  }

  function hide() {
    layer.remove()
  }

  /** A drag from the head or the corner: the frame follows the hand, inside the window. */
  function follow(from: PointerEvent, change: (start: InspectorPlace, dx: number, dy: number) => InspectorPlace) {
    from.preventDefault()
    const target = from.currentTarget as HTMLElement
    target.setPointerCapture(from.pointerId)
    const start = settle(actions.place())
    layer.classList.add('moving')
    let latest = start
    const move = (event: PointerEvent) => {
      latest = settle(change(start, event.clientX - from.clientX, event.clientY - from.clientY))
      actions.moved(latest, false)
    }
    const up = () => {
      layer.classList.remove('moving')
      target.removeEventListener('pointermove', move)
      target.removeEventListener('pointerup', up)
      target.removeEventListener('pointercancel', up)
      actions.moved(latest, true)
    }
    target.addEventListener('pointermove', move)
    target.addEventListener('pointerup', up)
    target.addEventListener('pointercancel', up)
  }

  on(head, 'pointerdown', (event: PointerEvent) => {
    if (event.button !== 0) return
    follow(event, (start, dx, dy) => ({ ...start, x: start.x + dx, y: start.y + dy }))
  })
  on(grip, 'pointerdown', (event: PointerEvent) => {
    if (event.button !== 0) return
    follow(event, (start, dx, dy) => ({ ...start, width: start.width + dx, height: start.height + dy }))
  })
  // A window made smaller keeps the panel inside it.
  window.addEventListener('resize', () => {
    if (layer.isConnected) settle(actions.place())
  })

  return { show, hide, showing: () => layer.isConnected }
}
