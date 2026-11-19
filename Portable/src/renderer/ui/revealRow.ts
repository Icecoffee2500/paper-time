/**
 * The list going to a paper chosen away from it (`revealPaper`): the ask is
 * taken once by whichever list is showing, and not at all once it is a
 * moment old — a list drawn later for another shelf would act on it.
 */
import { store } from '../state.js'

/** The paper to go to, when there is an ask this list has not taken yet. */
export function pendingReveal(taken: number): { paper: string; serial: number } | null {
  const ask = store.revealRequest
  if (!ask || ask.serial === taken || Date.now() - ask.at > 2000) return null
  return ask
}

/**
 * Brings a row to the middle of its scrolling box — unless it is in full
 * view already, where moving the list would only lose the reader's place.
 *
 * At once, not smoothly, and in the same turn the row was drawn: the board
 * is drawn again a moment later (the paper's «opened» stamp comes back from
 * the main process) and keeps whatever scroll it finds — a smooth scroll
 * just begun was kept at its start, and a row held for the next frame was a
 * row no longer in the page.
 */
export function centreRow(scroll: HTMLElement, row: HTMLElement): boolean {
  // Not laid out (a list not on screen): left for when it is.
  if (!row.isConnected || scroll.clientHeight === 0) return false
  const box = scroll.getBoundingClientRect()
  const at = row.getBoundingClientRect()
  if (at.top >= box.top + 4 && at.bottom <= box.bottom - 4) return true
  scroll.scrollTop = Math.max(0, scroll.scrollTop + (at.top - box.top) - (box.height - at.height) / 2)
  return true
}
