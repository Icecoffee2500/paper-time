/**
 * Undo for the drawing layer.
 *
 * One stack for the whole reader, holding a page's elements and strokes as
 * they were and as they became. Wholesale rather than per-operation, which is
 * what `SketchUndo` on the Mac does: a page's worth of shapes is small, and a
 * snapshot cannot get out of step with the thing it describes the way a
 * reversed operation can.
 */
import type { SketchElement } from '../../shared/sketch.js'
import type { InkStroke } from '../../shared/ink.js'

export interface Snapshot {
  pageIndex: number
  elements: SketchElement[]
  strokes: InkStroke[]
}

interface Step {
  before: Snapshot
  after: Snapshot
}

const LIMIT = 200

export class SketchUndo {
  private done: Step[] = []
  private undone: Step[] = []

  record(before: Snapshot, after: Snapshot) {
    this.done.push({ before, after })
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
    return step.before
  }

  redo(): Snapshot | null {
    const step = this.undone.pop()
    if (!step) return null
    this.done.push(step)
    return step.after
  }

  clear() {
    this.done = []
    this.undone = []
  }
}

export function snapshot(pageIndex: number, elements: SketchElement[], strokes: InkStroke[]): Snapshot {
  return {
    pageIndex,
    elements: elements.map((element) => element.copy()),
    strokes: strokes.map((stroke) => stroke.translated({ x: 0, y: 0 })),
  }
}
