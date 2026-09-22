/**
 * A selection's rectangles, grouped into the lines they came from.
 *
 * `getClientRects()` hands back one rectangle per text run, and a single line
 * of a paper is a dozen of them: the typesetter kerned a word apart, a title
 * is italic and so its own font, a citation is a superscript. A highlight
 * drawn straight from those has a gap at every seam, so the runs sitting on
 * one line are merged into the line they belong to.
 *
 * Knowing when to stop merging is the whole of this file. The rule that came
 * before let a line's band grow as it swallowed runs, which meant a band that
 * had taken in one tall run could reach the line below — and reaching it once
 * was enough, because the band then reached further still. Measured in the
 * window on a real paper: sixty runs sitting on thirty-four baselines came
 * back as five "lines", one of them eight and a half times the height of the
 * text, and eight lines of a reference list came back as one. That is the
 * lozenge drawn across half a column that a reader sent in a screenshot. A
 * run a quarter taller than the text was enough to start it, which is an
 * inline formula, a heading dragged into the selection, or any word at all on
 * a page whose text layer came out of an OCR pass.
 *
 * So the lines are made from the ordinary runs, and a tall one is handled
 * apart:
 *
 * - A line matches against **one run's box, never a union** — the box of the
 *   run that started it. A band that cannot grow cannot chain.
 * - A run much taller than the rest of the selection does not start a line
 *   and does not set a line's height. It widens the lines it stands across,
 *   which is what a drop cap is: not a line of its own, but the first two
 *   lines reaching further left.
 * - Unless it stands across none of them — a heading pulled into the drag —
 *   and then it is a line in its own right, at its own height.
 *
 * What that costs, knowingly: a tall thing standing across several lines is
 * covered by those lines and no further, so the top of a big summation sign in
 * a displayed equation is left bare. The alternative is a line that grows to
 * cover whatever leans into it, and a line that grows is the whole of the bug
 * this replaced. A band that stops short is a smaller wrong than a band that
 * swallows the column.
 *
 * The geometry these rules are tuned against is the text layer's, where a
 * run's box is its em box: it hangs mostly above the baseline (the ascent)
 * and only a little below (the descent). That is why a tall run reaches up
 * into the line above far more readily than down into the line below.
 */

/** A rectangle, as `DOMRect` and the page's own geometry both give one. */
export interface RunBox {
  left: number
  right: number
  top: number
  bottom: number
}

export type TextLine = RunBox

/**
 * How much taller than the selection's own text a run can be before it stops
 * being text and starts being furniture.
 *
 * Measured in the window: two runs on one line of an ordinary paper came back
 * 15.5 and 13 points tall — a roman beside an italic — so the allowance has
 * to sit well clear of a fifth. A drop cap, a heading or a displayed formula
 * is half again as tall or more.
 */
const TALL = 1.6

const height = (box: RunBox) => box.bottom - box.top

/** The middle value, taking the lower of the two when there is no middle —
 *  so a pair of runs is spoken for by the shorter. */
function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor((sorted.length - 1) / 2)] ?? 0
}

function overlapOf(a: RunBox, b: RunBox): number {
  return Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top)
}

/**
 * How much of the shorter box has to lie inside the taller one for the two to
 * be on the same line.
 *
 * Measured rather than picked, on the boxes this is actually given — the text
 * bands, trimmed by the caller. Across four papers: 6,081 pairs of runs the
 * text layer itself says are on one line (the second starts where the first
 * ended) against 1,095 pairs it says are a line apart (the second starts back
 * at the left, lower down).
 *
 *     on one line          a line apart
 *      5%  0.24–0.81       90%  −0.15–0.20
 *     10%  0.64–0.92       99%  −0.05–0.48
 *     50%  1.00            max   0.21–0.86
 *
 * Three fifths sits in the gap: it keeps nine in ten of the pairs that belong
 * together and holds the next line out in ninety-nine cases in a hundred.
 * Raising it starts splitting lines that belong together, which shows as a
 * seam through a highlight; lowering it gains nothing. And checked the other
 * way, against 3,204 pairs whose untrimmed boxes overlap by nine tenths and
 * so are certainly one line: it splits none of them — the small runs that a
 * trim could in principle strand are not there to strand, since the text
 * layer gives 6,465 runs in 6,471 the same box height.
 *
 * What matters more than the number is that it is fixed. The rule this
 * replaced measured against a line's running total, so a band that had taken
 * in one tall run could reach the line below, and then the line after that.
 */
const SHARED = 0.6

/**
 * Whether a run belongs to a line already started.
 *
 * Generous enough for the things that sit off the line and still belong to it
 * — a superscript rides above it, a subscript below — and mean enough to keep
 * the line beneath out.
 */
function onTheSameLine(band: RunBox, run: RunBox): boolean {
  return overlapOf(band, run) >= Math.min(height(band), height(run)) * SHARED
}

/** Groups runs into lines, matching each against the run that started its
 *  line and never against what the line has grown into. */
function group(runs: RunBox[]): RunBox[][] {
  const sorted = [...runs].sort((a, b) => a.top - b.top || a.left - b.left)
  const lines: { band: RunBox; runs: RunBox[] }[] = []
  for (const run of sorted) {
    const line = lines.find((one) => onTheSameLine(one.band, run))
    if (line) line.runs.push(run)
    else lines.push({ band: run, runs: [run] })
  }
  return lines.map((line) => line.runs)
}

function boxAround(runs: RunBox[]): TextLine {
  // Folded rather than spread: a spread of a hundred thousand arguments is a
  // stack overflow, and a selection is not obliged to be small.
  //
  // The first box is copied field by field and never spread. What arrives here
  // is a `DOMRect`, whose sides are getters on its prototype, so `{...rect}`
  // is `{}` — and a fold that starts from `{}` makes every side `NaN`, which
  // is then written into the reader's PDF as a quad no parser will read.
  const first = runs[0]
  return runs.reduce<TextLine>((box, run) => ({
    left: Math.min(box.left, run.left),
    right: Math.max(box.right, run.right),
    top: Math.min(box.top, run.top),
    bottom: Math.max(box.bottom, run.bottom),
  }), { left: first.left, right: first.right, top: first.top, bottom: first.bottom })
}

/** One rectangle per line of text, in reading order. */
export function linesFromRuns(runs: readonly RunBox[]): TextLine[] {
  if (runs.length === 0) return []
  // Tall against the selection's own text, not against a fixed size: a drag
  // over nothing but a title is all large runs, and every one of them is
  // ordinary there.
  const ceiling = median(runs.map(height)) * TALL
  const text = runs.filter((run) => height(run) <= ceiling)
  const furniture = runs.filter((run) => height(run) > ceiling)

  const lines = group(text).map(boxAround)
  const orphans: RunBox[] = []
  for (const run of furniture) {
    // Measured against the line's own height, so that standing across it
    // counts and merely touching its ascenders does not.
    const across = lines.filter((line) => overlapOf(line, run) >= height(line) * SHARED)
    if (across.length === 0) {
      orphans.push(run)
      continue
    }
    for (const line of across) {
      line.left = Math.min(line.left, run.left)
      line.right = Math.max(line.right, run.right)
    }
  }
  // A tall run standing across nothing is a line of its own — a heading the
  // drag ran into, which has to be marked like anything else.
  lines.push(...group(orphans).map(boxAround))
  return lines.sort((a, b) => a.top - b.top || a.left - b.left)
}
