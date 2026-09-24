/**
 * The placeholders of the snippets being filled in (tabstops_state_field.ts),
 * as the Mac engine keeps them in `LSTabstopState`.
 */
import { ChangeSet } from './changes.js'
import { clamped, isEmpty, type Span } from './text.js'

export class TabstopState {
  constructor(
    public groups: Span[][] = [],
    public colors: number[] = [],
    public index = 0,
    public nextColor = 0,
  ) {}

  copy(): TabstopState {
    return new TabstopState(this.groups.map((g) => g.map((r) => ({ ...r }))), [...this.colors], this.index, this.nextColor)
  }

  /**
   * `TabstopGroup.map`: marks inclusive at both ends; an empty one that ends up
   * inside replaced text is dropped (`MapMode.TrackDel`).
   */
  map(changes: ChangeSet) {
    if (changes.isEmpty) return
    this.groups = this.groups.map((group) => {
      const out: Span[] = []
      for (const range of group) {
        if (isEmpty(range)) {
          const from = changes.map(range.from, -1, 'trackDel')
          if (from === null) continue
          const to = changes.mapped(range.from, 1)
          if (to < from) continue
          out.push({ from, to })
          continue
        }
        const from = changes.mapped(range.from, -1)
        const to = changes.mapped(range.to, 1)
        if (from > to) continue
        out.push({ from, to })
      }
      return out
    })
  }

  /** The selection-change rule (§6.3). */
  select(selection: Span[]) {
    let found = this.groups.findIndex((group) =>
      selection.every((r) => group.some((g) => g.from <= r.from && g.to >= r.to)))
    if (found === -1) found = this.groups.length
    this.index = found
    if (this.groups.length <= 1 || this.index >= this.groups.length - 1) this.clear()
  }

  /** `getNextTabstopColor`. */
  takeColor(): number {
    const color = this.nextColor % 3
    this.nextColor += 1
    return color
  }

  /** Every range cut to a text of `count` units. */
  clamp(count: number) {
    this.groups = this.groups.map((group) => group.map((r) => clamped(r, count)))
  }

  clear() {
    this.groups = []
    this.colors = []
    this.index = 0
    this.nextColor = 0
  }
}
