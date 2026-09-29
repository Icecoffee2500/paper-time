/**
 * MathJax, set up once for everything either build sets: a note's formulas,
 * the `$…$` in a text card, the card that follows the caret. The Mac runs
 * this very file inside JavaScriptCore — `Scripts/mathjax-bundle.sh` bundles
 * it into `App/Resources/MathJax.js` — so both builds set a formula with the
 * same engine, the same packages and the same numbers.
 *
 * TeX in, SVG out, no DOM (the lite adaptor), no fonts to load (the glyphs
 * are paths). Everything amsmath has is here: `align`, `gather`, `multline`,
 * `cases`, the matrices, `split`, `\tag`, `\label` and `\eqref`.
 *
 * Numbers are amsmath's. An `equation` takes one, and so does each line of an
 * `align` or a `gather`; the starred forms and `$$…$$` do not; `\tag` writes
 * its own and `\notag` takes one away. A note counts from its top the way a
 * paper does, so a formula is set with the count it starts from and the
 * labels it refers to (`numberFormulas`), and answers with the count it
 * leaves and the labels it wrote.
 *
 * A formula MathJax cannot set — half typed, or with a command it does not
 * know — comes back as null, never as an error drawn in red: the note shows
 * what was typed instead, quietly.
 */
import { mathjax } from 'mathjax-full/js/mathjax.js'
import { TeX } from 'mathjax-full/js/input/tex.js'
import { SVG } from 'mathjax-full/js/output/svg.js'
import { liteAdaptor } from 'mathjax-full/js/adaptors/liteAdaptor.js'
import { RegisterHTMLHandler } from 'mathjax-full/js/handlers/html.js'
import { AllPackages } from 'mathjax-full/js/input/tex/AllPackages.js'
import { Label } from 'mathjax-full/js/input/tex/Tags.js'

/** What setting a formula gives back. */
export interface SetFormula {
  /** MathJax's SVG, `currentColor` and all. */
  svg: string
  /** The count after this formula: what the next one starts from. */
  next: number
  /** The labels this formula wrote, and the number each stands for. */
  labels: Record<string, string>
}

/**
 * Somewhere to keep what was set beyond this run: the Mac keeps it on disk
 * (`MathJaxEngine`), so a note opened again is not set again. Keys are the
 * setter's own; values are `SetFormula` as JSON.
 */
export interface MathStore {
  get(key: string): string | null | undefined
  set(key: string, value: string): void
}

export interface MathSetter {
  /** `width` is the room the formula has, in MathJax's pixels (`ex` = 8);
   *  only the environments that fill a line — `multline`, `flalign` — read it. */
  set(latex: string, display: boolean, start?: number, known?: Record<string, string>, width?: number): SetFormula | null
}

/**
 * The two packages that turn an error into a drawing are left out, and so is
 * the pair that fetches more packages at run time: there is nothing to fetch.
 */
export const PACKAGES = AllPackages.filter((name) => !['noerrors', 'noundefined', 'require', 'autoload'].includes(name))

/** Settings a note has no use for making different on the two builds. */
export const TEX_OPTIONS = {
  packages: PACKAGES,
  tags: 'ams',
  // A label written twice is LaTeX's warning, not its error; the second
  // formula is still set.
  ignoreDuplicateLabels: true,
} as const

const cacheLimit = 2000

/**
 * A setter. `fontCache` is `none` on the Mac, whose drawing of the SVG reads
 * paths and nothing else, and `local` in a window, where a glyph drawn twice
 * in one formula is written once.
 */
