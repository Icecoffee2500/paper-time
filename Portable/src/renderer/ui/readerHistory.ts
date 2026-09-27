/**
 * Where the reader stood before a link was followed, to come back to. The
 * Mac's PDF view keeps the same history, and Back walks it before it walks
 * the papers (`goBackInHistory`): follow a citation to the references, and
 * Back is the sentence it came from.
 */

/** Where the reader stands in a paper: its page, and how far down the scroll. */
export interface DocumentPlace {
  page: number
  top: number
  of: number
}

export class DocumentHistory {
  private back: DocumentPlace[] = []
  private forward: DocumentPlace[] = []

  get canGoBack(): boolean {
    return this.back.length > 0
  }

  get canGoForward(): boolean {
    return this.forward.length > 0
  }

  /** A jump from here: what lay ahead is forgotten. */
  leave(here: DocumentPlace) {
    this.back.push(here)
    this.forward = []
  }

  /** One step back, from `here`: where to go, or null. */
  goBack(here: DocumentPlace): DocumentPlace | null {
    const place = this.back.pop()
    if (!place) return null
    this.forward.push(here)
    return place
  }

  goForward(here: DocumentPlace): DocumentPlace | null {
    const place = this.forward.pop()
    if (!place) return null
    this.back.push(here)
    return place
  }

  clear() {
    this.back = []
    this.forward = []
  }
}

/**
 * The scroll that puts a place back: by the fraction of the way down when
 * the paper has changed height since — a page laid out half as wide is laid
 * out half as tall, so the pixel it was at is a different place in the
 * paper — and by the pixel when it has not, which is most of the time.
 */
export function scrollFor(place: { top: number; of: number }, height: number): number {
  const moved = place.of > 0 && Math.abs(height - place.of) > 1
  return moved ? Math.round(place.top * (height / place.of)) : place.top
}
