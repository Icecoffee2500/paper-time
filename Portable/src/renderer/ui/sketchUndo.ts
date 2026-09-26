/**
 * Undo for the drawing layer.
 *
 * One stack for the whole reader, holding a page's elements and strokes as
 * they were and as they became. Wholesale rather than per-operation, which is
 * what `SketchUndo` on the Mac does: a page's worth of shapes is small, and a
 * snapshot cannot get out of step with the thing it describes the way a
 * reversed operation can.
 *
 * A step is usually one page. A selection carried to another page is two —
 * the page it left and the page it landed on — and one ⌘Z brings it back,
 * which is why `undo` hands back the first page's snapshot with the others
 * riding along in `also`.
 */
import type { SketchElement } from '../../shared/sketch.js'
import type { InkStroke } from '../../shared/ink.js'
import type { Mark } from '../../shared/marks.js'

export interface Snapshot {
  pageIndex: number
  elements: SketchElement[]
  strokes: InkStroke[]
  /**
   * A step of the highlights and underlines rather than of the drawing: the
   * page's marks as they were, and nothing else about the page is touched —
   * writing its drawing back would claim a page this build was never asked
   * to draw on (and move a Mac's PencilKit file aside).
   */
  marks?: Mark[]
  /** The paper the step was taken in. An undo is put back into that paper or
   *  not at all — never into whichever paper happens to be open by then. */
  paperID?: string
  /** The other pages this same step changed, when it changed more than one. */
  also?: Snapshot[]
}

interface Step {
  before: Snapshot[]
  after: Snapshot[]
}

const LIMIT = 200

export class SketchUndo {
  private done: Step[] = []
  private undone: Step[] = []
  /** Which paper a step belongs to, asked when it is recorded. */
  paperOf: () => string | null = () => null

  /** One step, of one page or several; the lists line up page for page. */
  record(before: Snapshot | Snapshot[], after: Snapshot | Snapshot[]) {
    const paperID = this.paperOf() ?? undefined
    const stamp = (list: Snapshot[]) => list.map((one) => (one.paperID || !paperID ? one : { ...one, paperID }))
    const from = stamp(Array.isArray(before) ? before : [before])
    const to = stamp(Array.isArray(after) ? after : [after])
    if (from.length === 0) return
    this.done.push({ before: from, after: to })
    if (this.done.length > LIMIT) this.done.shift()
    this.undone = []
  }

  get canUndo(): boolean {
    return this.done.length > 0
  }

  get canRedo(): boolean {
    return this.undone.length > 0
  }

  undo(): Snapshot | null {
    const step = this.done.pop()
    if (!step) return null
    this.undone.push(step)
    return bundled(step.before)
  }

  redo(): Snapshot | null {
    const step = this.undone.pop()
    if (!step) return null
    this.done.push(step)
    return bundled(step.after)
  }

  clear() {
    this.done = []
    this.undone = []
  }
}

function bundled(snapshots: Snapshot[]): Snapshot {
  const [first, ...rest] = snapshots
  return rest.length === 0 ? first : { ...first, also: rest }
}

/** Every page a snapshot covers, in order. */
export function pagesOf(snapshot: Snapshot): Snapshot[] {
  return [snapshot, ...(snapshot.also ?? [])]
}

export function snapshot(pageIndex: number, elements: SketchElement[], strokes: InkStroke[]): Snapshot {
  return {
    pageIndex,
    elements: elements.map((element) => element.copy()),
    strokes: strokes.map((stroke) => stroke.translated({ x: 0, y: 0 })),
  }
}

/** A page's marks as a step of their own (see `Snapshot.marks`). */
export function marksSnapshot(pageIndex: number, marks: Mark[], paperID?: string): Snapshot {
  return {
    pageIndex,
    elements: [],
    strokes: [],
    marks: marks.map((mark) => ({ ...mark, quads: mark.quads.map((quad) => [...quad]), color: [...mark.color] as [number, number, number] })),
    ...(paperID ? { paperID } : {}),
  }
}