export function mathSetter(options: { fontCache: 'none' | 'local'; store?: MathStore }): MathSetter {
  const adaptor = liteAdaptor()
  RegisterHTMLHandler(adaptor)
  const tex = new TeX({ ...TEX_OPTIONS, formatError: (_jax: unknown, error: unknown) => { throw error } })
  const svg = new SVG({ fontCache: options.fontCache })
  const document = mathjax.document('', { InputJax: tex, OutputJax: svg })
  const cache = new Map<string, SetFormula | null>()

  function convert(latex: string, display: boolean, start: number, known: Record<string, string>, width: number | null): SetFormula | null {
    const tags = (tex as unknown as { parseOptions: { tags: TagsState } }).parseOptions.tags
    try {
      tags.reset(start)
      for (const [name, number] of Object.entries(known)) tags.allLabels[name] = new Label(number, tags.formatId(number))
      const node = document.convert(latex, width ? { display, containerWidth: width } : { display })
      const markup = adaptor.innerHTML(node)
      if (!markup.startsWith('<svg')) return null
      const labels: Record<string, string> = {}
      for (const [name, label] of Object.entries(tags.labels)) labels[name] = label.tag
      return { svg: markup, next: tags.allCounter, labels }
    } catch {
      return null
    }
  }

  return {
    set(latex, display, start = 0, known = {}, width) {
      const trimmed = latex.trim()
      if (!trimmed) return null
      // Rounded, so a pane moved by a pixel does not set the formula again.
      const room = width && fillsLine(trimmed) ? Math.max(80, Math.floor(width / 8) * 8) : null
      const key = `${display ? 'D' : 'I'}|${start}|${room ?? ''}|${signature(known)}|${trimmed}`
      if (cache.has(key)) return cache.get(key) ?? null
      const remember = (made: SetFormula | null) => {
        if (cache.size >= cacheLimit) cache.delete(cache.keys().next().value as string)
        cache.set(key, made)
        return made
      }
      const stored = options.store?.get(key)
      if (stored) {
        try {
          return remember(JSON.parse(stored) as SetFormula)
        } catch {
          // Unreadable: set it again below.
        }
      }
      const made = convert(trimmed, display, start, known, room)
      if (made) options.store?.set(key, JSON.stringify(made))
      return remember(made)
    },
  }
}

/** The part of MathJax's tag bookkeeping this reaches into. */
interface TagsState {
  reset(offset: number): void
  formatId(id: string): string
  allCounter: number
  allLabels: Record<string, InstanceType<typeof Label>>
  labels: Record<string, InstanceType<typeof Label>>
}

/** The known labels as one string, in a fixed order: part of a cache key. */
export function signature(known: Record<string, string>): string {
  return Object.keys(known).sort().map((name) => `${name}=${known[name]}`).join(',')
}

/**
 * Whether a formula can take a number of its own. Only then does the count
 * it starts from change how it looks — a note's hundred `$x$` are set once,
 * whatever is numbered above them.
 */
export function takesNumbers(latex: string): boolean {
  return /\\begin\s*\{(?:equation|align|alignat|gather|multline|flalign|eqnarray|xalignat|xxalignat)\}/.test(latex)
}

/** Whether a formula is laid out across the whole line it is given:
 *  a `multline` puts its last line at the right-hand edge, a `flalign` its
 *  columns at the two edges. */
export function fillsLine(latex: string): boolean {
  return /\\begin\s*\{(?:multline|flalign)\*?\}/.test(latex)
}

/** Whether a formula writes a label another may refer to. */
export function writesLabels(latex: string): boolean {
  return /\\label\s*\{/.test(latex)
}

/** The labels a formula refers to, in the order it names them. */
export function referencedLabels(latex: string): string[] {
  const names: string[] = []
  for (const match of latex.matchAll(/\\(?:eq)?ref\s*\{([^{}]*)\}/g)) {
    const name = match[1].trim()
    if (name && !names.includes(name)) names.push(name)
  }
  return names
}

/** What a formula is set with, once the note around it is counted. */
export interface Numbered {
  start: number
  known: Record<string, string>
}

/**
 * Counts a note's formulas from the top. Each is given the count it starts
 * from — zero for one that takes no number, so it is set once whatever is
 * above it — and the labels it refers to, which may be written below it: a
 * paper refers forward as often as back, and LaTeX, run twice, resolves both.
 * Only the formulas that number or label anything are set to find out.
 */
export function numberFormulas(
  formulas: readonly { latex: string; display: boolean }[],
  set: MathSetter['set'],
): Numbered[] {
  let count = 0
  const labels: Record<string, string> = {}
  const starts: number[] = []
  for (const formula of formulas) {
    const numbers = takesNumbers(formula.latex)
    starts.push(numbers ? count : 0)
    if (!numbers && !writesLabels(formula.latex)) continue
    // What it refers to, as far as the note has got — its numbers do not
    // depend on it, and the labels it writes do not either.
    const known = knownTo(formula.latex, labels)
    const made = set(formula.latex, formula.display, numbers ? count : 0, known)
    if (!made) continue
    if (numbers) count = made.next
    Object.assign(labels, made.labels)
  }
  return formulas.map((formula, index) => ({ start: starts[index], known: knownTo(formula.latex, labels) }))
}

function knownTo(latex: string, labels: Record<string, string>): Record<string, string> {
  const known: Record<string, string> = {}
  for (const name of referencedLabels(latex)) if (name in labels) known[name] = labels[name]
  return known
}
