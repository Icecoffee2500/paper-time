/**
 * A sheet over the window is modal: while one is up, Tab stays inside it and
 * no key reaches the window under it — not the reader, not the drawing. The
 * sheets close themselves on Escape; the window used to hear the same Escape
 * a moment later and let go of the drawing's selection too.
 *
 * Every sheet stands in a `.sheet-backdrop`. The key is claimed on its way
 * down, before any sheet's own listener has a chance to close the sheet —
 * after which the window could no longer tell a sheet had been there.
 */
const claimed = new WeakSet<Event>()

export function isSheetOpen(): boolean {
  return document.querySelector('.sheet-backdrop') !== null
}

/** Whether a key arrived while a sheet was up — and so is the sheet's. */
export function isSheetKey(event: Event): boolean {
  return claimed.has(event)
}

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"]), a[href]'

export function installSheetModality() {
  window.addEventListener('keydown', (event: KeyboardEvent) => {
    const backdrops = document.querySelectorAll<HTMLElement>('.sheet-backdrop')
    const top = backdrops[backdrops.length - 1]
    if (!top) return
    claimed.add(event)
    if (event.key !== 'Tab') return
    // Round the sheet's own controls, and nowhere under it.
    const stops = [...top.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((node) => node.offsetParent !== null)
    if (stops.length === 0) return
    const at = stops.indexOf(document.activeElement as HTMLElement)
    const next = event.shiftKey ? (at <= 0 ? stops.length - 1 : at - 1) : (at < 0 || at === stops.length - 1 ? 0 : at + 1)
    event.preventDefault()
    stops[next].focus()
  }, true)
}
