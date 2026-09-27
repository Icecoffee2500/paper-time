/**
 * Pages drawn small, for the page grid — two at a time, kept for a while.
 *
 * The grid asks for a thumbnail as each cell comes near, and a flick through
 * a long paper asks for a hundred at once. Each was a full render started on
 * the spot with nothing to stop it: the popup closed, and the renders went on.
 * Now they wait their turn, two run at once, what is waiting is let go of
 * when the grid closes, and the last few dozen drawn are kept — reopening
 * the grid on the same paper draws nothing again.
 */
const RUNNING_AT_ONCE = 2
const KEPT = 80

type Make = () => Promise<HTMLCanvasElement | null>

export class ThumbnailQueue {
  private readonly kept = new Map<string, HTMLCanvasElement>()
  private waiting: { key: string; make: Make; resolve: (canvas: HTMLCanvasElement | null) => void }[] = []
  private running = 0

  draw(key: string, make: Make): Promise<HTMLCanvasElement | null> {
    const known = this.kept.get(key)
    if (known) {
      // Most recently used goes last; the first is the next to go.
      this.kept.delete(key)
      this.kept.set(key, known)
      return Promise.resolve(known)
    }
    return new Promise((resolve) => {
      this.waiting.push({ key, make, resolve })
      this.next()
    })
  }

  /** Everything waiting is let go of: the grid that wanted it has closed. */
  cancel() {
    for (const one of this.waiting.splice(0)) one.resolve(null)
  }

  /** How many are waiting and running — for a test. */
  get pending(): { waiting: number; running: number; kept: number } {
    return { waiting: this.waiting.length, running: this.running, kept: this.kept.size }
  }

  private next() {
    while (this.running < RUNNING_AT_ONCE && this.waiting.length > 0) {
      const job = this.waiting.shift()!
      this.running += 1
      void job.make()
        .catch(() => null)
        .then((canvas) => {
          if (canvas) {
            this.kept.set(job.key, canvas)
            while (this.kept.size > KEPT) this.kept.delete(this.kept.keys().next().value!)
          }
          job.resolve(canvas)
        })
        .finally(() => {
          this.running -= 1
          this.next()
        })
    }
  }
}

export const thumbnails = new ThumbnailQueue()
